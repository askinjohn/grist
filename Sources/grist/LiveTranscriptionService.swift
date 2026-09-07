import Foundation

/// Rolling live transcription while a meeting is recording.
/// Periodically slices recent mic audio, runs whisper.cpp on the chunk, and appends text.
@MainActor
final class LiveTranscriptionService: ObservableObject {
    static let shared = LiveTranscriptionService()

    @Published private(set) var liveText: String = ""
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String = ""
    @Published private(set) var isProcessingChunk = false

    /// Seconds between chunk attempts.
    var intervalSeconds: TimeInterval = 4
    /// Audio window length sent to Whisper.
    var windowSeconds: Double = 5
    /// Overlap so words at boundaries are less likely to be lost (deduped on append).
    var overlapSeconds: Double = 1.2

    private var meetingId: String?
    private var timer: Timer?
    private var nextStart: Double = 0
    private var busy = false
    private let transcriber = WhisperTranscriber.shared

    private init() {}

    func start(meetingId: String) {
        stop()
        guard UserDefaults.standard.object(forKey: "liveTranscriptionEnabled") as? Bool ?? true else {
            GristLog.log("[LiveTranscript] disabled in settings")
            return
        }
        guard transcriber.isAvailable else {
            lastError = "Whisper not available"
            GristLog.log("[LiveTranscript] whisper unavailable")
            return
        }

        self.meetingId = meetingId
        liveText = ""
        lastError = ""
        nextStart = 0
        isRunning = true
        RecordingStatus.shared.setLiveTranscript("")

        // First chunk after enough audio has been captured
        timer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.tick()
            }
        }
        GristLog.log("[LiveTranscript] started meeting=\(meetingId)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        isProcessingChunk = false
        busy = false
        meetingId = nil
        GristLog.log("[LiveTranscript] stopped")
    }

    func resetText() {
        liveText = ""
        nextStart = 0
        RecordingStatus.shared.setLiveTranscript("")
    }

    private func tick() async {
        guard isRunning, !busy, let meetingId else { return }
        busy = true
        isProcessingChunk = true
        defer {
            busy = false
            isProcessingChunk = false
        }

        let folder = AudioRecorder.shared.getMeetingFolder(meetingId: meetingId)
        let micURL = folder.appendingPathComponent("mic.m4a")
        let systemURL = folder.appendingPathComponent("system.wav")

        // Prefer mic; fall back to system if mic missing
        let sourceURL: URL
        if FileManager.default.fileExists(atPath: micURL.path) {
            sourceURL = micURL
        } else if FileManager.default.fileExists(atPath: systemURL.path) {
            sourceURL = systemURL
        } else {
            return
        }

        let start = max(0, nextStart - overlapSeconds)
        let chunkURL = folder.appendingPathComponent("live-chunk.wav")

        let extracted = await transcriber.extractChunkWAV(
            from: sourceURL,
            startSeconds: start,
            durationSeconds: windowSeconds,
            to: chunkURL
        )
        guard extracted else { return }

        let text = await transcriber.transcribeChunk(wavURL: chunkURL, preferFastModel: true)
        try? FileManager.default.removeItem(at: chunkURL)
        guard let text else { return }

        appendDeduped(text)
        nextStart = start + windowSeconds - overlapSeconds
        if nextStart < 0 { nextStart = 0 }
    }

    private func appendDeduped(_ incoming: String) {
        let piece = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }

        if liveText.isEmpty {
            liveText = piece
        } else if liveText.hasSuffix(piece) {
            // exact duplicate tail
        } else if piece.hasPrefix(String(liveText.suffix(min(40, liveText.count)))) {
            // chunk overlaps existing tail — take only the new suffix
            let overlap = String(liveText.suffix(min(80, liveText.count)))
            if let range = piece.range(of: overlap) {
                let rest = String(piece[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty {
                    liveText += " " + rest
                }
            } else {
                liveText += " " + piece
            }
        } else {
            // Fuzzy: if last ~12 words appear at start of piece, strip them
            let tailWords = liveText.split(separator: " ").suffix(12).joined(separator: " ")
            if !tailWords.isEmpty, piece.lowercased().hasPrefix(tailWords.lowercased()) {
                let rest = String(piece.dropFirst(tailWords.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { liveText += " " + rest }
            } else {
                liveText += "\n" + piece
            }
        }

        RecordingStatus.shared.setLiveTranscript(liveText)
    }
}
