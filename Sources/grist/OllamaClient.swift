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
        GristLog.log("[OllamaClient] generate role=\(role.rawValue) backend=\(ep.backendName) model=\(useModel) promptChars=\(prompt.count) timeout=\(Int(timeout))s")

        if ep.isOllama {
            let url = URL(string: "\(ep.backend.baseURL)/api/generate")!
            let payload = OllamaRequest(model: useModel, prompt: prompt, stream: false)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)
            request.timeoutInterval = timeout
            let t0 = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Date().timeIntervalSince(t0)
            guard let httpResponse = response as? HTTPURLResponse else {
                GristLog.log("[OllamaClient] generate FAILED no HTTP response after \(String(format: "%.1f", elapsed))s")
                throw NSError(domain: "OllamaClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to Ollama at \(ep.backend.baseURL)."])
            }
            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
                GristLog.log("[OllamaClient] generate FAILED HTTP \(httpResponse.statusCode) after \(String(format: "%.1f", elapsed))s model=\(useModel) body=\(body)")
                throw NSError(domain: "OllamaClient", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Ollama HTTP \(httpResponse.statusCode) for model \(useModel). \(body)"])
            }
            let text = try JSONDecoder().decode(OllamaResponse.self, from: data).response.trimmingCharacters(in: .whitespacesAndNewlines)
            GristLog.log("[OllamaClient] generate OK \(String(format: "%.1f", elapsed))s model=\(useModel) responseChars=\(text.count)")
            return text
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
            let t0 = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Date().timeIntervalSince(t0)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                GristLog.log("[OllamaClient] generate OpenAI FAILED HTTP \(code) after \(String(format: "%.1f", elapsed))s")
                throw NSError(domain: "OllamaClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to OpenAI-compatible endpoint \(ep.backend.baseURL)."])
            }
            let text = try JSONDecoder().decode(OpenAIChatResponse.self, from: data).choices.first?.message.content
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            GristLog.log("[OllamaClient] generate OpenAI OK \(String(format: "%.1f", elapsed))s responseChars=\(text.count)")
            return text
        }
    }

    /// Soft cap so local models (8k–32k context) stay usable. Long YouTube mega-episodes
    /// are ~200k+ chars; without this the model truncates randomly and often invents a topic.
    private static let enhanceMaxTranscriptChars = 28_000
    private static let enhanceMaxNotesChars = 4_000

    /// Keep head + middle + tail so long podcasts still get structure + ending.
    static func truncateForEnhance(_ text: String, maxChars: Int, label: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxChars, maxChars > 800 else { return t }
        let headLen = maxChars * 55 / 100
        let midLen = maxChars * 20 / 100
        let tailLen = maxChars - headLen - midLen - 80
        let midStart = max(0, (t.count - midLen) / 2)
        let head = String(t.prefix(headLen))
        let midIdx = t.index(t.startIndex, offsetBy: midStart)
        let midEnd = t.index(midIdx, offsetBy: min(midLen, t.distance(from: midIdx, to: t.endIndex)))
        let mid = String(t[midIdx..<midEnd])
        let tail = String(t.suffix(max(0, tailLen)))
        GristLog.log("[OllamaClient] truncate \(label): \(t.count) → \(maxChars) chars (head+mid+tail)")
        return """
        \(head)

        [… \(label) middle excerpt …]

        \(mid)

        [… \(label) ending …]

        \(tail)
        """
    }

    /// Drop note body that merely duplicates the transcript (YouTube import copies captions into both).
    static func notesForEnhance(notes: String, transcript: String) -> String {
        let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let tr = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return "" }
        if tr.isEmpty {
            return truncateForEnhance(n, maxChars: enhanceMaxNotesChars, label: "notes")
        }

        // YouTube/web import: notes = source link(s) + same caption body as transcript.
        let sampleLen = min(240, tr.count)
        let sample = String(tr.prefix(sampleLen))
        let notesDuplicateTranscript = sampleLen >= 40 && n.contains(sample)

        if notesDuplicateTranscript {
            let lines = n.components(separatedBy: .newlines)
            var header: [String] = []
            for line in lines.prefix(16) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty {
                    if !header.isEmpty { header.append("") }
                    continue
                }
                let lower = t.lowercased()
                let isMeta = t.hasPrefix("[Open on YouTube]")
                    || t.hasPrefix("[Source]")
                    || lower.hasPrefix("## added from")
                    || lower.hasPrefix("source:")
                    || lower.hasPrefix("captions:")
                    || t.hasPrefix("http://")
                    || t.hasPrefix("https://")
                if isMeta {
                    header.append(line)
                    continue
                }
                // First real body line → stop (body is already in transcript)
                break
            }
            let h = header.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            GristLog.log("[OllamaClient] notes de-duped vs transcript: \(n.count) chars → header \(h.count) chars")
            return h
        }

        // Distinct notes (user writing) — keep but cap
        return truncateForEnhance(n, maxChars: enhanceMaxNotesChars, label: "notes")
    }

    private static let enhanceChunkChars = 12_000
    private static let enhanceMapReduceThreshold = 32_000

    private static func sectionGuide(for template: String) -> String {
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
    }

    /// Split long text into overlapping windows for map-reduce enhance.
    static func chunkTextForEnhance(_ text: String, chunkSize: Int = enhanceChunkChars) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > chunkSize else { return t.isEmpty ? [] : [t] }
        var chunks: [String] = []
        var start = t.startIndex
        let overlap = chunkSize / 10
        while start < t.endIndex {
            let endOffset = min(chunkSize, t.distance(from: start, to: t.endIndex))
            let end = t.index(start, offsetBy: endOffset)
            chunks.append(String(t[start..<end]))
            if end == t.endIndex { break }
            let step = max(1, endOffset - overlap)
            start = t.index(start, offsetBy: step)
        }
        return chunks
    }

    /// One model call (or map-reduce for long sources): TITLE + markdown summary.
    /// Inputs are original transcript/captions + notes — never the previous AI summary.
    func enhance(transcript: String, notes: String, template: String, customPrompt: String? = nil, model: String) async throws -> EnhanceResult {
        GristLog.log("[OllamaClient] enhance start model=\(model) rawTranscriptChars=\(transcript.count) rawNotesChars=\(notes.count) template=\(template)")

        let cleanedNotes = Self.notesForEnhance(notes: notes, transcript: transcript)
        let sectionGuide = Self.sectionGuide(for: template)

        // Map-reduce for very long transcripts (e.g. multi-hour podcasts)
        if transcript.count > Self.enhanceMapReduceThreshold {
            GristLog.log("[OllamaClient] enhance map-reduce path (\(transcript.count) chars)")
            return try await enhanceMapReduce(
                transcript: transcript,
                notes: cleanedNotes,
                template: template,
                sectionGuide: sectionGuide,
                customPrompt: customPrompt,
                model: model
            )
        }

        let body = Self.truncateForEnhance(
            transcript,
            maxChars: Self.enhanceMaxTranscriptChars,
            label: "transcript"
        )
        GristLog.log("[OllamaClient] enhance after prep transcriptChars=\(body.count) notesChars=\(cleanedNotes.count)")
        return try await enhanceSinglePass(
            body: body,
            notes: cleanedNotes,
            template: template,
            sectionGuide: sectionGuide,
            customPrompt: customPrompt,
            model: model,
            sourceLength: transcript.count,
            usedTruncation: transcript.count > Self.enhanceMaxTranscriptChars
        )
    }

    private func enhanceMapReduce(
        transcript: String,
        notes: String,
        template: String,
        sectionGuide: String,
        customPrompt: String?,
        model: String
    ) async throws -> EnhanceResult {
        let chunks = Self.chunkTextForEnhance(transcript)
        GristLog.log("[OllamaClient] enhance map: \(chunks.count) chunks")
        var partials: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let prompt = """
            Summarize part \(i + 1) of \(chunks.count) of a long transcript into tight bullet points.
            Keep concrete facts, names, decisions, action items. No preamble. Max ~250 words.

            Part \(i + 1)/\(chunks.count):
            \(chunk)
            """
            let partial = try await generateText(prompt: prompt, model: model, role: .enhance, timeout: 120)
            partials.append("### Part \(i + 1)\n\(partial)")
            GristLog.log("[OllamaClient] enhance map chunk \(i + 1)/\(chunks.count) → \(partial.count) chars")
        }

        var merged = partials.joined(separator: "\n\n")
        if merged.count > 24_000 {
            merged = Self.truncateForEnhance(merged, maxChars: 24_000, label: "partials")
        }
        let notesLine = notes.isEmpty ? "(none)" : notes
        let reduceBody = """
        PARTIAL SUMMARIES FROM A LONG SOURCE (combine these; do not invent new topics):
        \(merged)

        SOURCE NOTES / LINKS:
        \(notesLine)
        """
        return try await enhanceSinglePass(
            body: reduceBody,
            notes: "",
            template: template,
            sectionGuide: sectionGuide,
            customPrompt: customPrompt,
            model: model,
            sourceLength: transcript.count,
            usedTruncation: false,
            mapReduce: true
        )
    }

    private func enhanceSinglePass(
        body: String,
        notes: String,
        template: String,
        sectionGuide: String,
        customPrompt: String?,
        model: String,
        sourceLength: Int,
        usedTruncation: Bool,
        mapReduce: Bool = false
    ) async throws -> EnhanceResult {
        let lengthNote: String = {
            if mapReduce {
                return "Source length: \(sourceLength) characters. You are combining partial summaries of the full source — stay faithful; do not invent."
            }
            if usedTruncation {
                return "Source length: \(sourceLength) characters (long). You are given head+middle+end excerpts only — summarize those, do not invent sections that are not present."
            }
            return "Source length: \(sourceLength) characters."
        }()

        let grounding = """
        Grounding rules (strict):
        - Summarize ONLY the provided text. Do not invent a different topic, book, or talk.
        - Do not invent the medium (e.g. do not call it a "Twitter thread" unless that text says so). If Notes mention YouTube, treat it as a video/podcast transcript.
        - No chatty preamble ("Thank you for sharing…"). Output only TITLE line + Markdown body.
        - \(lengthNote)
        """

        let prompt: String
        if let custom = customPrompt, !custom.isEmpty {
            prompt = """
            \(custom)

            \(grounding)

            First line: TITLE: <max 8 words, no quotes>
            Then a blank line, then Markdown body only.

            Transcript:
            \(body)

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

            \(grounding)

            Transcript:
            \(body)

            Notes:
            \(notes.isEmpty ? "(none)" : notes)
            """
        }

        GristLog.log("[OllamaClient] enhance promptChars=\(prompt.count) mapReduce=\(mapReduce)")
        let raw = try await generateText(prompt: prompt, model: model, role: .enhance, timeout: 180)
        let parsed = Self.parseEnhanceOutput(raw)
        GristLog.log("[OllamaClient] enhance parsed title=\(parsed.title ?? "(none)") summaryChars=\(parsed.summary.count)")
        let sumPrev = parsed.summary.replacingOccurrences(of: "\n", with: " ")
        GristLog.log("[OllamaClient] enhance summaryPreview: \(sumPrev.prefix(200))…")
        return parsed
    }
    
    /// Synthesize many notes/meetings in a folder per user specs (action items, brief, custom).
    func folderSummarize(
        folderName: String,
        items: [(title: String, kind: String, content: String)],
        userSpecs: String,
        model: String
    ) async throws -> EnhanceResult {
        GristLog.log("[OllamaClient] Folder summarize '\(folderName)' (\(items.count) items) model=\(model)")

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
        GristLog.log("[OllamaClient] chat role=\(role.rawValue) backend=\(ep.backendName) model=\(useModel)")

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
        GristLog.log("[OllamaClient] embed backend=\(ep.backendName) model=\(useModel)")

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
