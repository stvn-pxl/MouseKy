import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var presentation: AppPresentationController

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

            VStack(alignment: .leading, spacing: 4) {
                Text("Device")
                    .font(.headline)
                Text(model.managedDevice?.name ?? "No Device Selected")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Active Profile")
                    .font(.headline)
                Text(model.effectiveProfile?.name ?? "Default")
                    .foregroundStyle(.secondary)
            }

            Divider()
            Button("Open MouseKy") {
                presentation.requestMainWindow()
            }
            .keyboardShortcut(",", modifiers: .command)

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
