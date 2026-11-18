import AppKit
import ServiceManagement

@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var message = ""

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
        if needsApproval {
            message = "Allow Quern in System Settings → General → Login Items."
        } else {
            message = ""
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
            if !enabled { message = "" }
        } catch {
            refresh()
            message = error.localizedDescription
        }
    }

    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
