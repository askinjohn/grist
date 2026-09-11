import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Read local files into plain text for appending into a note body (AI-readable).
enum NoteFileImporter {
    enum ImportError: LocalizedError {
        case unsupportedType(String)
        case unreadable
        case emptyPDF
        case emptyFile

        var errorDescription: String? {
            switch self {
            case .unsupportedType(let ext):
                return "Unsupported file type “\(ext)”. Use .md, .txt, or .pdf."
            case .unreadable:
                return "Could not read that file."
            case .emptyPDF:
                return "No extractable text in this PDF (it may be a scan/image-only)."
            case .emptyFile:
                return "That file is empty."
            }
        }
    }

    static let allowedContentTypes: [UTType] = [
        .plainText,
        .utf8PlainText,
        .text,
        UTType(filenameExtension: "md") ?? .plainText,
        UTType(filenameExtension: "markdown") ?? .plainText,
        .pdf,
    ]

    static func extractText(from url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "txt", "text", "":
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                throw ImportError.unreadable
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ImportError.emptyFile }
            return text

        case "pdf":
            guard let doc = PDFDocument(url: url) else { throw ImportError.unreadable }
            var parts: [String] = []
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i), let s = page.string, !s.isEmpty {
                    parts.append(s)
                }
            }
            let joined = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty else { throw ImportError.emptyPDF }
            return joined

        default:
            throw ImportError.unsupportedType(ext.isEmpty ? "(none)" : ext)
        }
    }

    /// Markdown block appended into `manualNotes`.
    static func attachmentBlock(filename: String, body: String) -> String {
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = name.isEmpty ? "file" : name
        return """

        ---
        **Attached:** `\(safeName)`

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))

        """
    }
}
