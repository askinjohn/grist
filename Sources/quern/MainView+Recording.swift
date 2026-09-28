import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

extension MainView {
    // MARK: - Recording

    func toggleRecording() {
        if isRecording { stopRecording() } else {
            guard let m = selectedMeeting else { return }
            startRecording(meetingId: m.id)
        }
    }

    func startRecording(meetingId: String) {
        // Fail *before* a long meeting if Whisper can’t launch (missing model / broken dylibs).
        statusMessage = "Checking Whisper…"
        Task {
            let preflight = await WhisperTranscriber.shared.preflightForRecording()
            await MainActor.run {
                if case .failed(let message) = preflight {
                    statusMessage = message
                    importErrorMessage = message
                    importErrorOpenURL = nil
                    showingImportErrorAlert = true
                    QuernLog.log("[Record] blocked — Whisper preflight failed")
                    return
                }
                beginRecordingAfterPreflight(meetingId: meetingId)
            }
        }
    }

    private func beginRecordingAfterPreflight(meetingId: String) {
        isRecording = true
        recordingMeetingId = meetingId
        recordingSeconds = 0
        RecordingStatus.shared.sync(isRecording: true, elapsedSeconds: 0)
        RecordingStatus.shared.clearLiveTranscript()
        statusMessage = "Starting capture…"
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                recordingSeconds += 1
                RecordingStatus.shared.sync(isRecording: true, elapsedSeconds: recordingSeconds)
            }
        }
        Task {
            do {
                try await recorder.start(meetingId: meetingId)
                await MainActor.run {
                    if recorder.isCapturingSystemAudio {
                        statusMessage = "Recording mic + system audio"
                    } else {
                        statusMessage = "Recording mic only (no system audio). Toggle Quern OFF→ON in Screen Recording, quit app, relaunch."
                    }
                    // Rolling live transcript (non-blocking); final Whisper pass still runs on Stop.
                    LiveTranscriptionService.shared.start(meetingId: meetingId)
                    if selectedTab != "transcript", selectedMeeting?.id == meetingId {
                        // Nudge users to the live view once
                        selectedTab = "transcript"
                    }
                }
            } catch {
                await MainActor.run {
                    isRecording = false
                    recordingMeetingId = nil
                    recordingTimer?.invalidate()
                    RecordingStatus.shared.sync(isRecording: false, elapsedSeconds: 0)
                    LiveTranscriptionService.shared.stop()
                    statusMessage = "Mic error"
                }
            }
        }
    }

    func stopRecording() {
        let meetingId = recordingMeetingId ?? selectedMeeting?.id
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        let capturedDuration = recordingSeconds
        recordingSeconds = 0
        recordingMeetingId = nil
        RecordingStatus.shared.sync(isRecording: false, elapsedSeconds: 0)
        let liveDraft = LiveTranscriptionService.shared.liveText
        LiveTranscriptionService.shared.stop()
        statusMessage = "Transcribing…"

        // Always stop capture — even if selection is gone — so mic/SCK don’t keep running.
        Task {
            await recorder.stop()

            guard let meetingId else {
                await MainActor.run {
                    statusMessage = "Recording stopped (no meeting selected)"
                    RecordingStatus.shared.markIdle()
                }
                return
            }

            let transcript = await transcriber.transcribe(meetingId: meetingId)
            await MainActor.run {
                // Prefer the recorded meeting row (may differ from current selection).
                var target = (selectedMeeting?.id == meetingId) ? selectedMeeting : db.getMeeting(id: meetingId)
                if target == nil { target = db.getMeeting(id: meetingId) }

                guard var m = target else {
                    statusMessage = "Recording saved to disk; meeting row missing"
                    RecordingStatus.shared.markIdle()
                    return
                }

                if transcript.hasPrefix("[Error"), !liveDraft.isEmpty {
                    m.transcript = liveDraft
                } else {
                    m.transcript = transcript
                }
                if capturedDuration > 0 {
                    m.durationSeconds = max(m.durationSeconds, capturedDuration)
                }
                db.saveMeeting(m)
                if selectedMeeting?.id == meetingId {
                    selectedMeeting = m
                } else if let idx = meetings.firstIndex(where: { $0.id == meetingId }) {
                    meetings[idx] = m
                }
                RecordingStatus.shared.markIdle()
                statusMessage = ""

                RAGEngine.shared.indexMeetingNow(m)

                if selectedMeeting?.id == meetingId {
                    if autoEnhance {
                        runEnhance()
                    } else if !m.transcript.hasPrefix("[Error") {
                        generateAutoTitle(force: false)
                    }
                }
            }
        }
    }

    /// Menu bar / MainView can disagree after a SwiftUI remount: chrome says REC, `@State` says idle.
    func handleStopRecordingRequest() {
        if isRecording || recordingMeetingId != nil {
            stopRecording()
            return
        }
        if RecordingStatus.shared.isRecording || recorder.isActivelyCapturing
            || LiveTranscriptionService.shared.isRunning {
            QuernLog.log("[Record] clearing stale recording chrome (MainView idle)")
            statusMessage = ""
            RecordingStatus.shared.forceStopHardwareAndChrome()
        }
    }

    /// Drop ghost “Recording 0:00” if chrome is on but nothing is capturing.
    func reconcileRecordingStatusWithHardware() {
        let chromeOn = RecordingStatus.shared.isRecording
        let capturing = recorder.isActivelyCapturing
        let liveOn = LiveTranscriptionService.shared.isRunning

        if chromeOn && !isRecording && !capturing {
            QuernLog.log("[Record] reconcile: stale menu chrome → idle")
            recordingTimer?.invalidate()
            recordingTimer = nil
            recordingMeetingId = nil
            recordingSeconds = 0
            if liveOn { LiveTranscriptionService.shared.stop() }
            RecordingStatus.shared.markIdle()
            return
        }

        // Hardware still running but UI lost the session — stop capture to avoid silent recording.
        if !isRecording && capturing {
            QuernLog.log("[Record] reconcile: orphaned capture → force stop")
            recordingMeetingId = nil
            recordingTimer?.invalidate()
            recordingTimer = nil
            RecordingStatus.shared.forceStopHardwareAndChrome()
        }
    }
}
