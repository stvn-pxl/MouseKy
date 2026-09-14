import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var terminationHandler: (() async -> Void)?
    private var terminationStarted = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let terminationHandler else { return .terminateNow }
        guard !terminationStarted else { return .terminateLater }
        terminationStarted = true
        Task { @MainActor in
            await terminationHandler()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct MouseKyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var permissions = PermissionManager()

    var body: some Scene {
        WindowGroup("MouseKy", id: "main") {
            MainWindowView()
                .environmentObject(model)
                .environmentObject(permissions)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear(perform: initialize)
        }
        .defaultSize(width: 920, height: 640)

        Settings {
            AppSettingsView()
                .environmentObject(model)
                .environmentObject(permissions)
        }

        MenuBarExtra("MouseKy", systemImage: "computermouse") {
            MenuBarContentView()
                .environmentObject(model)
                .environmentObject(permissions)
                .onAppear(perform: initialize)
        }
        .menuBarExtraStyle(.window)
    }

    private func initialize() {
        appDelegate.terminationHandler = { [weak model] in
            await model?.shutdown()
        }
        model.initializeOnAppear()
        permissions.refresh()
        if permissions.hasRequiredPermissions {
            _ = model.startEventTap()
        }
    }
}
