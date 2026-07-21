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
        let fileManager = FileManager.default
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let gristFolder = appSupportURL.appendingPathComponent("Grist", isDirectory: true)
        let meetingsFolder = gristFolder.appendingPathComponent("meetings", isDirectory: true)
        try? fileManager.createDirectory(at: meetingsFolder, withIntermediateDirectories: true, attributes: nil)
        return meetingsFolder
    }
    
    func getMeetingFolder(meetingId: String) -> URL {
        let folder = getMeetingsFolder().appendingPathComponent(meetingId, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        return folder
    }
    
    /// True after the last successful SCStream startCapture.
    private(set) var isCapturingSystemAudio = false

    /// Avoid hammering SCShareableContent (and its dialog) after a hard permission failure this launch.
    nonisolated(unsafe) private static var skipSystemAudioThisSession = false

    func start(meetingId: String) async throws {
        isCapturingSystemAudio = false

        await PermissionHelper.ensureMicrophonePermission()
        if !PermissionHelper.hasMicrophoneAccess {
            print("[AudioRecorder] ⚠️ Microphone not authorized")
        }

        let meetingFolder = getMeetingFolder(meetingId: meetingId)
        
        // Clean old files from previous recordings
        for name in ["mic.m4a", "system.wav", "mono.wav", "mono.wav.txt", "raw.m4a"] {
            try? FileManager.default.removeItem(at: meetingFolder.appendingPathComponent(name))
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
                print("[AudioRecorder] ✅ Mic recording started → mic.m4a")
            } else {
                print("[AudioRecorder] ⚠️ Mic recorder failed to start")
            }
        } catch {
            print("[AudioRecorder] ⚠️ Mic init error: \(error.localizedDescription)")
        }
        
        // === 2. Start System Audio via ScreenCaptureKit ===
        // IMPORTANT: Do NOT hard-skip solely on CGPreflightScreenCaptureAccess().
        // Settings can show Grist ON while preflight is still false (stale TCC /
        // post-re-sign). Always try SCShareableContent unless we already failed
        // this launch with a permission error.
        if Self.skipSystemAudioThisSession {
            print("[AudioRecorder] Skipping system audio (permission failed earlier this launch — quit & relaunch after enabling Grist)")
            return
        }

        do {
            // Prefer on-screen content; false/false is more likely to include active displays + audio.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                print("[AudioRecorder] ⚠️ No display found, system audio skipped")
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
            writer.add(writerInput)
            writer.startWriting()
            // Session start is deferred to first audio sample arrival
            
            self.audioWriter = writer
            self.audioWriterInput = writerInput
            self.sessionStarted = false
            
            let scStream = SCStream(filter: filter, configuration: config, delegate: self)
            try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.grist.systemaudio"))
            try await scStream.startCapture()
            self.stream = scStream
            self.isCapturingSystemAudio = true
            print("[AudioRecorder] ✅ System audio recording started via ScreenCaptureKit (display \(display.displayID))")
        } catch {
            let msg = error.localizedDescription
            print("[AudioRecorder] ⚠️ System audio unavailable: \(msg)")
            print("[AudioRecorder] Continuing with mic-only recording")
            // If TCC denied, don't re-hit SCShareableContent every meeting this launch.
            let lower = msg.lowercased()
            if lower.contains("deny") || lower.contains("not authorized") || lower.contains("permission")
                || lower.contains("tcc") || lower.contains("screen") {
                Self.skipSystemAudioThisSession = true
            }
            // Clean up half-created writer
            audioWriterInput = nil
            audioWriter = nil
            stream = nil
            sessionStarted = false
        }
    }
    
    func stop() async {
        // Stop mic recording
        if let rec = micRecorder {
            let url = rec.url
            rec.stop()
            micRecorder = nil
            try? await Task.sleep(nanoseconds: 200_000_000)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
            print("[AudioRecorder] Mic stopped. Size: \(size) bytes")
        }
        
        // Stop system audio capture
        if let scStream = stream {
            do {
                try await scStream.stopCapture()
                print("[AudioRecorder] System audio capture stopped")
            } catch {
                print("[AudioRecorder] Error stopping system audio: \(error.localizedDescription)")
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
            print("[AudioRecorder] System audio file finalized. Size: \(size) bytes")
            self.audioWriter = nil
            self.audioWriterInput = nil
        }
        
        try? await Task.sleep(nanoseconds: 200_000_000)
        print("[AudioRecorder] All recording stopped.")
    }
}

// MARK: - ScreenCaptureKit Audio Output

extension AudioRecorder: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        guard let writerInput = audioWriterInput, writerInput.isReadyForMoreMediaData else { return }
        
        if !sessionStarted {
            sessionStarted = true
            audioWriter?.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        
        writerInput.append(sampleBuffer)
    }
}

// MARK: - ScreenCaptureKit Delegate

extension AudioRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[AudioRecorder] ⚠️ System audio stream error: \(error.localizedDescription)")
    }
}
