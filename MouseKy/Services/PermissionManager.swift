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

    var missingPermissions: [Permission] {
        [
            accessibilityGranted ? nil : .accessibility,
            inputMonitoringGranted ? nil : .inputMonitoring
        ]
        .compactMap { $0 }
    }

    /// Checks current TCC state only. It never displays a system prompt.
    func refresh() {
        accessibilityGranted = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
        ] as CFDictionary)
        // CGPreflightListenEventAccess can retain a stale `false` result after
        // an app rebuild or TCC change. Creating a listen-only tap verifies the
        // effective permission without intercepting or modifying any input.
        inputMonitoringGranted = CGPreflightListenEventAccess() || canListenForEvents()
    }

    /// Must only be called after an explicit user action.
    func requestPermissions() {
        for permission in Permission.allCases {
            request(permission)
        }
    }

    /// Registers the app with TCC and requests one permission after a user action.
    func request(_ permission: Permission) {
        switch permission {
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions([
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        }
        refresh()
    }

    func openSettings() {
        guard let permission = missingPermissions.first else { return }
        openSettings(for: permission)
    }

    func openSettings(for permission: Permission) {
        guard let url = URL(string: permission.settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func canListenForEvents() -> Bool {
        let eventMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: Self.listenOnlyCallback,
            userInfo: nil
        ) != nil
    }

    private static let listenOnlyCallback: CGEventTapCallBack = { _, _, event, _ in
        Unmanaged.passUnretained(event)
    }
}

extension PermissionManager {
    enum Permission: CaseIterable, Identifiable {
        case accessibility
        case inputMonitoring

        var id: Self { self }

        var title: String {
            switch self {
            case .accessibility: "Accessibility"
            case .inputMonitoring: "Input Monitoring"
            }
        }

        var description: String {
            switch self {
            case .accessibility:
                "Allows MouseKy to trigger keyboard shortcuts."
            case .inputMonitoring:
                "Allows MouseKy to detect mouse button presses."
            }
        }

        var settingsURL: String {
            switch self {
            case .accessibility:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .inputMonitoring:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            }
        }
    }
}
