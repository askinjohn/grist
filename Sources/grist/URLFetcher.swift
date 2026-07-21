import Foundation

#if os(macOS)
import AppKit
#endif

struct FetchedWebContent: Sendable {
    let title: String
    let content: String
    /// "youtube" | "web"
    let sourceKind: String
}

actor URLFetcher {
    static let shared = URLFetcher()

    func fetchContent(from urlString: String) async throws -> FetchedWebContent {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            throw URLError(.badURL)
        }

        if YouTubeImporter.isYouTubeURL(trimmed) {
            let yt = try await YouTubeImporter.importVideo(urlString: trimmed)
            return FetchedWebContent(
                title: yt.title,
                content: yt.transcript,
                sourceKind: "youtube"
            )
        }

        let web = try await fetchWebContent(url: url)
        return FetchedWebContent(title: web.title, content: web.content, sourceKind: "web")
    }

    private func fetchWebContent(url: URL) async throws -> (title: String, content: String) {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }

        var title = "Web Article"
        if let titleRange = html.range(of: "<title>"), let endTitleRange = html.range(of: "</title>") {
            title = String(html[titleRange.upperBound..<endTitleRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var cleanHtml = html
        let scriptRegex = try NSRegularExpression(
            pattern: "<script[^>]*>.*?</script>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        )
        cleanHtml = scriptRegex.stringByReplacingMatches(
            in: cleanHtml,
            range: NSRange(location: 0, length: cleanHtml.utf16.count),
            withTemplate: ""
        )

        let styleRegex = try NSRegularExpression(
            pattern: "<style[^>]*>.*?</style>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        )
        cleanHtml = styleRegex.stringByReplacingMatches(
            in: cleanHtml,
            range: NSRange(location: 0, length: cleanHtml.utf16.count),
            withTemplate: ""
        )

        let tagRegex = try NSRegularExpression(pattern: "<[^>]+>")
        let text = tagRegex.stringByReplacingMatches(
            in: cleanHtml,
            range: NSRange(location: 0, length: cleanHtml.utf16.count),
            withTemplate: " "
        )

        let whitespaceRegex = try NSRegularExpression(pattern: "\\s+")
        let cleanedText = whitespaceRegex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: text.utf16.count),
            withTemplate: " "
        )

        return (title, cleanedText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
