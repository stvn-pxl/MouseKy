import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var errorMessage: String?

    func initialize(registerByDefault: Bool = true) {
        refresh()
        if registerByDefault, SMAppService.mainApp.status == .notRegistered {
            setEnabled(true)
        }
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = "The login item could not be changed: \(error.localizedDescription)"
        }
        refresh()
    }
}
