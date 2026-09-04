import Foundation
import Combine

/// Shared recording / detection state for the menu bar extra (lives outside `MainView`).
@MainActor
final class RecordingStatus: ObservableObject {
    static let shared = RecordingStatus()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds = 0
    /// When a call is detected and we're waiting on the user (prompt mode).
    @Published private(set) var detectedMeetingApp: String = ""
    @Published private(set) var detectedMeetingDetail: String = ""

    private init() {}

    var hasDetectedMeeting: Bool {
        !detectedMeetingApp.isEmpty && !isRecording
    }

    func sync(isRecording: Bool, elapsedSeconds: Int) {
        if self.isRecording != isRecording {
            self.isRecording = isRecording
        }
        if self.elapsedSeconds != elapsedSeconds {
            self.elapsedSeconds = elapsedSeconds
        }
        if isRecording {
            clearDetectedMeeting()
        }
    }

    func setDetectedMeeting(appName: String, detail: String) {
        detectedMeetingApp = appName
        detectedMeetingDetail = detail
    }

    func clearDetectedMeeting() {
        detectedMeetingApp = ""
        detectedMeetingDetail = ""
    }

    var formattedElapsed: String {
        String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }
}

extension Notification.Name {
    static let stopRecordingRequested = Notification.Name("stopRecordingRequested")
    static let showGristWindowRequested = Notification.Name("showGristWindowRequested")
}
