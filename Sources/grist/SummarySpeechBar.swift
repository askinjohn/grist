import SwiftUI
import AppKit
import AVFoundation

struct SummarySpeechBar: View {
    let text: String
    @ObservedObject private var speech = SpeechService.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.purple)
            Text("Listen")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if !speech.status.isEmpty {
                Text(speech.status)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if speech.isSpeaking {
                Button {
                    speech.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            } else {
                Button {
                    speech.speak(text)
                } label: {
                    Label("Read summary", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.small)
                .help("Read with macOS system voice (pick Enhanced voices in Settings → Integrations)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.purple.opacity(0.06))
    }
}
