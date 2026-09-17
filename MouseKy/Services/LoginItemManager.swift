import Foundation
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var errorMessage: String?
    private let defaults: UserDefaults
    private static let hasInitializedPreferenceKey = "hasInitializedLoginItemPreference"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func initialize(registerByDefault: Bool = true) {
        refresh()
        if registerByDefault,
           !defaults.bool(forKey: Self.hasInitializedPreferenceKey),
           SMAppService.mainApp.status == .notRegistered {
            defaults.set(true, forKey: Self.hasInitializedPreferenceKey)
            setEnabled(true)
        }
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(true, forKey: Self.hasInitializedPreferenceKey)
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
