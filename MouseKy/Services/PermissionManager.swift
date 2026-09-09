import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var inputMonitoringGranted = false

    var hasRequiredPermissions: Bool {
        accessibilityGranted && inputMonitoringGranted
    }

    /// Checks current TCC state only. It never displays a system prompt.
    func refresh() {
        accessibilityGranted = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
        ] as CFDictionary)
        inputMonitoringGranted = CGPreflightListenEventAccess()
    }

    /// Must only be called after an explicit user action.
    func requestPermissions() {
        _ = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary)
        _ = CGRequestListenEventAccess()
        refresh()
    }

    func openSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ]
        for url in urls.compactMap(URL.init(string:)) {
            NSWorkspace.shared.open(url)
        }
    }
}
