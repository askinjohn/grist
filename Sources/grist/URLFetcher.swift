import Foundation
import WebKit

#if os(macOS)
import AppKit
#endif

actor URLFetcher {
    static let shared = URLFetcher()
    
    func fetchContent(from urlString: String) async throws -> (title: String, content: String) {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        return try await fetchWebContent(url: url)
    }
    
    private func fetchWebContent(url: URL) async throws -> (title: String, content: String) {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }
        
        var title = "Web Article"
        if let titleRange = html.range(of: "<title>"), let endTitleRange = html.range(of: "</title>") {
            title = String(html[titleRange.upperBound..<endTitleRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // Strip scripts and styles
        var cleanHtml = html
        let scriptRegex = try NSRegularExpression(pattern: "<script[^>]*>.*?</script>", options: [.dotMatchesLineSeparators, .caseInsensitive])
        cleanHtml = scriptRegex.stringByReplacingMatches(in: cleanHtml, range: NSRange(location: 0, length: cleanHtml.utf16.count), withTemplate: "")
        
        let styleRegex = try NSRegularExpression(pattern: "<style[^>]*>.*?</style>", options: [.dotMatchesLineSeparators, .caseInsensitive])
        cleanHtml = styleRegex.stringByReplacingMatches(in: cleanHtml, range: NSRange(location: 0, length: cleanHtml.utf16.count), withTemplate: "")
        
        // Strip all remaining HTML tags
        let tagRegex = try NSRegularExpression(pattern: "<[^>]+>")
        let text = tagRegex.stringByReplacingMatches(in: cleanHtml, range: NSRange(location: 0, length: cleanHtml.utf16.count), withTemplate: " ")
        
        // Clean up whitespace
        let whitespaceRegex = try NSRegularExpression(pattern: "\\s+")
        let cleanedText = whitespaceRegex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: text.utf16.count), withTemplate: " ")
        
        return (title, cleanedText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
