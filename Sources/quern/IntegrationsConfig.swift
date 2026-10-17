import Foundation
import AppKit

/// User integrations (Obsidian, later Notion). Local file only.
struct IntegrationsFile: Codable, Equatable {
    var version: Int
    var obsidian: ObsidianIntegrationConfig
    var notion: NotionIntegrationConfig

    static let `default` = IntegrationsFile(
        version: 2,
        obsidian: .default,
        notion: .default
    )

    enum CodingKeys: String, CodingKey { case version, obsidian, notion }

    init(version: Int, obsidian: ObsidianIntegrationConfig, notion: NotionIntegrationConfig) {
        self.version = version
        self.obsidian = obsidian
        self.notion = notion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        obsidian = try c.decodeIfPresent(ObsidianIntegrationConfig.self, forKey: .obsidian) ?? .default
        notion = try c.decodeIfPresent(NotionIntegrationConfig.self, forKey: .notion) ?? .default
    }
}

/// Notion export settings. The integration token is deliberately stored in macOS Keychain, not JSON.
struct NotionIntegrationConfig: Codable, Equatable {
    var enabled: Bool
    /// Page ID from a Notion page shared with this integration.
    var parentPageID: String
    var destinationKind: String? = nil
    var destinationName: String? = nil
    /// Optional routes. Empty values keep older installations on the default destination.
    var meetingPageID: String = ""
    var meetingDestinationKind: String = "page"
    var meetingDestinationName: String = ""
    var notePageID: String = ""
    var noteDestinationKind: String = "page"
    var noteDestinationName: String = ""
    var taskPageID: String = ""
    var taskDestinationKind: String = "page"
    var taskDestinationName: String = ""
    var taskListPageID: String = ""
    var taskBlockIDs: [String] = []
    var autoExportAfterEnhance: Bool
    var includeSummary: Bool
    var includeNotes: Bool
    var includeTranscript: Bool

    static let `default` = NotionIntegrationConfig(
        enabled: false,
        parentPageID: "",
        autoExportAfterEnhance: false,
        includeSummary: true,
        includeNotes: true,
        includeTranscript: false
    )

    enum CodingKeys: String, CodingKey {
        case enabled, parentPageID, destinationKind, destinationName, autoExportAfterEnhance
        case includeSummary, includeNotes, includeTranscript
        case meetingPageID, meetingDestinationKind, meetingDestinationName
        case notePageID, noteDestinationKind, noteDestinationName
        case taskPageID, taskDestinationKind, taskDestinationName, taskListPageID, taskBlockIDs
    }

    init(enabled: Bool, parentPageID: String, autoExportAfterEnhance: Bool,
         includeSummary: Bool, includeNotes: Bool, includeTranscript: Bool) {
        self.enabled = enabled
        self.parentPageID = parentPageID
        self.autoExportAfterEnhance = autoExportAfterEnhance
        self.includeSummary = includeSummary
        self.includeNotes = includeNotes
        self.includeTranscript = includeTranscript
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        parentPageID = try c.decodeIfPresent(String.self, forKey: .parentPageID) ?? ""
        destinationKind = try c.decodeIfPresent(String.self, forKey: .destinationKind)
        destinationName = try c.decodeIfPresent(String.self, forKey: .destinationName)
        autoExportAfterEnhance = try c.decodeIfPresent(Bool.self, forKey: .autoExportAfterEnhance) ?? false
        includeSummary = try c.decodeIfPresent(Bool.self, forKey: .includeSummary) ?? true
        includeNotes = try c.decodeIfPresent(Bool.self, forKey: .includeNotes) ?? true
        includeTranscript = try c.decodeIfPresent(Bool.self, forKey: .includeTranscript) ?? false
        meetingPageID = try c.decodeIfPresent(String.self, forKey: .meetingPageID) ?? ""
        meetingDestinationKind = try c.decodeIfPresent(String.self, forKey: .meetingDestinationKind) ?? "page"
        meetingDestinationName = try c.decodeIfPresent(String.self, forKey: .meetingDestinationName) ?? ""
        notePageID = try c.decodeIfPresent(String.self, forKey: .notePageID) ?? ""
        noteDestinationKind = try c.decodeIfPresent(String.self, forKey: .noteDestinationKind) ?? "page"
        noteDestinationName = try c.decodeIfPresent(String.self, forKey: .noteDestinationName) ?? ""
        taskPageID = try c.decodeIfPresent(String.self, forKey: .taskPageID) ?? ""
        taskDestinationKind = try c.decodeIfPresent(String.self, forKey: .taskDestinationKind) ?? "page"
        taskDestinationName = try c.decodeIfPresent(String.self, forKey: .taskDestinationName) ?? ""
        taskListPageID = try c.decodeIfPresent(String.self, forKey: .taskListPageID) ?? ""
        taskBlockIDs = try c.decodeIfPresent([String].self, forKey: .taskBlockIDs) ?? []
    }

    var isConfigured: Bool {
        enabled
            && [parentPageID, meetingPageID, notePageID, taskPageID].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var exportOptions: ExportOptions {
        ExportOptions(
            includeMetadata: true,
            includeSources: true,
            includeSummary: includeSummary,
            includeNotes: includeNotes,
            includeTranscript: includeTranscript
        )
    }

    func destination(for meeting: Meeting) -> (id: String, kind: String) {
        let id = meeting.isNoteType ? notePageID : meetingPageID
        let kind = meeting.isNoteType ? noteDestinationKind : meetingDestinationKind
        return id.isEmpty ? (parentPageID, destinationKind ?? "page") : (id, kind)
    }
}

struct ObsidianIntegrationConfig: Codable, Equatable {
    /// Master switch
    var enabled: Bool
    /// Absolute path to vault root (folder containing `.obsidian` is ideal but not required)
    var vaultPath: String
    /// Optional vault name as shown in Obsidian’s vault switcher (if different from folder name).
    /// Empty = derive from folder name / `.obsidian` parent.
    var vaultName: String
    /// Subfolder under vault, e.g. `Quern` or `Meetings/Quern`
    var subfolder: String
    /// Optional per-type folders, relative to the vault. Empty uses `subfolder`.
    var meetingSubfolder: String = ""
    var noteSubfolder: String = ""
    /// One Markdown checklist, relative to the vault.
    var taskFilePath: String = "Quern/Todo.md"
    /// `{date}` = yyyy-MM-dd, `{title}` = sanitized title, `{id}` = short id
    var filenamePattern: String
    /// After Enhance, write Markdown into vault automatically
    var autoExportAfterEnhance: Bool
    /// Open note in Obsidian via URI after write
    var openAfterExport: Bool
    /// Default export sections when sending (mirrors ExportOptions)
    var includeMetadata: Bool
    var includeSources: Bool
    var includeSummary: Bool
    var includeNotes: Bool
    var includeTranscript: Bool

    static let `default` = ObsidianIntegrationConfig(
        enabled: false,
        vaultPath: "",
        vaultName: "",
        subfolder: "Quern",
        filenamePattern: "{date}-{title}",
        autoExportAfterEnhance: false,
        openAfterExport: true,
        includeMetadata: true,
        includeSources: true,
        includeSummary: true,
        includeNotes: true,
        includeTranscript: false
    )

    enum CodingKeys: String, CodingKey {
        case enabled, vaultPath, vaultName, subfolder, filenamePattern
        case meetingSubfolder, noteSubfolder, taskFilePath
        case autoExportAfterEnhance, openAfterExport
        case includeMetadata, includeSources, includeSummary, includeNotes, includeTranscript
    }

    init(
        enabled: Bool,
        vaultPath: String,
        vaultName: String = "",
        subfolder: String,
        filenamePattern: String,
        autoExportAfterEnhance: Bool,
        openAfterExport: Bool,
        includeMetadata: Bool,
        includeSources: Bool,
        includeSummary: Bool,
        includeNotes: Bool,
        includeTranscript: Bool
    ) {
        self.enabled = enabled
        self.vaultPath = vaultPath
        self.vaultName = vaultName
        self.subfolder = subfolder
        self.filenamePattern = filenamePattern
        self.autoExportAfterEnhance = autoExportAfterEnhance
        self.openAfterExport = openAfterExport
        self.includeMetadata = includeMetadata
        self.includeSources = includeSources
        self.includeSummary = includeSummary
        self.includeNotes = includeNotes
        self.includeTranscript = includeTranscript
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        vaultPath = try c.decodeIfPresent(String.self, forKey: .vaultPath) ?? ""
        vaultName = try c.decodeIfPresent(String.self, forKey: .vaultName) ?? ""
        subfolder = try c.decodeIfPresent(String.self, forKey: .subfolder) ?? "Quern"
        meetingSubfolder = try c.decodeIfPresent(String.self, forKey: .meetingSubfolder) ?? ""
        noteSubfolder = try c.decodeIfPresent(String.self, forKey: .noteSubfolder) ?? ""
        taskFilePath = try c.decodeIfPresent(String.self, forKey: .taskFilePath) ?? "Quern/Todo.md"
        filenamePattern = try c.decodeIfPresent(String.self, forKey: .filenamePattern) ?? "{date}-{title}"
        autoExportAfterEnhance = try c.decodeIfPresent(Bool.self, forKey: .autoExportAfterEnhance) ?? false
        openAfterExport = try c.decodeIfPresent(Bool.self, forKey: .openAfterExport) ?? true
        includeMetadata = try c.decodeIfPresent(Bool.self, forKey: .includeMetadata) ?? true
        includeSources = try c.decodeIfPresent(Bool.self, forKey: .includeSources) ?? true
        includeSummary = try c.decodeIfPresent(Bool.self, forKey: .includeSummary) ?? true
        includeNotes = try c.decodeIfPresent(Bool.self, forKey: .includeNotes) ?? true
        includeTranscript = try c.decodeIfPresent(Bool.self, forKey: .includeTranscript) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(vaultPath, forKey: .vaultPath)
        try c.encode(vaultName, forKey: .vaultName)
        try c.encode(subfolder, forKey: .subfolder)
        try c.encode(meetingSubfolder, forKey: .meetingSubfolder)
        try c.encode(noteSubfolder, forKey: .noteSubfolder)
        try c.encode(taskFilePath, forKey: .taskFilePath)
        try c.encode(filenamePattern, forKey: .filenamePattern)
        try c.encode(autoExportAfterEnhance, forKey: .autoExportAfterEnhance)
        try c.encode(openAfterExport, forKey: .openAfterExport)
        try c.encode(includeMetadata, forKey: .includeMetadata)
        try c.encode(includeSources, forKey: .includeSources)
        try c.encode(includeSummary, forKey: .includeSummary)
        try c.encode(includeNotes, forKey: .includeNotes)
        try c.encode(includeTranscript, forKey: .includeTranscript)
    }

    var isConfigured: Bool {
        enabled && !vaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var exportOptions: ExportOptions {
        ExportOptions(
            includeMetadata: includeMetadata,
            includeSources: includeSources,
            includeSummary: includeSummary,
            includeNotes: includeNotes,
            includeTranscript: includeTranscript
        )
    }

    var vaultURL: URL? {
        let p = vaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }
}

@MainActor
final class IntegrationsConfigManager: ObservableObject {
    static let shared = IntegrationsConfigManager()

    @Published private(set) var config: IntegrationsFile
    @Published var lastMessage: String = ""

    private static var fileURL: URL {
        QuernPaths.supportDirectory.appendingPathComponent("integrations.json")
    }

    private init() {
        config = Self.loadOrCreate()
    }

    static func loadOrCreate() -> IntegrationsFile {
        let url = fileURL
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(IntegrationsFile.self, from: data) {
            return decoded
        }
        let d = IntegrationsFile.default
        try? save(d)
        return d
    }

    static func save(_ file: IntegrationsFile) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(file)
        try data.write(to: fileURL, options: .atomic)
    }

    func reloadFromDisk() {
        config = Self.loadOrCreate()
        lastMessage = "Reloaded integrations"
    }

    func saveConfig(_ file: IntegrationsFile) -> Bool {
        do {
            try Self.save(file)
            config = file
            lastMessage = "Saved"
            return true
        } catch {
            lastMessage = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    func updateObsidian(_ block: (inout ObsidianIntegrationConfig) -> Void) {
        var f = config
        block(&f.obsidian)
        _ = saveConfig(f)
    }

    func updateNotion(_ block: (inout NotionIntegrationConfig) -> Void) {
        var f = config
        block(&f.notion)
        _ = saveConfig(f)
    }

    var configPath: String { Self.fileURL.path }
}

// MARK: - Write Markdown into Obsidian vault

enum ObsidianExportError: LocalizedError {
    case notEnabled
    case noVault
    case vaultMissing(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notEnabled:
            return "Obsidian export is off. Enable it in Settings → Integrations."
        case .noVault:
            return "No vault folder chosen. Pick a vault in Settings → Integrations."
        case .vaultMissing(let path):
            return "Vault folder not found:\n\(path)"
        case .writeFailed(let msg):
            return "Could not write file: \(msg)"
        }
    }
}

enum ObsidianExporter {
    /// Write one meeting/note into the configured vault. Returns the file URL written.
    @MainActor
    static func exportMeeting(_ meeting: Meeting, options: ExportOptions? = nil) throws -> URL {
        let cfg = IntegrationsConfigManager.shared.config.obsidian
        guard cfg.enabled else { throw ObsidianExportError.notEnabled }
        guard let vault = cfg.vaultURL else { throw ObsidianExportError.noVault }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vault.path, isDirectory: &isDir), isDir.boolValue else {
            throw ObsidianExportError.vaultMissing(vault.path)
        }

        let route = meeting.isNoteType ? cfg.noteSubfolder : cfg.meetingSubfolder
        let destDir = try destinationDirectory(vault: vault, subfolder: route.isEmpty ? cfg.subfolder : route)
        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch {
            throw ObsidianExportError.writeFailed(error.localizedDescription)
        }

        let opts = options ?? cfg.exportOptions
        let md = NoteExporter.markdown(for: meeting, options: opts)
        let base = filename(for: meeting, pattern: cfg.filenamePattern)
        let fileURL = uniqueFileURL(in: destDir, baseName: base)

        do {
            try md.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw ObsidianExportError.writeFailed(error.localizedDescription)
        }

        QuernLog.log("[Obsidian] wrote \(fileURL.path)")

        if cfg.openAfterExport {
            openInObsidian(vault: vault, fileURL: fileURL, preferredVaultName: cfg.vaultName)
        }
        return fileURL
    }

    /// Replace one checklist with the current task state; repeated syncs do not create copies.
    @MainActor
    static func exportTasks(_ tasks: [QuernTask]) throws -> URL {
        let cfg = IntegrationsConfigManager.shared.config.obsidian
        guard cfg.enabled else { throw ObsidianExportError.notEnabled }
        guard let vault = cfg.vaultURL else { throw ObsidianExportError.noVault }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vault.path, isDirectory: &isDir), isDir.boolValue else {
            throw ObsidianExportError.vaultMissing(vault.path)
        }
        let parts = try safeParts(cfg.taskFilePath)
        guard let name = parts.last, name.lowercased().hasSuffix(".md") else {
            throw ObsidianExportError.writeFailed("Task path must end in .md")
        }
        let directory = parts.dropLast().reduce(vault) { $0.appendingPathComponent($1, isDirectory: true) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        let lines = tasks.filter { !$0.isDeleted }.sorted { a, b in
            if a.isDone != b.isDone { return !a.isDone }
            return a.createdAt < b.createdAt
        }.map { task in
            let title = task.title.replacingOccurrences(of: "\n", with: " ")
            let detail = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            return "- [\(task.isDone ? "x" : " ")] \(title)" + (detail.isEmpty ? "" : " — \(detail)")
        }
        try ("# Quern tasks\n\n" + lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        if cfg.openAfterExport { openInObsidian(vault: vault, fileURL: file, preferredVaultName: cfg.vaultName) }
        return file
    }

    /// Walk up from `selected` until a folder containing `.obsidian` is found.
    static func resolveVaultRoot(from selected: URL) -> URL {
        var current = selected.standardizedFileURL
        let fm = FileManager.default
        for _ in 0..<12 {
            let marker = current.appendingPathComponent(".obsidian", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: marker.path, isDirectory: &isDir), isDir.boolValue {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return selected.standardizedFileURL
    }

    /// Relative path under vault for URI (posix, no leading slash).
    static func vaultRelativePath(vault: URL, fileURL: URL) -> String {
        let root = resolveVaultRoot(from: vault)
        let v = root.standardizedFileURL.path
        let f = fileURL.standardizedFileURL.path
        if f.hasPrefix(v) {
            var rel = String(f.dropFirst(v.count))
            if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
            return rel
        }
        return fileURL.lastPathComponent
    }

    /// Open the written note in Obsidian.
    /// Prefer absolute `path=` (does not depend on vault display name). Fall back to vault+file.
    static func openInObsidian(vault: URL, fileURL: URL, preferredVaultName: String = "") {
        let absPath = fileURL.standardizedFileURL.path

        // 1) Absolute path — most reliable when the vault is already known to Obsidian
        if let pathURL = makeObsidianOpenURL(queryItems: [
            URLQueryItem(name: "path", value: absPath),
        ]) {
            if NSWorkspace.shared.open(pathURL) {
                QuernLog.log("[Obsidian] open path \(absPath)")
                return
            }
        }

        // 2) vault name + relative file
        let root = resolveVaultRoot(from: vault)
        let name: String = {
            let custom = preferredVaultName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !custom.isEmpty { return custom }
            return root.lastPathComponent
        }()
        var rel = vaultRelativePath(vault: root, fileURL: fileURL)
        if rel.lowercased().hasSuffix(".md") {
            rel = String(rel.dropLast(3))
        }
        if let vaultURL = makeObsidianOpenURL(queryItems: [
            URLQueryItem(name: "vault", value: name),
            URLQueryItem(name: "file", value: rel),
        ]) {
            if NSWorkspace.shared.open(vaultURL) {
                QuernLog.log("[Obsidian] open vault=\(name) file=\(rel)")
                return
            }
        }

        // 3) Reveal in Finder so the user still finds the file (export already succeeded)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        QuernLog.log("[Obsidian] open URI failed; revealed in Finder \(absPath)")
    }

    private static func makeObsidianOpenURL(queryItems: [URLQueryItem]) -> URL? {
        var comps = URLComponents()
        comps.scheme = "obsidian"
        comps.host = "open"
        comps.queryItems = queryItems
        return comps.url
    }

    private static func safeParts(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains(":") }) else {
            throw ObsidianExportError.writeFailed("Use a relative path inside the vault without . or ..")
        }
        return parts
    }

    private static func destinationDirectory(vault: URL, subfolder: String) throws -> URL {
        let sub = subfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if sub.isEmpty { return vault }
        return try safeParts(sub).reduce(vault) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    static func filename(for meeting: Meeting, pattern: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let date = df.string(from: Date(timeIntervalSince1970: meeting.timestamp))
        var title = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = meeting.isNoteType ? "Note" : "Meeting" }
        title = sanitizeFilename(title)
        let shortId = String(meeting.id.prefix(8))

        var name = pattern
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{title}", with: title)
            .replacingOccurrences(of: "{id}", with: shortId)
        name = sanitizeFilename(name)
        if name.isEmpty { name = "\(date)-\(title)" }
        if !name.lowercased().hasSuffix(".md") { name += ".md" }
        return name
    }

    static func sanitizeFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        var s = raw.components(separatedBy: invalid).joined(separator: "-")
        s = s.replacingOccurrences(of: "\n", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 80 { s = String(s.prefix(80)) }
        return s
    }

    /// Avoid overwrite: foo.md → foo-2.md → …
    static func uniqueFileURL(in dir: URL, baseName: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(baseName)
        if !fm.fileExists(atPath: candidate.path) { return candidate }

        let stem: String
        let ext: String
        if baseName.lowercased().hasSuffix(".md") {
            stem = String(baseName.dropLast(3))
            ext = ".md"
        } else {
            stem = baseName
            ext = ".md"
        }
        var i = 2
        repeat {
            candidate = dir.appendingPathComponent("\(stem)-\(i)\(ext)")
            i += 1
        } while fm.fileExists(atPath: candidate.path) && i < 1000
        return candidate
    }

    @MainActor
    static func pickVaultFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose Vault"
        panel.message = "Select your Obsidian vault folder (the folder that contains your notes)"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
