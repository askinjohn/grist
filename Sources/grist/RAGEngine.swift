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

    /// Vector search over stored chunks. Throws if embeddings API fails.
    func search(query: String, meetingIds: [String], topK: Int = 10) async throws -> [TranscriptChunk] {
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
        let top = scored.sorted { $0.1 > $1.1 }.prefix(topK).map(\.0)
        print("[RAGEngine] Top \(top.count) of \(allChunks.count) chunks")
        return Array(top)
    }

    /// Keyword rank meetings when vector index is empty or as a complement.
    func rankMeetingsByKeywords(_ meetings: [Meeting], query: String, topK: Int = 12) -> [Meeting] {
        let terms = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        guard !terms.isEmpty else {
            return Array(meetings.sorted { $0.timestamp > $1.timestamp }.prefix(topK))
        }

        func score(_ m: Meeting) -> Int {
            let title = m.title.lowercased()
            let summary = m.summary.lowercased()
            let notes = m.manualNotes.lowercased()
            let transcript = m.transcript.lowercased()
            let folder = (m.groupName ?? "").lowercased()
            var s = 0
            for t in terms {
                if title.contains(t) { s += 12 }
                if folder.contains(t) { s += 4 }
                if summary.contains(t) { s += 6 }
                if notes.contains(t) { s += 3 }
                if transcript.contains(t) { s += 2 }
            }
            // Prefer items that have any content
            if !summary.isEmpty { s += 1 }
            if !notes.isEmpty || !transcript.isEmpty { s += 1 }
            return s
        }

        return meetings
            .map { ($0, score($0)) }
            .filter { $0.1 > 0 }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.timestamp > $1.0.timestamp
            }
            .prefix(topK)
            .map(\.0)
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
