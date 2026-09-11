import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct RootView: View {
    var body: some View {
        MainView()
    }
}

extension Notification.Name {
    static let meetingDeleted = Notification.Name("meetingDeleted")
    static let exportMeetingRequested = Notification.Name("exportMeetingRequested")
}

// MARK: - Main View

