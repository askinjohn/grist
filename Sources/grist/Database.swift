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
            timestamp REAL
        );
        """
        execute(createChatTable)
        
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
        
        // Safely migrate existing databases
        execute("ALTER TABLE meetings ADD COLUMN group_name TEXT DEFAULT '';")
        execute("ALTER TABLE meetings ADD COLUMN is_deleted INTEGER DEFAULT 0;")
        execute("ALTER TABLE meetings ADD COLUMN duration_seconds INTEGER DEFAULT 0;")
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
struct ChatMessage: Identifiable, Codable, Hashable {
    var id: String
    var groupName: String
    var role: String // "user" or "assistant"
    var content: String
    var timestamp: Double
}

extension Database {
    func saveChatMessage(_ message: ChatMessage) {
        let query = "INSERT OR REPLACE INTO chat_messages (id, group_name, role, content, timestamp) VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (message.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (message.groupName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (message.role as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (message.content as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 5, message.timestamp)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }
    
    func deleteChatMessages(forGroup groupName: String) {
        let query = "DELETE FROM chat_messages WHERE group_name = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (groupName as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func fetchChatMessages(forGroup groupName: String) -> [ChatMessage] {
        let query = "SELECT id, role, content, timestamp FROM chat_messages WHERE group_name = ? ORDER BY timestamp ASC;"
        var stmt: OpaquePointer?
        var results: [ChatMessage] = []
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (groupName as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(ChatMessage(
                    id: String(cString: sqlite3_column_text(stmt, 0)),
                    groupName: groupName,
                    role: String(cString: sqlite3_column_text(stmt, 1)),
                    content: String(cString: sqlite3_column_text(stmt, 2)),
                    timestamp: sqlite3_column_double(stmt, 3)
                ))
            }
        }
        sqlite3_finalize(stmt)
        return results
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
