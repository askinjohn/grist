import Foundation
import AVFoundation
import AppKit

/// Read AI summaries aloud using **macOS system speech** (`AVSpeechSynthesizer`).
/// No cloud, no Voicebox — fully on-device.
///
/// Expressiveness is limited vs neural TTS, but you can:
/// - pick an **Enhanced / Premium** system voice (System Settings → Accessibility → Spoken Content)
/// - tune **rate** and **pitch**
@MainActor
final class SpeechService: NSObject, ObservableObject {
    static let shared = SpeechService()

    @Published private(set) var isSpeaking = false
    @Published private(set) var status: String = ""

    /// Identifier from `AVSpeechSynthesisVoice.identifier` (empty = best available English).
    @Published var selectedVoiceId: String = UserDefaults.standard.string(forKey: "speechVoiceId") ?? "" {
        didSet { UserDefaults.standard.set(selectedVoiceId, forKey: "speechVoiceId") }
    }

    /// 0.4 … 1.0 relative to default (persisted).
    @Published var rate: Double = {
        let v = UserDefaults.standard.object(forKey: "speechRate") as? Double
        return v ?? 0.95
    }() {
        didSet { UserDefaults.standard.set(rate, forKey: "speechRate") }
    }

    /// 0.5 … 2.0 (persisted). 1.0 = neutral.
    @Published var pitch: Double = {
        let v = UserDefaults.standard.object(forKey: "speechPitch") as? Double
        return v ?? 1.0
    }() {
        didSet { UserDefaults.standard.set(pitch, forKey: "speechPitch") }
    }

    private var synthesizer = AVSpeechSynthesizer()
    private var speakTask: Task<Void, Never>?

    /// English (and related) voices, enhanced first.
    var availableVoices: [AVSpeechSynthesisVoice] {
        let all = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
        return all.sorted { a, b in
            let qa = Self.qualityRank(a)
            let qb = Self.qualityRank(b)
            if qa != qb { return qa > qb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public

    func stop() {
        speakTask?.cancel()
        speakTask = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        status = ""
    }

    /// Speak plain or markdown-ish text (summary).
    func speak(_ raw: String) {
        stop()
        let text = Self.plainTextForSpeech(raw)
        guard !text.isEmpty else {
            status = "Nothing to read"
            return
        }
        speakViaSystem(text)
    }

    // MARK: - System voice

    private func speakViaSystem(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        let clampedRate = min(max(rate, 0.4), 1.15)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(clampedRate)
        utterance.pitchMultiplier = Float(min(max(pitch, 0.5), 2.0))
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.05
        utterance.postUtteranceDelay = 0.05
        utterance.voice = resolveVoice()

        let voiceName = utterance.voice?.name ?? "System"
        status = voiceName
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    private func resolveVoice() -> AVSpeechSynthesisVoice? {
        if !selectedVoiceId.isEmpty,
           let v = AVSpeechSynthesisVoice(identifier: selectedVoiceId) {
            return v
        }
        // Prefer enhanced/premium English if installed
        if let best = availableVoices.first {
            return best
        }
        return AVSpeechSynthesisVoice(language: "en-US")
            ?? AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.hasPrefix("en") })
    }

    /// Higher = better for “expressive” defaults (Premium > Enhanced > Default).
    private static func qualityRank(_ voice: AVSpeechSynthesisVoice) -> Int {
        // quality is .default / .enhanced on most macOS; premium may appear as enhanced or via name
        switch voice.quality {
        case .premium: return 3
        case .enhanced: return 2
        default:
            let n = voice.name.lowercased()
            if n.contains("premium") || n.contains("siri") { return 3 }
            if n.contains("enhanced") || n.contains("neural") { return 2 }
            return 1
        }
    }

    /// Human label for settings picker.
    static func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        let q: String
        switch voice.quality {
        case .premium: q = "Premium"
        case .enhanced: q = "Enhanced"
        default:
            let n = voice.name.lowercased()
            if n.contains("premium") { q = "Premium" }
            else if n.contains("enhanced") || n.contains("neural") { q = "Enhanced" }
            else { q = "Standard" }
        }
        return "\(voice.name) · \(voice.language) · \(q)"
    }

    func openSpokenContentSettings() {
        // Accessibility → Spoken Content (best-effort URL; falls back to Accessibility root)
        let urls = [
            "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent",
            "x-apple.systempreferences:com.apple.preference.universalaccess",
            "x-apple.systempreferences:com.apple.Accessibility-Settings.extension",
        ]
        for s in urls {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }

    // MARK: - Text cleanup

    /// Strip markdown-ish markup so TTS doesn't read asterisks.
    static func plainTextForSpeech(_ markdown: String) -> String {
        var s = markdown
        s = replaceRegex(s, pattern: "```[\\s\\S]*?```", with: " ")
        s = replaceRegex(s, pattern: "\\*\\*(.+?)\\*\\*", with: "$1")
        s = replaceRegex(s, pattern: "\\*(.+?)\\*", with: "$1")
        s = replaceRegex(s, pattern: "__(.+?)__", with: "$1")
        s = replaceRegex(s, pattern: "`(.+?)`", with: "$1")
        s = replaceRegex(s, pattern: "\\[(.+?)\\]\\((.+?)\\)", with: "$1")
        let lines = s.components(separatedBy: .newlines).map { line -> String in
            var l = line
            l = replaceRegex(l, pattern: "^#{1,6}\\s+", with: "")
            l = replaceRegex(l, pattern: "^[\\-\\*•]\\s+", with: "")
            l = replaceRegex(l, pattern: "^\\d+\\.\\s+", with: "")
            l = replaceRegex(l, pattern: "^[-*_]{3,}\\s*$", with: "")
            return l
        }
        s = lines.joined(separator: "\n")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceRegex(_ input: String, pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return input }
        let range = NSRange(input.startIndex..., in: input)
        return re.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.status = ""
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.status = ""
        }
    }
}
