import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

extension MainView {
    // MARK: - Detail

    @ViewBuilder
    var detailContent: some View {
        Group {
            if selectedMeeting?.isNoteType == true {
                noteDetailView
            } else {
                meetingDetailView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { detailToolbar }
    }

    // MARK: - Shared chrome

    func startSelectionChat(text: String, title: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            statusMessage = "Select some text first"
            return
        }
        let id = "\(selectedMeeting?.id ?? "note")-\(abs(t.hashValue))"
        selectionChat = (id: id, title: title, text: t)
        selectedTab = "chat"
        statusMessage = "Chat scoped to selection"
    }

    func metaChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05))
        .clipShape(Capsule())
        .foregroundStyle(.secondary)
    }

    /// Prominent Enhance control that stays readable in light and dark mode.
    /// System `.borderedProminent` + blue tint often yields an empty blue pill in dark appearance.
    @ViewBuilder
    func enhanceToolbarButton(title: String, disabled: Bool, help: String) -> some View {
        Button {
            runEnhance()
        } label: {
            HStack(spacing: 6) {
                if statusMessage == "Enhancing…" {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                LinearGradient(
                    colors: disabled
                        ? [Color.gray.opacity(0.45), Color.gray.opacity(0.35)]
                        : [Color.blue, Color.purple.opacity(0.9)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.75 : 1)
        .help(help)
    }

    /// Play AI summary aloud (macOS system voice).
    @ViewBuilder
    func summarySpeechBar(text: String) -> some View {
        SummarySpeechBar(text: text)
    }

    func aiEmptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Empty Detail

    var emptyDetailPlaceholder: some View {
        VStack(spacing: 22) {
            QuernEmptyState(
                systemImage: "square.stack.3d.up",
                title: "Nothing selected",
                message: "Capture a meeting, jot a note, or pick something from the sidebar.",
                tint: .accent,
                badgeSize: 80
            )

            HStack(spacing: 14) {
                emptyCreateCard(kind: .meeting)
                emptyCreateCard(kind: .note)
                emptyCreateCard(kind: .article)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.windowBackground)
    }

    func emptyCreateCard(kind: CreateKind) -> some View {
        Button {
            openCreateSheet(kind: kind)
        } label: {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(kind.accent.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: kind.icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(kind.accent)
                }
                Text(kind.title)
                    .font(.headline)
                Text(kind.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 140)
            }
            .padding(20)
            .frame(width: 180, height: 160)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(kind.accent.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                withAnimation {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle Sidebar")
        }

        ToolbarItem(placement: .automatic) {
            Button {
                openCreateSheet(kind: .meeting)
            } label: {
                Label("New", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("Create meeting or note (⌘N)")
        }
    }

    @ToolbarContentBuilder
    var detailToolbar: some ToolbarContent {
        // Editable title in toolbar centre
        ToolbarItem(placement: .principal) {
            TextField("Title", text: Binding(
                get: { selectedMeeting?.title ?? "" },
                set: { selectedMeeting?.title = $0; saveMeeting() }
            ))
            .font(.headline)
            .multilineTextAlignment(.center)
            .textFieldStyle(.plain)
            .frame(maxWidth: 340)
        }

        // Recording status indicator — always has a frame to avoid zero-size warning
        ToolbarItem(placement: .status) {
            HStack(spacing: 6) {
                if isRecording {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle().stroke(.red.opacity(0.3), lineWidth: 4)
                                .scaleEffect(1.6)
                                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isRecording)
                        )
                    Text(formattedDuration(recordingSeconds))
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.red)
                        .frame(minWidth: 44)
                } else {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44)
                }
            }
            .frame(minWidth: 60)
        }

        // Export & Record / Note actions
        ToolbarItemGroup(placement: .primaryAction) {
            if let m = selectedMeeting {
                Menu {
                    Button {
                        attachFilesToCurrentNote()
                    } label: {
                        Label("Attach File…", systemImage: "doc.badge.plus")
                    }
                    .disabled(isAttachingFiles)
                    Button {
                        openImportSheet(appendToCurrent: true)
                    } label: {
                        Label("Add URL…", systemImage: "link.badge.plus")
                    }
                    .disabled(isImportingUrl)
                    Divider()
                    Button {
                        openExportSheet(meeting: m)
                    } label: {
                        Label("Export Markdown…", systemImage: "square.and.arrow.up")
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    Button {
                        sendToObsidian(meeting: m)
                    } label: {
                        Label("Send to Obsidian", systemImage: "book.closed")
                    }
                    .disabled(!IntegrationsConfigManager.shared.config.obsidian.isConfigured)
                    .help(IntegrationsConfigManager.shared.config.obsidian.isConfigured
                          ? "Write Markdown into your Obsidian vault"
                          : "Enable and pick a vault in Settings → Integrations")
                    if let folder = m.groupName, !folder.isEmpty {
                        Divider()
                        Button {
                            openFolderSummarize(name: folder)
                        } label: {
                            Label("Summarize Folder “\(folder)”…", systemImage: "sparkles")
                        }
                        Button {
                            openExportSheet(folder: folder)
                        } label: {
                            Label("Export Folder “\(folder)”…", systemImage: "folder")
                        }
                        Button {
                            sendFolderToObsidian(folder)
                        } label: {
                            Label("Send Folder to Obsidian…", systemImage: "book.closed")
                        }
                        .disabled(!IntegrationsConfigManager.shared.config.obsidian.isConfigured)
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export Markdown or send to Obsidian")
            }

            if selectedMeeting?.isNoteType == true {
                // Notes: recording is optional / secondary
                Button {
                    toggleRecording()
                } label: {
                    Label(isRecording ? "Stop" : "Record audio", systemImage: isRecording ? "stop.circle.fill" : "mic")
                }
                .help(isRecording ? "Stop and attach transcript" : "Optional: record audio into this note")
            } else {
                Button {
                    toggleRecording()
                } label: {
                    Label(
                        isRecording ? "Stop Recording" : "Record",
                        systemImage: isRecording ? "stop.circle.fill" : "record.circle"
                    )
                    .symbolRenderingMode(.multicolor)
                    .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderedProminent)
                .tint(isRecording ? .red : .accentColor)
                .help(isRecording ? "Stop and transcribe" : "Start recording")
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }

    // MARK: - Create Sheet helpers

    /// Default create folder: Unfiled (don't inherit sidebar focus — that mis-filed YT into Cooking).
    func preferredCreateFolder() -> String {
        ""
    }

    /// Open create sheet; kind is owned entirely by the sheet view.
    func openCreateSheet(kind: CreateKind) {
        createSheetRequest = CreateSheetRequest(kind: kind)
    }
}
