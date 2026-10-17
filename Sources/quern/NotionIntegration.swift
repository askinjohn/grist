import Foundation
import Security

/// Keeps successful Keychain reads for this process. The lock also coalesces
/// concurrent exports so they cannot trigger several access prompts at once.
final class NotionTokenCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func getOrLoad(_ load: () throws -> String?) rethrows -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let value { return value }
        let loaded = try load()
        if let loaded { value = loaded }
        return loaded
    }

    func set(_ token: String?) {
        lock.lock()
        value = token
        lock.unlock()
    }
}

enum NotionSecretStore {
    private static let service = "com.quern.meetingassistant.notion"
    private static let account = "integration-token"
    private static let cache = NotionTokenCache()

    private static let keychainLock = NSLock()

    static func requiredToken() throws -> String {
        guard let token = try cache.getOrLoad({ try readToken(allowInteraction: false) }) else {
            throw NotionExportError.notConfigured
        }
        return token
    }

    /// Only an explicit Settings action can request approval for an older item.
    static func repairSavedAccess() throws {
        guard let token = try readToken(allowInteraction: true) else {
            throw NotionExportError.notConfigured
        }
        try save(token: token)
    }

    private static func readToken(allowInteraction: Bool) throws -> String? {
        try withKeychainAccess(allowInteraction: allowInteraction) {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else {
                QuernLog.log("[Notion] Credential unavailable status=\(status)")
                throw NotionExportError.requestFailed("Saved Notion access needs attention. Open Settings → Integrations → Notion and choose Repair saved access. Automatic export did not request a password.")
            }
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8), !value.isEmpty else {
                throw NotionExportError.notConfigured
            }
            return value
        }
    }

    /// This credential uses the macOS file-based Keychain. Its legacy UI switch
    /// is scoped to this synchronous operation and restored even on failure.
    /// Serialize all Quern Keychain operations because the switch is process-wide.
    static func withKeychainAccess<T>(allowInteraction: Bool, _ operation: () throws -> T) throws -> T {
        keychainLock.lock()
        defer { keychainLock.unlock() }
        if allowInteraction { return try operation() }
        var previous = DarwinBoolean(true)
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            throw NotionExportError.requestFailed("Could not read the saved Notion credential without a dialog. Repair saved access in Notion settings.")
        }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try operation()
    }

    static func save(token: String) throws {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        try withKeychainAccess(allowInteraction: true) {
            guard !value.isEmpty else {
                let status = SecItemDelete(base as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw NotionExportError.requestFailed("Could not remove the token from Keychain.")
                }
                return
            }
            // Trust only this signed app, never every application. Re-saving also
            // repairs ACLs left behind by an older ad-hoc-signed Quern build.
            var access: SecAccess?
            let accessStatus = SecAccessCreate("Quern Notion integration" as CFString, nil, &access)
            guard accessStatus == errSecSuccess, let access else {
                throw NotionExportError.requestFailed("Could not configure saved Notion access.")
            }
            let attributes: [CFString: Any] = [
                kSecValueData: Data(value.utf8),
                kSecAttrAccess: access,
                kSecAttrLabel: "Quern Notion integration",
            ]
            var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(base.merging(attributes) { _, new in new } as CFDictionary, nil)
            }
            guard status == errSecSuccess else {
                throw NSError(domain: "Quern.Notion", code: Int(status), userInfo: [
                    NSLocalizedDescriptionKey: "Could not save the Notion token in macOS Keychain."
                ])
            }
        }
        cache.set(value.isEmpty ? nil : value)
    }
}

enum NotionExportError: LocalizedError {
    case notConfigured
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Set up Notion in Settings → Integrations first."
        case .requestFailed(let message):
            return "Notion export failed: \(message)"
        }
    }
}

/// Appends one Quern item below a Notion page that the user has shared with their integration.
enum NotionExporter {
    private static let version = "2025-09-03"

    static func exportMeeting(_ meeting: Meeting, options: ExportOptions? = nil) async throws {
        let config = await MainActor.run { IntegrationsConfigManager.shared.config.notion }
        let destination = config.destination(for: meeting)
        guard config.enabled,
              !destination.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotionExportError.notConfigured
        }

        let token = try NotionSecretStore.requiredToken()
        var targetID = ""
        var appended = 0
        do {
            let blocks = blocks(for: meeting, options: options ?? config.exportOptions)
            guard !blocks.isEmpty else { throw NotionExportError.requestFailed("There is no content to export.") }
            let id = try normalizedID(destination.id)
            if destination.kind == "data_source" {
                let schema = try await request("data_sources/\(id)", token: token)
                guard let properties = schema["properties"] as? [String: [String: Any]],
                      let titleKey = properties.first(where: { $0.value["type"] as? String == "title" })?.key else {
                    throw NotionExportError.requestFailed("The database has no title property.")
                }
                let page = try await request("pages", method: "POST", token: token, body: [
                    "parent": ["data_source_id": id],
                    "properties": [titleKey: ["title": [["text": ["content": String(meeting.title.prefix(1800))]]]]]
                ])
                guard let pageID = page["id"] as? String else { throw NotionExportError.requestFailed("No page ID returned.") }
                targetID = pageID
            } else { targetID = id }
            // Notion accepts at most 100 children per append. Keep payloads bounded too.
            for batch in batches(blocks) {
                let encoded = try JSONEncoder().encode(NotionAppendRequest(children: batch))
                let body = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
                _ = try await request("blocks/\(targetID)/children", method: "PATCH", token: token, body: body)
                appended += batch.count
            }
            await NotionExportHistory.shared.record(title: meeting.title, status: "Sent \(appended) blocks", destination: targetID)
        } catch {
            let message = appended > 0 ? "Partial export (\(appended) blocks). Retrying may duplicate content. \(error.localizedDescription)" : error.localizedDescription
            await NotionExportHistory.shared.record(title: meeting.title, status: message, destination: targetID)
            throw NotionExportError.requestFailed(message)
        }
    }

    /// Keep a single Quern-owned task page under the selected Notion destination.
    static func exportTasks(_ tasks: [QuernTask]) async throws {
        var config = await MainActor.run { IntegrationsConfigManager.shared.config.notion }
        guard config.enabled, !config.taskPageID.isEmpty else {
            throw NotionExportError.notConfigured
        }
        let token = try NotionSecretStore.requiredToken()
        let destinationID = try normalizedID(config.taskPageID)
        if config.taskListPageID.isEmpty {
            let title = [["text": ["content": "Quern Tasks"]]]
            let properties: [String: Any]
            if config.taskDestinationKind == "data_source" {
                let schema = try await request("data_sources/\(destinationID)", token: token)
                guard let fields = schema["properties"] as? [String: [String: Any]],
                      let key = fields.first(where: { $0.value["type"] as? String == "title" })?.key else {
                    throw NotionExportError.requestFailed("The task database has no title property.")
                }
                properties = [key: ["title": title]]
            } else {
                properties = ["title": ["title": title]]
            }
            let parentKey = config.taskDestinationKind == "data_source" ? "data_source_id" : "page_id"
            let page = try await request("pages", method: "POST", token: token, body: [
                "parent": [parentKey: destinationID], "properties": properties
            ])
            guard let id = page["id"] as? String else { throw NotionExportError.requestFailed("No task page ID returned.") }
            config.taskListPageID = id
            await MainActor.run { IntegrationsConfigManager.shared.updateNotion { $0.taskListPageID = id } }
        }
        let pageID = try normalizedID(config.taskListPageID)
        let active = tasks.filter { !$0.isDeleted }.sorted { a, b in
            if a.isDone != b.isDone { return !a.isDone }
            return a.createdAt < b.createdAt
        }
        let blocks = NotionBlock.heading(level: 1, text: "Quern tasks") + active.flatMap { task in
            let detail = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            return NotionBlock.todo(text: task.title + (detail.isEmpty ? "" : " — " + detail), checked: task.isDone)
        }
        var newIDs: [String] = []
        let oldIDs = config.taskBlockIDs
        do {
            for batch in batches(blocks) {
                let encoded = try JSONEncoder().encode(NotionAppendRequest(children: batch))
                let body = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
                let response = try await request("blocks/\(pageID)/children", method: "PATCH", token: token, body: body)
                newIDs += (response["results"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                let retainedIDs = oldIDs + newIDs
                await MainActor.run { IntegrationsConfigManager.shared.updateNotion { $0.taskBlockIDs = retainedIDs } }
            }
            for id in oldIDs {
                _ = try await request("blocks/\(id)", method: "PATCH", token: token, body: ["archived": true])
            }
            await MainActor.run { IntegrationsConfigManager.shared.updateNotion { $0.taskBlockIDs = newIDs } }
            await NotionExportHistory.shared.record(title: "Quern Tasks", status: "Synced \(active.count) tasks", destination: pageID)
        } catch {
            await NotionExportHistory.shared.record(title: "Quern Tasks", status: error.localizedDescription, destination: pageID)
            throw error
        }
    }

    static func normalizedID(_ value: String) throws -> String {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = URL(string: raw).flatMap { $0.scheme == nil ? nil : $0.path } ?? raw
        let compact = path.replacingOccurrences(of: "-", with: "")
        let id = String(compact.suffix(32))
        guard id.count == 32, id.allSatisfy({ $0.isHexDigit }) else { throw NotionExportError.requestFailed("Paste a valid Notion page URL or ID.") }
        return id
    }

    static func batches(_ blocks: [NotionBlock]) -> [[NotionBlock]] {
        stride(from: 0, to: blocks.count, by: 50).map { Array(blocks[$0..<min($0 + 50, blocks.count)]) }
    }

    static func request(_ path: String, method: String = "GET", token: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/" + path)!)
        request.timeoutInterval = 30
        request.httpMethod = method
        request.setValue("Bearer " + token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        request.setValue(version, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NotionExportError.requestFailed(json["message"] as? String ?? "Connection failed. Check your token and destination access.")
        }
        return json
    }


    static func blocks(for meeting: Meeting, options: ExportOptions) -> [NotionBlock] {
        let markdown = NoteExporter.markdown(for: meeting, options: options)
        var blocks: [NotionBlock] = []
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, line != "---", !line.hasPrefix("*Exported from Quern*") else { continue }
            if line.hasPrefix("# ") {
                blocks += NotionBlock.heading(level: 1, text: String(line.dropFirst(2)))
            } else if line.hasPrefix("## ") {
                blocks += NotionBlock.heading(level: 2, text: String(line.dropFirst(3)))
            } else if line.hasPrefix("### ") {
                blocks += NotionBlock.heading(level: 3, text: String(line.dropFirst(4)))
            } else if line.hasPrefix("- ") {
                blocks += NotionBlock.bullet(text: String(line.dropFirst(2)))
            } else {
                blocks += NotionBlock.paragraph(text: line)
            }
        }
        return blocks
    }
}

struct NotionAppendRequest: Encodable { let children: [NotionBlock] }

struct NotionBlock: Encodable, Equatable {
    let object = "block"
    let type: String
    let paragraph: NotionTextContainer?
    let heading_1: NotionTextContainer?
    let heading_2: NotionTextContainer?
    let heading_3: NotionTextContainer?
    let bulleted_list_item: NotionTextContainer?
    let to_do: NotionTodoContainer?

    static func paragraph(text: String) -> [NotionBlock] { make(type: "paragraph", text: text) }
    static func bullet(text: String) -> [NotionBlock] { make(type: "bulleted_list_item", text: text) }
    static func heading(level: Int, text: String) -> [NotionBlock] { make(type: "heading_\(level)", text: text) }
    static func todo(text: String, checked: Bool) -> [NotionBlock] {
        make(type: "to_do", text: text, checked: checked)
    }

    private static func make(type: String, text: String, checked: Bool = false) -> [NotionBlock] {
        let chunks = text.isEmpty ? [""] : stride(from: 0, to: text.count, by: 1_800).map {
            let start = text.index(text.startIndex, offsetBy: $0)
            let end = text.index(start, offsetBy: min(1_800, text.distance(from: start, to: text.endIndex)))
            return String(text[start..<end])
        }
        return chunks.map { chunk in
            let container = NotionTextContainer(rich_text: [NotionRichText(plain_text: chunk)])
            return NotionBlock(type: type,
                               paragraph: type == "paragraph" ? container : nil,
                               heading_1: type == "heading_1" ? container : nil,
                               heading_2: type == "heading_2" ? container : nil,
                               heading_3: type == "heading_3" ? container : nil,
                               bulleted_list_item: type == "bulleted_list_item" ? container : nil,
                               to_do: type == "to_do" ? NotionTodoContainer(rich_text: container.rich_text, checked: checked) : nil)
        }
    }
}

struct NotionTextContainer: Encodable, Equatable { let rich_text: [NotionRichText] }
struct NotionTodoContainer: Encodable, Equatable { let rich_text: [NotionRichText]; let checked: Bool }
struct NotionRichText: Encodable, Equatable {
    let type = "text"
    let text: NotionText
    init(plain_text: String) { text = NotionText(content: plain_text) }
}
struct NotionText: Encodable, Equatable { let content: String }
