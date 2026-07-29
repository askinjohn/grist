import Foundation

/// Snapshot of local dependencies Grist needs for full AI / capture features.
struct GristHealthReport: Sendable {
    var ollamaReachable: Bool
    var ollamaModels: [String]
    var hasEmbedModel: Bool
    var hasChatModel: Bool
    var ytDlpInstalled: Bool
    var whisperAvailable: Bool
    var checkedAt: Date

    var isHealthy: Bool {
        ollamaReachable && hasChatModel && hasEmbedModel
    }

    var issues: [GristHealthIssue] {
        var list: [GristHealthIssue] = []
        if !ollamaReachable {
            list.append(.ollamaDown)
        } else {
            if !hasChatModel {
                list.append(.missingChatModel)
            }
            if !hasEmbedModel {
                list.append(.missingEmbedModel)
            }
        }
        if !ytDlpInstalled {
            list.append(.missingYtDlp)
        }
        if !whisperAvailable {
            list.append(.missingWhisper)
        }
        return list
    }
}

enum GristHealthIssue: Identifiable, Sendable {
    case ollamaDown
    case missingChatModel
    case missingEmbedModel
    case missingYtDlp
    case missingWhisper

    var id: String {
        switch self {
        case .ollamaDown: return "ollama"
        case .missingChatModel: return "chat"
        case .missingEmbedModel: return "embed"
        case .missingYtDlp: return "ytdlp"
        case .missingWhisper: return "whisper"
        }
    }

    var title: String {
        switch self {
        case .ollamaDown: return "Ollama not running"
        case .missingChatModel: return "No chat model"
        case .missingEmbedModel: return "No embedding model"
        case .missingYtDlp: return "yt-dlp missing"
        case .missingWhisper: return "Whisper not set up"
        }
    }

    var detail: String {
        switch self {
        case .ollamaDown:
            return "Start Ollama (app or `ollama serve`). Grist talks to http://127.0.0.1:11434 by default."
        case .missingChatModel:
            return "Pull a model, e.g. `ollama pull gemma2:2b` or `ollama pull qwen2.5:7b`."
        case .missingEmbedModel:
            return "For Ask everything / RAG: `ollama pull nomic-embed-text`."
        case .missingYtDlp:
            return "YouTube captions need yt-dlp: `brew install yt-dlp` (or re-run ./setup.sh)."
        case .missingWhisper:
            return "Meeting transcription needs Whisper from setup: re-run ./setup.sh Whisper step."
        }
    }

    var systemImage: String {
        switch self {
        case .ollamaDown: return "bolt.slash"
        case .missingChatModel: return "cpu"
        case .missingEmbedModel: return "magnifyingglass"
        case .missingYtDlp: return "play.rectangle"
        case .missingWhisper: return "waveform"
        }
    }

    var isBlocking: Bool {
        switch self {
        case .ollamaDown, .missingChatModel: return true
        case .missingEmbedModel, .missingYtDlp, .missingWhisper: return false
        }
    }
}

enum GristHealth {
    static func check() async -> GristHealthReport {
        let base = await MainActor.run {
            AIConfigManager.shared.config.backends["local"]?.baseURL
                ?? UserDefaults.standard.string(forKey: "OllamaURL")
                ?? "http://127.0.0.1:11434"
        }
        let root = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var reachable = false
        var models: [String] = []
        if let url = URL(string: "\(root)/api/tags") {
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 3
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    reachable = true
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let arr = json["models"] as? [[String: Any]] {
                        models = arr.compactMap { $0["name"] as? String }
                    }
                }
            } catch {
                reachable = false
            }
        }

        let lower = models.map { $0.lowercased() }
        let hasEmbed = lower.contains { $0.contains("nomic-embed") || $0.contains("embed") }
        let hasChat = models.contains { m in
            let l = m.lowercased()
            return !l.contains("embed") && !l.contains("nomic")
        }

        let yt = YouTubeImporter.resolveYtDlpPath() != nil
        let whisper = whisperBinaryAvailable()

        return GristHealthReport(
            ollamaReachable: reachable,
            ollamaModels: models,
            hasEmbedModel: hasEmbed,
            hasChatModel: hasChat || (!models.isEmpty && reachable),
            ytDlpInstalled: yt,
            whisperAvailable: whisper,
            checkedAt: Date()
        )
    }

    private static func whisperBinaryAvailable() -> Bool {
        let candidates = [
            UserDefaults.standard.string(forKey: "whisperPath"),
            (ProcessInfo.processInfo.environment["HOME"] ?? "") + "/Library/Application Support/Grist/whisper.cpp/build/bin/whisper-cli",
            (ProcessInfo.processInfo.environment["HOME"] ?? "") + "/Library/Application Support/Grist/whisper.cpp/main",
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
        ].compactMap { $0 }.filter { !$0.isEmpty }
        for p in candidates {
            if FileManager.default.isExecutableFile(atPath: p) { return true }
        }
        // Also accept any path stored by setup
        if let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Grist/whisper.cpp", isDirectory: true) {
            if FileManager.default.fileExists(atPath: dir.path) { return true }
        }
        return false
    }
}
