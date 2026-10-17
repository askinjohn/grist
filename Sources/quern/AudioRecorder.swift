import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

class AudioRecorder: NSObject, @unchecked Sendable {
    static let shared = AudioRecorder()
    
    // Mic recording
    private var micRecorder: AVAudioRecorder?
    
    // System audio via ScreenCaptureKit
    private var stream: SCStream?
    private var audioWriter: AVAssetWriter?
    private var audioWriterInput: AVAssetWriterInput?
    private var sessionStarted = false
    
    private override init() {
        super.init()
    }
    
    func getMeetingsFolder() -> URL {
        let meetingsFolder = QuernPaths.supportDirectory.appendingPathComponent("meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: meetingsFolder, withIntermediateDirectories: true, attributes: nil)
        return meetingsFolder
    }
    
    func getMeetingFolder(meetingId: String) -> URL {
        let folder = getMeetingsFolder().appendingPathComponent(meetingId, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        return folder
    }
    
    /// True after the last successful SCStream startCapture.
    private(set) var isCapturingSystemAudio = false

    private(set) var systemAudioFailure: String?

    var isCapturingMicrophone: Bool { micRecorder?.isRecording == true }

    func start(meetingId: String) async throws {
        isCapturingSystemAudio = false
        systemAudioFailure = nil

        await PermissionHelper.ensureMicrophonePermission()
        if !PermissionHelper.hasMicrophoneAccess {
            QuernLog.log("[AudioRecorder] ⚠️ Microphone not authorized")
        }

        let meetingFolder = getMeetingFolder(meetingId: meetingId)
        
        // Preserve every previous session before preparing fresh capture files.
        try RecordingArchive.preservePreviousSession(in: meetingFolder)
        defer {
            // A failed mic initialization can leave an unusable file behind.
            if !isCapturingMicrophone {
                try? FileManager.default.removeItem(at: meetingFolder.appendingPathComponent("mic.m4a"))
            }
        }

        // === 1. Start Microphone Recording ===
        let micURL = meetingFolder.appendingPathComponent("mic.m4a")
        let micSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            let recorder = try AVAudioRecorder(url: micURL, settings: micSettings)
            recorder.prepareToRecord()
            if recorder.record() {
                self.micRecorder = recorder
                QuernLog.log("[AudioRecorder] ✅ Mic recording started → mic.m4a")
            } else {
                QuernLog.log("[AudioRecorder] ⚠️ Mic recorder failed to start")
            }
        } catch {
            QuernLog.log("[AudioRecorder] ⚠️ Mic init error: \(error.localizedDescription)")
        }
        
        // === 2. Start System Audio via ScreenCaptureKit ===
        // Attempt capture on every recording: a previous failure must not disable
        // system audio for the rest of the launch after permissions change.
        do {
            // Prefer on-screen content; false/false is more likely to include active displays + audio.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                systemAudioFailure = "No display is available for system audio capture."
                QuernLog.log("[AudioRecorder] No display available; system audio skipped")
                try requireActiveCapture()
                return
            }
            
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.sampleRate = 16000
            config.channelCount = 1
            config.excludesCurrentProcessAudio = true
            // Minimal video config to reduce overhead (we only want audio)
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            
            // Set up AVAssetWriter to write system audio as PCM WAV
            let systemURL = meetingFolder.appendingPathComponent("system.wav")
            let writer = try AVAssetWriter(outputURL: systemURL, fileType: .wav)
            let outputSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
            writerInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(writerInput) else {
                throw NSError(domain: "QuernCapture", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "System audio writer does not support the requested audio format."
                ])
            }
            writer.add(writerInput)
            guard writer.startWriting() else {
                throw writer.error ?? NSError(domain: "QuernCapture", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "System audio writer could not start."
                ])
            }
            // Session start is deferred to first audio sample arrival
            
            self.audioWriter = writer
            self.audioWriterInput = writerInput
            self.sessionStarted = false
            
            let scStream = SCStream(filter: filter, configuration: config, delegate: self)
            try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.quern.systemaudio"))
            try await scStream.startCapture()
            self.stream = scStream
            self.isCapturingSystemAudio = true
            QuernLog.log("[AudioRecorder] ✅ System audio recording started via ScreenCaptureKit (display \(display.displayID))")
        } catch {
            let msg = error.localizedDescription
            QuernLog.log("[AudioRecorder] ⚠️ System audio unavailable: \(msg)")
            QuernLog.log("[AudioRecorder] Continuing with mic-only recording")
            systemAudioFailure = msg
            let captureError = error as NSError
            QuernLog.log("[AudioRecorder] System audio failure domain=\(captureError.domain) code=\(captureError.code)")
            // Clean up half-created writer
            audioWriter?.cancelWriting()
            audioWriterInput = nil
            audioWriter = nil
            stream = nil
            sessionStarted = false
        }
        try requireActiveCapture()
    }

    private func requireActiveCapture() throws {
        guard isCapturingMicrophone || isCapturingSystemAudio else {
            throw NSError(domain: "QuernCapture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Recording could not start: microphone and system audio are unavailable. Check recording permissions and try again."
            ])
        }
    }
    
    func stop() async {
        isCapturingSystemAudio = false
        // Stop mic recording
        if let rec = micRecorder {
            let url = rec.url
            rec.stop()
            micRecorder = nil
            try? await Task.sleep(nanoseconds: 200_000_000)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
            QuernLog.log("[AudioRecorder] Mic stopped. Size: \(size) bytes")
        }
        
        // Stop system audio capture
        if let scStream = stream {
            do {
                try await scStream.stopCapture()
                QuernLog.log("[AudioRecorder] System audio capture stopped")
            } catch {
                QuernLog.log("[AudioRecorder] Error stopping system audio: \(error.localizedDescription)")
            }
            stream = nil
        }
        
        // Finalize the system audio WAV file
        if let writerInput = audioWriterInput, let writer = audioWriter {
            writerInput.markAsFinished()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writer.finishWriting {
                    continuation.resume()
                }
            }
            let outputURL = writer.outputURL
            let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path))?[.size] as? Int64 ?? 0
            QuernLog.log("[AudioRecorder] System audio finalized status=\(writer.status.rawValue) bytes=\(size) error=\(writer.error?.localizedDescription ?? "none")")
            self.audioWriter = nil
            self.audioWriterInput = nil
        }
        
        try? await Task.sleep(nanoseconds: 200_000_000)
        QuernLog.log("[AudioRecorder] All recording stopped.")
    }
}

// MARK: - ScreenCaptureKit Audio Output

extension AudioRecorder: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isCapturingSystemAudio else { return }
        guard sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        guard let writerInput = audioWriterInput, writerInput.isReadyForMoreMediaData else { return }
        
        if !sessionStarted {
            sessionStarted = true
            audioWriter?.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        
        if !writerInput.append(sampleBuffer) {
            // Disable further appends so one failure produces one diagnostic.
            isCapturingSystemAudio = false
            systemAudioFailure = audioWriter?.error?.localizedDescription ?? "System audio could not be written."
            QuernLog.log("[AudioRecorder] System audio append failed: \(systemAudioFailure ?? "unknown")")
        }
    }
}

// MARK: - ScreenCaptureKit Delegate

extension AudioRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        isCapturingSystemAudio = false
        systemAudioFailure = error.localizedDescription
        QuernLog.log("[AudioRecorder] ⚠️ System audio stream error: \(error.localizedDescription)")
    }
}
