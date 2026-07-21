import SwiftUI
import AppKit

// MARK: - App Entry Point

@main
struct GristApp: App {
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
                    NotificationCenter.default.post(name: .newMeetingRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        
        Settings {
            SettingsView()
        }
        
        MenuBarExtra("Grist", systemImage: "waveform") {
            Button("New Meeting") {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .newMeetingRequested, object: nil)
            }
            .keyboardShortcut("n")
            
            Divider()
            
            Button("Settings...") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .keyboardShortcut(",")
            
            Divider()
            
            Button("Quit Grist") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

extension Notification.Name {
    static let newMeetingRequested = Notification.Name("newMeetingRequested")
}
