import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var permissions: PermissionManager

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
                        Button("Open \(permission.title) Settings") {
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
        }
        .formStyle(.grouped)
        .buttonStyle(.bordered)
        .frame(width: 460, height: 320)
        .onAppear {
            permissions.refresh()
            model.loginItem.refresh()
        }
    }
}
