import Foundation
import SQLite3

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
