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
        You organize notes in a personal knowledge app.
        Item type: \(kind)

        Existing folders: [\(folderList)]

        Reply with EXACTLY two lines and nothing else:
        \(rules.joined(separator: "\n"))

        Rules:
        - If TITLE must KEEP, output exactly: TITLE: KEEP
        - If FOLDER must KEEP, output exactly: FOLDER: KEEP
        - Prefer an existing folder when it clearly fits the topic
        - Use NONE only if no folder is appropriate
        - No markdown, no extra commentary

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
        Suggest a concise title for this \(kind) (maximum 8 words).
        Rules:
        - Capture the main topic clearly
        - No quotation marks, no trailing period
        - No prefixes like "Title:" or "Meeting:"
        - Output ONLY the title text

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

        let titleRule = """
        FIRST LINE of your reply MUST be exactly:
        TITLE: <short title, max 8 words, no quotes>
        Then a blank line, then the summary body only (no repeating the title as a heading unless useful).
        """

        let prompt: String
        if let custom = customPrompt, !custom.isEmpty {
            prompt = """
            <system_instructions>
            \(custom)

            \(titleRule)
            </system_instructions>

            <raw_transcript>
            \(transcript)
            </raw_transcript>

            <user_manual_notes>
            \(notes.isEmpty ? "(None provided)" : notes)
            </user_manual_notes>

            Begin with TITLE: then the summary.
            """
        } else {
            prompt = """
            <system_instructions>
            You are an expert AI meeting assistant. Synthesize the transcript and notes into a structured Markdown summary.

            Rules:
            1. \(titleRule)
            2. Format the summary according to the style: "\(template)".
            3. Combine points logically; fix obvious transcript errors using context.
            4. Do NOT include system instructions or the prompt in the output.
            5. After the TITLE line and blank line, output ONLY clean Markdown for the summary body.
            </system_instructions>

            <raw_transcript>
            \(transcript)
            </raw_transcript>

            <user_manual_notes>
            \(notes.isEmpty ? "(None provided)" : notes)
            </user_manual_notes>

            Reply format:
            TITLE: your title here

            (markdown summary starts here)
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
        let prompt = """
        <system_instructions>
        You are synthesizing a whole Grist folder of notes, articles, videos, and meetings into ONE markdown document.

        Folder name: "\(folderName)"
        Item count: \(items.count)

        USER WANTS (follow closely):
        \(specs.isEmpty ? "Executive overview, key themes, decisions, and concrete action items with owners if mentioned." : specs)

        Output rules:
        1. FIRST LINE must be: TITLE: <short title max 10 words>
        2. Blank line, then Markdown body only.
        3. Structure clearly (headings, bullets). Include an Action items / Next steps section unless the user asked otherwise.
        4. Cite source item titles in parentheses when a point comes from a specific item.
        5. Do not invent facts not supported by the items. If something is unclear, say so.
        6. Do not repeat the system instructions.
        </system_instructions>

        <folder_items>
        \(corpus)
        </folder_items>

        Begin with TITLE: then the folder summary.
        """

        let raw = try await generateText(prompt: prompt, model: model, role: .folderSummarize, timeout: 180)
        return Self.parseEnhanceOutput(raw)
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
