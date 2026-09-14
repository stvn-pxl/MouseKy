import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var permissions: PermissionManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MouseKy")
                    .font(.headline)
                Spacer()
                Image(systemName: permissions.hasRequiredPermissions
                      ? "checkmark.shield.fill"
                      : "exclamationmark.shield.fill")
                    .foregroundStyle(permissions.hasRequiredPermissions ? .green : .orange)
            }

            if let device = model.managedDevice {
                LabeledContent("Verwaltetes Gerät", value: device.name)
                LabeledContent(
                    "Vordergrund-App",
                    value: model.foregroundBundleIdentifier ?? "macOS / unbekannt"
                )
                LabeledContent("Wirksames Profil", value: model.effectiveProfile?.name ?? "Default")
                LabeledContent("Backend", value: model.backendStatus.displayText)
            } else {
                Text("Kein verwaltetes Gerät")
                    .foregroundStyle(.secondary)
            }

            Divider()
            Button("Open MouseKy") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Scan Mice") {
                model.refreshMice()
            }

            Divider()
            Button("Quit MouseKy") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 280)
        .task { permissions.refresh() }
    }
}
