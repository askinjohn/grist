import Foundation
import AppKit
import SwiftUI
import UserNotifications

/// Delivers an actionable prompt with a floating fallback when system alerts are unavailable.
@MainActor
final class MeetingPromptController: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = MeetingPromptController()
    static let categoryId = "GRIST_MEETING_DETECT"
    static let actionRecord = "RECORD"
    static let actionDismiss = "DISMISS"
    private static let requestID = "quern-meeting-detection"

    @Published private(set) var notificationStatus = "Checking notification permission…"
    private(set) var lastDetection: MeetingDetector.Detection?
    private var panel: NSPanel?
    private var generation = UUID()
    private var pendingRequestID: String?

    private override init() { super.init() }

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(identifier: Self.actionRecord, title: "Take notes in Quern", options: [.foreground])
        let dismiss = UNNotificationAction(identifier: Self.actionDismiss, title: "Not now", options: [])
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.categoryId, actions: [record, dismiss], intentIdentifiers: [], options: [.customDismissAction]
        )])
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            Task { @MainActor in
                if let error { QuernLog.log("[MeetingPrompt] authorization error: \(error.localizedDescription)") }
                self.refreshAuthorization()
                // A call detected while the permission sheet was open must not be lost.
                if let detection = self.lastDetection { self.present(detection: detection) }
            }
        }
    }

    func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let canAlert = settings.alertSetting == .enabled
            Task { @MainActor in
                self.notificationStatus = canAlert
                    ? "System notifications enabled. Focus settings may silence banners."
                    : "System alerts unavailable. Quern will show a floating meeting prompt."
            }
        }
    }

    func present(detection: MeetingDetector.Detection, isTest: Bool = false) {
        clearPending()
        lastDetection = detection
        let token = generation
        if !isTest, !detection.requiresConfirmation, MeetingDetectionSettings.shared.isAutoStart {
            NotificationCenter.default.post(name: .recordDetectedMeetingRequested, object: detection.appName)
            return
        }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard generation == token, lastDetection != nil else { return }
            refreshAuthorization()
            guard settings.alertSetting == .enabled else {
                showPanel(detection: detection, isTest: isTest)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = isTest ? "Quern meeting prompt test" : "Take notes for this meeting?"
            content.body = detection.requiresConfirmation
                ? "\(detection.appName) is using your microphone. In a meeting? Quern can take notes."
                : "\(detection.appName) meeting detected. Start taking notes in Quern?"
            content.sound = .default
            content.categoryIdentifier = isTest ? "" : Self.categoryId
            content.userInfo = ["appName": detection.appName, "isTest": isTest, "generation": token.uuidString]
            let requestID = Self.requestID + "-" + token.uuidString
            pendingRequestID = requestID
            do {
                try await center.add(UNNotificationRequest(identifier: requestID, content: content, trigger: nil))
                if generation != token {
                    center.removePendingNotificationRequests(withIdentifiers: [requestID])
                    center.removeDeliveredNotifications(withIdentifiers: [requestID])
                }
            } catch {
                guard generation == token else { return }
                notificationStatus = "Notification delivery failed. Using a floating prompt."
                showPanel(detection: detection, isTest: isTest)
            }
        }
    }

    func testPrompt() {
        present(detection: .init(appName: "Google Meet", detail: "Test only — no recording will start"), isTest: true)
    }

    func clearPending() {
        generation = UUID()
        lastDetection = nil
        panel?.orderOut(nil)
        panel = nil
        let center = UNUserNotificationCenter.current()
        if let pendingRequestID {
            center.removePendingNotificationRequests(withIdentifiers: [pendingRequestID])
            center.removeDeliveredNotifications(withIdentifiers: [pendingRequestID])
        }
        pendingRequestID = nil
    }

    private func showPanel(detection: MeetingDetector.Detection, isTest: Bool) {
        panel?.orderOut(nil)
        let prompt = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 170),
                             styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        prompt.titleVisibility = .hidden
        prompt.titlebarAppearsTransparent = true
        prompt.isReleasedWhenClosed = false
        prompt.hidesOnDeactivate = false
        prompt.level = .floating
        prompt.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        prompt.contentView = NSHostingView(rootView: MeetingPromptCard(
            appName: detection.appName, isTest: isTest, uncertain: detection.requiresConfirmation,
            record: { [weak self] in
                self?.clearPending()
                if !isTest { NotificationCenter.default.post(name: .recordDetectedMeetingRequested, object: detection.appName) }
            }, dismiss: {
                if isTest { self.clearPending() } else { MeetingDetector.shared.dismissCurrentPrompt() }
            }
        ))
        if let screen = NSScreen.main {
            prompt.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - 380, y: screen.visibleFrame.maxY - 20))
        }
        panel = prompt
        prompt.orderFrontRegardless()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let appName = info["appName"] as? String
        let token = info["generation"] as? String
        let isTest = info["isTest"] as? Bool ?? false
        let action = response.actionIdentifier
        Task { @MainActor in
            guard token == self.generation.uuidString else { return }
            if isTest { self.clearPending(); return }
            switch action {
            case Self.actionRecord, UNNotificationDefaultActionIdentifier:
                self.clearPending()
                NotificationCenter.default.post(name: .recordDetectedMeetingRequested, object: appName)
            case Self.actionDismiss, UNNotificationDismissActionIdentifier:
                MeetingDetector.shared.dismissCurrentPrompt()
            default: break
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

private struct MeetingPromptCard: View {
    let appName: String
    let isTest: Bool
    let uncertain: Bool
    let record: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(isTest ? "Quern prompt test" : "Take notes for this meeting?", systemImage: "waveform")
                .font(.headline)
            Text(isTest ? "This is how Quern will ask to take notes. No recording will start."
                 : uncertain ? "\(appName) is using your microphone. In a meeting?"
                 : "\(appName) meeting detected. Quern can record and transcribe it.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Not now", action: dismiss)
                Spacer()
                Button(isTest ? "Looks good" : "Take notes", action: record).buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 360, height: 170)
    }
}

extension Notification.Name {
    static let recordDetectedMeetingRequested = Notification.Name("recordDetectedMeetingRequested")
}
