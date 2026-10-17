import SwiftUI
import AppKit

private enum IntegrationChoice: String, CaseIterable {
    case obsidian, notion

    var title: String { rawValue.capitalized }
    var icon: String { self == .obsidian ? "book.closed.fill" : "square.inset.filled" }
    var detail: String { self == .obsidian ? "Local Markdown vault" : "Pages and databases" }
    var tint: Color { self == .obsidian ? .purple : .accentColor }
}

struct IntegrationsSettingsView: View {
    @ObservedObject private var integrations = IntegrationsConfigManager.shared
    @State private var selected: IntegrationChoice = .obsidian
    @State private var obsidian: ObsidianIntegrationConfig = .default
    @State private var notion: NotionIntegrationConfig = .default
    @State private var notionToken = ""
    @State private var message = ""

    private var hasChanges: Bool {
        selected == .obsidian
            ? obsidian != integrations.config.obsidian
            : notion != integrations.config.notion || !notionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        ForEach(IntegrationChoice.allCases, id: \.self) { choice in
                            integrationChoice(choice)
                        }
                    }
                    if selected == .obsidian { obsidianContent }
                    else { notionContent }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 12) {
                if !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if hasChanges {
                    Label("Unsaved changes", systemImage: "circle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text("Changes are saved").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save \(selected.title)") { saveSelected() }
                    .buttonStyle(.borderedProminent)
                    .tint(selected.tint)
                    .disabled(!hasChanges)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onAppear {
            obsidian = integrations.config.obsidian
            notion = integrations.config.notion
            notionToken = ""
        }
        .onChange(of: obsidian) { _, _ in message = "" }
        .onChange(of: notion) { _, _ in message = "" }
        .onChange(of: notionToken) { _, _ in message = "" }
    }

    private func integrationChoice(_ choice: IntegrationChoice) -> some View {
        let active = selected == choice
        let enabled = choice == .obsidian ? obsidian.enabled : notion.enabled
        let ready = choice == .obsidian
            ? !obsidian.vaultPath.isEmpty
            : [notion.parentPageID, notion.meetingPageID, notion.notePageID, notion.taskPageID].contains { !$0.isEmpty }
        let changed = choice == .obsidian
            ? obsidian != integrations.config.obsidian
            : notion != integrations.config.notion || !notionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button {
            selected = choice
            message = ""
        } label: {
            HStack(spacing: 12) {
                Image(systemName: choice.icon)
                    .font(.title3)
                    .foregroundStyle(choice.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(choice.title).font(.headline)
                    Text(choice.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(changed ? "Unsaved" : enabled ? (ready ? "Configured" : "Set up") : "Off")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(changed ? .orange : enabled && ready ? .green : .secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? choice.tint.opacity(0.10) : Color.primary.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(active ? choice.tint.opacity(0.45) : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private var obsidianContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            integrationSection("1", "Connect your vault", subtitle: "Quern writes Markdown files inside this folder.") {
                Toggle("Enable Obsidian export", isOn: $obsidian.enabled)
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(.purple)
                    Text(obsidian.vaultPath.isEmpty ? "No vault selected" : obsidian.vaultPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(obsidian.vaultPath.isEmpty ? .secondary : .primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") {
                        if let folder = ObsidianExporter.pickVaultFolder() { obsidian.vaultPath = folder.path }
                    }
                    if !obsidian.vaultPath.isEmpty {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: obsidian.vaultPath)])
                        } label: { Image(systemName: "arrow.up.right.square") }
                            .help("Reveal vault in Finder")
                    }
                }
                .padding(11)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            }

            integrationSection("2", "Choose destinations", subtitle: "Folders are relative to the vault. Quern creates them when exporting.") {
                destinationField("Meetings", icon: "video", hint: "One Markdown file per meeting",
                                 placeholder: "Default folder", text: $obsidian.meetingSubfolder)
                destinationField("Notes", icon: "note.text", hint: "One Markdown file per note",
                                 placeholder: "Default folder", text: $obsidian.noteSubfolder)
                destinationField("Tasks", icon: "checklist", hint: "One checklist, replaced on export",
                                 placeholder: "Quern/Todo.md", text: $obsidian.taskFilePath)
                DisclosureGroup("Default folder and file naming") {
                    VStack(alignment: .leading, spacing: 10) {
                        labeledField("Default folder", text: $obsidian.subfolder, placeholder: "Quern")
                        labeledField("File name", text: $obsidian.filenamePattern, placeholder: "{date}-{title}")
                        Text("Use {date}, {title}, or {id} in file names.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }.font(.callout)
            }

            integrationSection("3", "Export behavior", subtitle: "Manual export is available from each item. Tasks export from the Tasks page.") {
                Toggle("Export after Enhance", isOn: $obsidian.autoExportAfterEnhance)
                Toggle("Open exported file in Obsidian", isOn: $obsidian.openAfterExport)
                DisclosureGroup("Included content and advanced options") {
                    VStack(alignment: .leading, spacing: 9) {
                        Toggle("Metadata", isOn: $obsidian.includeMetadata)
                        Toggle("Sources and links", isOn: $obsidian.includeSources)
                        Toggle("AI summary", isOn: $obsidian.includeSummary)
                        Toggle("Notes body", isOn: $obsidian.includeNotes)
                        Toggle("Transcript and captions", isOn: $obsidian.includeTranscript)
                        labeledField("Vault name override", text: $obsidian.vaultName, placeholder: "Use folder name")
                    }.padding(.top, 8)
                }.font(.callout)
            }
        }
    }

    private var notionContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            integrationSection("1", "Connect Notion", subtitle: "The saved integration token stays in this Mac’s Keychain.") {
                Toggle("Enable Notion export", isOn: $notion.enabled)
                SecureField("Paste a token to connect or replace the saved one", text: $notionToken)
                    .textFieldStyle(.roundedBorder)
                Text("Leave this blank to keep your saved token. Quern reads it only when you test, search, or export.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Repair saved access") {
                    do {
                        try NotionSecretStore.repairSavedAccess()
                        message = "Saved Notion access repaired. Automatic exports will not ask for a password."
                    } catch { message = error.localizedDescription }
                }
                .help("Authorize this Quern installation to use your saved token. macOS may ask once during repair.")
                Text("Share each destination page or database with the integration in Notion before searching.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            integrationSection("2", "Choose destinations", subtitle: "Route each type to a Notion page or database.") {
                NotionConnectionTools(config: $notion, token: $notionToken)
            }

            integrationSection("3", "Export behavior", subtitle: "Notes and meetings can be sent manually from their action menu.") {
                Toggle("Export after Enhance", isOn: $notion.autoExportAfterEnhance)
                DisclosureGroup("Included content") {
                    VStack(alignment: .leading, spacing: 9) {
                        Toggle("AI summary", isOn: $notion.includeSummary)
                        Toggle("Notes body", isOn: $notion.includeNotes)
                        Toggle("Transcript and captions", isOn: $notion.includeTranscript)
                    }.padding(.top, 8)
                }.font(.callout)
            }
        }
    }

    private func integrationSection<Content: View>(_ number: String, _ title: String,
                                                   subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Text(number)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 23, height: 23)
                    .background(Color.primary.opacity(0.07), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.primary.opacity(0.07)))
    }

    private func destinationField(_ title: String, icon: String, hint: String,
                                  placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func labeledField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func saveSelected() {
        if selected == .obsidian {
            integrations.updateObsidian { $0 = obsidian }
            message = integrations.lastMessage == "Saved" ? "Obsidian settings saved" : integrations.lastMessage
        } else {
            do {
                if !notionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try NotionSecretStore.save(token: notionToken)
                }
                integrations.updateNotion { $0 = notion }
                notionToken = ""
                message = integrations.lastMessage == "Saved" ? "Notion settings saved" : integrations.lastMessage
            } catch { message = error.localizedDescription }
        }
    }
}
