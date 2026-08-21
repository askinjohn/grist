import SwiftUI
import AppKit

// MARK: - App Entry Point

@main
struct GristApp: App {
    @StateObject private var recordingStatus = RecordingStatus.shared

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
        }
        // Mic only at launch. Never call CGRequestScreenCaptureAccess — it
        // re-shows the "Open System Settings" sheet every launch when TCC is stale.
        Task {
            await PermissionHelper.ensureMicrophonePermission()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Meeting") {
                    NotificationCenter.default.post(name: .newMeetingRequested, object: CreateKind.meeting.rawValue)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("New Note") {
                    NotificationCenter.default.post(name: .newMeetingRequested, object: CreateKind.note.rawValue)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .frame(width: SettingsView.sheetWidth, height: SettingsView.sheetHeight)
        }

        MenuBarExtra {
            menuBarContent
        } label: {
            // Recording: red record glyph; idle: waveform
            Label {
                Text(recordingStatus.isRecording
                     ? "Grist · REC \(recordingStatus.formattedElapsed)"
                     : "Grist")
            } icon: {
                Image(systemName: recordingStatus.isRecording ? "record.circle.fill" : "waveform")
            }
            .help(recordingStatus.isRecording
                  ? "Recording \(recordingStatus.formattedElapsed) — click to stop or show Grist"
                  : "Grist")
        }
    }

    @ViewBuilder
    private var menuBarContent: some View {
        if recordingStatus.isRecording {
            Text("Recording \(recordingStatus.formattedElapsed)")
                .foregroundStyle(.secondary)
            Button("Stop Recording") {
                NotificationCenter.default.post(name: .stopRecordingRequested, object: nil)
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .showGristWindowRequested, object: nil)
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Show Grist") {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .showGristWindowRequested, object: nil)
            }
            Divider()
        }

        Button("New Meeting") {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .showGristWindowRequested, object: nil)
            NotificationCenter.default.post(name: .newMeetingRequested, object: CreateKind.meeting.rawValue)
        }
        Button("New Note") {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .showGristWindowRequested, object: nil)
            NotificationCenter.default.post(name: .newMeetingRequested, object: CreateKind.note.rawValue)
        }

        Divider()

        Button("Settings...") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Grist") {
            if recordingStatus.isRecording {
                NotificationCenter.default.post(name: .stopRecordingRequested, object: nil)
            }
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

extension Notification.Name {
    static let newMeetingRequested = Notification.Name("newMeetingRequested")
}
