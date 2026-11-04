import Foundation
import SwiftUI

struct AskEvidence: Codable, Hashable, Identifiable {
    var id: String
    var meetingID: String?
    var title: String
    var timestamp: Double
    var section: String
    var quote: String
}

enum SearchEvidence {
    static func match(_ meeting: Meeting, query: String) -> AskEvidence? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        for (section, text) in [("notes", meeting.manualNotes), ("transcript", meeting.transcript), ("summary", meeting.summary), ("title", meeting.title)] {
            if let range = text.range(of: query, options: .caseInsensitive) {
                let start = text.index(range.lowerBound, offsetBy: -100, limitedBy: text.startIndex) ?? text.startIndex
                let end = text.index(range.upperBound, offsetBy: 200, limitedBy: text.endIndex) ?? text.endIndex
                return AskEvidence(id: "match", meetingID: meeting.id, title: meeting.title, timestamp: meeting.timestamp, section: section, quote: String(text[start..<end]))
            }
        }
        return nil
    }

    static func highlight(_ text: String, query: String) -> AttributedString {
        var result = AttributedString(text)
        guard !query.isEmpty else { return result }
        var start = result.startIndex
        while start < result.endIndex, let range = result[start...].range(of: query, options: .caseInsensitive) {
            result[range].backgroundColor = .yellow.opacity(0.3)
            start = range.upperBound
        }
        return result
    }
}

/// Pure ranking operations are shared by retrieval and the offline regression suite.
enum EvidenceRanking {
    static func fuse(_ lists: [[String]], limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var scores: [String: Double] = [:]
        for list in lists {
            var seen = Set<String>()
            for (rank, id) in list.enumerated() where seen.insert(id).inserted {
                scores[id, default: 0] += 1 / Double(61 + rank)
            }
        }
        return Array(scores.keys.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0]! > scores[$1]! }.prefix(limit))
    }

    static func lexical(_ candidates: [AskEvidence], query: String) -> [AskEvidence] {
        let queryTerms = terms(query)
        func score(_ e: AskEvidence) -> Int {
            queryTerms.reduce(0) { $0 + (e.quote.lowercased().contains($1) ? 2 : 0) + (e.title.lowercased().contains($1) ? 1 : 0) }
        }
        return candidates.filter { score($0) > 0 }.sorted { score($0) == score($1) ? $0.id < $1.id : score($0) > score($1) }
    }

    static func terms(_ text: String) -> Set<String> {
        let stop: Set<String> = ["what", "which", "when", "where", "does", "have", "with", "that", "this", "about", "from", "your", "were", "please", "could", "would", "the", "and", "for", "are", "how", "can", "did"]
        return Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 && !stop.contains($0) })
    }

    /// Preserve paragraphs/speaker turns; split only oversize blocks. Character ceiling
    /// is a conservative context budget, not a claim of model-specific tokenization.
    static func passages(_ text: String, ceiling: Int = 1200) -> [String] {
        guard ceiling > 0 else { return [] }
        var output: [String] = []
        for paragraph in text.components(separatedBy: "\n") where !paragraph.trimmingCharacters(in: .whitespaces).isEmpty {
            var remainder = paragraph[...]
            while !remainder.isEmpty {
                let end = remainder.index(remainder.startIndex, offsetBy: ceiling, limitedBy: remainder.endIndex) ?? remainder.endIndex
                output.append(String(remainder[..<end]))
                remainder = remainder[end...]
            }
        }
        return output
    }

    static func scoped(_ meetings: [Meeting], folder: String, days: Int, now: Date = Date()) -> [Meeting] {
        meetings.filter { !$0.isDeleted && (folder.isEmpty || $0.groupName == folder) && (days == 0 || $0.timestamp >= now.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970) }
    }

    static func unknownCitations(_ answer: String, evidence: [AskEvidence]) -> [String] {
        let regex = try! NSRegularExpression(pattern: "\\[S[0-9]+\\]")
        let valid = Set(evidence.map { "[\($0.id)]" })
        return regex.matches(in: answer, range: NSRange(answer.startIndex..., in: answer)).compactMap { Range($0.range, in: answer).map { String(answer[$0]) } }.filter { !valid.contains($0) }
    }
}

extension Notification.Name {
    static let revealAskEvidence = Notification.Name("revealAskEvidence")
    static let libraryContentChanged = Notification.Name("libraryContentChanged")
}
