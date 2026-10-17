import Testing
@testable import quern

@MainActor
struct MeetingDetectionTests {
    @Test func chromeHelperActivityOffersConfirmation() throws {
        let detection = try #require(MeetingDetector.audioDetection(bundleID: "com.google.Chrome.helper"))
        #expect(detection.appName == "Google Chrome")
        #expect(detection.requiresConfirmation)
        #expect(detection.episodeKey == "Google Chrome")
    }

    @Test func unrelatedMicrophoneAppsAreIgnored() {
        #expect(MeetingDetector.audioDetection(bundleID: "com.quern.meetingassistant") == nil)
        #expect(MeetingDetector.audioDetection(bundleID: "com.apple.QuickTimePlayerX") == nil)
        #expect(MeetingDetector.audioDetection(bundleID: "example.chrome.recorder") == nil)
    }

    @Test func nativeMeetingAudioIsRecognized() {
        #expect(MeetingDetector.audioDetection(bundleID: "us.zoom.xos")?.appName == "Zoom")
        #expect(MeetingDetector.audioDetection(bundleID: "com.microsoft.teams2")?.appName == "Microsoft Teams")
        #expect(MeetingDetector.audioDetection(bundleID: "com.cisco.webexmeetingsapp")?.appName == "Webex")
    }

    @Test func meetWindowAndChromeAudioShareEpisode() throws {
        let detector = MeetingDetector.shared
        for title in ["Meet - abc-defg-hij", "Design review - Google Meet", "abc-defg-hij – Meet"] {
            let detection = try #require(detector.matchGoogleMeet(owner: "Google Chrome", title: title))
            #expect(detection.appName == "Google Meet")
            #expect(detection.episodeKey == "Google Chrome")
        }
        #expect(detector.matchGoogleMeet(owner: "Google Chrome", title: "Calendar - calendar.google.com") == nil)
        #expect(detector.matchGoogleMeet(owner: "Notes", title: "Meet - abc-defg-hij") == nil)
        #expect(detector.matchGoogleMeet(owner: "Google Chrome", title: "How to meet people - Search") == nil)
    }

    @Test func episodeDebouncesAndDoesNotRepeatAfterDismissal() {
        var episode = MeetingDetectionEpisode()
        #expect(episode.observe("Google Chrome") == false)
        #expect(episode.observe("Google Chrome") == true)
        episode.dismiss()
        for _ in 0..<10 { #expect(episode.observe("Google Chrome") == false) }
    }

    @Test func briefSignalLossDoesNotRepeatPrompt() {
        var episode = MeetingDetectionEpisode()
        _ = episode.observe("Google Chrome")
        _ = episode.observe("Google Chrome")
        for _ in 0..<3 { #expect(episode.observe(nil) == false) }
        #expect(episode.observe("Google Chrome") == false)
    }

    @Test func newMeetingPromptsAfterPreviousEpisodeEnds() {
        var episode = MeetingDetectionEpisode()
        _ = episode.observe("Google Chrome")
        _ = episode.observe("Google Chrome")
        for _ in 0..<4 { _ = episode.observe(nil) }
        #expect(episode.key == nil)
        #expect(episode.observe("Google Chrome") == false)
        #expect(episode.observe("Google Chrome") == true)
    }
}
