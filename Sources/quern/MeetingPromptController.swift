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
    static let recordingCategoryId = "QUERN_RECORDING_REMINDER"
    static let meetingEndedCategoryId = "QUERN_MEETING_ENDED_RECORDING"
    static let actionStopRecording = "STOP_RECORDING"
    static let actionKeepRecording = "KEEP_RECORDING"
    private static let requestID = "quern-meeting-detection"
    nonisolated private static let recordingReminderPrefix = "quern-recording-reminder-"
    private static let recordingReminderInterval: TimeInterval = 30 * 60
    private static let meetingEndedRequestID = "quern-meeting-ended-recording"

    @Published private(set) var notificationStatus = "Checking notification permission…"
    private(set) var lastDetection: MeetingDetector.Detection?
    private var panel: NSPanel?
    private var generation = UUID()
    private var pendingRequestID: String?
    private var recordingReminderTimer: Timer?
    private var recordingReminderSequence = 0
    private var recordingPanel: NSPanel?

    private override init() { super.init() }

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(identifier: Self.actionRecord, title: "Take notes in Quern", options: [.foreground])
        let dismiss = UNNotificationAction(identifier: Self.actionDismiss, title: "Not now", options: [])
        let stopRecording = UNNotificationAction(identifier: Self.actionStopRecording, title: "Stop Recording", options: [.foreground])
        let keepRecording = UNNotificationAction(identifier: Self.actionKeepRecording, title: "Keep Recording", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryId, actions: [record, dismiss], intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: Self.recordingCategoryId, actions: [stopRecording], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.meetingEndedCategoryId, actions: [stopRecording, keepRecording], intentIdentifiers: [], options: [.customDismissAction])
        ])
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

    /// Remind during unattended sessions, even when macOS alerts are disabled.
    func startRecordingReminders() {
        stopRecordingReminders()
        recordingReminderTimer = Timer.scheduledTimer(withTimeInterval: Self.recordingReminderInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.presentRecordingReminder() }
        }
    }

    func stopRecordingReminders() {
        recordingReminderTimer?.invalidate()
        recordingReminderTimer = nil
        recordingReminderSequence = 0
        recordingPanel?.orderOut(nil)
        recordingPanel = nil
        clearMeetingEndedPrompt()
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let ids = notifications.map(\.request.identifier).filter { $0.hasPrefix(Self.recordingReminderPrefix) }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(Self.recordingReminderPrefix) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    func presentMeetingEndedPrompt() {
        guard RecordingStatus.shared.isRecording else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard RecordingStatus.shared.isRecording else { return }
            guard settings.alertSetting == .enabled else {
                showMeetingEndedPanel()
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Has your meeting ended?"
            content.body = "Quern hasn’t detected meeting microphone activity for 3 minutes. Stop this recording or keep it going?"
            content.sound = .default
            content.categoryIdentifier = Self.meetingEndedCategoryId
            do {
                try await center.add(UNNotificationRequest(identifier: Self.meetingEndedRequestID, content: content, trigger: nil))
            } catch {
                QuernLog.log("[RecordingReminder] meeting-end prompt failed: \(error.localizedDescription)")
                showMeetingEndedPanel()
            }
        }
    }

    func clearMeetingEndedPrompt() {
        recordingPanel?.orderOut(nil)
        recordingPanel = nil
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.meetingEndedRequestID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.meetingEndedRequestID])
    }

    private func keepRecording() {
        clearMeetingEndedPrompt()
        MeetingDetector.shared.keepRecordingAfterMeetingEndPrompt()
    }

    private func confirmStopAfterMeetingEnd() {
        clearMeetingEndedPrompt()
        NotificationCenter.default.post(name: .stopRecordingRequested, object: "meetingEnded")
    }

    private func showMeetingEndedPanel() {
        let panel: NSPanel
        if let existing = recordingPanel {
            panel = existing
        } else {
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            recordingPanel = panel
        }
        panel.contentView = NSHostingView(rootView: MeetingEndedCard(
            elapsed: RecordingStatus.shared.formattedElapsed,
            keep: { [weak self] in self?.keepRecording() },
            stop: { [weak self] in self?.confirmStopAfterMeetingEnd() }
        ))
        if let screen = NSScreen.main {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - 400, y: screen.visibleFrame.maxY - 20))
        }
        panel.orderFrontRegardless()
    }

    private func presentRecordingReminder() {
        guard RecordingStatus.shared.isRecording else {
            stopRecordingReminders()
            return
        }
        recordingReminderSequence += 1
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard RecordingStatus.shared.isRecording else { return }
            guard settings.alertSetting == .enabled else {
                showRecordingReminderPanel()
                return
            }
            let elapsed = RecordingStatus.shared.formattedElapsed
            let content = UNMutableNotificationContent()
            content.title = "Quern is still recording"
            content.body = "This session has been recording for \(elapsed). Stop it when your meeting is over."
            content.sound = .default
            content.categoryIdentifier = Self.recordingCategoryId
            let id = Self.recordingReminderPrefix + UUID().uuidString
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            } catch {
                QuernLog.log("[RecordingReminder] notification failed: \(error.localizedDescription)")
                showRecordingReminderPanel()
            }
        }
    }

    private func showRecordingReminderPanel() {
        let panel: NSPanel
        if let existing = recordingPanel {
            panel = existing
        } else {
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            recordingPanel = panel
        }
        panel.contentView = NSHostingView(rootView: RecordingReminderCard(
            elapsed: RecordingStatus.shared.formattedElapsed,
            stop: { [weak self] in
                self?.stopRecordingReminders()
                NotificationCenter.default.post(name: .stopRecordingRequested, object: nil)
            }, show: {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .showQuernWindowRequested, object: nil)
            }
        ))
        if let screen = NSScreen.main {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - 400, y: screen.visibleFrame.maxY - 20))
        }
        panel.orderFrontRegardless()
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
        let category = response.notification.request.content.categoryIdentifier
        Task { @MainActor in
            if category == Self.meetingEndedCategoryId {
                switch action {
                case Self.actionStopRecording:
                    self.confirmStopAfterMeetingEnd()
                case Self.actionKeepRecording, UNNotificationDefaultActionIdentifier, UNNotificationDismissActionIdentifier:
                    self.keepRecording()
                default: break
                }
                return
            }
            if category == Self.recordingCategoryId, action == Self.actionStopRecording {
                self.stopRecordingReminders()
                NotificationCenter.default.post(name: .stopRecordingRequested, object: nil)
                return
            }
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

private struct RecordingReminderCard: View {
    let elapsed: String
    let stop: () -> Void
    let show: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Quern is still recording", systemImage: "record.circle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("This session has been running for \(elapsed). Stop it when your meeting is over.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Show Quern", action: show)
                Spacer()
                Button("Stop Recording", action: stop).buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 380, height: 180)
    }
}

private struct MeetingEndedCard: View {
    let elapsed: String
    let keep: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Has your meeting ended?", systemImage: "waveform")
                .font(.headline)
            Text("Quern hasn’t detected meeting microphone activity for 3 minutes. This recording has run for \(elapsed).")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Keep Recording", action: keep)
                Spacer()
                Button("Stop Recording", action: stop).buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 380, height: 180)
    }
}

extension Notification.Name {
    static let recordDetectedMeetingRequested = Notification.Name("recordDetectedMeetingRequested")
}
