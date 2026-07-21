import Foundation
import Accelerate

/// Library search index: embed title / summary / notes / transcript chunks for Ask everything + folder chat.
@MainActor
class RAGEngine: @unchecked Sendable {
    static let shared = RAGEngine()

    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private(set) var lastIndexError: String?
    private(set) var isReindexing = false
    private(set) var reindexProgress: (done: Int, total: Int) = (0, 0)

    private init() {}

    // MARK: - Index one item

    /// Embed all useful fields for a note/meeting. Replaces previous chunks for that id.
    func indexMeeting(_ meeting: Meeting) async {
        let id = meeting.id
        print("[RAGEngine] Indexing \(id) “\(meeting.title)”")

        Database.shared.deleteChunks(forMeetingId: id)

        let sections = buildSections(for: meeting)
        guard !sections.isEmpty else {
            print("[RAGEngine] Nothing to index for \(id)")
            return
        }

        var chunkIndex = 0
        var failures = 0
        for section in sections {
            let pieces = chunkText(section, chunkSize: 280, overlap: 40)
            for piece in pieces {
                let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.count >= 20 || pieces.count == 1 else { continue }
                do {
                    let embedding = try await OllamaClient.shared.getEmbedding(text: text)
                    let chunkId = "\(id)_c\(chunkIndex)"
                    chunkIndex += 1
                    Database.shared.saveChunk(
                        TranscriptChunk(id: chunkId, meetingId: id, text: text, embedding: embedding)
                    )
                } catch {
                    failures += 1
                    lastIndexError = error.localizedDescription
                    print("[RAGEngine] Embed failed: \(error.localizedDescription)")
                    // Don't spam if embeddings model missing — stop this item
                    if failures >= 2 { return }
                }
            }
        }
        if failures == 0 { lastIndexError = nil }
        print("[RAGEngine] Indexed \(chunkIndex) chunks for \(id)")
    }

    /// Debounced re-index (typing in notes shouldn't hit Ollama every keystroke).
    func scheduleIndex(meeting: Meeting, delayNanoseconds: UInt64 = 1_500_000_000) {
        let id = meeting.id
        debounceTasks[id]?.cancel()
        debounceTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            // Fresh row from DB
            let m = Database.shared.getMeeting(id: id) ?? meeting
            await self?.indexMeeting(m)
            self?.debounceTasks[id] = nil
        }
    }

    /// Immediate index after import / enhance / recording (no debounce).
    func indexMeetingNow(_ meeting: Meeting) {
        Task {
            await indexMeeting(meeting)
        }
    }

    /// Rebuild the whole library index. Returns (itemsIndexed, chunkCount, errorMessage?).
    func reindexAll(meetings: [Meeting]) async -> (items: Int, chunks: Int, error: String?) {
        isReindexing = true
        reindexProgress = (0, meetings.count)
        lastIndexError = nil
        defer {
            isReindexing = false
        }

        var indexed = 0
        for (i, m) in meetings.enumerated() {
            guard !Task.isCancelled else { break }
            await indexMeeting(m)
            indexed += 1
            reindexProgress = (i + 1, meetings.count)
        }
        let totalChunks = Database.shared.chunkCount()
        return (indexed, totalChunks, lastIndexError)
    }

    // MARK: - Search

    /// Vector search over stored chunks. Diversifies across meetings so one huge article can't own all top-K.
    func search(query: String, meetingIds: [String], topK: Int = 10, maxPerMeeting: Int = 3) async throws -> [TranscriptChunk] {
        print("[RAGEngine] Search '\(query.prefix(80))' across \(meetingIds.count) meetings")
        let queryEmbedding = try await OllamaClient.shared.getEmbedding(text: query)
        let allChunks = Database.shared.fetchChunks(forMeetingIds: meetingIds)
        guard !allChunks.isEmpty else {
            print("[RAGEngine] No chunks in index")
            return []
        }

        let scored = allChunks.map { chunk -> (TranscriptChunk, Double) in
            (chunk, cosineSimilarity(a: queryEmbedding, b: chunk.embedding))
        }
        .sorted { $0.1 > $1.1 }

        var perMeeting: [String: Int] = [:]
        var top: [TranscriptChunk] = []
        for (chunk, _) in scored {
            let n = perMeeting[chunk.meetingId, default: 0]
            if n >= maxPerMeeting { continue }
            perMeeting[chunk.meetingId] = n + 1
            top.append(chunk)
            if top.count >= topK { break }
        }
        print("[RAGEngine] Top \(top.count) of \(allChunks.count) chunks (max \(maxPerMeeting)/meeting)")
        return top
    }

    /// Keyword rank meetings — boost folder/title matches so “financial planning” beats a huge unrelated article.
    func rankMeetingsByKeywords(_ meetings: [Meeting], query: String, topK: Int = 12) -> [Meeting] {
        let q = query.lowercased()
        let stop: Set<String> = [
            "what", "about", "the", "and", "for", "you", "your", "from", "with", "this", "that",
            "know", "tell", "me", "let", "most", "popular", "does", "how", "are", "any", "all",
            "have", "has", "was", "were", "into", "docs", "doc", "content", "please", "recorded",
        ]
        let terms = q
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stop.contains($0) }
        // Multi-word phrase bonus (e.g. "financial planning")
        let phrases: [String] = {
            guard terms.count >= 2 else { return [] }
            var p: [String] = []
            for i in 0..<(terms.count - 1) {
                p.append("\(terms[i]) \(terms[i + 1])")
            }
            return p
        }()

        guard !terms.isEmpty || !phrases.isEmpty else {
            return Array(meetings.sorted { $0.timestamp > $1.timestamp }.prefix(topK))
        }

        func score(_ m: Meeting) -> Int {
            let title = m.title.lowercased()
            let summary = m.summary.lowercased()
            let notes = m.manualNotes.lowercased()
            let transcript = m.transcript.lowercased()
            let folder = (m.groupName ?? "").lowercased()
            // Normalize folder for matching (FinancialPlanning → financialplanning)
            let folderLoose = folder.replacingOccurrences(of: " ", with: "")
            var s = 0

            for phrase in phrases {
                let compact = phrase.replacingOccurrences(of: " ", with: "")
                if title.contains(phrase) || title.replacingOccurrences(of: " ", with: "").contains(compact) { s += 40 }
                if folder.contains(phrase) || folderLoose.contains(compact) { s += 50 }
                if summary.contains(phrase) { s += 20 }
                if notes.contains(phrase) { s += 12 }
            }

            for t in terms {
                if folder.contains(t) || folderLoose.contains(t) { s += 18 }
                if title.contains(t) { s += 14 }
                if summary.contains(t) { s += 8 }
                if notes.contains(t) { s += 4 }
                if transcript.contains(t) { s += 2 }
            }
            if !summary.isEmpty { s += 1 }
            if !notes.isEmpty || !transcript.isEmpty { s += 1 }
            return s
        }

        let ranked = meetings
            .map { ($0, score($0)) }
            .filter { $0.1 > 0 }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.timestamp > $1.0.timestamp
            }

        // Always surface positive keyword hits first; never drop a folder match for a 0-score giant article
        return Array(ranked.prefix(topK).map(\.0))
    }

    /// Catalog line for library-wide questions (“what do I have?”).
    func libraryCatalog(_ meetings: [Meeting], limit: Int = 40) -> String {
        let sorted = meetings.sorted { $0.timestamp > $1.timestamp }
        var lines: [String] = ["Library catalog (\(meetings.count) items):"]
        for m in sorted.prefix(limit) {
            let folder = m.groupName.map { " [\($0)]" } ?? ""
            let flags = [
                m.summary.isEmpty ? nil : "summary",
                m.manualNotes.isEmpty ? nil : "notes",
                m.transcript.isEmpty ? nil : "transcript",
            ].compactMap { $0 }.joined(separator: ",")
            lines.append("- \(m.kindLabel): \(m.title)\(folder)\(flags.isEmpty ? "" : " {\(flags)}")")
        }
        if meetings.count > limit {
            lines.append("…and \(meetings.count - limit) more")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Sections to embed

    private func buildSections(for m: Meeting) -> [String] {
        var sections: [String] = []
        let title = m.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = (m.groupName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var header = "Title: \(title.isEmpty ? "Untitled" : title)\nType: \(m.kindLabel)"
        if !folder.isEmpty { header += "\nFolder: \(folder)" }
        sections.append(header)

        let summary = m.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            sections.append("AI Summary of “\(title)”:\n\(summary)")
        }

        let notes = m.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            sections.append("Notes for “\(title)”:\n\(notes)")
        }

        let transcript = m.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !transcript.isEmpty && !transcript.hasPrefix("[Error") {
            // Avoid double-embedding if notes == transcript (imports often copy)
            if notes.isEmpty || transcript != notes {
                sections.append("Transcript/captions for “\(title)”:\n\(transcript)")
            }
        }
        return sections
    }

    // MARK: - Helpers

    private func cosineSimilarity(a: [Double], b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }
        let n = vDSP_Length(a.count)
        var dotProduct: Double = 0
        vDSP_dotprD(a, 1, b, 1, &dotProduct, n)
        var normA: Double = 0
        var normB: Double = 0
        vDSP_svesqD(a, 1, &normA, n)
        vDSP_svesqD(b, 1, &normB, n)
        if normA == 0 || normB == 0 { return 0.0 }
        return dotProduct / (sqrt(normA) * sqrt(normB))
    }

    private func chunkText(_ text: String, chunkSize: Int, overlap: Int) -> [String] {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        if words.count <= chunkSize {
            return [words.joined(separator: " ")]
        }
        var chunks: [String] = []
        var i = 0
        let step = max(1, chunkSize - overlap)
        while i < words.count {
            let end = min(i + chunkSize, words.count)
            chunks.append(words[i..<end].joined(separator: " "))
            if end >= words.count { break }
            i += step
        }
        return chunks
    }
}
