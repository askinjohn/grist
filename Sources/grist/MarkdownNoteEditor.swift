import SwiftUI
import AppKit

/// Formatting actions for the markdown note body.
enum MarkdownFormatCommand: Equatable {
    case bold
    case italic
    case strikethrough
    case heading
    case bullet
    case numbered
    case checkbox
    case quote
    case code
    case codeBlock
    case link
    case divider
}

/// NSTextView-backed editor so we can wrap the real selection (SwiftUI `TextEditor` cannot).
struct MarkdownNoteEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var pendingFormat: MarkdownFormatCommand?
    var fontSize: CGFloat = 16

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let tv = NSTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.usesFindBar = true
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: 0, height: 8)
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = .labelColor
        tv.string = text
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        context.coordinator.textView = tv
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self

        if tv.string != text, !context.coordinator.isEditing {
            let selected = tv.selectedRange()
            tv.string = text
            let maxLen = (tv.string as NSString).length
            let loc = min(selected.location, maxLen)
            let len = min(selected.length, max(0, maxLen - loc))
            tv.setSelectedRange(NSRange(location: loc, length: len))
        }

        if let cmd = pendingFormat {
            context.coordinator.apply(cmd)
            DispatchQueue.main.async {
                context.coordinator.parent.pendingFormat = nil
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownNoteEditor
        weak var textView: NSTextView?
        var isEditing = false

        init(_ parent: MarkdownNoteEditor) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
            sync()
        }

        func textDidChange(_ notification: Notification) {
            sync()
        }

        private func sync() {
            guard let tv = textView else { return }
            if parent.text != tv.string {
                parent.text = tv.string
            }
        }

        func apply(_ command: MarkdownFormatCommand) {
            guard let tv = textView else { return }
            let full = tv.string as NSString
            var range = tv.selectedRange()
            if range.location == NSNotFound {
                range = NSRange(location: full.length, length: 0)
            }
            let selected = range.length > 0 ? full.substring(with: range) : ""

            switch command {
            case .bold:
                wrap(tv, range: range, selected: selected, left: "**", right: "**")
            case .italic:
                wrap(tv, range: range, selected: selected, left: "*", right: "*")
            case .strikethrough:
                wrap(tv, range: range, selected: selected, left: "~~", right: "~~")
            case .code:
                wrap(tv, range: range, selected: selected, left: "`", right: "`")
            case .codeBlock:
                if selected.isEmpty {
                    replace(tv, range: range, with: "```\n\n```", cursorOffset: 4)
                } else {
                    replace(tv, range: range, with: "```\n\(selected)\n```", cursorOffset: ("```\n\(selected)\n```" as NSString).length)
                }
            case .link:
                if selected.isEmpty {
                    replace(tv, range: range, with: "[text](url)", cursorOffset: 1)
                } else if selected.lowercased().hasPrefix("http") {
                    let r = "[\(selected)](\(selected))"
                    replace(tv, range: range, with: r, cursorOffset: (r as NSString).length)
                } else {
                    let r = "[\(selected)](url)"
                    replace(tv, range: range, with: r, cursorOffset: 1 + selected.count + 2)
                }
            case .heading:
                let lineRange = full.lineRange(for: range)
                let line = full.substring(with: lineRange)
                let endsNL = line.hasSuffix("\n")
                var body = line.trimmingCharacters(in: CharacterSet.newlines)
                if body.hasPrefix("### ") {
                    body = String(body.dropFirst(4))
                } else if body.hasPrefix("## ") {
                    body = "### " + String(body.dropFirst(3))
                } else if body.hasPrefix("# ") {
                    body = "## " + String(body.dropFirst(2))
                } else {
                    body = "## " + body
                }
                let rep = body + (endsNL ? "\n" : "")
                replace(tv, range: lineRange, with: rep, cursorOffset: (rep as NSString).length)
            case .bullet:
                toggleLinePrefix(tv, range: range, marker: "- ")
            case .numbered:
                toggleLinePrefix(tv, range: range, marker: "1. ")
            case .checkbox:
                toggleLinePrefix(tv, range: range, marker: "- [ ] ")
            case .quote:
                toggleLinePrefix(tv, range: range, marker: "> ")
            case .divider:
                let needsNL = range.location > 0 && full.character(at: range.location - 1) != 10
                let rep = (needsNL ? "\n" : "") + "\n---\n\n"
                replace(tv, range: range, with: rep, cursorOffset: (rep as NSString).length)
            }
        }

        private func wrap(_ tv: NSTextView, range: NSRange, selected: String, left: String, right: String) {
            if selected.isEmpty {
                let rep = left + right
                replace(tv, range: range, with: rep, cursorOffset: left.count)
            } else {
                // Toggle off if already wrapped
                if selected.hasPrefix(left), selected.hasSuffix(right), selected.count >= left.count + right.count {
                    let inner = String(selected.dropFirst(left.count).dropLast(right.count))
                    replace(tv, range: range, with: inner, cursorOffset: (inner as NSString).length)
                } else {
                    let rep = left + selected + right
                    replace(tv, range: range, with: rep, cursorOffset: (rep as NSString).length)
                }
            }
        }

        private func toggleLinePrefix(_ tv: NSTextView, range: NSRange, marker: String) {
            let full = tv.string as NSString
            let workRange: NSRange
            let selected: String
            if range.length == 0 {
                workRange = full.lineRange(for: range)
                selected = full.substring(with: workRange)
            } else {
                workRange = range
                selected = full.substring(with: range)
            }
            let endsNL = selected.hasSuffix("\n")
            let core = endsNL ? String(selected.dropLast()) : selected
            let lines = core.components(separatedBy: "\n")
            let mapped = lines.map { line -> String in
                if line.isEmpty { return marker.trimmingCharacters(in: .whitespaces).isEmpty ? line : marker }
                if line.hasPrefix(marker) { return String(line.dropFirst(marker.count)) }
                return marker + line
            }.joined(separator: "\n") + (endsNL ? "\n" : "")
            replace(tv, range: workRange, with: mapped, cursorOffset: (mapped as NSString).length)
        }

        private func replace(_ tv: NSTextView, range: NSRange, with string: String, cursorOffset: Int) {
            guard tv.shouldChangeText(in: range, replacementString: string) else { return }
            tv.textStorage?.replaceCharacters(in: range, with: string)
            tv.didChangeText()
            let maxLen = (tv.string as NSString).length
            tv.setSelectedRange(NSRange(location: min(range.location + cursorOffset, maxLen), length: 0))
            sync()
        }
    }
}

// MARK: - Format toolbar

struct MarkdownFormatToolbar: View {
    @Binding var pendingFormat: MarkdownFormatCommand?

    var body: some View {
        HStack(spacing: 2) {
            group {
                fmtButton("bold", help: "Bold (wrap **)", cmd: .bold)
                fmtButton("italic", help: "Italic (wrap *)", cmd: .italic)
                fmtButton("strikethrough", help: "Strikethrough", cmd: .strikethrough)
            }
            Divider().frame(height: 18).padding(.horizontal, 4)
            group {
                fmtButton("textformat.size", help: "Heading", cmd: .heading)
                fmtButton("list.bullet", help: "Bullet list", cmd: .bullet)
                fmtButton("list.number", help: "Numbered list", cmd: .numbered)
                fmtButton("checklist", help: "Checklist", cmd: .checkbox)
            }
            Divider().frame(height: 18).padding(.horizontal, 4)
            group {
                fmtButton("text.quote", help: "Quote", cmd: .quote)
                fmtButton("chevron.left.forwardslash.chevron.right", help: "Inline code", cmd: .code)
                fmtButton("curlybraces", help: "Code block", cmd: .codeBlock)
                fmtButton("link", help: "Link", cmd: .link)
                fmtButton("minus", help: "Divider", cmd: .divider)
            }
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2, content: content)
    }

    private func fmtButton(_ systemImage: String, help: String, cmd: MarkdownFormatCommand) -> some View {
        Button {
            pendingFormat = cmd
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .help(help)
    }
}
