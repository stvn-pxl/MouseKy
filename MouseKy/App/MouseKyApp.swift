import SwiftUI

@main
struct MouseKyApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var permissions = PermissionManager()

    var body: some Scene {
        MenuBarExtra("MouseKy", systemImage: "computermouse") {
            MenuBarContentView()
                .environmentObject(model)
                .environmentObject(permissions)
                .onAppear {
                    model.initializeOnAppear()
                    permissions.refresh()
                    if permissions.hasRequiredPermissions {
                        _ = model.startEventTap()
                    }
                }
        }
        .menuBarExtraStyle(.window)
    }
}
