import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct CreateItemSheet: View {
    let initialKind: CreateKind
    let folders: [String]
    let presetModels: [String]
    let templates: [String]
    let customTemplates: [AITemplate]
    let initialFolder: String
    let initialModel: String
    let onCancel: () -> Void
    let onCreate: (CreateItemPayload) -> Void

    @State private var kind: CreateKind
    @State private var title: String
    @State private var articleURL: String = ""
    @State private var folderSelection: String
    @State private var isCreatingNewFolder: Bool = false
    @State private var newFolderName: String = ""
    @State private var template: String
    @State private var model: String
    @State private var autoStartRecording: Bool

    init(
        initialKind: CreateKind,
        folders: [String],
        presetModels: [String],
        templates: [String],
        customTemplates: [AITemplate],
        initialFolder: String,
        initialModel: String,
        onCancel: @escaping () -> Void,
        onCreate: @escaping (CreateItemPayload) -> Void
    ) {
        self.initialKind = initialKind
        self.folders = folders
        self.presetModels = presetModels
        self.templates = templates
        self.customTemplates = customTemplates
        self.initialFolder = initialFolder
        self.initialModel = initialModel
        self.onCancel = onCancel
        self.onCreate = onCreate

        _kind = State(initialValue: initialKind)
        let defaultTitle: String = {
            switch initialKind {
            case .note, .article: return "Untitled Note"
            case .meeting: return "Untitled Meeting"
            }
        }()
        _title = State(initialValue: defaultTitle)
        _folderSelection = State(initialValue: initialFolder)
        _template = State(initialValue: (initialKind == .note || initialKind == .article) ? "Note" : "Standard Summary")
        _model = State(initialValue: initialModel)
        _autoStartRecording = State(initialValue: initialKind == .meeting)
    }

    private var createSheetTint: GristSheetTint {
        switch kind {
        case .meeting: return .red
        case .note: return .blue
        case .article: return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GristSheetHeader(
                title: "Create \(kind.title)",
                subtitle: kind.subtitle,
                systemImage: kind.icon,
                tint: createSheetTint,
                onClose: onCancel
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // 3 type tiles can wrap — use LazyVGrid
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(CreateKind.allCases) { k in
                            kindTile(k)
                        }
                    }

                    if kind == .article {
                        GristLabeledField(label: {
                            let n = MainView.parseImportURLs(from: articleURL).count
                            return n > 1 ? "URLs (\(n))" : "URL(s)"
                        }()) {
                            TextEditor(text: $articleURL)
                                .font(.body)
                                .frame(minHeight: 88, maxHeight: 130)
                                .gristFieldStyle(minHeight: 88)
                                .overlay(alignment: .topLeading) {
                                    if articleURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text("One or more links — one per line\nhttps://… article or YouTube")
                                            .font(.body)
                                            .foregroundStyle(.tertiary)
                                            .padding(.horizontal, 24)
                                            .padding(.vertical, 20)
                                            .allowsHitTesting(false)
                                    }
                                }
                        }
                        Group {
                            let parsed = MainView.parseImportURLs(from: articleURL)
                            let ytCount = parsed.filter { YouTubeImporter.isYouTubeURL($0) }.count
                            if ytCount > 0 {
                                Label(
                                    YouTubeImporter.resolveYtDlpPath() == nil
                                        ? "\(ytCount) YouTube — install yt-dlp: brew install yt-dlp"
                                        : "\(ytCount) YouTube — will import captions",
                                    systemImage: "play.rectangle.fill"
                                )
                                .font(.caption)
                                .foregroundStyle(YouTubeImporter.resolveYtDlpPath() == nil ? .orange : .secondary)
                            } else if parsed.count > 1 {
                                Text("Will import \(parsed.count) pages as separate notes")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        GristLabeledField(label: "Title") {
                            TextField(kind == .meeting ? "e.g. Weekly Sync" : "e.g. Product ideas", text: $title)
                                .textFieldStyle(.plain)
                                .gristFieldStyle()
                        }
                    }

                    GristLabeledField(label: folderSelection.isEmpty ? "Folder · Unfiled" : "Folder · \(folderSelection)") {
                        VStack(alignment: .leading, spacing: 10) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    chip("Unfiled", icon: "tray", selected: folderSelection.isEmpty && !isCreatingNewFolder) {
                                        isCreatingNewFolder = false
                                        folderSelection = ""
                                        newFolderName = ""
                                    }
                                    ForEach(folders.sorted(), id: \.self) { name in
                                        chip(name, icon: "folder.fill", selected: folderSelection == name && !isCreatingNewFolder) {
                                            isCreatingNewFolder = false
                                            folderSelection = name
                                            newFolderName = ""
                                        }
                                    }
                                    chip("New folder", icon: "folder.badge.plus", selected: isCreatingNewFolder) {
                                        isCreatingNewFolder = true
                                        folderSelection = ""
                                    }
                                }
                            }

                            if isCreatingNewFolder {
                                TextField("Folder name", text: $newFolderName)
                                    .textFieldStyle(.plain)
                                    .gristFieldStyle()
                                    .onChange(of: newFolderName) { _, val in
                                        folderSelection = val.trimmingCharacters(in: .whitespaces)
                                    }
                            }
                        }
                    }

                    if kind == .meeting {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("MEETING OPTIONS")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            HStack {
                                Text("Template")
                                Spacer()
                                Picker("", selection: $template) {
                                    ForEach(templates, id: \.self) { t in Text(t).tag(t) }
                                    if !customTemplates.isEmpty {
                                        Divider()
                                        ForEach(customTemplates) { ct in
                                            Text(ct.name).tag(ct.name)
                                        }
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 200)
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                            HStack {
                                Text("AI Model")
                                Spacer()
                                Picker("", selection: $model) {
                                    ForEach(presetModels, id: \.self) { m in Text(m).tag(m) }
                                }
                                .labelsHidden()
                                .frame(width: 200)
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                            Toggle(isOn: $autoStartRecording) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Start recording immediately")
                                    Text("Uses mic + system audio when permitted")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    } else if kind == .note {
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.blue)
                            Text("Creates a blank note. Opens the writing surface — no recording.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.orange)
                            Text("Fetches the page or YouTube captions, creates a Note, and can Enhance automatically if Auto is on.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
                .padding(.top, 16)
            }

            GristSheetFooter {
                Button("Cancel", action: onCancel)
            } trailing: {
                Button {
                    let folder: String? = {
                        if isCreatingNewFolder {
                            let n = newFolderName.trimmingCharacters(in: .whitespaces)
                            return n.isEmpty ? nil : n
                        }
                        let n = folderSelection.trimmingCharacters(in: .whitespaces)
                        return n.isEmpty ? nil : n
                    }()
                    let url = articleURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    onCreate(CreateItemPayload(
                        kind: kind,
                        title: title,
                        folderName: folder,
                        template: (kind == .note || kind == .article) ? "Note" : template,
                        model: model,
                        autoStartRecording: kind == .meeting && autoStartRecording,
                        articleURL: kind == .article ? url : nil
                    ))
                } label: {
                    Label(createButtonTitle, systemImage: createButtonIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(kind.accent)
                .disabled(kind == .article && MainView.parseImportURLs(from: articleURL).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 560, height: kind == .meeting ? 640 : 520)
        .animation(.easeInOut(duration: 0.2), value: kind)
    }

    private var createButtonTitle: String {
        switch kind {
        case .meeting: return autoStartRecording ? "Start Meeting" : "Create Meeting"
        case .note: return "Create Note"
        case .article:
            let n = MainView.parseImportURLs(from: articleURL).count
            return n > 1 ? "Import \(n) URLs" : "Import Article"
        }
    }

    private var createButtonIcon: String {
        switch kind {
        case .meeting: return "record.circle"
        case .note: return "square.and.pencil"
        case .article: return "square.and.arrow.down"
        }
    }

    private func kindTile(_ k: CreateKind) -> some View {
        let selected = kind == k
        return Button {
            kind = k
            autoStartRecording = (k == .meeting)
            switch k {
            case .note, .article:
                template = "Note"
                if isPlaceholderTitle(title) { title = "Untitled Note" }
            case .meeting:
                if template == "Note" { template = "Standard Summary" }
                if isPlaceholderTitle(title) { title = "Untitled Meeting" }
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: k.icon)
                        .font(.system(size: 26))
                        .foregroundStyle(k.accent)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? k.accent : Color.secondary.opacity(0.35))
                }
                Text(k.title)
                    .font(.headline)
                Text(k.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background(selected ? k.accent.opacity(0.14) : Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? k.accent.opacity(0.65) : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func chip(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption)
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
            .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.85))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(selected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func isPlaceholderTitle(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty || s.hasPrefix("Untitled ") || s.hasPrefix("Meeting ") || s.hasPrefix("Note ")
    }
}

// MARK: - Summary read-aloud bar

/// Observes `SpeechService` so Play/Stop and status update while speaking.
