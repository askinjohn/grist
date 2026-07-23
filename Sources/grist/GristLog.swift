import Foundation

/// Append-only logger so Enhance/AI diagnostics are visible even when the app is
/// launched via Finder/`open` (stdout is not captured).
///
/// File: ~/Library/Application Support/Grist/grist.log
enum GristLog {
    private static let queue = DispatchQueue(label: "com.grist.log", qos: .utility)
    private static let maxBytes: UInt64 = 2_000_000

    private static var logURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Grist", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("grist.log")
    }

    static func log(_ message: String) {
        // Keep Console.app / Xcode stream working when available.
        print(message)
        queue.async {
            append(message)
        }
    }

    private static func append(_ message: String) {
        let url = logURL
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        // Soft rotate if huge
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64, size > maxBytes {
            let bak = url.deletingLastPathComponent().appendingPathComponent("grist.log.1")
            try? FileManager.default.removeItem(at: bak)
            try? FileManager.default.moveItem(at: url, to: bak)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    static var path: String { logURL.path }
}
