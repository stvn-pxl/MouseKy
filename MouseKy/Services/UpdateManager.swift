import Combine
import Sparkle

@MainActor
protocol UpdateDriving: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }

    func checkForUpdates()
    func observeCanCheckForUpdates(_ handler: @escaping (Bool) -> Void)
}

@MainActor
final class UpdateManager: ObservableObject {
    @Published private(set) var canCheckForUpdates: Bool

    private let driver: UpdateDriving

    var automaticallyChecksForUpdates: Bool {
        get { driver.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            driver.automaticallyChecksForUpdates = newValue
        }
    }

    convenience init() {
        #if DEBUG
        let startsUpdater = false
        #else
        let startsUpdater = true
        #endif
        self.init(driver: SparkleUpdateDriver(startingUpdater: startsUpdater))
    }

    init(driver: UpdateDriving) {
        self.driver = driver
        canCheckForUpdates = driver.canCheckForUpdates
        driver.observeCanCheckForUpdates { [weak self] canCheck in
            self?.canCheckForUpdates = canCheck
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        driver.checkForUpdates()
    }
}

@MainActor
private final class SparkleUpdateDriver: UpdateDriving {
    private let controller: SPUStandardUpdaterController
    private var canCheckObservation: NSKeyValueObservation?

    init(startingUpdater: Bool) {
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func observeCanCheckForUpdates(_ handler: @escaping (Bool) -> Void) {
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { _, change in
            guard let canCheck = change.newValue else { return }
            Task { @MainActor in handler(canCheck) }
        }
    }
}
