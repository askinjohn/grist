import Foundation
import AppKit

// MARK: - Schema (editable JSON)

/// On-disk AI configuration: backends + per-role model bindings.
/// Path: ~/Library/Application Support/Grist/ai-config.json
struct AIConfigFile: Codable, Equatable {
    var version: Int
    var backends: [String: AIBackendConfig]
    var roles: [String: AIRoleConfig]

    static let currentVersion = 1

    static var `default`: AIConfigFile {
        AIConfigFile(
            version: currentVersion,
            backends: [
                "local": AIBackendConfig(
                    type: .ollama,
                    baseURL: "http://127.0.0.1:11434",
                    apiKey: nil,
                    apiKeyEnv: nil
                ),
                "openai": AIBackendConfig(
                    type: .openaiCompatible,
                    baseURL: "https://api.openai.com/v1",
                    apiKey: nil,
                    apiKeyEnv: "OPENAI_API_KEY"
                ),
            ],
            roles: [
                AIRole.chat.rawValue: AIRoleConfig(backend: "local", model: "gemma2:2b"),
                AIRole.askEverything.rawValue: AIRoleConfig(backend: "local", model: "gemma2:2b"),
                AIRole.enhance.rawValue: AIRoleConfig(backend: "local", model: "gemma2:2b"),
                AIRole.title.rawValue: AIRoleConfig(backend: "local", model: "gemma2:2b"),
                AIRole.organize.rawValue: AIRoleConfig(backend: "local", model: "gemma2:2b"),
                AIRole.folderSummarize.rawValue: AIRoleConfig(backend: "local", model: "gemma2:2b"),
                AIRole.taskExtract.rawValue: AIRoleConfig(backend: "local", model: "gemma2:2b"),
                AIRole.embed.rawValue: AIRoleConfig(backend: "local", model: "nomic-embed-text"),
            ]
        )
    }
}

struct AIBackendConfig: Codable, Equatable, Identifiable {
    var type: AIBackendType
    var baseURL: String
    var apiKey: String?
    /// If set, API key is read from this environment variable when `apiKey` is empty.
    var apiKeyEnv: String?

    var id: String { baseURL + type.rawValue }

    enum AIBackendType: String, Codable, CaseIterable {
        case ollama
        case openaiCompatible = "openai_compatible"

        var label: String {
            switch self {
            case .ollama: return "Ollama (local)"
            case .openaiCompatible: return "OpenAI-compatible"
            }
        }
    }

    func resolvedAPIKey() -> String {
        if let apiKey, !apiKey.isEmpty { return apiKey }
        if let env = apiKeyEnv, !env.isEmpty {
            return ProcessInfo.processInfo.environment[env] ?? ""
        }
        return ""
    }
}

struct AIRoleConfig: Codable, Equatable {
    var backend: String
    var model: String
}

/// Logical jobs that can each use a different backend + model name.
enum AIRole: String, CaseIterable, Identifiable {
    case chat
    case askEverything
    case enhance
    case title
    case organize
    case folderSummarize
    case taskExtract
    case embed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: return "Chat (item)"
        case .askEverything: return "Ask everything"
        case .enhance: return "Enhance / summary"
        case .title: return "Auto-title"
        case .organize: return "Auto-organize"
        case .folderSummarize: return "Folder summarize"
        case .taskExtract: return "Extract tasks"
        case .embed: return "Embeddings (RAG)"
        }
    }

    var help: String {
        switch self {
        case .chat: return "Per-note / meeting Chat tab"
        case .askEverything: return "Library-wide Ask everything"
        case .enhance: return "Summaries after record / Enhance button"
        case .title: return "Title generation"
        case .organize: return "Auto-organize titles & folders"
        case .folderSummarize: return "Folder summarize sheet"
        case .taskExtract: return "Pull action items into Tasks after enhance"
        case .embed: return "Search index vectors (nomic-embed-text locally)"
        }
    }
}

// MARK: - Resolved endpoint

struct ResolvedAIEndpoint: Equatable {
    var backendName: String
    var backend: AIBackendConfig
    var model: String

    var isOllama: Bool { backend.type == .ollama }
}

// MARK: - Manager

@MainActor
final class AIConfigManager: ObservableObject {
    static let shared = AIConfigManager()

    @Published private(set) var config: AIConfigFile
    @Published var lastError: String?
    @Published var lastSavedMessage: String = ""

    /// Pretty JSON for the Settings editor.
    @Published var jsonText: String = ""

    private init() {
        config = Self.loadOrCreate()
        jsonText = Self.prettyJSON(config) ?? ""
        // Keep legacy UserDefaults roughly in sync for older code paths
        syncLegacyDefaults(from: config)
    }

    static var configFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Grist", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ai-config.json")
    }

    static func loadOrCreate() -> AIConfigFile {
        let url = configFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                var file = try JSONDecoder().decode(AIConfigFile.self, from: data)
                file = mergeMissingDefaults(file)
                return file
            } catch {
                print("[AIConfig] Failed to load \(url.path): \(error) — using defaults")
            }
        }
        // Migrate from UserDefaults once
        let migrated = migrateFromUserDefaults()
        try? save(migrated)
        return migrated
    }

    /// Fill any missing role/backend keys so older files still work after app updates.
    static func mergeMissingDefaults(_ file: AIConfigFile) -> AIConfigFile {
        var f = file
        let d = AIConfigFile.default
        for (k, v) in d.backends where f.backends[k] == nil {
            f.backends[k] = v
        }
        for (k, v) in d.roles where f.roles[k] == nil {
            f.roles[k] = v
        }
        f.version = AIConfigFile.currentVersion
        return f
    }

    static func migrateFromUserDefaults() -> AIConfigFile {
        var file = AIConfigFile.default
        let ud = UserDefaults.standard
        let provider = ud.string(forKey: "aiProviderType") ?? "Ollama"
        let ollamaURL = ud.string(forKey: "OllamaURL") ?? "http://127.0.0.1:11434"
        let openAIURL = ud.string(forKey: "openAIBaseURL") ?? "https://api.openai.com/v1"
        let openAIKey = ud.string(forKey: "openAIAPIKey") ?? ""
        let openAIModel = ud.string(forKey: "openAIModel") ?? "gpt-4o"

        file.backends["local"] = AIBackendConfig(
            type: .ollama,
            baseURL: ollamaURL,
            apiKey: nil,
            apiKeyEnv: nil
        )
        file.backends["openai"] = AIBackendConfig(
            type: .openaiCompatible,
            baseURL: openAIURL,
            apiKey: openAIKey.isEmpty ? nil : openAIKey,
            apiKeyEnv: openAIKey.isEmpty ? "OPENAI_API_KEY" : nil
        )

        let defaultBackend = provider == "Ollama" ? "local" : "openai"
        let defaultModel = provider == "Ollama" ? "gemma2:2b" : openAIModel
        for role in AIRole.allCases {
            if role == .embed {
                file.roles[role.rawValue] = AIRoleConfig(
                    backend: "local",
                    model: "nomic-embed-text"
                )
            } else {
                file.roles[role.rawValue] = AIRoleConfig(backend: defaultBackend, model: defaultModel)
            }
        }
        return file
    }

    static func prettyJSON(_ file: AIConfigFile) -> String? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(file) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ file: AIConfigFile) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(file)
        try data.write(to: configFileURL, options: .atomic)
    }

    func reloadFromDisk() {
        config = Self.loadOrCreate()
        jsonText = Self.prettyJSON(config) ?? ""
        lastError = nil
        lastSavedMessage = "Reloaded from disk"
        syncLegacyDefaults(from: config)
    }

    /// Parse JSON editor text and save.
    @discardableResult
    func saveJSONText() -> Bool {
        guard let data = jsonText.data(using: .utf8) else {
            lastError = "Invalid UTF-8"
            return false
        }
        do {
            var file = try JSONDecoder().decode(AIConfigFile.self, from: data)
            file = Self.mergeMissingDefaults(file)
            try Self.save(file)
            config = file
            jsonText = Self.prettyJSON(file) ?? jsonText
            lastError = nil
            lastSavedMessage = "Saved \(Self.configFileURL.path)"
            syncLegacyDefaults(from: file)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Save current structured config (from UI pickers).
    @discardableResult
    func saveConfig(_ file: AIConfigFile) -> Bool {
        do {
            let f = Self.mergeMissingDefaults(file)
            try Self.save(f)
            config = f
            jsonText = Self.prettyJSON(f) ?? ""
            lastError = nil
            lastSavedMessage = "Saved"
            syncLegacyDefaults(from: f)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func resetToDefaults() {
        let d = AIConfigFile.default
        _ = saveConfig(d)
        lastSavedMessage = "Reset to defaults"
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.configFileURL])
    }

    func resolve(role: AIRole, modelOverride: String? = nil) -> ResolvedAIEndpoint {
        let binding = config.roles[role.rawValue]
            ?? AIConfigFile.default.roles[role.rawValue]
            ?? AIRoleConfig(backend: "local", model: "gemma2:2b")
        let backendName = binding.backend
        let backend = config.backends[backendName]
            ?? config.backends["local"]
            ?? AIBackendConfig(type: .ollama, baseURL: "http://127.0.0.1:11434", apiKey: nil, apiKeyEnv: nil)
        let model: String = {
            if let o = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty, o != "custom" {
                return o
            }
            return binding.model
        }()
        return ResolvedAIEndpoint(backendName: backendName, backend: backend, model: model)
    }

    func modelName(for role: AIRole) -> String {
        config.roles[role.rawValue]?.model ?? "gemma2:2b"
    }

    func setRole(_ role: AIRole, backend: String, model: String) {
        var c = config
        c.roles[role.rawValue] = AIRoleConfig(backend: backend, model: model)
        _ = saveConfig(c)
    }

    func setBackend(_ name: String, _ backend: AIBackendConfig) {
        var c = config
        c.backends[name] = backend
        _ = saveConfig(c)
    }

    private func syncLegacyDefaults(from file: AIConfigFile) {
        let ud = UserDefaults.standard
        if let local = file.backends["local"] {
            ud.set(local.baseURL, forKey: "OllamaURL")
        }
        if let openai = file.backends["openai"] {
            ud.set(openai.baseURL, forKey: "openAIBaseURL")
            if let k = openai.apiKey, !k.isEmpty {
                ud.set(k, forKey: "openAIAPIKey")
            }
        }
        // Prefer enhance role as the “main” legacy provider signal
        if let enhance = file.roles[AIRole.enhance.rawValue],
           let b = file.backends[enhance.backend] {
            ud.set(b.type == .ollama ? "Ollama" : "OpenAI Compatible", forKey: "aiProviderType")
            if b.type == .openaiCompatible {
                ud.set(enhance.model, forKey: "openAIModel")
            }
        }
    }
}
