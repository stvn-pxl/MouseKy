import Carbon.HIToolbox
import SwiftUI

@MainActor
final class AppPresentationController: ObservableObject {
    static let shared = AppPresentationController()

    @Published private(set) var openRequest = 0

    private init() {}

    func requestMainWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        openRequest &+= 1
    }

    func mainWindowClosed() {
        let requestAtClose = openRequest
        DispatchQueue.main.async {
            guard self.openRequest == requestAtClose else { return }
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var terminationHandler: (() async -> Void)?
    private var terminationStarted = false
    private var handledInitialOpenEvent = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        let eventManager = NSAppleEventManager.shared()
        eventManager.setEventHandler(
            self,
            andSelector: #selector(handleOpenApplicationEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenApplication)
        )

        if let event = eventManager.currentAppleEvent,
           event.eventID == AEEventID(kAEOpenApplication) {
            handleOpenApplicationEvent(event, withReplyEvent: nil)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        AppPresentationController.shared.requestMainWindow()
        return true
    }

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

    @objc
    private func handleOpenApplicationEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor?
    ) {
        guard !handledInitialOpenEvent else { return }
        handledInitialOpenEvent = true

        let launchedAtLogin =
            event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue ==
            OSType(keyAELaunchedAsLogInItem)
        if !launchedAtLogin {
            AppPresentationController.shared.requestMainWindow()
        }
    }
}

@main
struct MouseKyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var permissions = PermissionManager()
    @StateObject private var presentation = AppPresentationController.shared

    var body: some Scene {
        Window("MouseKy", id: "main") {
            MainWindowView()
                .environmentObject(model)
                .environmentObject(permissions)
                .environmentObject(presentation)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear(perform: initialize)
                .onDisappear(perform: presentation.mainWindowClosed)
        }
        .defaultSize(width: 920, height: 640)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            AppSettingsView()
                .environmentObject(model)
                .environmentObject(permissions)
        }

        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(model)
                .environmentObject(permissions)
                .environmentObject(presentation)
                .onAppear(perform: initialize)
        } label: {
            MenuBarLabel(initialize: initialize)
                .environmentObject(presentation)
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

private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var presentation: AppPresentationController
    @State private var handledOpenRequest = 0

    let initialize: () -> Void

    var body: some View {
        Image(systemName: "computermouse")
            .onAppear {
                initialize()
                handleOpenRequest()
            }
            .onChange(of: presentation.openRequest) {
                handleOpenRequest()
            }
    }

    private func handleOpenRequest() {
        guard presentation.openRequest > handledOpenRequest else { return }
        handledOpenRequest = presentation.openRequest
        openWindow(id: "main")
    }
}
