import Foundation
import AVFoundation
import AppKit

/// Local text-to-speech for reading AI summaries aloud.
///
/// - **Voicebox** (optional): open-source local voice studio at http://127.0.0.1:17493
///   (Qwen3-TTS, Chatterbox, Kokoro, …) — think “Ollama for voices,” not Ollama itself.
/// - **macOS system voice**: always-available fallback (clear, less expressive).
@MainActor
final class SpeechService: NSObject, ObservableObject {
    static let shared = SpeechService()

    enum Backend: String, CaseIterable, Identifiable {
        case auto
        case voicebox
        case system

        var id: String { rawValue }

        var label: String {
            switch self {
            case .auto: return "Auto (Voicebox if running)"
            case .voicebox: return "Voicebox (local TTS engines)"
            case .system: return "macOS system voice"
            }
        }
    }

    @Published private(set) var isSpeaking = false
    @Published private(set) var status: String = ""
    @Published private(set) var voiceboxAvailable = false
    @Published private(set) var voiceboxProfiles: [(id: String, name: String)] = []
    @Published var preferredBackend: Backend = {
        let raw = UserDefaults.standard.string(forKey: "speechBackend") ?? Backend.auto.rawValue
        return Backend(rawValue: raw) ?? .auto
    }() {
        didSet { UserDefaults.standard.set(preferredBackend.rawValue, forKey: "speechBackend") }
    }
    @Published var voiceboxBaseURL: String = UserDefaults.standard.string(forKey: "voiceboxURL")
        ?? "http://127.0.0.1:17493"
    {
        didSet { UserDefaults.standard.set(voiceboxBaseURL, forKey: "voiceboxURL") }
    }
    @Published var selectedProfileId: String = UserDefaults.standard.string(forKey: "voiceboxProfileId") ?? "" {
        didSet { UserDefaults.standard.set(selectedProfileId, forKey: "voiceboxProfileId") }
    }

    private var synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var speakTask: Task<Void, Never>?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public

    func refreshVoicebox() async {
        let base = voiceboxBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let healthURL = URL(string: "\(base)/health") else {
            voiceboxAvailable = false
            return
        }
        do {
            var req = URLRequest(url: healthURL)
            req.timeoutInterval = 1.5
            let (_, response) = try await URLSession.shared.data(for: req)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            voiceboxAvailable = ok
            if ok {
                await loadProfiles()
            } else {
                voiceboxProfiles = []
            }
        } catch {
            voiceboxAvailable = false
            voiceboxProfiles = []
        }
    }

    func stop() {
        speakTask?.cancel()
        speakTask = nil
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
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

        isSpeaking = true
        status = "Speaking…"

        speakTask = Task { [weak self] in
            guard let self else { return }
            do {
                let useVoicebox: Bool = {
                    switch preferredBackend {
                    case .voicebox: return true
                    case .system: return false
                    case .auto: return voiceboxAvailable
                    }
                }()

                if useVoicebox {
                    await refreshVoicebox()
                    if voiceboxAvailable {
                        try await speakViaVoicebox(text)
                        return
                    }
                    if preferredBackend == .voicebox {
                        await MainActor.run {
                            self.status = "Voicebox not running — open Voicebox, then try again"
                            self.isSpeaking = false
                        }
                        return
                    }
                }

                await MainActor.run {
                    self.speakViaSystem(text)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    // Fall back to system if Voicebox failed
                    self.status = "Voicebox failed — using system voice"
                    self.speakViaSystem(text)
                }
            }
        }
    }

    // MARK: - Voicebox (local API)

    private func loadProfiles() async {
        let base = voiceboxBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/profiles") else { return }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 3
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }

            // Flexible JSON: array of objects with id + name, or { profiles: [...] }
            let json = try JSONSerialization.jsonObject(with: data)
            var list: [(id: String, name: String)] = []
            let arr: [[String: Any]]
            if let a = json as? [[String: Any]] {
                arr = a
            } else if let o = json as? [String: Any], let a = o["profiles"] as? [[String: Any]] {
                arr = a
            } else {
                arr = []
            }
            for item in arr {
                let id = (item["id"] as? String)
                    ?? (item["profile_id"] as? String)
                    ?? ""
                let name = (item["name"] as? String)
                    ?? (item["title"] as? String)
                    ?? id
                if !id.isEmpty {
                    list.append((id, name.isEmpty ? id : name))
                }
            }
            voiceboxProfiles = list
            if selectedProfileId.isEmpty, let first = list.first {
                selectedProfileId = first.id
            }
        } catch {
            // ignore — generate may still work with defaults
        }
    }

    private func speakViaVoicebox(_ text: String) async throws {
        let base = voiceboxBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // POST /generate returns WAV (see voicebox.sh API) — play in Grist so Stop works.
        guard let genURL = URL(string: "\(base)/generate") else {
            throw URLError(.badURL)
        }
        await MainActor.run { self.status = "Generating with Voicebox…" }

        var body: [String: Any] = [
            "text": text,
            "language": "en",
        ]
        if !selectedProfileId.isEmpty {
            body["profile_id"] = selectedProfileId
        }
        var req = URLRequest(url: genURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        try Task.checkCancellation()

        // Audio bytes (typical for /generate --output style)
        if let type = http.value(forHTTPHeaderField: "Content-Type"),
           type.contains("audio") || type.contains("octet-stream") || type.contains("wav") {
            try playAudioData(data)
            await MainActor.run {
                self.status = "Voicebox"
                self.isSpeaking = true
            }
            return
        }

        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let b64 = obj["audio_base64"] as? String ?? obj["audio"] as? String,
               let decoded = Data(base64Encoded: b64) {
                try playAudioData(decoded)
                await MainActor.run {
                    self.status = "Voicebox"
                    self.isSpeaking = true
                }
                return
            }
            if let path = obj["path"] as? String ?? obj["file"] as? String ?? obj["output_path"] as? String {
                let url = URL(fileURLWithPath: path)
                let fileData = try Data(contentsOf: url)
                try playAudioData(fileData)
                await MainActor.run {
                    self.status = "Voicebox"
                    self.isSpeaking = true
                }
                return
            }
        }

        // Heuristic: non-trivial binary payload is likely audio
        if data.count > 44, data.starts(with: [0x52, 0x49, 0x46, 0x46]) /* RIFF */ || !data.isEmpty {
            try playAudioData(data)
            await MainActor.run {
                self.status = "Voicebox"
                self.isSpeaking = true
            }
            return
        }

        throw URLError(.cannotDecodeContentData)
    }

    private func playAudioData(_ data: Data) throws {
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.prepareToPlay()
        audioPlayer = player
        player.play()
    }

    // MARK: - System voice

    private func speakViaSystem(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.pitchMultiplier = 1.0
        if let voice = AVSpeechSynthesisVoice(language: "en-US")
            ?? AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.hasPrefix("en") }) {
            utterance.voice = voice
        }
        status = "System voice"
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    // MARK: - Text cleanup

    /// Strip markdown-ish markup so TTS doesn't read asterisks.
    static func plainTextForSpeech(_ markdown: String) -> String {
        var s = markdown
        // code fences
        s = replaceRegex(s, pattern: "```[\\s\\S]*?```", with: " ")
        // bold/italic/code/links
        s = replaceRegex(s, pattern: "\\*\\*(.+?)\\*\\*", with: "$1")
        s = replaceRegex(s, pattern: "\\*(.+?)\\*", with: "$1")
        s = replaceRegex(s, pattern: "__(.+?)__", with: "$1")
        s = replaceRegex(s, pattern: "`(.+?)`", with: "$1")
        s = replaceRegex(s, pattern: "\\[(.+?)\\]\\((.+?)\\)", with: "$1")
        // line-anchored cleanup (headings, bullets, rules)
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

extension SpeechService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isSpeaking = false
            self.status = ""
            self.audioPlayer = nil
        }
    }
}
