import Foundation

/// Fetch YouTube video title + caption transcript via `yt-dlp` (local CLI).
/// Not a network API key flow — user must have `yt-dlp` installed (setup.sh / Homebrew).
enum YouTubeImporter {
    struct Result: Sendable {
        let title: String
        let transcript: String
        let sourceURL: String
        let captionLanguage: String?
        let usedAutoCaptions: Bool
    }

    enum ImportError: LocalizedError {
        case notYouTube
        case ytDlpMissing
        case noCaptions
        case processFailed(String)
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .notYouTube:
                return "Not a YouTube URL."
            case .ytDlpMissing:
                return "yt-dlp is not installed. Run: brew install yt-dlp  (or re-run ./setup.sh)"
            case .noCaptions:
                return "No captions found for this video (manual or auto). Try another video, or record system audio while playing it."
            case .processFailed(let msg):
                return "yt-dlp failed: \(msg)"
            case .emptyTranscript:
                return "Captions downloaded but transcript was empty."
            }
        }
    }

    static func isYouTubeURL(_ string: String) -> Bool {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased() else { return false }
        return host.contains("youtube.com") || host == "youtu.be" || host.hasSuffix(".youtube.com")
    }

    static func resolveYtDlpPath() -> String? {
        let candidates = [
            UserDefaults.standard.string(forKey: "ytDlpPath"),
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/opt/homebrew/bin/yt-dlp",
            (ProcessInfo.processInfo.environment["HOME"] ?? "") + "/.local/bin/yt-dlp",
        ].compactMap { $0 }.filter { !$0.isEmpty }

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }

        // Fall back to PATH lookup
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["yt-dlp"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {}
        return nil
    }

    /// Download captions (prefer human en, else auto) and return plain-text transcript.
    static func importVideo(urlString: String) async throws -> Result {
        let urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isYouTubeURL(urlString) else { throw ImportError.notYouTube }
        guard let ytDlp = resolveYtDlpPath() else { throw ImportError.ytDlpMissing }

        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("grist-yt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        // Title (and id) without downloading media
        let titleOut = try await runProcess(
            executable: ytDlp,
            arguments: [
                "--skip-download",
                "--no-warnings",
                "--print", "%(title)s",
                urlString,
            ],
            cwd: tmpRoot
        )
        let title = titleOut.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first(where: { !$0.isEmpty }) ?? "YouTube Video"

        if titleOut.exitCode != 0 {
            let err = titleOut.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ImportError.processFailed(err.isEmpty ? "Could not read video metadata (exit \(titleOut.exitCode))" : err)
        }

        // Captions: human subs first, then auto-subs. English family preferred.
        let outTemplate = tmpRoot.appendingPathComponent("%(id)s").path
        let cap = try await runProcess(
            executable: ytDlp,
            arguments: [
                "--skip-download",
                "--no-warnings",
                "--write-subs",
                "--write-auto-subs",
                "--sub-langs", "en.*,en,en-US,en-GB",
                "--sub-format", "vtt/srt/best",
                "--convert-subs", "vtt",
                "-o", outTemplate,
                urlString,
            ],
            cwd: tmpRoot
        )

        if cap.exitCode != 0 {
            // Still try to find any subs that were written
            print("[YouTubeImporter] yt-dlp caption exit \(cap.exitCode): \(cap.stderr.prefix(300))")
        }

        let files = (try? FileManager.default.contentsOfDirectory(at: tmpRoot, includingPropertiesForKeys: nil)) ?? []
        let vttFiles = files.filter { $0.pathExtension.lowercased() == "vtt" || $0.lastPathComponent.contains(".vtt") }
        let srtFiles = files.filter { $0.pathExtension.lowercased() == "srt" }

        guard let captionURL = preferredCaptionFile(vtt: vttFiles, srt: srtFiles) else {
            throw ImportError.noCaptions
        }

        let raw = try String(contentsOf: captionURL, encoding: .utf8)
        let transcript: String
        if captionURL.pathExtension.lowercased() == "srt" || captionURL.lastPathComponent.hasSuffix(".srt") {
            transcript = parseSRT(raw)
        } else {
            transcript = parseVTT(raw)
        }

        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ImportError.emptyTranscript }

        let usedAuto = captionURL.lastPathComponent.contains(".auto.")
            || captionURL.lastPathComponent.contains("auto")
        let lang = extractLang(from: captionURL.lastPathComponent)

        // Readable paragraphs for the note editor (not one giant caption blob)
        let body = paragraphizeTranscript(cleaned)

        return Result(
            title: sanitizeTitle(title),
            transcript: body,
            sourceURL: urlString,
            captionLanguage: lang,
            usedAutoCaptions: usedAuto
        )
    }

    /// Turn caption stream into short paragraphs for reading / editing.
    static func paragraphizeTranscript(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return text }

        // Split into sentences (keep terminator)
        var sentences: [String] = []
        var current = ""
        for ch in collapsed {
            current.append(ch)
            if ".!?".contains(ch) {
                let s = current.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { sentences.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        if sentences.isEmpty { return collapsed }

        // Group ~3 sentences per paragraph
        var paragraphs: [String] = []
        var i = 0
        while i < sentences.count {
            let end = min(i + 3, sentences.count)
            paragraphs.append(sentences[i..<end].joined(separator: " "))
            i = end
        }
        return paragraphs.joined(separator: "\n\n")
    }

    // MARK: - Caption file pick

    private static func preferredCaptionFile(vtt: [URL], srt: [URL]) -> URL? {
        let all = vtt + srt
        guard !all.isEmpty else { return nil }
        // Prefer non-auto English, then any English, then any
        let scored = all.map { url -> (URL, Int) in
            let name = url.lastPathComponent.lowercased()
            var score = 0
            if name.contains(".en.") || name.contains(".en-") || name.hasSuffix(".en.vtt") || name.contains("en.vtt") {
                score += 10
            }
            if name.contains("en-us") || name.contains("en-gb") { score += 5 }
            if name.contains("auto") { score -= 3 }
            if name.hasSuffix(".vtt") { score += 1 }
            return (url, score)
        }
        return scored.max(by: { $0.1 < $1.1 })?.0
    }

    private static func extractLang(from filename: String) -> String? {
        // e.g. abc123.en.vtt, abc123.en-US.vtt, abc123.en.auto.vtt
        let parts = filename.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        // id.lang.ext or id.lang.auto.ext
        let candidate = String(parts[1])
        if candidate.count <= 8 { return candidate }
        return nil
    }

    private static func sanitizeTitle(_ title: String) -> String {
        var t = title
        // yt-dlp / HTML entities sometimes slip through
        let entities = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
        ]
        for (a, b) in entities {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - VTT / SRT parsers

    static func parseVTT(_ raw: String) -> String {
        var linesOut: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let upper = trimmed.uppercased()
            if upper.hasPrefix("WEBVTT") { continue }
            if upper.hasPrefix("NOTE") { continue }
            if upper.hasPrefix("KIND:") || upper.hasPrefix("LANGUAGE:") { continue }
            if trimmed.contains("-->") { continue }
            // Cue identifiers (often numeric)
            if trimmed.range(of: #"^\d+$"#, options: .regularExpression) != nil { continue }
            // Strip simple VTT tags: <c>, <00:00:00.000>, etc.
            var text = trimmed
            text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"&nbsp;"#, with: " ", options: .caseInsensitive)
            text = text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            // Only skip consecutive duplicates (auto-captions often repeat rolling lines)
            if linesOut.last == text { continue }
            linesOut.append(text)
        }
        return linesOut.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseSRT(_ raw: String) -> String {
        var linesOut: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.range(of: #"^\d+$"#, options: .regularExpression) != nil { continue }
            if trimmed.contains("-->") { continue }
            var text = trimmed.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            if linesOut.last == text { continue }
            linesOut.append(text)
        }
        return linesOut.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapseConsecutive(_ lines: [String]) -> [String] {
        var out: [String] = []
        for line in lines {
            if out.last == line { continue }
            out.append(line)
        }
        return out
    }

    // MARK: - Process

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static func runProcess(executable: String, arguments: [String], cwd: URL) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = arguments
            proc.currentDirectoryURL = cwd
            let out = Pipe()
            let err = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            proc.terminationHandler = { p in
                let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cont.resume(returning: ProcessResult(exitCode: p.terminationStatus, stdout: o, stderr: e))
            }
            do {
                try proc.run()
            } catch {
                cont.resume(throwing: ImportError.processFailed(error.localizedDescription))
            }
        }
    }
}
