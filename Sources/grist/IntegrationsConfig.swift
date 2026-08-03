import Foundation
import AppKit

/// User integrations (Obsidian, later Notion). Local file only.
struct IntegrationsFile: Codable, Equatable {
    var version: Int
    var obsidian: ObsidianIntegrationConfig

    static let `default` = IntegrationsFile(
        version: 1,
        obsidian: .default
    )
}

struct ObsidianIntegrationConfig: Codable, Equatable {
    /// Master switch
    var enabled: Bool
    /// Absolute path to vault root (folder containing `.obsidian` is ideal but not required)
    var vaultPath: String
    /// Subfolder under vault, e.g. `Grist` or `Meetings/Grist`
    var subfolder: String
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
        subfolder: "Grist",
        filenamePattern: "{date}-{title}",
        autoExportAfterEnhance: false,
        openAfterExport: true,
        includeMetadata: true,
        includeSources: true,
        includeSummary: true,
        includeNotes: true,
        includeTranscript: false
    )

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
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Grist", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("integrations.json")
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

        let destDir = destinationDirectory(vault: vault, subfolder: cfg.subfolder)
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

        GristLog.log("[Obsidian] wrote \(fileURL.path)")

        if cfg.openAfterExport {
            openInObsidian(vault: vault, fileURL: fileURL)
        }
        return fileURL
    }

    /// Relative path under vault for URI (posix, no leading slash).
    static func vaultRelativePath(vault: URL, fileURL: URL) -> String {
        let v = vault.standardizedFileURL.path
        let f = fileURL.standardizedFileURL.path
        if f.hasPrefix(v) {
            var rel = String(f.dropFirst(v.count))
            if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
            return rel
        }
        return fileURL.lastPathComponent
    }

    static func openInObsidian(vault: URL, fileURL: URL) {
        let vaultName = vault.lastPathComponent
        let rel = vaultRelativePath(vault: vault, fileURL: fileURL)
        // Prefer open-by-path when possible; vault name is the folder name.
        var comps = URLComponents()
        comps.scheme = "obsidian"
        comps.host = "open"
        comps.queryItems = [
            URLQueryItem(name: "vault", value: vaultName),
            URLQueryItem(name: "file", value: rel.replacingOccurrences(of: ".md", with: "")),
        ]
        if let url = comps.url {
            NSWorkspace.shared.open(url)
        }
    }

    private static func destinationDirectory(vault: URL, subfolder: String) -> URL {
        let sub = subfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if sub.isEmpty { return vault }
        var url = vault
        for part in sub.split(separator: "/") {
            url = url.appendingPathComponent(String(part), isDirectory: true)
        }
        return url
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
