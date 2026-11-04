import Foundation
import AppKit
import CoreGraphics

/// Detects likely meetings via window titles and per-process microphone activity (local only).
@MainActor
final class MeetingDetector: ObservableObject {
    static let shared = MeetingDetector()

    struct Detection: Equatable {
        let appName: String
        let detail: String
        var sourceID: String = ""
        var requiresConfirmation: Bool = false
        var suggestedTitle: String? {
            guard !requiresConfirmation else { return nil }
            var title = detail
            for suffix in [" - Google Chrome", " - Google Meet", " – Google Meet", " - Meet", " – Meet"] {
                if title.hasSuffix(suffix) { title = String(title.dropLast(suffix.count)) }
            }
            for prefix in ["Meet - ", "Meet – "] { if title.hasPrefix(prefix) { title = String(title.dropFirst(prefix.count)) } }
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !clean.contains("using your microphone"), clean != appName else { return nil }
            return clean
        }
        var episodeKey: String { sourceID.isEmpty ? appName : sourceID }
    }

    @Published private(set) var current: Detection?
    /// True after debounce when a meeting appears and user hasn't dismissed this episode.
    @Published private(set) var pendingPrompt: Detection?

    private var timer: Timer?
    private var episode = MeetingDetectionEpisode()
    private let pollInterval: TimeInterval = 2.5
    private let meetingEndGrace: TimeInterval = 3 * 60
    private var sawMeetingActivityDuringRecording = false
    private var meetingActivityMissingSince: Date?
    private var isMeetingEndPromptPresented = false
    private var promptSnoozedUntil: Date?

    private init() {}

    func start() {
        stop()
        guard MeetingDetectionSettings.shared.detectEnabled || MeetingDetectionSettings.shared.askToStopAfterMeetingEnd else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Fire soon so first detection isn't delayed a full interval
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.tick()
        }
        QuernLog.log("[MeetingDetect] started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        episode = MeetingDetectionEpisode()
        resetRecordingMonitor()
        MeetingPromptController.shared.clearMeetingEndedPrompt()
        current = nil
        pendingPrompt = nil
        RecordingStatus.shared.clearDetectedMeeting()
        MeetingPromptController.shared.clearPending()
    }

    func dismissCurrentPrompt() {
        episode.dismiss()
        pendingPrompt = nil
        RecordingStatus.shared.clearDetectedMeeting()
        MeetingPromptController.shared.clearPending()
    }

    func clearPromptAfterRecordingStarted() {
        dismissCurrentPrompt()
    }

    private func tick() {
        guard timer != nil else { return }
        if RecordingStatus.shared.isRecording {
            monitorRecordingForMeetingEnd()
            pendingPrompt = nil
            return
        }
        resetRecordingMonitor()
        guard MeetingDetectionSettings.shared.detectEnabled else { return }
        let found = scan()
        let shouldPrompt = episode.observe(found?.episodeKey)
        if let found {
            current = found
            if shouldPrompt {
                pendingPrompt = found
                RecordingStatus.shared.setDetectedMeeting(appName: found.appName, detail: found.detail)
                MeetingPromptController.shared.present(detection: found)
                QuernLog.log("[MeetingDetect] prompt source=\(found.appName)")
            }
        } else if episode.key == nil, current != nil {
            current = nil
            pendingPrompt = nil
            RecordingStatus.shared.clearDetectedMeeting()
            MeetingPromptController.shared.clearPending()
        }
    }

    private func monitorRecordingForMeetingEnd() {
        if hasMeetingMicrophoneActivity() {
            if isMeetingEndPromptPresented { MeetingPromptController.shared.clearMeetingEndedPrompt() }
            sawMeetingActivityDuringRecording = true
            meetingActivityMissingSince = nil
            isMeetingEndPromptPresented = false
            promptSnoozedUntil = nil
            return
        }
        guard MeetingDetectionSettings.shared.askToStopAfterMeetingEnd,
              !isMeetingEndPromptPresented,
              sawMeetingActivityDuringRecording else { return }
        let missingSince = meetingActivityMissingSince ?? Date()
        meetingActivityMissingSince = missingSince
        guard Date().timeIntervalSince(missingSince) >= meetingEndGrace,
              promptSnoozedUntil.map({ Date() >= $0 }) ?? true else { return }

        isMeetingEndPromptPresented = true
        QuernLog.log("[MeetingDetect] asking whether to stop after meeting activity was absent for 3 minutes")
        MeetingPromptController.shared.presentMeetingEndedPrompt()
    }

    func keepRecordingAfterMeetingEndPrompt() {
        isMeetingEndPromptPresented = false
        promptSnoozedUntil = Date().addingTimeInterval(15 * 60)
        QuernLog.log("[MeetingDetect] recording kept; meeting-end prompt snoozed for 15 minutes")
    }

    private func hasMeetingMicrophoneActivity() -> Bool {
        let settings = MeetingDetectionSettings.shared
        return MeetingAudioActivity.inputBundleIDs().contains { bundleID in
            guard let detection = Self.audioDetection(bundleID: bundleID) else { return false }
            switch detection.appName {
            case "Zoom": return settings.zoomEnabled
            case "Microsoft Teams": return settings.teamsEnabled
            case "Webex": return settings.webexEnabled
            default: return detection.requiresConfirmation && settings.meetEnabled
            }
        }
    }

    private func resetRecordingMonitor() {
        sawMeetingActivityDuringRecording = false
        meetingActivityMissingSince = nil
        isMeetingEndPromptPresented = false
        promptSnoozedUntil = nil
    }

    private func scan() -> Detection? {
        let settings = MeetingDetectionSettings.shared
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

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

        // Core Audio still exposes browser input activity when window titles are
        // unavailable (permissions, another tab, minimized window, or another Space).
        for bundleID in MeetingAudioActivity.inputBundleIDs().sorted() {
            if let detection = Self.audioDetection(bundleID: bundleID),
               (detection.appName == "Zoom" && settings.zoomEnabled)
                || (detection.appName == "Microsoft Teams" && settings.teamsEnabled)
                || (detection.appName == "Webex" && settings.webexEnabled)
                || (detection.requiresConfirmation && settings.meetEnabled) {
                return detection
            }
        }
        return nil
    }

    static func browserName(_ identity: String) -> String? {
        let value = identity.lowercased()
        let browsers = [("chrome", "Google Chrome"), ("safari", "Safari"), ("arc", "Arc"),
                        ("firefox", "Firefox"), ("brave", "Brave"), ("edge", "Microsoft Edge"),
                        ("dia", "Dia"), ("comet", "Comet")]
        return browsers.first(where: { value.contains($0.0) })?.1
    }

    static func audioDetection(bundleID: String) -> Detection? {
        let id = bundleID.lowercased()
        if id == "us.zoom.xos" || id.hasPrefix("us.zoom.") {
            return Detection(appName: "Zoom", detail: "Zoom is using your microphone")
        }
        if id.hasPrefix("com.microsoft.teams") {
            return Detection(appName: "Microsoft Teams", detail: "Teams is using your microphone")
        }
        if id.hasPrefix("com.cisco.webex") || id.hasPrefix("com.webex") {
            return Detection(appName: "Webex", detail: "Webex is using your microphone")
        }
        // Browser mic use alone cannot distinguish Meet from dictation or another site.
        let browserPrefixes = ["com.google.chrome", "com.apple.safari", "com.apple.webkit", "company.thebrowser.browser",
                               "org.mozilla.firefox", "com.brave.browser", "com.microsoft.edgemac",
                               "company.thebrowser.dia", "ai.perplexity.comet"]
        guard browserPrefixes.contains(where: { id == $0 || id.hasPrefix($0 + ".") }) else { return nil }
        let browser = id.hasPrefix("company.thebrowser.browser") ? "Arc"
            : id.hasPrefix("com.apple.webkit") ? "Safari" : browserName(id) ?? "Browser"
        return Detection(appName: browser, detail: "Your browser is using the microphone. In a meeting?",
                         sourceID: browser, requiresConfirmation: true)
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

    func matchGoogleMeet(owner: String, title: String) -> Detection? {
        let o = owner.lowercased()
        let browsers = ["chrome", "safari", "arc", "firefox", "brave", "microsoft edge", "edge", "dia", "comet"]
        guard browsers.contains(where: { o.contains($0) }) else { return nil }
        let t = title.lowercased()
        // Meet tab titles: "Meet - abc-defg-hij" or "xyz-abcd-efg - Meet"
        if t.contains("meet.google.com")
            || t.contains("meet –")
            || t.contains("meet -")
            || t.hasSuffix(" - meet") || t.hasSuffix(" – meet")
            || t.contains(" - google meet") {
            // Exclude calendar.google.com noise
            if t.contains("calendar.google.com") { return nil }
            return Detection(appName: "Google Meet", detail: title, sourceID: Self.browserName(owner) ?? owner)
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

    /// Requires supported meeting-app microphone activity during the session.
    var askToStopAfterMeetingEnd: Bool {
        get { d.object(forKey: "autoStopAfterMeetingEnd") as? Bool ?? true }
        set {
            d.set(newValue, forKey: "autoStopAfterMeetingEnd")
            objectWillChange.send()
            applyRunningState()
        }
    }

    var isAutoStart: Bool { detectMode == "auto" }

    private init() {}

    private func applyRunningState() {
        if detectEnabled || askToStopAfterMeetingEnd {
            MeetingDetector.shared.start()
        } else {
            MeetingDetector.shared.stop()
            RecordingStatus.shared.clearDetectedMeeting()
        }
    }
}
