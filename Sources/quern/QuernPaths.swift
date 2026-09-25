import Foundation

/// Shared Application Support layout for Quern, with one-time migration from Grist.
enum QuernPaths {
    static let folderName = "Quern"
    /// Previous product name — data lived here before the rename.
    static let legacyFolderName = "Grist"

    /// `~/Library/Application Support/Quern` — migrates from `…/Grist` on first use when needed.
    static var supportDirectory: URL {
        migrateLegacyIfNeeded()
        let url = applicationSupportRoot.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var meetingsDB: URL {
        supportDirectory.appendingPathComponent("meetings.db")
    }

    static var logFile: URL {
        supportDirectory.appendingPathComponent("quern.log")
    }

    static var whisperDirectory: URL {
        supportDirectory.appendingPathComponent("whisper.cpp", isDirectory: true)
    }

    // MARK: - Migration

    private static var applicationSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    /// If Quern’s folder is missing (or empty of `meetings.db`) and a Grist folder exists, move/copy it over.
    static func migrateLegacyIfNeeded() {
        let fm = FileManager.default
        let root = applicationSupportRoot
        let quern = root.appendingPathComponent(folderName, isDirectory: true)
        let grist = root.appendingPathComponent(legacyFolderName, isDirectory: true)
        let flag = quern.appendingPathComponent(".migrated-from-grist")

        // Already migrated (or never needed).
        if fm.fileExists(atPath: flag.path) { return }

        let quernExists = fm.fileExists(atPath: quern.path)
        let gristExists = fm.fileExists(atPath: grist.path)
        if !gristExists {
            if quernExists {
                fm.createFile(atPath: flag.path, contents: nil)
            }
            return
        }

        let quernDB = quern.appendingPathComponent("meetings.db")
        let gristDB = grist.appendingPathComponent("meetings.db")
        let quernHasDB = fm.fileExists(atPath: quernDB.path)
        let gristHasDB = fm.fileExists(atPath: gristDB.path)

        // Full folder rename when Quern does not exist yet.
        if !quernExists {
            do {
                try fm.moveItem(at: grist, to: quern)
                renameLegacyLog(in: quern)
                fixWhisperRpathsIfNeeded()
                fm.createFile(atPath: flag.path, contents: nil)
                print("[Quern] Migrated Application Support/Grist → Quern")
            } catch {
                print("[Quern] Migration move failed: \(error.localizedDescription)")
            }
            return
        }

        // Quern exists but has no DB yet — copy core files from Grist.
        if !quernHasDB, gristHasDB {
            for name in ["meetings.db", "ai-config.json", "integrations.json", "whisper.cpp"] {
                let src = grist.appendingPathComponent(name)
                let dst = quern.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
                do {
                    try fm.copyItem(at: src, to: dst)
                } catch {
                    print("[Quern] Migration copy \(name) failed: \(error.localizedDescription)")
                }
            }
            // Recordings / other loose files
            if let kids = try? fm.contentsOfDirectory(at: grist, includingPropertiesForKeys: nil) {
                for src in kids {
                    let dst = quern.appendingPathComponent(src.lastPathComponent)
                    guard !fm.fileExists(atPath: dst.path) else { continue }
                    try? fm.copyItem(at: src, to: dst)
                }
            }
            renameLegacyLog(in: quern)
            fixWhisperRpathsIfNeeded()
            print("[Quern] Copied library data from Application Support/Grist")
        }

        fm.createFile(atPath: flag.path, contents: nil)
        // Even if migration already ran, repair whisper @rpath once if still broken.
        fixWhisperRpathsIfNeeded()
    }

    private static func renameLegacyLog(in dir: URL) {
        let fm = FileManager.default
        let oldLog = dir.appendingPathComponent("grist.log")
        let newLog = dir.appendingPathComponent("quern.log")
        guard fm.fileExists(atPath: oldLog.path), !fm.fileExists(atPath: newLog.path) else { return }
        try? fm.moveItem(at: oldLog, to: newLog)
    }

    /// whisper-cli was built under `…/Grist/…`; after the folder rename, `@rpath` still
    /// points at the missing Grist path and every transcription fails with “process failed”.
    static func fixWhisperRpathsIfNeeded() {
        let binDir = whisperDirectory.appendingPathComponent("build/bin", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: binDir.path) else { return }

        let oldRpath = (applicationSupportRoot
            .appendingPathComponent(legacyFolderName, isDirectory: true)
            .appendingPathComponent("whisper.cpp/build/bin")).path
        let newRpath = binDir.path

        guard let items = try? fm.contentsOfDirectory(atPath: binDir.path) else { return }
        var fixed = 0
        for name in items {
            let path = binDir.appendingPathComponent(name).path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }

            let otool = Process()
            otool.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
            otool.arguments = ["-l", path]
            let pipe = Pipe()
            otool.standardOutput = pipe
            otool.standardError = Pipe()
            do { try otool.run() } catch { continue }
            otool.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard out.contains("Grist/whisper.cpp") else { continue }

            let tool = Process()
            tool.executableURL = URL(fileURLWithPath: "/usr/bin/install_name_tool")
            tool.arguments = ["-rpath", oldRpath, newRpath, path]
            tool.standardOutput = Pipe()
            tool.standardError = Pipe()
            do {
                try tool.run()
                tool.waitUntilExit()
                if tool.terminationStatus == 0 {
                    fixed += 1
                } else {
                    // Fallback: add Quern rpath if replace failed (e.g. already partially fixed).
                    let add = Process()
                    add.executableURL = URL(fileURLWithPath: "/usr/bin/install_name_tool")
                    add.arguments = ["-add_rpath", newRpath, path]
                    add.standardOutput = Pipe()
                    add.standardError = Pipe()
                    try? add.run()
                    add.waitUntilExit()
                    if add.terminationStatus == 0 { fixed += 1 }
                }
            } catch {
                continue
            }
        }
        if fixed > 0 {
            print("[Quern] Fixed whisper @rpath on \(fixed) binary/dylib(s) → Quern")
            QuernLog.log("[Quern] Fixed whisper @rpath on \(fixed) binary/dylib(s)")
        }
    }
}
