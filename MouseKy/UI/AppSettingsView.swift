import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var permissions: PermissionManager

    var body: some View {
        Form {
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
                    Button("Request Permissions") {
                        permissions.requestPermissions()
                    }
                    Button("Open Privacy & Security") {
                        permissions.openSettings()
                    }
                }

                Button("Check Again") {
                    permissions.refresh()
                    if permissions.hasRequiredPermissions {
                        _ = model.startEventTap()
                    }
                }
            }
            Section("Systemstart") {
                Toggle(
                    "MouseKy bei der Anmeldung öffnen",
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
            Section("Logitech HID++") {
                LabeledContent("Runtime-Backend", value: model.backendStatus.displayText)
                Text("G HUB oder Options+ muss beendet sein, wenn es das gleiche HID++-Interface exklusiv verwendet.")
                    .foregroundStyle(.secondary)
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
