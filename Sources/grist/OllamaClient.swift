import Foundation

class OllamaClient: @unchecked Sendable {
    static let shared = OllamaClient()
    
    private init() {}

    // MARK: - Role resolution (ai-config.json)

    /// Resolve endpoint for a logical role (chat, enhance, embed, …).
    @MainActor
    private func endpoint(for role: AIRole, modelOverride: String? = nil) -> ResolvedAIEndpoint {
        AIConfigManager.shared.resolve(role: role, modelOverride: modelOverride)
    }

    /// Fallback when not on MainActor — read file synchronously (rare).
    private func endpointSync(for role: AIRole, modelOverride: String? = nil) -> ResolvedAIEndpoint {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                AIConfigManager.shared.resolve(role: role, modelOverride: modelOverride)
            }
        }
        return DispatchQueue.main.sync {
            AIConfigManager.shared.resolve(role: role, modelOverride: modelOverride)
        }
    }

    // Legacy helpers (tests / getModels without role)
    private var legacyIsOllama: Bool {
        (UserDefaults.standard.string(forKey: "aiProviderType") ?? "Ollama") == "Ollama"
    }
    private var ollamaBaseURL: String {
        UserDefaults.standard.string(forKey: "OllamaURL") ?? "http://127.0.0.1:11434"
    }
    private var openAIBaseURL: String {
        UserDefaults.standard.string(forKey: "openAIBaseURL") ?? "https://api.openai.com/v1"
    }
    private var openAIAPIKey: String {
        UserDefaults.standard.string(forKey: "openAIAPIKey") ?? ""
    }
    private var openAIModel: String {
        UserDefaults.standard.string(forKey: "openAIModel") ?? "gpt-4o"
    }
    
    // MARK: - Shared Structs
    struct OllamaChatMessage: Codable {
        let role: String
        let content: String
    }
    
    // MARK: - Ollama Structs
    struct OllamaRequest: Encodable {
        let model: String
        let prompt: String
        let stream: Bool
    }
    struct OllamaResponse: Decodable {
        let response: String
    }
    struct OllamaChatRequest: Encodable {
        let model: String
        let messages: [OllamaChatMessage]
        let stream: Bool
    }
    struct OllamaChatResponse: Decodable {
        let message: OllamaChatMessage
    }
    struct OllamaEmbeddingRequest: Encodable {
        let model: String
        let prompt: String
    }
    struct OllamaEmbeddingResponse: Decodable {
        let embedding: [Double]
    }
    struct OllamaTagsResponse: Decodable {
        let models: [OllamaModel]
    }
    struct OllamaModel: Decodable {
        let name: String
    }
    
    // MARK: - OpenAI Structs
    struct OpenAIChatRequest: Encodable {
        let model: String
        let messages: [OllamaChatMessage]
        let stream: Bool
    }
    struct OpenAIChatResponse: Decodable {
        struct Choice: Decodable {
            let message: OllamaChatMessage
        }
        let choices: [Choice]
    }
    struct OpenAIModelsResponse: Decodable {
        struct ModelInfo: Decodable {
            let id: String
        }
        let data: [ModelInfo]
    }
    struct OpenAIEmbeddingRequest: Encodable {
        let model: String
        let input: String
    }
    struct OpenAIEmbeddingResponse: Decodable {
        struct EmbeddingData: Decodable {
            let embedding: [Double]
        }
        let data: [EmbeddingData]
    }
    
    // MARK: - Methods
    
    func getModels() async throws -> [String] {
        // Prefer models from local Ollama when available; also surface configured role models.
        var names = Set<String>()
        let ep = endpointSync(for: .chat)
        if ep.isOllama || legacyIsOllama {
            let base = ep.isOllama ? ep.backend.baseURL : ollamaBaseURL
            if let url = URL(string: "\(base)/api/tags") {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 10
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let tags = try? JSONDecoder().decode(OllamaTagsResponse.self, from: data) {
                    tags.models.forEach { names.insert($0.name) }
                }
            }
        }
        // Include every role’s configured model name so pickers always show them
        await MainActor.run {
            for role in AIRole.allCases {
                names.insert(AIConfigManager.shared.modelName(for: role))
            }
        }
        if names.isEmpty {
            return [ep.model, "gemma2:2b", "nomic-embed-text"]
        }
        return names.sorted()
    }
    
    /// Result of a single enhance call: summary body + optional title (one model round-trip).
    struct EnhanceResult {
        var title: String?
        var summary: String
    }

    struct OrganizeResult: Sendable {
        var title: String?
        var folder: String?
    }

    /// One call: TITLE + FOLDER for auto-organize (no full summary).
    func organizeMetadata(
        content: String,
        kind: String,
        existingFolders: [String],
        needsTitle: Bool,
        needsFolder: Bool,
        model: String
    ) async throws -> OrganizeResult {
        let snippet = String(content.prefix(2500))
        let folderList = existingFolders.isEmpty
            ? "(none yet — invent a short 1–3 word folder if useful)"
            : existingFolders.sorted().joined(separator: ", ")

        var rules: [String] = []
        if needsTitle {
            rules.append("TITLE: <max 8 words, no quotes>")
        } else {
            rules.append("TITLE: KEEP")
        }
        if needsFolder {
            rules.append("FOLDER: <exact existing folder name if it fits, OR a new short 1–3 word name, OR NONE>")
        } else {
            rules.append("FOLDER: KEEP")
        }

        let prompt = """
        Item type: \(kind)
        Existing folders: [\(folderList)]

        Output EXACTLY two lines (no markdown, no extra text):
        \(rules.joined(separator: "\n"))

        Prefer an existing folder name when it fits. Use NONE if none fits.
        Content:
        \(snippet)
        """

        let raw = try await generateText(prompt: prompt, model: model, role: .organize, timeout: 60)
        return Self.parseOrganizeOutput(raw, needsTitle: needsTitle, needsFolder: needsFolder)
    }

    static func parseOrganizeOutput(_ raw: String, needsTitle: Bool, needsFolder: Bool) -> OrganizeResult {
        var title: String? = nil
        var folder: String? = nil
        for line in raw.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: #"^TITLE\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
                let v = cleanTitle(String(t[r.upperBound...]))
                if needsTitle, !v.isEmpty, v.uppercased() != "KEEP" {
                    title = v
                }
            } else if let r = t.range(of: #"^FOLDER\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
                var v = String(t[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if needsFolder, !v.isEmpty {
                    let upper = v.uppercased()
                    if upper != "KEEP" && upper != "NONE" && upper != "N/A" && upper != "UNFILED" {
                        // Normalize length
                        if v.count > 40 { v = String(v.prefix(40)) }
                        folder = v
                    }
                }
            }
        }
        return OrganizeResult(title: title, folder: folder)
    }

    /// Short human title only — used when enhance is skipped (e.g. Auto off).
    func suggestTitle(content: String, kind: String = "meeting", model: String) async throws -> String {
        let snippet = String(content.prefix(2500))
        let prompt = """
        Write a title for this \(kind) (max 8 words).
        Output only the title — no quotes, no period, no "Title:" prefix.

        Content:
        \(snippet)
        """
        let raw = try await generateText(prompt: prompt, model: model, role: .title, timeout: 45)
        return Self.cleanTitle(raw)
    }

    private static func cleanTitle(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "^\"|\"$", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "^'|'$", with: "", options: .regularExpression)
        if let range = t.range(of: #"^(Title|Meeting|Note)\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            t = String(t[range.upperBound...])
        }
        if let nl = t.firstIndex(of: "\n") {
            t = String(t[..<nl])
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 80 { t = String(t.prefix(77)) + "…" }
        return t
    }

    /// Parse `TITLE: …` + summary body from a single model response.
    static func parseEnhanceOutput(_ raw: String) -> EnhanceResult {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: .newlines)
        guard let first = lines.first else {
            return EnhanceResult(title: nil, summary: text)
        }
        let trimmedFirst = first.trimmingCharacters(in: .whitespaces)
        // TITLE: foo   or   Title: foo
        if let range = trimmedFirst.range(of: #"^TITLE\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            let title = cleanTitle(String(trimmedFirst[range.upperBound...]))
            let rest = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            // Drop a blank line after TITLE if present
            return EnhanceResult(title: title.isEmpty ? nil : title, summary: rest)
        }
        // Fallback: first markdown H1 as title
        if trimmedFirst.hasPrefix("# ") {
            let title = cleanTitle(String(trimmedFirst.dropFirst(2)))
            let rest = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return EnhanceResult(title: title.isEmpty ? nil : title, summary: rest.isEmpty ? text : rest)
        }
        return EnhanceResult(title: nil, summary: text)
    }

    private func generateText(
        prompt: String,
        model: String,
        role: AIRole = .enhance,
        timeout: TimeInterval
    ) async throws -> String {
        let ep = endpointSync(for: role, modelOverride: model)
        let useModel = ep.model
        print("[OllamaClient] generate role=\(role.rawValue) backend=\(ep.backendName) model=\(useModel)")

        if ep.isOllama {
            let url = URL(string: "\(ep.backend.baseURL)/api/generate")!
            let payload = OllamaRequest(model: useModel, prompt: prompt, stream: false)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)
            request.timeoutInterval = timeout
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw NSError(domain: "OllamaClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to Ollama at \(ep.backend.baseURL)."])
            }
            return try JSONDecoder().decode(OllamaResponse.self, from: data).response.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let url = URL(string: "\(ep.backend.baseURL)/chat/completions")!
            let msg = OllamaChatMessage(role: "user", content: prompt)
            let payload = OpenAIChatRequest(model: useModel, messages: [msg], stream: false)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let key = ep.backend.resolvedAPIKey()
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONEncoder().encode(payload)
            request.timeoutInterval = timeout
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw NSError(domain: "OllamaClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to OpenAI-compatible endpoint \(ep.backend.baseURL)."])
            }
            return try JSONDecoder().decode(OpenAIChatResponse.self, from: data).choices.first?.message.content
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    /// One model call: produce a short TITLE line plus the markdown summary.
    func enhance(transcript: String, notes: String, template: String, customPrompt: String? = nil, model: String) async throws -> EnhanceResult {
        print("[OllamaClient] Starting AI enhancement using model: \(model)...")

        // Template → section checklist (keeps small models structured)
        let sectionGuide: String = {
            switch template {
            case "Daily Standup":
                return "Sections: ## Yesterday, ## Today, ## Blockers"
            case "Sales Call":
                return "Sections: ## Context, ## Needs, ## Objections, ## Next steps"
            case "Action Items Focus":
                return "Sections: ## Decisions, ## Action items (owner if named), ## Open questions"
            case "Note":
                return "Sections: ## Summary, ## Key points, ## Action items (if any)"
            default:
                return "Sections: ## Summary, ## Key points, ## Decisions, ## Action items, ## Open questions"
            }
        }()

        let prompt: String
        if let custom = customPrompt, !custom.isEmpty {
            prompt = """
            \(custom)

            First line: TITLE: <max 8 words, no quotes>
            Then a blank line, then Markdown body only.

            Transcript:
            \(transcript)

            Notes:
            \(notes.isEmpty ? "(none)" : notes)
            """
        } else {
            prompt = """
            Summarize this note/meeting into clean Markdown.

            First line: TITLE: <max 8 words, no quotes>
            Blank line, then body using:
            \(sectionGuide)
            Style hint: \(template)
            Fix obvious transcript typos. Do not invent facts. Output only TITLE line + Markdown body.

            Transcript:
            \(transcript)

            Notes:
            \(notes.isEmpty ? "(none)" : notes)
            """
        }

        let raw = try await generateText(prompt: prompt, model: model, role: .enhance, timeout: 90)
        return Self.parseEnhanceOutput(raw)
    }
    
    /// Synthesize many notes/meetings in a folder per user specs (action items, brief, custom).
    func folderSummarize(
        folderName: String,
        items: [(title: String, kind: String, content: String)],
        userSpecs: String,
        model: String
    ) async throws -> EnhanceResult {
        print("[OllamaClient] Folder summarize '\(folderName)' (\(items.count) items) model=\(model)")

        var corpus = ""
        for (i, item) in items.enumerated() {
            corpus += """
            <<<ITEM \(i + 1): \(item.kind) — \(item.title)>>>
            \(item.content)

            """
        }
        // Keep prompt bounded for small local models
        if corpus.count > 100_000 {
            corpus = String(corpus.prefix(100_000)) + "\n\n[…corpus truncated…]"
        }

        let specs = userSpecs.trimmingCharacters(in: .whitespacesAndNewlines)
        let want = specs.isEmpty
            ? "Overview, key themes, decisions, action items (owners if named)."
            : specs
        let prompt = """
        Summarize folder "\(folderName)" (\(items.count) items) into one Markdown doc.

        User wants: \(want)

        First line: TITLE: <max 10 words>
        Blank line, then Markdown. Cite source titles in parentheses. No invented facts.
        Include ## Action items unless the user asked for something else.

        Items:
        \(corpus)
        """

        let raw = try await generateText(prompt: prompt, model: model, role: .folderSummarize, timeout: 180)
        return Self.parseEnhanceOutput(raw)
    }

    /// Extract concrete action items from a note/meeting for the Tasks list.
    /// Returns empty array if none. Each item: (title, optional notes).
    func extractTasks(
        title: String,
        summary: String,
        notes: String,
        transcript: String,
        model: String
    ) async throws -> [(title: String, notes: String)] {
        let body = """
        Title: \(title)

        AI Summary:
        \(summary.prefix(6000))

        Notes:
        \(notes.prefix(4000))

        Transcript:
        \(transcript.prefix(4000))
        """

        let prompt = """
        Extract concrete todo items from this note/meeting.

        - Only real actions (call, send, schedule, write, decide, buy, fix).
        - Skip background facts and vague themes. Max 12 tasks.
        - If none: reply exactly NONE
        - Else one task per block:
        TASK: <short action>
        NOTE: <optional owner/deadline/context — omit if empty>

        Content:
        \(body)
        """

        let raw = try await generateText(prompt: prompt, model: model, role: .taskExtract, timeout: 60)
        return Self.parseTaskExtractOutput(raw)
    }

    static func parseTaskExtractOutput(_ raw: String) -> [(title: String, notes: String)] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased() == "NONE" || trimmed.isEmpty { return [] }

        var results: [(String, String)] = []
        var currentTitle: String?
        var currentNotes = ""

        func flush() {
            guard let t = currentTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return }
            results.append((t, currentNotes.trimmingCharacters(in: .whitespacesAndNewlines)))
            currentTitle = nil
            currentNotes = ""
        }

        for line in trimmed.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.uppercased().hasPrefix("TASK:") {
                flush()
                currentTitle = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if t.uppercased().hasPrefix("NOTE:") {
                currentNotes = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") {
                // Bullet fallback
                flush()
                currentTitle = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return results
    }

    /// Chat using the **chat** role backend by default. Pass `role: .askEverything` for library chat.
    func chat(
        messages: [OllamaChatMessage],
        model: String,
        role: AIRole = .chat
    ) async throws -> OllamaChatMessage {
        let ep = endpointSync(for: role, modelOverride: model)
        let useModel = ep.model
        print("[OllamaClient] chat role=\(role.rawValue) backend=\(ep.backendName) model=\(useModel)")

        if ep.isOllama {
            let url = URL(string: "\(ep.backend.baseURL)/api/chat")!
            let payload = OllamaChatRequest(model: useModel, messages: messages, stream: false)

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)
            request.timeoutInterval = 120

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw NSError(domain: "OllamaClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to Ollama Chat API at \(ep.backend.baseURL)."])
            }
            let decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
            return decoded.message

        } else {
            let url = URL(string: "\(ep.backend.baseURL)/chat/completions")!
            let payload = OpenAIChatRequest(model: useModel, messages: messages, stream: false)

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let key = ep.backend.resolvedAPIKey()
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONEncoder().encode(payload)
            request.timeoutInterval = 120

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw NSError(domain: "OllamaClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to OpenAI-compatible Chat API at \(ep.backend.baseURL)."])
            }
            let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
            return decoded.choices.first?.message ?? OllamaChatMessage(role: "assistant", content: "")
        }
    }

    func getEmbedding(text: String, model: String = "nomic-embed-text") async throws -> [Double] {
        let ep = endpointSync(for: .embed, modelOverride: model == "nomic-embed-text" ? nil : model)
        var useModel = ep.model
        print("[OllamaClient] embed backend=\(ep.backendName) model=\(useModel)")

        if ep.isOllama {
            let url = URL(string: "\(ep.backend.baseURL)/api/embeddings")!
            let payload = OllamaEmbeddingRequest(model: useModel, prompt: text)

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)
            request.timeoutInterval = 30

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw NSError(domain: "OllamaClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch embeddings from Ollama. Is nomic-embed-text installed?"])
            }
            let decoded = try JSONDecoder().decode(OllamaEmbeddingResponse.self, from: data)
            return decoded.embedding

        } else {
            let url = URL(string: "\(ep.backend.baseURL)/embeddings")!
            if useModel == "nomic-embed-text" {
                useModel = "text-embedding-3-small"
            }
            let payload = OpenAIEmbeddingRequest(model: useModel, input: text)

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let key = ep.backend.resolvedAPIKey()
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONEncoder().encode(payload)
            request.timeoutInterval = 30

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw NSError(domain: "OllamaClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch embeddings from OpenAI-compatible API."])
            }
            let decoded = try JSONDecoder().decode(OpenAIEmbeddingResponse.self, from: data)
            return decoded.data.first?.embedding ?? []
        }
    }
}
