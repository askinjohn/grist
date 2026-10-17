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
        guard !isRecording, !isStartingRecording, !isTranscribing else { return }
        isStartingRecording = true
        // Fail *before* a long meeting if Whisper can’t launch (missing model / broken dylibs).
        statusMessage = "Checking Whisper…"
        Task {
            let preflight = await WhisperTranscriber.shared.preflightForRecording()
            await MainActor.run {
                if case .failed(let message) = preflight {
                    isStartingRecording = false
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
        statusMessage = "Starting capture…"
        Task {
            do {
                try await recorder.start(meetingId: meetingId)
                await MainActor.run {
                    isStartingRecording = false
                    isRecording = true
                    recordingMeetingId = meetingId
                    recordingSeconds = 0
                    RecordingStatus.shared.sync(isRecording: true, elapsedSeconds: 0)
                    RecordingStatus.shared.clearLiveTranscript()
                    recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                        Task { @MainActor in
                            recordingSeconds += 1
                            RecordingStatus.shared.sync(isRecording: true, elapsedSeconds: recordingSeconds)
                        }
                    }
                    if recorder.isCapturingSystemAudio && recorder.isCapturingMicrophone {
                        statusMessage = "Recording mic + system audio"
                    } else if recorder.isCapturingSystemAudio {
                        statusMessage = "Recording system audio only (microphone unavailable)"
                    } else {
                        statusMessage = "Recording microphone only — meeting audio is unavailable."
                        importErrorMessage = "System audio capture failed. This recording can only hear your microphone.\n\nQuit Quern, turn its Screen & System Audio Recording permission off and on, then reopen Quern and try a short test with audio playing.\n\nDetails: \(recorder.systemAudioFailure ?? "System audio did not start.")"
                        importErrorOpenURL = nil
                        showingImportErrorAlert = true
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
                    isStartingRecording = false
                    isRecording = false
                    recordingMeetingId = nil
                    recordingTimer?.invalidate()
                    RecordingStatus.shared.sync(isRecording: false, elapsedSeconds: 0)
                    LiveTranscriptionService.shared.stop()
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    func stopRecording() {
        guard isRecording, !isTranscribing else { return }
        isTranscribing = true
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
            defer { isTranscribing = false }
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
                let failed = transcript.hasPrefix("[Error") || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                guard let m = db.modifyMeeting(id: meetingId, { current in
                    if !failed {
                        current.transcript = transcript
                    } else if current.transcript.isEmpty, !liveDraft.isEmpty {
                        current.transcript = liveDraft
                    }
                    if capturedDuration > 0 { current.durationSeconds = max(current.durationSeconds, capturedDuration) }
                }) else {
                    statusMessage = "Audio saved to disk; transcript could not be saved"
                    RecordingStatus.shared.markIdle()
                    return
                }
                if selectedMeeting?.id == meetingId {
                    selectedMeeting = m
                }
                if let idx = meetings.firstIndex(where: { $0.id == meetingId }) {
                    meetings[idx] = m
                }
                RecordingStatus.shared.markIdle()
                statusMessage = failed ? "Transcription failed. Audio saved — use Retry transcription. Previous text was preserved when available." : ""

                RAGEngine.shared.indexMeetingNow(m)

                if !failed, selectedMeeting?.id == meetingId {
                    if autoEnhance {
                        runEnhance()
                    } else if !m.transcript.hasPrefix("[Error") {
                        generateAutoTitle(force: false)
                    }
                }
            }
        }
    }
    func retryTranscription() {
        guard let id = selectedMeeting?.id, !isRecording, !isStartingRecording, !isTranscribing else { return }
        isTranscribing = true
        statusMessage = "Transcribing saved audio…"
        Task {
            defer { isTranscribing = false }
            let transcript = await transcriber.transcribe(meetingId: id)
            guard !transcript.hasPrefix("[Error"), !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                statusMessage = "Transcription failed. Saved audio and existing transcript were preserved."
                return
            }
            guard let updated = db.modifyMeeting(id: id, { $0.transcript = transcript }) else {
                statusMessage = "Could not save transcript"
                return
            }
            if selectedMeeting?.id == id { selectedMeeting = updated }
            if let index = meetings.firstIndex(where: { $0.id == id }) { meetings[index] = updated }
            RAGEngine.shared.indexMeetingNow(updated)
            statusMessage = "Transcription complete"
        }
    }


    /// Menu bar / MainView can disagree after a SwiftUI remount: chrome says REC, `@State` says idle.
    func handleStopRecordingRequest() {
        if isRecording {
            stopRecording()
            return
        }
        if recordingMeetingId != nil || RecordingStatus.shared.isRecording || recorder.isActivelyCapturing
            || LiveTranscriptionService.shared.isRunning {
            QuernLog.log("[Record] clearing stale recording chrome (MainView idle)")
            recordingMeetingId = nil
            recordingTimer?.invalidate()
            recordingTimer = nil
            statusMessage = ""
            RecordingStatus.shared.forceStopHardwareAndChrome()
        }
    }

    /// Drop ghost “Recording 0:00” if chrome is on but nothing is capturing.
    func reconcileRecordingStatusWithHardware() {
        guard !isStartingRecording, !isTranscribing else { return }
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
