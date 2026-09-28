import Foundation

// MARK: - Config (stored in integrations.json; token lives in Keychain)

struct CompanionSyncConfig: Codable, Equatable {
    var enabled: Bool
    /// e.g. https://sync.example.com or http://192.168.1.10:8787
    var baseURL: String
    var syncNotesBody: Bool
    var syncSummary: Bool
    var syncTranscript: Bool
    var syncTasks: Bool
    /// Auto-push shortly after local saves (debounced)
    var autoSyncOnSave: Bool

    static let `default` = CompanionSyncConfig(
        enabled: false,
        baseURL: "",
        syncNotesBody: true,
        syncSummary: true,
        syncTranscript: true,
        syncTasks: true,
        autoSyncOnSave: true
    )

    var isConfigured: Bool {
        enabled && !normalizedBaseURL.isEmpty
    }

    var normalizedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

// MARK: - Wire models

private struct SyncPushBody: Encodable {
    var meetings: [SyncMeetingDTO]
    var folders: [SyncFolderDTO]
    var tasks: [SyncTaskDTO]
}

private struct SyncMeetingDTO: Encodable {
    var id: String
    var title: String
    var timestamp: Double
    var manual_notes: String
    var transcript: String
    var summary: String
    var template: String
    var group_name: String
    var duration_seconds: Int
    var is_deleted: Bool
    var updated_at: Double
}

private struct SyncFolderDTO: Encodable {
    var name: String
    var created_at: Double
    var updated_at: Double
}

private struct SyncTaskDTO: Encodable {
    var id: String
    var title: String
    var notes: String
    var source_meeting_id: String?
    var source_title: String?
    var status: String
    var created_at: Double
    var completed_at: Double?
    var is_deleted: Bool
    var updated_at: Double
}

private struct SyncPushResponse: Decodable {
    var ok: Bool?
}

private struct SyncHealthResponse: Decodable {
    var ok: Bool?
    var version: String?
}

// MARK: - Manager

@MainActor
final class CompanionSyncManager: ObservableObject {
    static let shared = CompanionSyncManager()

    static let keychainAccount = "companion-sync-token"

    @Published private(set) var lastStatus: String = ""
    @Published private(set) var lastSyncedAt: Date? = nil
    @Published private(set) var isSyncing = false

    private var debounceTask: Task<Void, Never>?
    private let db = Database.shared

    private init() {}

    func token() -> String {
        QuernKeychain.password(account: Self.keychainAccount) ?? ""
    }

    func setToken(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            QuernKeychain.deletePassword(account: Self.keychainAccount)
        } else {
            _ = QuernKeychain.setPassword(trimmed, account: Self.keychainAccount)
        }
    }

    /// Debounced full push after local edits.
    func schedulePush(reason: String = "save") {
        let cfg = IntegrationsConfigManager.shared.config.companion
        guard cfg.isConfigured, cfg.autoSyncOnSave else { return }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await pushNow(reason: reason)
        }
    }

    /// Immediate push of a soft-deleted meeting tombstone + optional full library.
    func pushTombstone(meetingId: String) {
        let cfg = IntegrationsConfigManager.shared.config.companion
        guard cfg.isConfigured else { return }
        Task { @MainActor in
            guard var m = db.getMeeting(id: meetingId) else { return }
            m.isDeleted = true
            await push(meetings: [m], folders: [], tasks: [], reason: "tombstone")
        }
    }

    func pushNow(reason: String = "manual") async {
        let cfg = IntegrationsConfigManager.shared.config.companion
        guard cfg.isConfigured else {
            lastStatus = "Companion sync is off or missing URL"
            return
        }
        let token = token()
        guard !token.isEmpty else {
            lastStatus = "Add an API token in Settings → Integrations"
            return
        }

        let meetings = db.fetchActiveMeetings()
        let folderNames = db.fetchFolders()
        let now = Date().timeIntervalSince1970
        let folders: [(String, Double)] = folderNames.map { ($0, now) }
        let tasks = cfg.syncTasks ? db.fetchTasks(includeDone: true) : []

        await push(meetings: meetings, folders: folders, tasks: tasks, reason: reason)
    }

    func testConnection() async {
        let cfg = IntegrationsConfigManager.shared.config.companion
        guard let url = URL(string: cfg.normalizedBaseURL + "/v1/health") else {
            lastStatus = "Invalid base URL"
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                lastStatus = "No HTTP response"
                return
            }
            if http.statusCode == 200,
               let body = try? JSONDecoder().decode(SyncHealthResponse.self, from: data),
               body.ok == true {
                lastStatus = "Reachable\(body.version.map { " (v\($0))" } ?? "")"
            } else {
                lastStatus = "Health check failed (\(http.statusCode))"
            }
        } catch {
            lastStatus = "Unreachable: \(error.localizedDescription)"
        }
    }

    private func push(
        meetings: [Meeting],
        folders: [(String, Double)],
        tasks: [QuernTask],
        reason: String
    ) async {
        let cfg = IntegrationsConfigManager.shared.config.companion
        let token = token()
        guard cfg.isConfigured, !token.isEmpty else { return }
        guard let url = URL(string: cfg.normalizedBaseURL + "/v1/sync/push") else {
            lastStatus = "Invalid base URL"
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        let now = Date().timeIntervalSince1970
        let meetingDTOs = meetings.map { m -> SyncMeetingDTO in
            SyncMeetingDTO(
                id: m.id,
                title: m.title,
                timestamp: m.timestamp,
                manual_notes: cfg.syncNotesBody ? m.manualNotes : "",
                transcript: cfg.syncTranscript ? m.transcript : "",
                summary: cfg.syncSummary ? m.summary : "",
                template: m.template,
                group_name: m.groupName ?? "",
                duration_seconds: m.durationSeconds,
                is_deleted: m.isDeleted,
                updated_at: now
            )
        }
        let folderDTOs = folders.map { SyncFolderDTO(name: $0.0, created_at: $0.1, updated_at: now) }
        let taskDTOs: [SyncTaskDTO] = cfg.syncTasks
            ? tasks.map {
                SyncTaskDTO(
                    id: $0.id,
                    title: $0.title,
                    notes: $0.notes,
                    source_meeting_id: $0.sourceMeetingId,
                    source_title: $0.sourceTitle,
                    status: $0.status,
                    created_at: $0.createdAt,
                    completed_at: $0.completedAt,
                    is_deleted: $0.isDeleted,
                    updated_at: now
                )
            }
            : []

        let body = SyncPushBody(meetings: meetingDTOs, folders: folderDTOs, tasks: taskDTOs)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastStatus = "Push failed (no response)"
                return
            }
            if (200..<300).contains(http.statusCode) {
                lastSyncedAt = Date()
                lastStatus = "Synced \(meetingDTOs.count) notes · \(taskDTOs.count) tasks (\(reason))"
                QuernLog.log("[CompanionSync] ok reason=\(reason) meetings=\(meetingDTOs.count) tasks=\(taskDTOs.count)")
                _ = data
            } else {
                let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                lastStatus = "Push failed (\(http.statusCode)) \(snippet)"
                QuernLog.log("[CompanionSync] fail status=\(http.statusCode) \(snippet)")
            }
        } catch {
            lastStatus = "Push error: \(error.localizedDescription)"
            QuernLog.log("[CompanionSync] error \(error.localizedDescription)")
        }
    }
}
