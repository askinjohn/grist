import Foundation

/// Old sessions remain available even when the next capture fails to start.
enum RecordingArchive {
    static let filenames = ["mic.m4a", "system.wav", "mono.wav", "mono.wav.txt", "raw.m4a"]

    static func preservePreviousSession(in folder: URL) throws {
        let fm = FileManager.default
        let existing = filenames.map { folder.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        let archive = folder.appendingPathComponent("recordings", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        // Finish all copies before removing any originals. Propagate errors to abort capture.
        for source in existing {
            try fm.copyItem(at: source, to: archive.appendingPathComponent(source.lastPathComponent))
        }
        for source in existing { try fm.removeItem(at: source) }
    }
}
