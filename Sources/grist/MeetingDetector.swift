import Foundation
import AppKit
import CoreGraphics

/// Detects active video meetings via running apps + window titles (local only).
@MainActor
final class MeetingDetector: ObservableObject {
    static let shared = MeetingDetector()

    struct Detection: Equatable {
        let appName: String
        let detail: String
    }

    @Published private(set) var current: Detection?
    /// True after debounce when a meeting appears and user hasn't dismissed this episode.
    @Published private(set) var pendingPrompt: Detection?

    private var timer: Timer?
    private var hits = 0
    private var lastFingerprint: String?
    /// Fingerprints dismissed until the meeting episode ends.
    private var dismissedFingerprints: Set<String> = []
    private let pollInterval: TimeInterval = 2.5
    private let hitsRequired = 2

    private init() {}

    func start() {
        stop()
        guard MeetingDetectionSettings.shared.detectEnabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Fire soon so first detection isn't delayed a full interval
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.tick()
        }
        GristLog.log("[MeetingDetect] started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func dismissCurrentPrompt() {
        guard let d = pendingPrompt ?? current else { return }
        let fp = fingerprint(d)
        dismissedFingerprints.insert(fp)
        pendingPrompt = nil
        MeetingPromptController.shared.clearPending()
        GristLog.log("[MeetingDetect] dismissed \(fp)")
    }

    func clearPromptAfterRecordingStarted() {
        pendingPrompt = nil
        MeetingPromptController.shared.clearPending()
    }

    private func tick() {
        guard MeetingDetectionSettings.shared.detectEnabled else {
            current = nil
            pendingPrompt = nil
            hits = 0
            return
        }
        if RecordingStatus.shared.isRecording {
            // Don't prompt while already recording
            pendingPrompt = nil
            return
        }

        let found = scan()
        if let found {
            let fp = fingerprint(found)
            if lastFingerprint == fp {
                hits += 1
            } else {
                lastFingerprint = fp
                hits = 1
            }
            current = found

            if hits >= hitsRequired,
               !dismissedFingerprints.contains(fp),
               pendingPrompt != found {
                pendingPrompt = found
                RecordingStatus.shared.setDetectedMeeting(appName: found.appName, detail: found.detail)
                MeetingPromptController.shared.present(detection: found)
                GristLog.log("[MeetingDetect] prompt \(found.appName) — \(found.detail)")
            }
        } else {
            if current != nil {
                // Meeting ended — allow future prompts
                if let last = lastFingerprint {
                    dismissedFingerprints.remove(last)
                }
                lastFingerprint = nil
                hits = 0
                current = nil
                pendingPrompt = nil
                RecordingStatus.shared.clearDetectedMeeting()
                MeetingPromptController.shared.clearPending()
            }
        }
    }

    private func fingerprint(_ d: Detection) -> String {
        "\(d.appName)|\(d.detail)"
    }

    private func scan() -> Detection? {
        let settings = MeetingDetectionSettings.shared
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        for w in windows {
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            let name = (w[kCGWindowName as String] as? String) ?? ""
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0, !name.isEmpty else { continue }

            if settings.zoomEnabled, let d = matchZoom(owner: owner, title: name) { return d }
            if settings.teamsEnabled, let d = matchTeams(owner: owner, title: name) { return d }
            if settings.webexEnabled, let d = matchWebex(owner: owner, title: name) { return d }
            if settings.meetEnabled, let d = matchGoogleMeet(owner: owner, title: name) { return d }
        }

        // Process fallback (app open with typical meeting helper) — weaker signal
        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            guard let bid = app.bundleIdentifier else { continue }
            if settings.zoomEnabled, bid == "us.zoom.xos" || bid.hasPrefix("us.zoom.") {
                // Only count if we also saw a Zoom window with a meeting-like title above;
                // bare Zoom client is not enough — skip process-only for Zoom.
                continue
            }
            if settings.teamsEnabled, bid.contains("teams") || bid == "com.microsoft.teams2" {
                continue
            }
        }
        return nil
    }

    private func matchZoom(owner: String, title: String) -> Detection? {
        let o = owner.lowercased()
        guard o.contains("zoom") else { return nil }
        let t = title.lowercased()
        if t == "zoom" || t == "zoom workplace" || t.contains("zoom cloud meetings") { return nil }
        if t.contains("settings") || t == "chat" { return nil }
        // Active call windows: "Zoom Meeting", webinar, or a topic-titled meeting window
        if t.contains("zoom meeting") || t.contains("webinar") || t.contains("meeting") {
            return Detection(appName: "Zoom", detail: title)
        }
        // Topic as window title while Zoom owns it (common during calls)
        if t.count >= 4 && !t.hasPrefix("zoom") {
            return Detection(appName: "Zoom", detail: title)
        }
        return nil
    }

    private func matchTeams(owner: String, title: String) -> Detection? {
        let o = owner.lowercased()
        guard o.contains("microsoft teams") || o.contains("teams") else { return nil }
        let t = title.lowercased()
        if t.contains("meeting")
            || t.contains("call with")
            || t.contains("| microsoft teams") && (t.contains("call") || t.contains("meeting"))
            || t.hasSuffix("call") {
            if t == "microsoft teams" || t == "teams" { return nil }
            return Detection(appName: "Microsoft Teams", detail: title)
        }
        return nil
    }

    private func matchWebex(owner: String, title: String) -> Detection? {
        let o = owner.lowercased()
        guard o.contains("webex") else { return nil }
        let t = title.lowercased()
        if t.contains("webex") || t.contains("meeting") {
            if t == "webex" || t.contains("webex app") { return nil }
            return Detection(appName: "Webex", detail: title)
        }
        return nil
    }

    private func matchGoogleMeet(owner: String, title: String) -> Detection? {
        let o = owner.lowercased()
        let browsers = ["chrome", "safari", "arc", "firefox", "brave", "microsoft edge", "edge", "dia", "comet"]
        guard browsers.contains(where: { o.contains($0) }) else { return nil }
        let t = title.lowercased()
        // Meet tab titles: "Meet - abc-defg-hij" or "xyz-abcd-efg - Meet"
        if t.contains("meet.google.com")
            || t.contains("meet –")
            || t.contains("meet -")
            || (t.contains(" meet") && t.contains("-") && t.count < 80) {
            // Exclude calendar.google.com noise
            if t.contains("calendar.google.com") { return nil }
            return Detection(appName: "Google Meet", detail: title)
        }
        return nil
    }
}

// MARK: - Settings

@MainActor
final class MeetingDetectionSettings: ObservableObject {
    static let shared = MeetingDetectionSettings()

    private let d = UserDefaults.standard

    var detectEnabled: Bool {
        get { d.object(forKey: "meetingDetectEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "meetingDetectEnabled"); objectWillChange.send(); applyRunningState() }
    }

    /// prompt | auto
    var detectMode: String {
        get { d.string(forKey: "meetingDetectMode") ?? "prompt" }
        set { d.set(newValue, forKey: "meetingDetectMode"); objectWillChange.send() }
    }

    var zoomEnabled: Bool {
        get { d.object(forKey: "meetingDetectZoom") as? Bool ?? true }
        set { d.set(newValue, forKey: "meetingDetectZoom"); objectWillChange.send() }
    }
    var teamsEnabled: Bool {
        get { d.object(forKey: "meetingDetectTeams") as? Bool ?? true }
        set { d.set(newValue, forKey: "meetingDetectTeams"); objectWillChange.send() }
    }
    var meetEnabled: Bool {
        get { d.object(forKey: "meetingDetectMeet") as? Bool ?? true }
        set { d.set(newValue, forKey: "meetingDetectMeet"); objectWillChange.send() }
    }
    var webexEnabled: Bool {
        get { d.object(forKey: "meetingDetectWebex") as? Bool ?? true }
        set { d.set(newValue, forKey: "meetingDetectWebex"); objectWillChange.send() }
    }

    var isAutoStart: Bool { detectMode == "auto" }

    private init() {}

    private func applyRunningState() {
        if detectEnabled {
            MeetingDetector.shared.start()
        } else {
            MeetingDetector.shared.stop()
            RecordingStatus.shared.clearDetectedMeeting()
        }
    }
}
