import Foundation
import SQLite3

// MARK: - RAG Models & DB Extensions
struct TranscriptChunk: Identifiable {
    var id: String
    var meetingId: String
    var text: String
    var embedding: [Double]
}

extension Database {
    func saveChunk(_ chunk: TranscriptChunk) {
        let query = "INSERT OR REPLACE INTO chunks (id, meeting_id, text_chunk, embedding) VALUES (?, ?, ?, ?);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (chunk.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (chunk.meetingId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (chunk.text as NSString).utf8String, -1, nil)

            // Copy embedding bytes with SQLITE_TRANSIENT so SQLite owns the data
            let data = chunk.embedding.withUnsafeBufferPointer { Data(buffer: $0) }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                sqlite3_bind_blob(stmt, 4, base, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }

            if sqlite3_step(stmt) != SQLITE_DONE {
                print("[Database] saveChunk failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
        sqlite3_finalize(stmt)
    }

    func deleteChunks(forMeetingId meetingId: String) {
        let query = "DELETE FROM chunks WHERE meeting_id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (meetingId as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func chunkCount() -> Int {
        let query = "SELECT COUNT(*) FROM chunks;"
        var stmt: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return count
    }

    func fetchChunks(forMeetingIds meetingIds: [String]) -> [TranscriptChunk] {
        guard !meetingIds.isEmpty else { return [] }
        
        let placeholders = meetingIds.map { _ in "?" }.joined(separator: ",")
        let query = "SELECT id, meeting_id, text_chunk, embedding FROM chunks WHERE meeting_id IN (\(placeholders));"
        
        var stmt: OpaquePointer?
        var results: [TranscriptChunk] = []
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            for (index, id) in meetingIds.enumerated() {
                sqlite3_bind_text(stmt, Int32(index + 1), (id as NSString).utf8String, -1, nil)
            }
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let meetingId = String(cString: sqlite3_column_text(stmt, 1))
                let text = String(cString: sqlite3_column_text(stmt, 2))
                
                var embedding: [Double] = []
                if let blobPointer = sqlite3_column_blob(stmt, 3) {
                    let blobLength = Int(sqlite3_column_bytes(stmt, 3))
                    let count = blobLength / MemoryLayout<Double>.stride
                    let buffer = blobPointer.bindMemory(to: Double.self, capacity: count)
                    embedding = Array(UnsafeBufferPointer(start: buffer, count: count))
                }
                
                results.append(TranscriptChunk(id: id, meetingId: meetingId, text: text, embedding: embedding))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }
}
