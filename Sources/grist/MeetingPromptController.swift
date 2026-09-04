import Foundation
import AppKit
import UserNotifications

/// Shows a local notification (and keeps menu-bar fallback state) when a meeting is detected.
@MainActor
final class MeetingPromptController: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MeetingPromptController()

    static let categoryId = "GRIST_MEETING_DETECT"
    static let actionRecord = "RECORD"
    static let actionDismiss = "DISMISS"

    private var authorized = false
    private(set) var lastDetection: MeetingDetector.Detection?

    private override init() {
        super.init()
    }

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let record = UNNotificationAction(
            identifier: Self.actionRecord,
            title: "Record in Grist",
            options: [.foreground]
        )
        let dismiss = UNNotificationAction(
            identifier: Self.actionDismiss,
            title: "Not now",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryId,
            actions: [record, dismiss],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        center.requestAuthorization(options: [.alert, .sound, .badge]) { ok, error in
            Task { @MainActor in
                self.authorized = ok
                if let error {
                    GristLog.log("[MeetingPrompt] auth error: \(error.localizedDescription)")
                } else {
                    GristLog.log("[MeetingPrompt] notifications authorized=\(ok)")
                }
            }
        }
    }

    func present(detection: MeetingDetector.Detection) {
        lastDetection = detection

        if MeetingDetectionSettings.shared.isAutoStart {
            NotificationCenter.default.post(
                name: .recordDetectedMeetingRequested,
                object: detection.appName
            )
            return
        }

        guard authorized else {
            // Menu bar still shows “Record detected meeting…”
            GristLog.log("[MeetingPrompt] no notification permission — menu bar only")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Meeting detected"
        content.body = "\(detection.appName) looks like an active call. Record in Grist?"
        content.sound = .default
        content.categoryIdentifier = Self.categoryId
        content.userInfo = [
            "appName": detection.appName,
            "detail": detection.detail,
        ]

        let req = UNNotificationRequest(
            identifier: "grist-meeting-\(detection.appName)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { err in
            if let err {
                GristLog.log("[MeetingPrompt] add failed: \(err.localizedDescription)")
            }
        }
    }

    func clearPending() {
        lastDetection = nil
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let appName = info["appName"] as? String
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            switch action {
            case Self.actionRecord, UNNotificationDefaultActionIdentifier:
                NotificationCenter.default.post(
                    name: .recordDetectedMeetingRequested,
                    object: appName
                )
            case Self.actionDismiss:
                MeetingDetector.shared.dismissCurrentPrompt()
            default:
                break
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

extension Notification.Name {
    static let recordDetectedMeetingRequested = Notification.Name("recordDetectedMeetingRequested")
}
