import Foundation

#if os(macOS)
import AppKit
#endif

struct FetchedWebContent: Sendable {
    let title: String
    let content: String
    /// "youtube" | "web"
    let sourceKind: String
    /// YouTube episode links found on the page (e.g. podcast posts). Empty for pure YT imports.
    let relatedYouTubeURLs: [String]

    init(title: String, content: String, sourceKind: String, relatedYouTubeURLs: [String] = []) {
        self.title = title
        self.content = content
        self.sourceKind = sourceKind
        self.relatedYouTubeURLs = relatedYouTubeURLs
    }
}

enum URLFetchError: LocalizedError {
    case badURL
    case httpStatus(Int)
    case emptyContent
    case authWall(host: String)
    case loginChrome
    case noReadableContent

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "That doesn’t look like a valid URL."
        case .httpStatus(let code):
            if code == 401 || code == 403 {
                return "This page returned \(code) — it likely requires a login. Open it in a browser and paste the text into a Note, or use a public page."
            }
            return "Server returned HTTP \(code)."
        case .emptyContent:
            return "The page had no readable text."
        case .authWall(let host):
            return "\(host) blocked the fetch (login or app-only page). Open the link in a browser, copy the content, and paste into a Note. YouTube still works via captions if yt-dlp is installed."
        case .loginChrome:
            return "This page looks like a login / sign-up wall, not the article. Open it in a browser and paste the text into a Note."
        case .noReadableContent:
            return "Couldn’t extract readable article text from this URL. Try pasting the content into a Note instead."
        }
    }
}

actor URLFetcher {
    static let shared = URLFetcher()

    /// Hosts that usually need a session / JS app shell and rarely return real article text to a simple GET.
    private static let knownAuthHosts: Set<String> = [
        "x.com", "twitter.com", "mobile.twitter.com",
        "www.linkedin.com", "linkedin.com",
        "www.instagram.com", "instagram.com",
        "www.facebook.com", "facebook.com", "m.facebook.com",
        "www.threads.net", "threads.net",
    ]

    private static let loginMarkers: [String] = [
        "log in", "sign in", "sign up", "create account",
        "sign in to continue", "log in to continue",
        "cookie use", "terms of service", "privacy policy",
        "new to x?", "join x", "don't miss what's happening",
        "don’t miss what’s happening",
        "sign in with google", "sign in with apple",
        "continue with google", "continue with apple",
    ]

    func fetchContent(from urlString: String) async throws -> FetchedWebContent {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            throw URLFetchError.badURL
        }

        if YouTubeImporter.isYouTubeURL(trimmed) {
            let yt = try await YouTubeImporter.importVideo(urlString: trimmed)
            return FetchedWebContent(
                title: yt.title,
                content: yt.transcript,
                sourceKind: "youtube",
                relatedYouTubeURLs: [yt.sourceURL]
            )
        }

        let web = try await fetchWebContent(url: url)
        return FetchedWebContent(
            title: web.title,
            content: web.content,
            sourceKind: "web",
            relatedYouTubeURLs: web.youtubeURLs
        )
    }

    private func fetchWebContent(url: URL) async throws -> (title: String, content: String, youtubeURLs: [String]) {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLFetchError.noReadableContent
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw URLFetchError.httpStatus(httpResponse.statusCode)
        }

        guard (200...299).contains(httpResponse.statusCode),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw URLFetchError.httpStatus(httpResponse.statusCode)
        }

        let host = (url.host ?? "").lowercased()
        let title = Self.extractTitle(from: html)
        let youtubeURLs = Self.extractYouTubeURLs(fromHTML: html)
        var cleanedText = Self.htmlToPlainText(html)
        cleanedText = Self.trimSiteChrome(cleanedText)

        if cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if Self.isKnownAuthHost(host) {
                throw URLFetchError.authWall(host: host)
            }
            throw URLFetchError.emptyContent
        }

        if Self.looksLikeAuthWall(host: host, title: title, text: cleanedText, html: html) {
            if Self.isKnownAuthHost(host) {
                throw URLFetchError.authWall(host: host)
            }
            throw URLFetchError.loginChrome
        }

        // Reject trivially short extracts that aren't useful notes
        let wordCount = cleanedText.split { $0.isWhitespace || $0.isNewline }.count
        if wordCount < 40 {
            if Self.isKnownAuthHost(host) {
                throw URLFetchError.authWall(host: host)
            }
            throw URLFetchError.noReadableContent
        }

        return (title.isEmpty ? "Web Article" : title, cleanedText, youtubeURLs)
    }

    /// Find YouTube *video* links in page HTML (not channels / @handles).
    static func extractYouTubeURLs(fromHTML html: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()

        // Capture video id tightly so Substack JSON junk after the id is ignored.
        let patterns: [(String, Int)] = [
            // group 1 = video id
            (#"https?://(?:www\.)?youtube\.com/watch\?[^"'<>\s]*?[?&]v=([A-Za-z0-9_-]{6,15})"#, 1),
            (#"https?://(?:www\.)?youtube\.com/watch\?v=([A-Za-z0-9_-]{6,15})"#, 1),
            (#"https?://(?:www\.)?youtube\.com/embed/([A-Za-z0-9_-]{6,15})"#, 1),
            (#"https?://(?:www\.)?youtube\.com/live/([A-Za-z0-9_-]{6,15})"#, 1),
            (#"https?://(?:www\.)?youtube\.com/shorts/([A-Za-z0-9_-]{6,15})"#, 1),
            (#"https?://youtu\.be/([A-Za-z0-9_-]{6,15})"#, 1),
        ]

        for (pattern, group) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let ns = html as NSString
            let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            for m in matches {
                guard m.numberOfRanges > group else { continue }
                let id = ns.substring(with: m.range(at: group))
                // Real YT ids are 11 chars typically; allow short range to avoid channel noise
                guard (6...15).contains(id.count) else { continue }
                let canonical = "https://www.youtube.com/watch?v=\(id)"
                if seen.insert(canonical).inserted {
                    found.append(canonical)
                }
            }
        }
        return found
    }

    /// Normalize to https://www.youtube.com/watch?v=VIDEO_ID when this is a video URL.
    static func canonicalizeYouTubeURL(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&amp;", with: "&")
        guard YouTubeImporter.isYouTubeURL(trimmed) else { return nil }

        // Prefer regex extract (handles trailing JSON/HTML junk)
        let scraped = extractYouTubeURLs(fromHTML: trimmed)
        if let first = scraped.first { return first }

        guard let components = URLComponents(string: trimmed) else { return nil }
        let host = (components.host ?? "").lowercased()
        if host == "youtu.be" {
            let id = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .split(separator: "/").first.map(String.init) ?? ""
            guard (6...15).contains(id.count) else { return nil }
            return "https://www.youtube.com/watch?v=\(id)"
        }

        let path = components.path
        if path.contains("/embed/") || path.contains("/live/") || path.contains("/shorts/") {
            let id = path.split(separator: "/").last.map(String.init) ?? ""
            guard (6...15).contains(id.count) else { return nil }
            return "https://www.youtube.com/watch?v=\(id)"
        }

        if let items = components.queryItems, let v = items.first(where: { $0.name == "v" })?.value,
           (6...15).contains(v.count) {
            return "https://www.youtube.com/watch?v=\(v)"
        }

        // Channels / @handles /c/ — not episode videos
        return nil
    }

    /// Drop common nav / paywall chrome that pollutes Substack-style scrapes.
    private static func trimSiteChrome(_ text: String) -> String {
        var lines = text
            .replacingOccurrences(of: "\r", with: "")
            // Re-split long space-joined scrapes: keep as one block but strip known phrases
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let junkPhrases = [
            "Audio playback is not supported on your browser. Please upgrade.",
            "This post is for paid subscribers",
            "Already a paid subscriber? Sign in",
            "Start your Substack",
            "Get the app",
            "Substack is the home for great culture",
            "© 2026 Substack Inc",
            "Subscribe Sign in",
        ]
        for phrase in junkPhrases {
            lines = lines.replacingOccurrences(of: phrase, with: " ", options: .caseInsensitive)
        }

        // Collapse whitespace again
        if let regex = try? NSRegularExpression(pattern: "\\s+") {
            lines = regex.stringByReplacingMatches(
                in: lines,
                range: NSRange(location: 0, length: lines.utf16.count),
                withTemplate: " "
            )
        }
        return lines.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Extraction

    private static func extractTitle(from html: String) -> String {
        var title = "Web Article"
        if let titleRange = html.range(of: "<title>", options: .caseInsensitive),
           let endTitleRange = html.range(of: "</title>", options: .caseInsensitive),
           titleRange.upperBound < endTitleRange.lowerBound {
            title = String(html[titleRange.upperBound..<endTitleRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return decodeHTMLEntities(title)
    }

    private static func htmlToPlainText(_ html: String) -> String {
        var cleanHtml = html
        let patterns = [
            "<script[^>]*>.*?</script>",
            "<style[^>]*>.*?</style>",
            "<noscript[^>]*>.*?</noscript>",
            "<!--.*?-->",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.dotMatchesLineSeparators, .caseInsensitive]
            ) {
                cleanHtml = regex.stringByReplacingMatches(
                    in: cleanHtml,
                    range: NSRange(location: 0, length: cleanHtml.utf16.count),
                    withTemplate: ""
                )
            }
        }

        let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>")
        var text = tagRegex?.stringByReplacingMatches(
            in: cleanHtml,
            range: NSRange(location: 0, length: cleanHtml.utf16.count),
            withTemplate: " "
        ) ?? cleanHtml

        text = decodeHTMLEntities(text)

        let whitespaceRegex = try? NSRegularExpression(pattern: "\\s+")
        if let whitespaceRegex {
            text = whitespaceRegex.stringByReplacingMatches(
                in: text,
                range: NSRange(location: 0, length: text.utf16.count),
                withTemplate: " "
            )
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decode common HTML entities (&quot; &#x27; &amp; numeric).
    static func decodeHTMLEntities(_ raw: String) -> String {
        guard raw.contains("&") else { return raw }
        var s = raw
        let named: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&#39;", "'"),
            ("&#x27;", "'"),
            ("&#x2F;", "/"),
            ("&ldquo;", "\""),
            ("&rdquo;", "\""),
            ("&lsquo;", "'"),
            ("&rsquo;", "'"),
            ("&mdash;", "—"),
            ("&ndash;", "–"),
            ("&hellip;", "…"),
        ]
        for (entity, replacement) in named {
            s = s.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }

        // Numeric decimal: &#123;
        if let dec = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let ns = s as NSString
            let matches = dec.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed()
            for m in matches {
                guard m.numberOfRanges >= 2 else { continue }
                let numStr = ns.substring(with: m.range(at: 1))
                if let code = Int(numStr), let scalar = UnicodeScalar(code) {
                    s = (s as NSString).replacingCharacters(in: m.range, with: String(Character(scalar)))
                }
            }
        }

        // Numeric hex: &#x1F;
        if let hex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);") {
            let ns = s as NSString
            let matches = hex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed()
            for m in matches {
                guard m.numberOfRanges >= 2 else { continue }
                let numStr = ns.substring(with: m.range(at: 1))
                if let code = Int(numStr, radix: 16), let scalar = UnicodeScalar(code) {
                    s = (s as NSString).replacingCharacters(in: m.range, with: String(Character(scalar)))
                }
            }
        }

        return s
    }

    // MARK: - Auth / login detection

    private static func isKnownAuthHost(_ host: String) -> Bool {
        if knownAuthHosts.contains(host) { return true }
        // subdomain match e.g. mobile.x.com
        return knownAuthHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private static func looksLikeAuthWall(host: String, title: String, text: String, html: String) -> Bool {
        let lowerText = text.lowercased()
        let lowerTitle = title.lowercased()
        let lowerHTML = html.lowercased()

        // Explicit login chrome in extracted text
        var markerHits = 0
        for marker in loginMarkers {
            if lowerText.contains(marker) {
                markerHits += 1
            }
        }

        // X/Twitter title chrome: "… on X: … / X"
        let xTitleChrome =
            lowerTitle.contains(" on x:")
            || lowerTitle.hasSuffix(" / x")
            || lowerTitle.contains(" / x")

        if isKnownAuthHost(host) {
            // Social apps almost always ship a shell; require either login markers or weak content signal
            if markerHits >= 2 || xTitleChrome { return true }
            // og:description often missing when gated; many "Sign in" buttons in raw HTML
            let signInInHTML =
                lowerHTML.contains("log in")
                || lowerHTML.contains("sign in")
                || lowerHTML.contains("data-testid=\"login")
            if signInInHTML && markerHits >= 1 { return true }
            // Still mostly marketing chrome for X
            if host.contains("x.com") || host.contains("twitter.com") {
                if lowerText.contains("don't miss what")
                    || lowerText.contains("don’t miss what")
                    || lowerText.contains("people on x are the first to know")
                    || lowerText.contains("new to x?") {
                    return true
                }
            }
        } else {
            // Generic sites: only fail when clearly a login wall
            if markerHits >= 3 {
                // Avoid false positives on pages that merely link "Privacy Policy"
                let strong = ["log in", "sign in", "sign up", "create account", "sign in to continue"]
                let strongHits = strong.filter { lowerText.contains($0) }.count
                if strongHits >= 2 { return true }
            }
        }

        // Title still full of raw entities after decode attempt means bad scrape
        if title.contains("&quot;") || title.contains("&#") {
            return true
        }

        return false
    }
}
