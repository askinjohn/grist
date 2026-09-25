import Foundation

/// Snapshot of local dependencies Quern needs for full AI / capture features.
struct QuernHealthReport: Sendable {
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

    var issues: [QuernHealthIssue] {
        var list: [QuernHealthIssue] = []
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

enum QuernHealthIssue: Identifiable, Sendable {
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
            return "Start Ollama (app or `ollama serve`). Quern talks to http://127.0.0.1:11434 by default."
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

enum QuernHealth {
    static func check() async -> QuernHealthReport {
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
        let configuredEmbed = await MainActor.run {
            AIConfigManager.shared.modelName(for: .embed).lowercased()
        }

        // Prefer capability-aware / configured-name match; avoid classifying chat models as embed.
        let hasEmbed = lower.contains { name in
            if !configuredEmbed.isEmpty,
               name == configuredEmbed
                || name.hasPrefix(configuredEmbed + ":")
                || configuredEmbed.hasPrefix(name.split(separator: ":").first.map(String.init) ?? configuredEmbed) {
                return true
            }
            return name.contains("nomic-embed")
                || name.contains("bge-")
                || name.contains("mxbai-embed")
                || name.hasSuffix("-embed")
                || name.contains("embed-text")
                || name.contains("embedding")
        }
        let hasChat = models.contains { m in
            let l = m.lowercased()
            let looksEmbed = l.contains("nomic-embed") || l.contains("embed-text")
                || l.contains("embedding") || l.contains("bge-") || l.hasSuffix("-embed")
            return !looksEmbed
        }

        let yt = YouTubeImporter.resolveYtDlpPath() != nil
        // Real launch probe (not just “file exists”) — catches broken @rpath after Grist→Quern.
        let whisper: Bool
        switch await WhisperTranscriber.shared.preflightForRecording() {
        case .ok: whisper = true
        case .failed: whisper = false
        }

        return QuernHealthReport(
            ollamaReachable: reachable,
            ollamaModels: models,
            hasEmbedModel: hasEmbed,
            // Never treat “any model exists” as chat — embed-only installs must fail this check.
            hasChatModel: hasChat,
            ytDlpInstalled: yt,
            whisperAvailable: whisper,
            checkedAt: Date()
        )
    }
}
