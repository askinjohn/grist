import Foundation
import SQLite3

@MainActor
class Database {
    static let shared = Database()
    var db: OpaquePointer?
    
    private init() {
        openDatabase()
        createTables()
    }
    
    private func openDatabase() {
        let dbPath = QuernPaths.meetingsDB.path
        
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("Error opening database meetings.db at path \(dbPath)")
        } else {
            print("Successfully opened database meetings.db at \(dbPath)")
            // Safe for concurrent Quern app + MCP writers.
            execute("PRAGMA journal_mode=WAL;")
            execute("PRAGMA busy_timeout=5000;")
            execute("PRAGMA synchronous=NORMAL;")
        }
    }
    
    private func createTables() {
        let createTableString = """
        CREATE TABLE IF NOT EXISTS meetings (
            id TEXT PRIMARY KEY,
            title TEXT,
            timestamp REAL,
            manual_notes TEXT,
            transcript TEXT,
            summary TEXT,
            template TEXT,
            group_name TEXT DEFAULT '',
            is_deleted INTEGER DEFAULT 0,
            duration_seconds INTEGER DEFAULT 0
        );
        """
        execute(createTableString)
        
        let createTemplatesTable = """
        CREATE TABLE IF NOT EXISTS templates (
            id TEXT PRIMARY KEY,
            name TEXT,
            prompt TEXT
        );
        """
        execute(createTemplatesTable)
        
        let createChatTable = """
        CREATE TABLE IF NOT EXISTS chat_messages (
            id TEXT PRIMARY KEY,
            group_name TEXT,
            role TEXT,
            content TEXT,
            timestamp REAL,
            conversation_id TEXT
        );
        """
        execute(createChatTable)

        let createConversationsTable = """
        CREATE TABLE IF NOT EXISTS chat_conversations (
            id TEXT PRIMARY KEY,
            scope_key TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT 'New chat',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """
        execute(createConversationsTable)
        
        // Column name must match saveChunk/fetchChunks (`text_chunk`).
        let createChunksTable = """
        CREATE TABLE IF NOT EXISTS chunks (
            id TEXT PRIMARY KEY,
            meeting_id TEXT,
            text_chunk TEXT,
            embedding BLOB
        );
        """
        execute(createChunksTable)

        let createFoldersTable = """
        CREATE TABLE IF NOT EXISTS folders (
            name TEXT PRIMARY KEY,
            created_at REAL
        );
        """
        execute(createFoldersTable)

        let createTasksTable = """
        CREATE TABLE IF NOT EXISTS tasks (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            notes TEXT DEFAULT '',
            source_meeting_id TEXT,
            source_title TEXT,
            status TEXT DEFAULT 'open',
            created_at REAL,
            completed_at REAL,
            is_deleted INTEGER DEFAULT 0
        );
        """
        execute(createTasksTable)
        
        // Safely migrate existing databases
        execute("ALTER TABLE meetings ADD COLUMN group_name TEXT DEFAULT '';")
        execute("ALTER TABLE meetings ADD COLUMN is_deleted INTEGER DEFAULT 0;")
        execute("ALTER TABLE meetings ADD COLUMN duration_seconds INTEGER DEFAULT 0;")
        execute("ALTER TABLE chat_messages ADD COLUMN conversation_id TEXT;")
        execute("ALTER TABLE chat_messages ADD COLUMN sources TEXT;")
        execute("ALTER TABLE chat_conversations ADD COLUMN is_pinned INTEGER DEFAULT 0;")
        migrateLegacyChatThreads()
        migrateLegacyItemScopeKeys()
    }

    /// Older builds stored per-item chats as bare meeting id; now we use `item:<id>`.
    private func migrateLegacyItemScopeKeys() {
        // Conversations whose scope is a meeting id (no prefix)
        let q = """
        UPDATE chat_conversations
        SET scope_key = 'item:' || scope_key
        WHERE scope_key NOT LIKE 'item:%'
          AND scope_key NOT LIKE 'sel:%'
          AND scope_key != '__global__'
          AND length(scope_key) > 0;
        """
        _ = execute(q)
        let q2 = """
        UPDATE chat_messages
        SET group_name = 'item:' || group_name
        WHERE group_name NOT LIKE 'item:%'
          AND group_name NOT LIKE 'sel:%'
          AND group_name != '__global__'
          AND group_name IS NOT NULL
          AND group_name != ''
          AND length(group_name) > 8;
        """
        _ = execute(q2)
    }

    /// One-time: turn old single-thread `group_name` histories into conversations.
    private func migrateLegacyChatThreads() {
        // Already migrated if every message with content has a conversation_id,
        // or there are no messages without conversation_id.
        let need = """
        SELECT COUNT(*) FROM chat_messages
        WHERE conversation_id IS NULL OR conversation_id = '';
        """
        var stmt: OpaquePointer?
        var orphanCount = 0
        if sqlite3_prepare_v2(db, need, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                orphanCount = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        guard orphanCount > 0 else { return }

        // Distinct legacy group keys
        let groupsQ = """
        SELECT DISTINCT group_name FROM chat_messages
        WHERE (conversation_id IS NULL OR conversation_id = '')
          AND group_name IS NOT NULL AND group_name != '';
        """
        var gStmt: OpaquePointer?
        var groups: [String] = []
        if sqlite3_prepare_v2(db, groupsQ, -1, &gStmt, nil) == SQLITE_OK {
            while sqlite3_step(gStmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(gStmt, 0) {
                    groups.append(String(cString: c))
                }
            }
        }
        sqlite3_finalize(gStmt)

        for group in groups {
            let convId = UUID().uuidString
            // Title from first user message
            var title = "Chat"
            let titleQ = """
            SELECT content FROM chat_messages
            WHERE group_name = ? AND role = 'user'
            ORDER BY timestamp ASC LIMIT 1;
            """
            var tStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, titleQ, -1, &tStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(tStmt, 1, (group as NSString).utf8String, -1, nil)
                if sqlite3_step(tStmt) == SQLITE_ROW, let c = sqlite3_column_text(tStmt, 0) {
                    let raw = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !raw.isEmpty {
                        title = raw.count > 48 ? String(raw.prefix(48)) + "…" : raw
                    }
                }
            }
            sqlite3_finalize(tStmt)

            var minTs: Double = Date().timeIntervalSince1970
            var maxTs: Double = minTs
            let rangeQ = "SELECT MIN(timestamp), MAX(timestamp) FROM chat_messages WHERE group_name = ?;"
            var rStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, rangeQ, -1, &rStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(rStmt, 1, (group as NSString).utf8String, -1, nil)
                if sqlite3_step(rStmt) == SQLITE_ROW {
                    minTs = sqlite3_column_double(rStmt, 0)
                    maxTs = sqlite3_column_double(rStmt, 1)
                    if minTs == 0 { minTs = Date().timeIntervalSince1970 }
                    if maxTs == 0 { maxTs = minTs }
                }
            }
            sqlite3_finalize(rStmt)

            let insertConv = """
            INSERT OR IGNORE INTO chat_conversations (id, scope_key, title, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?);
            """
            var iStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, insertConv, -1, &iStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(iStmt, 1, (convId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(iStmt, 2, (group as NSString).utf8String, -1, nil)
                sqlite3_bind_text(iStmt, 3, (title as NSString).utf8String, -1, nil)
                sqlite3_bind_double(iStmt, 4, minTs)
                sqlite3_bind_double(iStmt, 5, maxTs)
                sqlite3_step(iStmt)
            }
            sqlite3_finalize(iStmt)

            let upd = """
            UPDATE chat_messages SET conversation_id = ?
            WHERE group_name = ? AND (conversation_id IS NULL OR conversation_id = '');
            """
            var uStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, upd, -1, &uStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(uStmt, 1, (convId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(uStmt, 2, (group as NSString).utf8String, -1, nil)
                sqlite3_step(uStmt)
            }
            sqlite3_finalize(uStmt)
            print("[DB] Migrated chat group \(group) → conversation \(convId) \"\(title)\"")
        }
    }
    
    @discardableResult
    func execute(_ query: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_DONE
    }
}
