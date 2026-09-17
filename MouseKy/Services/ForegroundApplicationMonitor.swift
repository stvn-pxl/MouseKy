import AppKit

@MainActor
final class ForegroundApplicationMonitor {
    typealias BundleIdentifierHandler = (String?) -> Void

    private let workspace: NSWorkspace
    private var observer: NSObjectProtocol?
    private var handler: BundleIdentifierHandler?

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    deinit {
        if let observer {
            workspace.notificationCenter.removeObserver(observer)
        }
    }

    func start(handler: @escaping BundleIdentifierHandler) {
        self.handler = handler
        if observer == nil {
            observer = workspace.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let application = notification.userInfo?[
                    NSWorkspace.applicationUserInfoKey
                ] as? NSRunningApplication
                Task { @MainActor [weak self] in
                    self?.handler?(application?.bundleIdentifier)
                }
            }
        }
        handler(workspace.frontmostApplication?.bundleIdentifier)
    }

    func stop() {
        if let observer {
            workspace.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        handler = nil
    }
}
