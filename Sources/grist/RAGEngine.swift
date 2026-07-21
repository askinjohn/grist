import Foundation
import Accelerate

@MainActor
class RAGEngine: @unchecked Sendable {
    static let shared = RAGEngine()
    
    private init() {}
    
    /// Splits a transcript into smaller chunks, embeds them, and saves to the database.
    func processTranscriptForRAG(meetingId: String, transcript: String) async {
        print("[RAGEngine] Processing transcript for meeting \(meetingId)")
        let chunks = chunkText(transcript, chunkSize: 300, overlap: 50)
        
        for (index, text) in chunks.enumerated() {
            do {
                let embedding = try await OllamaClient.shared.getEmbedding(text: text)
                let chunkId = "\(meetingId)_chunk_\(index)"
                let dbChunk = TranscriptChunk(id: chunkId, meetingId: meetingId, text: text, embedding: embedding)
                Database.shared.saveChunk(dbChunk)
            } catch {
                print("[RAGEngine] Failed to embed chunk \(index): \(error)")
            }
        }
        print("[RAGEngine] Finished processing \(chunks.count) chunks for meeting \(meetingId)")
    }
    
    /// Searches for the most relevant chunks using fast cosine similarity (vDSP)
    func search(query: String, meetingIds: [String], topK: Int = 10) async throws -> [TranscriptChunk] {
        print("[RAGEngine] Searching for query: '\(query)' across \(meetingIds.count) meetings")
        let queryEmbedding = try await OllamaClient.shared.getEmbedding(text: query)
        
        let allChunks = Database.shared.fetchChunks(forMeetingIds: meetingIds)
        guard !allChunks.isEmpty else { return [] }
        
        // Calculate Cosine Similarity natively using Apple Accelerate
        let scoredChunks = allChunks.map { chunk -> (chunk: TranscriptChunk, score: Double) in
            let score = cosineSimilarity(a: queryEmbedding, b: chunk.embedding)
            return (chunk, score)
        }
        
        let sorted = scoredChunks.sorted { $0.score > $1.score }
        let top = Array(sorted.prefix(topK)).map { $0.chunk }
        print("[RAGEngine] Found \(top.count) relevant chunks.")
        return top
    }
    
    // MARK: - Helpers
    
    private func cosineSimilarity(a: [Double], b: [Double]) -> Double {
        guard a.count == b.count else { return 0.0 }
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
        var chunks: [String] = []
        
        var i = 0
        while i < words.count {
            let end = min(i + chunkSize, words.count)
            let chunkWords = words[i..<end]
            chunks.append(chunkWords.joined(separator: " "))
            i += (chunkSize - overlap)
        }
        
        return chunks
    }
}
