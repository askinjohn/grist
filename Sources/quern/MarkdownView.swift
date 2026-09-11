import SwiftUI
import WebKit

// MARK: - Markdown → HTML Converter (No external deps)

struct MarkdownRenderer {
    /// - Parameters:
    ///   - compact: Tighter type and spacing for AI summaries (less vertical whitespace).
    static func toHTML(
        _ markdown: String,
        bodyFontSize: CGFloat = 14,
        contentPadding: CGFloat = 24,
        compact: Bool = false
    ) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var html = ""
        var inList = false
        var inCodeBlock = false
        // Collapse runs of blank lines in compact mode (model often emits double blanks)
        var lastWasBlank = false

        for (_, line) in lines.enumerated() {
            // Code fence
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCodeBlock {
                    html += "</code></pre>\n"
                    inCodeBlock = false
                } else {
                    if inList { html += "</ul>\n"; inList = false }
                    html += "<pre><code>"
                    inCodeBlock = true
                }
                lastWasBlank = false
                continue
            }

            if inCodeBlock {
                html += escapeHTML(line) + "\n"
                lastWasBlank = false
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Close list if line is not a bullet
            let isBullet = trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("• ")
            if inList && !isBullet && !trimmed.isEmpty {
                html += "</ul>\n"
                inList = false
            }

            // Headings
            if trimmed.hasPrefix("#### ") {
                html += "<h4>\(inline(trimmed.dropFirst(5)))</h4>\n"
                lastWasBlank = false
            } else if trimmed.hasPrefix("### ") {
                html += "<h3>\(inline(trimmed.dropFirst(4)))</h3>\n"
                lastWasBlank = false
            } else if trimmed.hasPrefix("## ") {
                html += "<h2>\(inline(trimmed.dropFirst(3)))</h2>\n"
                lastWasBlank = false
            } else if trimmed.hasPrefix("# ") {
                html += "<h1>\(inline(trimmed.dropFirst(2)))</h1>\n"
                lastWasBlank = false
            // Horizontal rule
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                html += "<hr/>\n"
                lastWasBlank = false
            // Bullet list
            } else if isBullet {
                if !inList { html += "<ul>\n"; inList = true }
                let content = String(trimmed.dropFirst(2))
                html += "<li>\(inline(content))</li>\n"
                lastWasBlank = false
            // Blockquote
            } else if trimmed.hasPrefix("> ") {
                html += "<blockquote>\(inline(String(trimmed.dropFirst(2))))</blockquote>\n"
                lastWasBlank = false
            // Empty line → paragraph break (skip double blanks when compact)
            } else if trimmed.isEmpty {
                if compact {
                    if !lastWasBlank {
                        html += "\n" // spacing via CSS only; no extra <br/>
                        lastWasBlank = true
                    }
                } else {
                    html += "<br/>\n"
                    lastWasBlank = true
                }
            // Regular paragraph
            } else {
                html += "<p>\(inline(trimmed))</p>\n"
                lastWasBlank = false
            }
        }

        if inList { html += "</ul>\n" }
        if inCodeBlock { html += "</code></pre>\n" }

        return wrapHTML(html, bodyFontSize: bodyFontSize, contentPadding: contentPadding, compact: compact)
    }

    // Process inline styles: **bold**, *italic*, `code`, [link](url)
    private static func inline(_ input: Substring) -> String {
        inline(String(input))
    }

    private static func inline(_ input: String) -> String {
        var s = escapeHTML(input)
        // Bold+italic
        s = applyRegex(s, pattern: #"\*\*\*(.+?)\*\*\*"#, replacement: "<strong><em>$1</em></strong>")
        // Bold
        s = applyRegex(s, pattern: #"\*\*(.+?)\*\*"#, replacement: "<strong>$1</strong>")
        s = applyRegex(s, pattern: #"__(.+?)__"#, replacement: "<strong>$1</strong>")
        // Italic
        s = applyRegex(s, pattern: #"\*(.+?)\*"#, replacement: "<em>$1</em>")
        s = applyRegex(s, pattern: #"_(.+?)_"#, replacement: "<em>$1</em>")
        // Inline code
        s = applyRegex(s, pattern: #"`(.+?)`"#, replacement: "<code>$1</code>")
        // Links — show label + selectable/copyable URL
        s = applyRegex(
            s,
            pattern: #"\[(.+?)\]\((.+?)\)"#,
            replacement: #"<a href="$2" title="$2">$1</a> <code class="url-plain">$2</code>"#
        )
        return s
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func applyRegex(_ input: String, pattern: String, replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return input }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: replacement)
    }

    private static func wrapHTML(
        _ body: String,
        bodyFontSize: CGFloat = 14,
        contentPadding: CGFloat = 24,
        compact: Bool = false
    ) -> String {
        let fontSize = Int(bodyFontSize.rounded())
        let pad = Int(contentPadding.rounded())
        let lineHeight = compact ? "1.45" : "1.7"
        let bodyPadV = compact ? 10 : 16
        let bodyPadBottom = compact ? 28 : 48
        let pMargin = compact ? "0 0 0.45em 0" : "0 0 1em 0"
        let hTop = compact ? 12 : 20
        let hBottom = compact ? 4 : 6
        let h1Size = compact ? 18 : 22
        let h2Size = compact ? 15 : 17
        let h3Size = compact ? 13 : 15
        let ulPad = compact ? 16 : 20
        let liMargin = compact ? 1 : 3
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
        <style>
          :root {
            color-scheme: light dark;
            --text: #1d1d1f;
            --subtext: #6e6e73;
            --bg: #ffffff;
            --surface: #f5f5f7;
            --border: #e0e0e5;
            --accent: #007aff;
            --code-bg: #f2f2f7;
            --code-text: #c0392b;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --text: #f5f5f7;
              --subtext: #98989d;
              --bg: #1c1c1e;
              --surface: #2c2c2e;
              --border: #3a3a3c;
              --accent: #0a84ff;
              --code-bg: #2c2c2e;
              --code-text: #ff6961;
            }
          }
          * { box-sizing: border-box; margin: 0; padding: 0; }
          html, body {
            background: var(--bg);
            color: var(--text);
            font-family: -apple-system, 'SF Pro Text', 'Helvetica Neue', sans-serif;
            font-size: \(fontSize)px;
            line-height: \(lineHeight);
            padding: \(bodyPadV)px \(pad)px \(bodyPadBottom)px;
            max-width: none;
            width: 100%;
          }
          p { margin: \(pMargin); max-width: none; }
          h1, h2, h3, h4 {
            color: var(--text);
            font-family: -apple-system, 'SF Pro Display', sans-serif;
            font-weight: 700;
            margin-top: \(hTop)px;
            margin-bottom: \(hBottom)px;
          }
          h1:first-child, h2:first-child, h3:first-child { margin-top: 0; }
          h1 { font-size: \(h1Size)px; border-bottom: 1px solid var(--border); padding-bottom: \(compact ? 4 : 8)px; margin-bottom: \(compact ? 8 : 12)px; }
          h2 { font-size: \(h2Size)px; }
          h3 { font-size: \(h3Size)px; color: var(--subtext); font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em; }
          h4 { font-size: \(compact ? 13 : 14)px; }
          ul { padding-left: \(ulPad)px; margin: \(compact ? 2 : 6)px 0 \(compact ? 6 : 6)px; }
          li { margin: \(liMargin)px 0; }
          li::marker { color: var(--accent); }
          code {
            background: var(--code-bg);
            color: var(--code-text);
            font-family: 'SF Mono', Menlo, Monaco, monospace;
            font-size: 0.9em;
            padding: 2px 5px;
            border-radius: 4px;
          }
          pre {
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: \(compact ? 10 : 14)px \(compact ? 12 : 16)px;
            overflow-x: auto;
            margin: \(compact ? 8 : 12)px 0;
          }
          pre code {
            background: none;
            color: var(--text);
            padding: 0;
            font-size: 0.9em;
          }
          blockquote {
            border-left: 3px solid var(--accent);
            padding-left: 14px;
            margin: \(compact ? 6 : 10)px 0;
            color: var(--subtext);
            font-style: italic;
          }
          hr {
            border: none;
            border-top: 1px solid var(--border);
            margin: \(compact ? 8 : 14)px 0;
          }
          a { color: var(--accent); text-decoration: none; user-select: text; -webkit-user-select: text; }
          a:hover { text-decoration: underline; }
          code.url-plain {
            background: transparent;
            color: var(--subtext);
            font-size: 0.85em;
            padding: 0 2px;
            word-break: break-all;
            user-select: all;
            -webkit-user-select: all;
          }
          body { user-select: text; -webkit-user-select: text; }
          strong { font-weight: 600; }
        </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }
}

// MARK: - WKWebView SwiftUI Wrapper

struct MarkdownView: NSViewRepresentable {
    let markdown: String
    /// Body font size in CSS px (notes can use larger type).
    var bodyFontSize: CGFloat = 14
    /// Horizontal padding inside the web document.
    var contentPadding: CGFloat = 24
    /// Denser layout for AI summaries (tighter headings, lists, padding).
    var compact: Bool = false

    /// Prefab for AI Summary tabs.
    static func summary(_ markdown: String) -> MarkdownView {
        MarkdownView(markdown: markdown, bodyFontSize: 13, contentPadding: 16, compact: true)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground") // transparent bg, let SwiftUI control it
        wv.allowsMagnification = false
        // Expand to whatever SwiftUI gives us (avoid intrinsic half-width sizing)
        wv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        wv.setContentHuggingPriority(.defaultLow, for: .vertical)
        wv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        let html = MarkdownRenderer.toHTML(
            markdown,
            bodyFontSize: bodyFontSize,
            contentPadding: contentPadding,
            compact: compact
        )
        // Avoid reloading the same document on every layout pass
        if context.coordinator.lastMarkdown != markdown
            || context.coordinator.lastFontSize != bodyFontSize
            || context.coordinator.lastPadding != contentPadding
            || context.coordinator.lastCompact != compact {
            context.coordinator.lastMarkdown = markdown
            context.coordinator.lastFontSize = bodyFontSize
            context.coordinator.lastPadding = contentPadding
            context.coordinator.lastCompact = compact
            wv.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastMarkdown: String = ""
        var lastCompact: Bool = false
        var lastFontSize: CGFloat = 0
        var lastPadding: CGFloat = 0
    }
}
