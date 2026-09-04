import SwiftUI
import AppKit

// MARK: - App Entry Point

@main
struct GristApp: App {
    // Shared singleton — use ObservedObject so Published updates refresh the menu bar label.
    @ObservedObject private var recordingStatus = RecordingStatus.shared

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
        DispatchQueue.main.async {
            MeetingPromptController.shared.configure()
            MeetingDetector.shared.start()
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
            Label {
                Text(menuBarTitle)
            } icon: {
                Image(systemName: menuBarSymbol)
            }
            .help(menuBarHelp)
        }
    }

    private var menuBarTitle: String {
        if recordingStatus.isRecording {
            return "Grist · REC \(recordingStatus.formattedElapsed)"
        }
        if recordingStatus.hasDetectedMeeting {
            return "Grist · \(recordingStatus.detectedMeetingApp)"
        }
        return "Grist"
    }

    private var menuBarSymbol: String {
        if recordingStatus.isRecording {
            return "record.circle.fill"
        }
        if recordingStatus.hasDetectedMeeting {
            return "bell.badge.fill"
        }
        return "waveform"
    }

    private var menuBarHelp: String {
        if recordingStatus.isRecording {
            return "Recording \(recordingStatus.formattedElapsed) — click to stop or show Grist"
        }
        if recordingStatus.hasDetectedMeeting {
            return "\(recordingStatus.detectedMeetingApp) detected — record in Grist?"
        }
        return "Grist"
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
        } else if recordingStatus.hasDetectedMeeting {
            Text("\(recordingStatus.detectedMeetingApp) looks active")
                .foregroundStyle(.secondary)
            if !recordingStatus.detectedMeetingDetail.isEmpty {
                Text(recordingStatus.detectedMeetingDetail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Button("Record in Grist") {
                NotificationCenter.default.post(
                    name: .recordDetectedMeetingRequested,
                    object: recordingStatus.detectedMeetingApp
                )
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Not now") {
                MeetingDetector.shared.dismissCurrentPrompt()
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
            MeetingDetector.shared.stop()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

extension Notification.Name {
    static let newMeetingRequested = Notification.Name("newMeetingRequested")
}
