import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var updates: UpdateManager

    var body: some View {
        Form {
            Section("Startup") {
                Toggle(
                    "Open MouseKy at Login",
                    isOn: Binding(
                        get: { model.loginItem.isEnabled },
                        set: { model.loginItem.setEnabled($0) }
                    )
                )
                if let error = model.loginItem.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            Section("Input Permissions") {
                Label(
                    "Accessibility: \(permissions.accessibilityGranted ? "Granted" : "Missing")",
                    systemImage: permissions.accessibilityGranted ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                Label(
                    "Input Monitoring: \(permissions.inputMonitoringGranted ? "Granted" : "Missing")",
                    systemImage: permissions.inputMonitoringGranted ? "checkmark.circle.fill" : "xmark.circle.fill"
                )

                if !permissions.hasRequiredPermissions {
                    ForEach(permissions.missingPermissions) { permission in
                        Button("Request \(permission.title) Permission") {
                            permissions.request(permission)
                            permissions.openSettings(for: permission)
                        }
                    }
                }

                Button("Check Again") {
                    permissions.refresh()
                    if permissions.hasRequiredPermissions {
                        _ = model.startEventTap()
                    }
                }
            }
            Section("Updates") {
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.automaticallyChecksForUpdates = $0 }
                    )
                )
                Button("Check for Updates…") {
                    updates.checkForUpdates()
                }
                .disabled(!updates.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
        .buttonStyle(.bordered)
        .frame(width: 460, height: 410)
        .onAppear {
            permissions.refresh()
            model.loginItem.refresh()
        }
    }
}
