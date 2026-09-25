import Foundation

class WhisperTranscriber: @unchecked Sendable {
    static let shared = WhisperTranscriber()

    private var whisperDir: String {
        QuernPaths.whisperDirectory.path
    }
    private let ffmpegPath = "/opt/homebrew/bin/ffmpeg"

    private init() {}

    /// Full meeting transcription after Stop (existing behavior).
    func transcribe(meetingId: String) async -> String {
        let meetingFolder = AudioRecorder.shared.getMeetingFolder(meetingId: meetingId)

        let micURL = meetingFolder.appendingPathComponent("mic.m4a")
        let systemURL = meetingFolder.appendingPathComponent("system.wav")
        let rawURL = meetingFolder.appendingPathComponent("raw.m4a") // legacy format
        let wavURL = meetingFolder.appendingPathComponent("mono.wav")
        let txtURL = meetingFolder.appendingPathComponent("mono.wav.txt")

        // Always clean old outputs
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: txtURL)

        let hasMic = FileManager.default.fileExists(atPath: micURL.path)
        let hasSystem = FileManager.default.fileExists(atPath: systemURL.path)
        let hasRaw = FileManager.default.fileExists(atPath: rawURL.path)

        // Check system.wav is non-empty (SCK writes a header even with no audio)
        let systemSize = (try? FileManager.default.attributesOfItem(atPath: systemURL.path))?[.size] as? Int64 ?? 0
        let hasUsableSystem = hasSystem && systemSize > 100

        print("[WhisperTranscriber] Sources: mic=\(hasMic), system=\(hasUsableSystem) (\(systemSize)B), raw=\(hasRaw)")

        // Step 1: Convert/merge sources into mono.wav
        var ffmpegArgs: [String]

        if hasMic && hasUsableSystem {
            print("[WhisperTranscriber] Merging mic + system audio...")
            ffmpegArgs = [
                "-y", "-nostdin",
                "-i", micURL.path,
                "-i", systemURL.path,
                "-filter_complex", "amix=inputs=2:duration=longest",
                "-ar", "16000",
                "-ac", "1",
                wavURL.path
            ]
        } else if hasMic {
            print("[WhisperTranscriber] Converting mic audio only...")
            ffmpegArgs = [
                "-y", "-nostdin",
                "-i", micURL.path,
                "-ar", "16000",
                "-ac", "1",
                wavURL.path
            ]
        } else if hasUsableSystem {
            print("[WhisperTranscriber] Converting system audio only...")
            ffmpegArgs = [
                "-y", "-nostdin",
                "-i", systemURL.path,
                "-ar", "16000",
                "-ac", "1",
                wavURL.path
            ]
        } else if hasRaw {
            print("[WhisperTranscriber] Converting legacy raw.m4a...")
            ffmpegArgs = [
                "-y", "-nostdin",
                "-i", rawURL.path,
                "-ar", "16000",
                "-ac", "1",
                wavURL.path
            ]
        } else {
            return "[Error: No recording file found]"
        }

        let ffmpegSuccess = await runProcess(executable: ffmpegPath, arguments: ffmpegArgs)
        guard ffmpegSuccess else {
            return "[Error: Failed to convert audio to WAV]"
        }

        guard FileManager.default.fileExists(atPath: wavURL.path) else {
            return "[Error: FFmpeg succeeded but WAV file is missing]"
        }

        guard let finalModel = resolveModelPath() else {
            return "[Error: Whisper model not found]"
        }
        guard let finalBinary = resolveBinaryPath() else {
            return "[Error: whisper.cpp binary not found]"
        }

        print("[WhisperTranscriber] Running Whisper transcription...")
        print("[WhisperTranscriber] Binary: \(finalBinary)")
        print("[WhisperTranscriber] Model: \(finalModel)")

        let whisperSuccess = await runProcess(
            executable: finalBinary,
            arguments: ["-m", finalModel, "-f", wavURL.path, "-nt", "-otxt"]
        )

        guard whisperSuccess else {
            return "[Error: Whisper.cpp process failed. Binary: \(finalBinary)]"
        }

        if FileManager.default.fileExists(atPath: txtURL.path) {
            do {
                let text = try String(contentsOf: txtURL, encoding: .utf8)
                let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
                print("[WhisperTranscriber] ✅ Transcript (\(result.count) chars)")
                return result
            } catch {
                return "[Error reading transcript: \(error.localizedDescription)]"
            }
        } else {
            return "[Error: Transcript file not generated]"
        }
    }

    /// Transcribe a short WAV/audio chunk for live transcription (no meeting merge).
    func transcribeChunk(wavURL: URL, preferFastModel: Bool = true) async -> String? {
        guard FileManager.default.fileExists(atPath: wavURL.path) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: wavURL.path))?[.size] as? Int64 ?? 0
        guard size > 1000 else { return nil }

        guard let binary = resolveBinaryPath() else { return nil }
        guard let model = preferFastModel ? resolveFastModelPath() ?? resolveModelPath() : resolveModelPath() else {
            return nil
        }

        let txtURL = URL(fileURLWithPath: wavURL.path + ".txt")
        try? FileManager.default.removeItem(at: txtURL)

        let ok = await runProcess(
            executable: binary,
            arguments: ["-m", model, "-f", wavURL.path, "-nt", "-otxt"]
        )
        guard ok, FileManager.default.fileExists(atPath: txtURL.path) else { return nil }

        defer { try? FileManager.default.removeItem(at: txtURL) }
        let text = (try? String(contentsOf: txtURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        // Filter whisper hallucinations on silence
        let lowered = text.lowercased()
        if lowered == "you" || lowered == "thank you." || lowered == "thanks for watching." {
            return nil
        }
        return text
    }

    /// Extract a mono 16 kHz WAV window from a (possibly still-growing) recording file.
    func extractChunkWAV(
        from sourceURL: URL,
        startSeconds: Double,
        durationSeconds: Double,
        to outputURL: URL
    ) async -> Bool {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return false }
        try? FileManager.default.removeItem(at: outputURL)
        let start = max(0, startSeconds)
        let dur = max(0.5, durationSeconds)
        let args = [
            "-y", "-nostdin",
            "-ss", String(format: "%.2f", start),
            "-t", String(format: "%.2f", dur),
            "-i", sourceURL.path,
            "-ar", "16000",
            "-ac", "1",
            outputURL.path
        ]
        return await runProcess(executable: ffmpegPath, arguments: args)
    }

    func resolveBinaryPath() -> String? {
        var whisperBinary = UserDefaults.standard.string(forKey: "whisperBinaryPath")
        if whisperBinary == nil || whisperBinary!.isEmpty || !FileManager.default.fileExists(atPath: whisperBinary!) {
            whisperBinary = "\(whisperDir)/build/bin/whisper-cli"
            if !FileManager.default.fileExists(atPath: whisperBinary!) {
                whisperBinary = "\(whisperDir)/build/bin/main"
            }
        }
        guard let path = whisperBinary, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    func resolveModelPath() -> String? {
        var whisperModel = UserDefaults.standard.string(forKey: "whisperModelPath")
        if whisperModel == nil || whisperModel!.isEmpty || !FileManager.default.fileExists(atPath: whisperModel!) {
            whisperModel = "\(whisperDir)/models/ggml-base.en.bin"
            if !FileManager.default.fileExists(atPath: whisperModel!) {
                whisperModel = "\(whisperDir)/models/ggml-base.bin"
            }
        }
        guard let path = whisperModel, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// Prefer tiny/base.en for live speed.
    func resolveFastModelPath() -> String? {
        let candidates = [
            "\(whisperDir)/models/ggml-tiny.en.bin",
            "\(whisperDir)/models/ggml-tiny.bin",
            "\(whisperDir)/models/ggml-base.en.bin",
            "\(whisperDir)/models/ggml-base.bin",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    var isAvailable: Bool {
        resolveBinaryPath() != nil && (resolveFastModelPath() != nil || resolveModelPath() != nil)
    }

    /// Result of a real launch probe (binary + dylibs + model present) before recording.
    enum PreflightResult: Sendable {
        case ok
        case failed(String)

        var isOK: Bool {
            if case .ok = self { return true }
            return false
        }

        var message: String? {
            if case .failed(let m) = self { return m }
            return nil
        }
    }

    /// Actually runs `whisper-cli --help` so broken rpaths / missing dylibs fail *before* a meeting.
    func preflightForRecording() async -> PreflightResult {
        // After Grist→Quern folder moves, Mach-O @rpath can still point at the old path.
        QuernPaths.fixWhisperRpathsIfNeeded()

        guard let binary = resolveBinaryPath() else {
            return .failed("Whisper is not installed. Run ./setup.sh (Step 2: Speech-to-text) before recording.")
        }
        guard resolveModelPath() != nil || resolveFastModelPath() != nil else {
            return .failed("Whisper model missing (ggml-base.bin). Run ./setup.sh to download it.")
        }

        let probe = await runProcessCapturing(executable: binary, arguments: ["--help"])
        if probe.exitCode == 0 {
            QuernLog.log("[Whisper] preflight OK binary=\(binary)")
            return .ok
        }

        let err = (probe.stderr + "\n" + probe.stdout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        QuernLog.log("[Whisper] preflight FAILED binary=\(binary) exit=\(probe.exitCode) err=\(err.prefix(400))")

        if err.localizedCaseInsensitiveContains("library not loaded")
            || err.localizedCaseInsensitiveContains("libwhisper")
            || err.localizedCaseInsensitiveContains("image not found") {
            // One more rpath repair pass, then retry once.
            QuernPaths.fixWhisperRpathsIfNeeded()
            let retry = await runProcessCapturing(executable: binary, arguments: ["--help"])
            if retry.exitCode == 0 {
                QuernLog.log("[Whisper] preflight OK after rpath repair")
                return .ok
            }
            return .failed(
                "Whisper can’t start (broken library path after rename). Re-run ./setup.sh Step 2, or ask Quern to rebuild whisper.cpp under Application Support/Quern."
            )
        }

        let short = err.isEmpty ? "exit \(probe.exitCode)" : String(err.prefix(180))
        return .failed("Whisper preflight failed: \(short)")
    }

    private nonisolated func runProcess(executable: String, arguments: [String]) async -> Bool {
        let result = await runProcessCapturing(executable: executable, arguments: arguments)
        return result.exitCode == 0
    }

    private nonisolated func runProcessCapturing(
        executable: String,
        arguments: [String]
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            process.terminationHandler = { proc in
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: (proc.terminationStatus, out, err))
            }

            do {
                try process.run()
            } catch {
                print("[WhisperTranscriber] Failed to run \(executable): \(error.localizedDescription)")
                continuation.resume(returning: (-1, "", error.localizedDescription))
            }
        }
    }
}
