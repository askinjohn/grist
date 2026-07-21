import SwiftUI
import WebKit

// MARK: - Markdown → HTML Converter (No external deps)

struct MarkdownRenderer {
    static func toHTML(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var html = ""
        var inList = false
        var inCodeBlock = false

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
                continue
            }

            if inCodeBlock {
                html += escapeHTML(line) + "\n"
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
            } else if trimmed.hasPrefix("### ") {
                html += "<h3>\(inline(trimmed.dropFirst(4)))</h3>\n"
            } else if trimmed.hasPrefix("## ") {
                html += "<h2>\(inline(trimmed.dropFirst(3)))</h2>\n"
            } else if trimmed.hasPrefix("# ") {
                html += "<h1>\(inline(trimmed.dropFirst(2)))</h1>\n"
            // Horizontal rule
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                html += "<hr/>\n"
            // Bullet list
            } else if isBullet {
                if !inList { html += "<ul>\n"; inList = true }
                let content = String(trimmed.dropFirst(2))
                html += "<li>\(inline(content))</li>\n"
            // Blockquote
            } else if trimmed.hasPrefix("> ") {
                html += "<blockquote>\(inline(String(trimmed.dropFirst(2))))</blockquote>\n"
            // Empty line → paragraph break
            } else if trimmed.isEmpty {
                html += "<br/>\n"
            // Regular paragraph
            } else {
                html += "<p>\(inline(trimmed))</p>\n"
            }
        }

        if inList { html += "</ul>\n" }
        if inCodeBlock { html += "</code></pre>\n" }

        return wrapHTML(html)
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
        // Links
        s = applyRegex(s, pattern: #"\[(.+?)\]\((.+?)\)"#, replacement: "<a href=\"$2\">$1</a>")
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

    private static func wrapHTML(_ body: String) -> String {
        """
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
            font-size: 14px;
            line-height: 1.65;
            padding: 20px 24px 40px;
          }
          h1, h2, h3, h4 {
            color: var(--text);
            font-family: -apple-system, 'SF Pro Display', sans-serif;
            font-weight: 700;
            margin-top: 20px;
            margin-bottom: 6px;
          }
          h1 { font-size: 22px; border-bottom: 1px solid var(--border); padding-bottom: 8px; margin-bottom: 12px; }
          h2 { font-size: 17px; }
          h3 { font-size: 15px; color: var(--subtext); font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em; }
          h4 { font-size: 14px; }
          p  { margin: 6px 0; color: var(--text); }
          ul { padding-left: 20px; margin: 6px 0; }
          li { margin: 3px 0; }
          li::marker { color: var(--accent); }
          code {
            background: var(--code-bg);
            color: var(--code-text);
            font-family: 'SF Mono', Menlo, Monaco, monospace;
            font-size: 12.5px;
            padding: 2px 5px;
            border-radius: 4px;
          }
          pre {
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 14px 16px;
            overflow-x: auto;
            margin: 12px 0;
          }
          pre code {
            background: none;
            color: var(--text);
            padding: 0;
            font-size: 12.5px;
          }
          blockquote {
            border-left: 3px solid var(--accent);
            padding-left: 14px;
            margin: 10px 0;
            color: var(--subtext);
            font-style: italic;
          }
          hr {
            border: none;
            border-top: 1px solid var(--border);
            margin: 14px 0;
          }
          a { color: var(--accent); text-decoration: none; }
          a:hover { text-decoration: underline; }
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

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground") // transparent bg, let SwiftUI control it
        wv.allowsMagnification = false
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        let html = MarkdownRenderer.toHTML(markdown)
        wv.loadHTMLString(html, baseURL: nil)
    }
}
