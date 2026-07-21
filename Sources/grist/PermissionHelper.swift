import AVFoundation
import AppKit
import CoreGraphics
import Foundation

/// Permission helpers.
///
/// IMPORTANT: We never call `CGRequestScreenCaptureAccess()`.
/// On modern macOS that API always shows an "Open System Settings" sheet and
/// does NOT grant access from the dialog. When Settings already lists Grist as
/// ON but the process still lacks access (stale TCC after re-sign), calling it
/// only re-spams the sheet every launch.
///
/// System audio is obtained by attempting ScreenCaptureKit; if that fails we
/// fall back to mic-only and show an in-app status message.
enum PermissionHelper {
    /// Mic only — never triggers the Screen Recording system sheet.
    static func ensureMicrophonePermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            print("[Permissions] Microphone: already authorized")
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            print("[Permissions] Microphone: \(granted ? "granted" : "denied")")
        case .denied, .restricted:
            print("[Permissions] Microphone: denied — System Settings → Privacy → Microphone")
        @unknown default:
            break
        }
    }

    /// Open the Screen Recording privacy pane (no system permission sheet).
    static func openScreenRecordingSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
        ]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) {
                return
            }
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    static var hasMicrophoneAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Best-effort check only. Do NOT use as a hard gate for capture —
    /// Settings can show ON while this is still false.
    static var hasScreenRecordingAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }
}
