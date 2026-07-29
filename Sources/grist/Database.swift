import Foundation
import SQLite3

@MainActor
class Database {
    static let shared = Database()
    private var db: OpaquePointer?
    
    private init() {
        openDatabase()
        createTables()
    }
    
    private func openDatabase() {
        // Resolve Application Support directory for Grist data
        let fileManager = FileManager.default
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let gristFolder = appSupportURL.appendingPathComponent("Grist", isDirectory: true)
        
        try? fileManager.createDirectory(at: gristFolder, withIntermediateDirectories: true, attributes: nil)
        
        let dbPath = gristFolder.appendingPathComponent("meetings.db").path
        
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("Error opening database meetings.db at path \(dbPath)")
        } else {
            print("Successfully opened database meetings.db at \(dbPath)")
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
    private func execute(_ query: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_DONE
    }
    
    func saveMeeting(_ meeting: Meeting) {
        let insertStatementString = """
        INSERT OR REPLACE INTO meetings (id, title, timestamp, manual_notes, transcript, summary, template, group_name, is_deleted, duration_seconds)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        
        var insertStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, insertStatementString, -1, &insertStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(insertStatement, 1, (meeting.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStatement, 2, (meeting.title as NSString).utf8String, -1, nil)
            sqlite3_bind_double(insertStatement, 3, meeting.timestamp)
            sqlite3_bind_text(insertStatement, 4, (meeting.manualNotes as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStatement, 5, (meeting.transcript as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStatement, 6, (meeting.summary as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStatement, 7, (meeting.template as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insertStatement, 8, ((meeting.groupName ?? "") as NSString).utf8String, -1, nil)
            sqlite3_bind_int(insertStatement, 9, meeting.isDeleted ? 1 : 0)
            sqlite3_bind_int(insertStatement, 10, Int32(meeting.durationSeconds))
            
            if sqlite3_step(insertStatement) != SQLITE_DONE {
                print("Could not insert/replace meeting row.")
            }
        }
        sqlite3_finalize(insertStatement)
    }
    
    func softDeleteMeeting(id: String) {
        let query = "UPDATE meetings SET is_deleted = 1 WHERE id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }
    
    func getMeeting(id: String) -> Meeting? {
        let queryStatementString = "SELECT id, title, timestamp, manual_notes, transcript, summary, template, group_name, is_deleted, COALESCE(duration_seconds, 0) FROM meetings WHERE id = ?;"
        var queryStatement: OpaquePointer?
        var meeting: Meeting? = nil
        
        if sqlite3_prepare_v2(db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(queryStatement, 1, (id as NSString).utf8String, -1, nil)
            
            if sqlite3_step(queryStatement) == SQLITE_ROW {
                meeting = meetingFromRow(queryStatement)
            }
        }
        sqlite3_finalize(queryStatement)
        return meeting
    }
    
    func fetchActiveMeetings() -> [Meeting] {
        let queryStatementString = "SELECT id, title, timestamp, manual_notes, transcript, summary, template, group_name, is_deleted, COALESCE(duration_seconds, 0) FROM meetings WHERE is_deleted = 0 ORDER BY timestamp DESC;"
        var queryStatement: OpaquePointer?
        var meetings: [Meeting] = []
        
        if sqlite3_prepare_v2(db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            while sqlite3_step(queryStatement) == SQLITE_ROW {
                if let meeting = meetingFromRow(queryStatement) {
                    meetings.append(meeting)
                }
            }
        }
        sqlite3_finalize(queryStatement)
        return meetings
    }

    private func meetingFromRow(_ queryStatement: OpaquePointer?) -> Meeting? {
        guard let queryStatement else { return nil }
        let id = String(cString: sqlite3_column_text(queryStatement, 0))
        let title = String(cString: sqlite3_column_text(queryStatement, 1))
        let timestamp = sqlite3_column_double(queryStatement, 2)
        let manualNotes = sqlite3_column_text(queryStatement, 3) != nil ? String(cString: sqlite3_column_text(queryStatement, 3)) : ""
        let transcript = sqlite3_column_text(queryStatement, 4) != nil ? String(cString: sqlite3_column_text(queryStatement, 4)) : ""
        let summary = sqlite3_column_text(queryStatement, 5) != nil ? String(cString: sqlite3_column_text(queryStatement, 5)) : ""
        let template = sqlite3_column_text(queryStatement, 6) != nil ? String(cString: sqlite3_column_text(queryStatement, 6)) : ""
        let groupName = sqlite3_column_text(queryStatement, 7) != nil ? String(cString: sqlite3_column_text(queryStatement, 7)) : ""
        let isDeleted = sqlite3_column_int(queryStatement, 8) == 1
        let durationSeconds = Int(sqlite3_column_int(queryStatement, 9))
        return Meeting(
            id: id,
            title: title,
            timestamp: timestamp,
            manualNotes: manualNotes,
            transcript: transcript,
            summary: summary,
            template: template,
            groupName: groupName.isEmpty ? nil : groupName,
            isDeleted: isDeleted,
            durationSeconds: durationSeconds
        )
    }

    // MARK: - Folders
    
    func fetchFolders() -> [String] {
        var folders: [String] = []
        let query = "SELECT name FROM folders ORDER BY name ASC;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let nCStr = sqlite3_column_text(statement, 0) {
                    folders.append(String(cString: nCStr))
                }
            }
        }
        sqlite3_finalize(statement)
        return folders
    }
    
    func saveFolder(_ name: String) {
        let query = "INSERT OR REPLACE INTO folders (name, created_at) VALUES (?, ?);"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }
    
    enum FolderDeleteContentsMode {
        /// Keep notes/meetings; clear their folder → Unfiled
        case moveToUnfiled
        /// Soft-delete notes/meetings in the folder (`is_deleted = 1`)
        case softDeleteContents
    }

    /// Remove the folder. Contents are either unfiled or soft-deleted.
    func deleteFolder(_ name: String, contents: FolderDeleteContentsMode) {
        switch contents {
        case .moveToUnfiled:
            let unfile = "UPDATE meetings SET group_name = '' WHERE group_name = ? AND is_deleted = 0;"
            var unfileStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, unfile, -1, &unfileStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(unfileStmt, 1, (name as NSString).utf8String, -1, nil)
                sqlite3_step(unfileStmt)
            }
            sqlite3_finalize(unfileStmt)
        case .softDeleteContents:
            let soft = "UPDATE meetings SET is_deleted = 1 WHERE group_name = ? AND is_deleted = 0;"
            var softStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, soft, -1, &softStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(softStmt, 1, (name as NSString).utf8String, -1, nil)
                sqlite3_step(softStmt)
            }
            sqlite3_finalize(softStmt)
        }

        let query = "DELETE FROM folders WHERE name = ?"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }
}

// MARK: - Template Model & DB Extensions
struct AITemplate: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var prompt: String
}

extension Database {
    func saveTemplate(_ template: AITemplate) {
        let query = "INSERT OR REPLACE INTO templates (id, name, prompt) VALUES (?, ?, ?);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (template.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (template.name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (template.prompt as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }
    
    func deleteTemplate(id: String) {
        let query = "DELETE FROM templates WHERE id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }
    
    func fetchTemplates() -> [AITemplate] {
        let query = "SELECT id, name, prompt FROM templates ORDER BY name ASC;"
        var stmt: OpaquePointer?
        var results: [AITemplate] = []
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(AITemplate(
                    id: String(cString: sqlite3_column_text(stmt, 0)),
                    name: String(cString: sqlite3_column_text(stmt, 1)),
                    prompt: String(cString: sqlite3_column_text(stmt, 2))
                ))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }
}

// MARK: - Chat Model & DB Extensions

/// One chat thread (like a ChatGPT conversation or WhatsApp chat).
struct ChatConversation: Identifiable, Codable, Hashable {
    var id: String
    var scopeKey: String
    var title: String
    var createdAt: Double
    var updatedAt: Double
    var isPinned: Bool

    init(id: String, scopeKey: String, title: String, createdAt: Double, updatedAt: Double, isPinned: Bool = false) {
        self.id = id
        self.scopeKey = scopeKey
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
    }
}

struct ChatMessage: Identifiable, Codable, Hashable {
    var id: String
    /// Scope key (legacy + filter): `__global__`, `item:<id>`, …
    var groupName: String
    var role: String // "user" or "assistant"
    var content: String
    var timestamp: Double
    var conversationId: String
    /// Note/meeting titles used as RAG/document sources (assistant messages).
    var sources: [String]

    init(
        id: String,
        groupName: String,
        role: String,
        content: String,
        timestamp: Double,
        conversationId: String = "",
        sources: [String] = []
    ) {
        self.id = id
        self.groupName = groupName
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.conversationId = conversationId
        self.sources = sources
    }
}

extension Database {
    // MARK: Conversations (multi-thread history)

    func createConversation(scopeKey: String, title: String = "New chat") -> ChatConversation {
        let now = Date().timeIntervalSince1970
        let conv = ChatConversation(
            id: UUID().uuidString,
            scopeKey: scopeKey,
            title: title.isEmpty ? "New chat" : title,
            createdAt: now,
            updatedAt: now,
            isPinned: false
        )
        let q = """
        INSERT INTO chat_conversations (id, scope_key, title, created_at, updated_at, is_pinned)
        VALUES (?, ?, ?, ?, ?, 0);
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (conv.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (conv.scopeKey as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (conv.title as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 4, conv.createdAt)
            sqlite3_bind_double(stmt, 5, conv.updatedAt)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        return conv
    }

    /// Most recent conversation for scope, or a brand-new empty one.
    func latestOrCreateConversation(scopeKey: String) -> ChatConversation {
        if let latest = fetchConversations(scopeKey: scopeKey, search: nil, limit: 1).first {
            return latest
        }
        return createConversation(scopeKey: scopeKey)
    }

    func fetchConversation(id: String) -> ChatConversation? {
        let q = """
        SELECT id, scope_key, title, created_at, updated_at, COALESCE(is_pinned, 0)
        FROM chat_conversations WHERE id = ? LIMIT 1;
        """
        var stmt: OpaquePointer?
        var result: ChatConversation?
        if sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = ChatConversation(
                    id: String(cString: sqlite3_column_text(stmt, 0)),
                    scopeKey: String(cString: sqlite3_column_text(stmt, 1)),
                    title: String(cString: sqlite3_column_text(stmt, 2)),
                    createdAt: sqlite3_column_double(stmt, 3),
                    updatedAt: sqlite3_column_double(stmt, 4),
                    isPinned: sqlite3_column_int(stmt, 5) == 1
                )
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    /// List threads for a scope (Ask everything / one note). Optional title+content search.
    func fetchConversations(scopeKey: String, search: String? = nil, limit: Int = 100) -> [ChatConversation] {
        let term = (search ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var results: [ChatConversation] = []
        var stmt: OpaquePointer?

        if term.isEmpty {
            let q = """
            SELECT id, scope_key, title, created_at, updated_at, COALESCE(is_pinned, 0)
            FROM chat_conversations
            WHERE scope_key = ?
            ORDER BY is_pinned DESC, updated_at DESC
            LIMIT ?;
            """
            if sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (scopeKey as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 2, Int32(limit))
            }
        } else {
            let q = """
            SELECT DISTINCT c.id, c.scope_key, c.title, c.created_at, c.updated_at, COALESCE(c.is_pinned, 0)
            FROM chat_conversations c
            LEFT JOIN chat_messages m ON m.conversation_id = c.id
            WHERE c.scope_key = ?
              AND (
                c.title LIKE ? COLLATE NOCASE
                OR m.content LIKE ? COLLATE NOCASE
              )
            ORDER BY c.is_pinned DESC, c.updated_at DESC
            LIMIT ?;
            """
            let like = "%\(term)%"
            if sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (scopeKey as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (like as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (like as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 4, Int32(limit))
            }
        }

        if stmt != nil {
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(ChatConversation(
                    id: String(cString: sqlite3_column_text(stmt, 0)),
                    scopeKey: String(cString: sqlite3_column_text(stmt, 1)),
                    title: String(cString: sqlite3_column_text(stmt, 2)),
                    createdAt: sqlite3_column_double(stmt, 3),
                    updatedAt: sqlite3_column_double(stmt, 4),
                    isPinned: sqlite3_column_int(stmt, 5) == 1
                ))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    func renameConversation(id: String, title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let q = "UPDATE chat_conversations SET title = ?, updated_at = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (t as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func setConversationPinned(id: String, pinned: Bool) {
        let q = "UPDATE chat_conversations SET is_pinned = ?, updated_at = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, pinned ? 1 : 0)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func touchConversation(id: String) {
        let q = "UPDATE chat_conversations SET updated_at = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    /// Delete thread + all messages.
    func deleteConversation(id: String) {
        let q1 = "DELETE FROM chat_messages WHERE conversation_id = ?;"
        var s1: OpaquePointer?
        if sqlite3_prepare_v2(db, q1, -1, &s1, nil) == SQLITE_OK {
            sqlite3_bind_text(s1, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_step(s1)
        }
        sqlite3_finalize(s1)
        let q2 = "DELETE FROM chat_conversations WHERE id = ?;"
        var s2: OpaquePointer?
        if sqlite3_prepare_v2(db, q2, -1, &s2, nil) == SQLITE_OK {
            sqlite3_bind_text(s2, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_step(s2)
        }
        sqlite3_finalize(s2)
    }

    func saveChatMessage(_ message: ChatMessage) {
        let convId = message.conversationId
        let sourcesJSON: String = {
            guard !message.sources.isEmpty,
                  let data = try? JSONEncoder().encode(message.sources),
                  let s = String(data: data, encoding: .utf8) else { return "" }
            return s
        }()
        let query = """
        INSERT OR REPLACE INTO chat_messages (id, group_name, role, content, timestamp, conversation_id, sources)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (message.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (message.groupName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (message.role as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (message.content as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 5, message.timestamp)
            sqlite3_bind_text(stmt, 6, (convId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 7, (sourcesJSON as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        if !convId.isEmpty {
            touchConversation(id: convId)
        }
    }

    private func decodeSources(_ raw: UnsafePointer<UInt8>?) -> [String] {
        guard let raw else { return [] }
        let s = String(cString: raw)
        guard !s.isEmpty, let data = s.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }

    func fetchChatMessages(conversationId: String) -> [ChatMessage] {
        let query = """
        SELECT id, group_name, role, content, timestamp, conversation_id, sources
        FROM chat_messages
        WHERE conversation_id = ?
        ORDER BY timestamp ASC;
        """
        var stmt: OpaquePointer?
        var results: [ChatMessage] = []
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (conversationId as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let g = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let cid = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? conversationId
                results.append(ChatMessage(
                    id: String(cString: sqlite3_column_text(stmt, 0)),
                    groupName: g,
                    role: String(cString: sqlite3_column_text(stmt, 2)),
                    content: String(cString: sqlite3_column_text(stmt, 3)),
                    timestamp: sqlite3_column_double(stmt, 4),
                    conversationId: cid,
                    sources: decodeSources(sqlite3_column_text(stmt, 6))
                ))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    /// Legacy API — all messages for a scope (any thread). Prefer conversationId APIs.
    func fetchChatMessages(forGroup groupName: String) -> [ChatMessage] {
        let query = """
        SELECT id, group_name, role, content, timestamp, conversation_id, sources
        FROM chat_messages WHERE group_name = ? ORDER BY timestamp ASC;
        """
        var stmt: OpaquePointer?
        var results: [ChatMessage] = []
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (groupName as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let cid = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                results.append(ChatMessage(
                    id: String(cString: sqlite3_column_text(stmt, 0)),
                    groupName: groupName,
                    role: String(cString: sqlite3_column_text(stmt, 2)),
                    content: String(cString: sqlite3_column_text(stmt, 3)),
                    timestamp: sqlite3_column_double(stmt, 4),
                    conversationId: cid,
                    sources: decodeSources(sqlite3_column_text(stmt, 6))
                ))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    func deleteChatMessages(forGroup groupName: String) {
        // Delete all conversations + messages for this scope
        let convs = fetchConversations(scopeKey: groupName, search: nil, limit: 500)
        for c in convs {
            deleteConversation(id: c.id)
        }
        // Orphan legacy rows
        let query = "DELETE FROM chat_messages WHERE group_name = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (groupName as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func deleteChatMessages(conversationId: String) {
        deleteConversation(id: conversationId)
    }
}

// MARK: - RAG Models & DB Extensions
struct TranscriptChunk: Identifiable {
    var id: String
    var meetingId: String
    var text: String
    var embedding: [Double]
}

extension Database {
    func saveChunk(_ chunk: TranscriptChunk) {
        let query = "INSERT OR REPLACE INTO chunks (id, meeting_id, text_chunk, embedding) VALUES (?, ?, ?, ?);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (chunk.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (chunk.meetingId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (chunk.text as NSString).utf8String, -1, nil)

            // Copy embedding bytes with SQLITE_TRANSIENT so SQLite owns the data
            let data = chunk.embedding.withUnsafeBufferPointer { Data(buffer: $0) }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                sqlite3_bind_blob(stmt, 4, base, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }

            if sqlite3_step(stmt) != SQLITE_DONE {
                print("[Database] saveChunk failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
        sqlite3_finalize(stmt)
    }

    func deleteChunks(forMeetingId meetingId: String) {
        let query = "DELETE FROM chunks WHERE meeting_id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (meetingId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func chunkCount() -> Int {
        let query = "SELECT COUNT(*) FROM chunks;"
        var stmt: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return count
    }

    func fetchChunks(forMeetingIds meetingIds: [String]) -> [TranscriptChunk] {
        guard !meetingIds.isEmpty else { return [] }
        
        let placeholders = meetingIds.map { _ in "?" }.joined(separator: ",")
        let query = "SELECT id, meeting_id, text_chunk, embedding FROM chunks WHERE meeting_id IN (\(placeholders));"
        
        var stmt: OpaquePointer?
        var results: [TranscriptChunk] = []
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            for (index, id) in meetingIds.enumerated() {
                sqlite3_bind_text(stmt, Int32(index + 1), (id as NSString).utf8String, -1, nil)
            }
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let meetingId = String(cString: sqlite3_column_text(stmt, 1))
                let text = String(cString: sqlite3_column_text(stmt, 2))
                
                var embedding: [Double] = []
                if let blobPointer = sqlite3_column_blob(stmt, 3) {
                    let blobLength = Int(sqlite3_column_bytes(stmt, 3))
                    let count = blobLength / MemoryLayout<Double>.stride
                    let buffer = blobPointer.bindMemory(to: Double.self, capacity: count)
                    embedding = Array(UnsafeBufferPointer(start: buffer, count: count))
                }
                
                results.append(TranscriptChunk(id: id, meetingId: meetingId, text: text, embedding: embedding))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }
}

// MARK: - Tasks

extension Database {
    func saveTask(_ task: GristTask) {
        let query = """
        INSERT OR REPLACE INTO tasks
        (id, title, notes, source_meeting_id, source_title, status, created_at, completed_at, is_deleted)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (task.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (task.title as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (task.notes as NSString).utf8String, -1, nil)
            if let sid = task.sourceMeetingId {
                sqlite3_bind_text(stmt, 4, (sid as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            if let st = task.sourceTitle {
                sqlite3_bind_text(stmt, 5, (st as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_bind_text(stmt, 6, (task.status as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 7, task.createdAt)
            if let c = task.completedAt {
                sqlite3_bind_double(stmt, 8, c)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            sqlite3_bind_int(stmt, 9, task.isDeleted ? 1 : 0)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func fetchTasks(includeDone: Bool = true) -> [GristTask] {
        let query: String
        if includeDone {
            query = "SELECT id, title, notes, source_meeting_id, source_title, status, created_at, completed_at, is_deleted FROM tasks WHERE is_deleted = 0 ORDER BY status ASC, created_at DESC;"
        } else {
            query = "SELECT id, title, notes, source_meeting_id, source_title, status, created_at, completed_at, is_deleted FROM tasks WHERE is_deleted = 0 AND status = 'open' ORDER BY created_at DESC;"
        }
        var stmt: OpaquePointer?
        var results: [GristTask] = []
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(readTaskRow(stmt))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    func fetchTasks(forMeetingId meetingId: String) -> [GristTask] {
        let query = "SELECT id, title, notes, source_meeting_id, source_title, status, created_at, completed_at, is_deleted FROM tasks WHERE is_deleted = 0 AND source_meeting_id = ? ORDER BY created_at DESC;"
        var stmt: OpaquePointer?
        var results: [GristTask] = []
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (meetingId as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(readTaskRow(stmt))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    func openTaskCount() -> Int {
        let query = "SELECT COUNT(*) FROM tasks WHERE is_deleted = 0 AND status = 'open';"
        var stmt: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return count
    }

    /// Soft-delete.
    func deleteTask(id: String) {
        let query = "UPDATE tasks SET is_deleted = 1 WHERE id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    /// Avoid exact duplicate open tasks from the same source with the same title.
    func hasOpenTask(title: String, sourceMeetingId: String?) -> Bool {
        let query: String
        if let sid = sourceMeetingId {
            query = "SELECT COUNT(*) FROM tasks WHERE is_deleted = 0 AND status = 'open' AND title = ? AND source_meeting_id = ?;"
            var stmt: OpaquePointer?
            var count = 0
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (title as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (sid as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
            }
            sqlite3_finalize(stmt)
            return count > 0
        } else {
            let q = "SELECT COUNT(*) FROM tasks WHERE is_deleted = 0 AND status = 'open' AND title = ? AND source_meeting_id IS NULL;"
            var stmt: OpaquePointer?
            var count = 0
            if sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (title as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
            }
            sqlite3_finalize(stmt)
            return count > 0
        }
    }

    private func readTaskRow(_ stmt: OpaquePointer?) -> GristTask {
        func textCol(_ i: Int32) -> String? {
            guard let p = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: p)
        }
        let completed: Double? = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 7)
        return GristTask(
            id: textCol(0) ?? UUID().uuidString,
            title: textCol(1) ?? "",
            notes: textCol(2) ?? "",
            sourceMeetingId: textCol(3),
            sourceTitle: textCol(4),
            status: textCol(5) ?? "open",
            createdAt: sqlite3_column_double(stmt, 6),
            completedAt: completed,
            isDeleted: sqlite3_column_int(stmt, 8) != 0
        )
    }
}
