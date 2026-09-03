import Foundation
import Combine

/// Shared recording state for the menu bar extra (lives outside `MainView`).
@MainActor
final class RecordingStatus: ObservableObject {
    static let shared = RecordingStatus()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var liveTranscript: String = ""

    private init() {}

    func sync(isRecording: Bool, elapsedSeconds: Int) {
        if self.isRecording != isRecording {
            self.isRecording = isRecording
        }
        if self.elapsedSeconds != elapsedSeconds {
            self.elapsedSeconds = elapsedSeconds
        }
        if !isRecording {
            // Keep last live text until UI clears / final transcript lands
        }
    }

    func setLiveTranscript(_ text: String) {
        if liveTranscript != text {
            liveTranscript = text
        }
    }

    func clearLiveTranscript() {
        liveTranscript = ""
    }

    var formattedElapsed: String {
        String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }
}

extension Notification.Name {
    static let stopRecordingRequested = Notification.Name("stopRecordingRequested")
    static let showGristWindowRequested = Notification.Name("showGristWindowRequested")
}
