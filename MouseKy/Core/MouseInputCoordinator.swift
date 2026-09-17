import Foundation

@MainActor
final class MouseInputCoordinator {
    typealias SessionFactory = (ConnectedMouse) async throws -> HIDPPDeviceSessionProtocol
    struct SessionPreparation {
        let profile: MouseProfile?
        let blockedControls: Set<MouseControlID>
    }

    private(set) var status: MouseBackendStatus = .idle {
        didSet { onStatusChanged?(status) }
    }
    private(set) var controls: [MouseControl] = [] {
        didSet { onControlsChanged?(controls) }
    }
    var onStatusChanged: ((MouseBackendStatus) -> Void)?
    var onControlsChanged: (([MouseControl]) -> Void)?
    var onControlEvent: ((MouseControlEvent) -> Void)?
    var prepareSession: ((HIDPPDeviceSessionProtocol) async -> SessionPreparation)?

    private let sessionFactory: SessionFactory
    private let emitter: ShortcutEmitter.State
    private var backend: LogitechInputBackend?
    private var actions: [MouseControlID: MouseButtonAction] = [:]
    private var pendingActions: [MouseControlID: MouseButtonAction]?
    private var pressedControls = Set<MouseControlID>()
    private var pressedShortcuts: [MouseControlID: KeyboardShortcut] = [:]
    private var generation = 0
    private var blockedControls = Set<MouseControlID>()

    init(
        sessionFactory: @escaping SessionFactory = { mouse in
            try await HIDPPDeviceSession.connect(mouse: mouse)
        },
        emitter: ShortcutEmitter.State
    ) {
        self.sessionFactory = sessionFactory
        self.emitter = emitter
    }

    func start(
        mouse: ConnectedMouse,
        profile: MouseProfile?
    ) async {
        generation += 1
        let currentGeneration = generation
        await stopCurrent()
        guard mouse.identifier.vendorID == HIDPPDeviceSession.logitechVendorID else {
            status = .unsupported("MouseKy currently supports Logitech HID++ only.")
            return
        }
        status = .probing
        actions = Self.actions(from: profile)
        do {
            let session = try await sessionFactory(mouse)
            guard generation == currentGeneration else { return }
            if let preparation = await prepareSession?(session) {
                guard generation == currentGeneration else { return }
                actions = Self.actions(from: preparation.profile)
                blockedControls = preparation.blockedControls
                for controlID in blockedControls {
                    actions[controlID] = .passthrough
                }
            } else {
                blockedControls = []
            }
            let selectedBackend: LogitechInputBackend
            if let feature = try await session.feature(0x8110) {
                selectedBackend = MouseButtonSpy8110Backend(
                    session: session,
                    feature: feature,
                    productID: mouse.identifier.productID
                )
            } else if let feature = try await session.feature(0x1B04) {
                selectedBackend = ReprogrammableControls1B04Backend(
                    session: session, feature: feature
                )
            } else {
                status = .unsupported("No HID++ 0x8110 or 0x1B04 feature was found.")
                return
            }
            selectedBackend.onEvent = { [weak self] event in self?.handle(event) }
            backend = selectedBackend
            try await selectedBackend.start(actions: actions)
            guard generation == currentGeneration else {
                await selectedBackend.stop()
                if backend === selectedBackend { backend = nil }
                return
            }
            controls = selectedBackend.controls
            status = .active(selectedBackend.kind)
        } catch {
            guard generation == currentGeneration else { return }
            status = .failed(error.localizedDescription)
            await backend?.stop()
            backend = nil
            controls = []
        }
    }

    func update(profile: MouseProfile?) {
        var updated = Self.actions(from: profile)
        for controlID in blockedControls {
            updated[controlID] = .passthrough
        }
        guard pressedControls.isEmpty else {
            pendingActions = updated
            return
        }
        apply(updated)
    }

    func updateBlockedControls(_ controls: Set<MouseControlID>, profile: MouseProfile?) {
        blockedControls = controls
        update(profile: profile)
    }

    func stop() async {
        generation += 1
        await stopCurrent()
    }

    private func stopCurrent() async {
        await backend?.stop()
        backend = nil
        for shortcut in pressedShortcuts.values {
            emitter.release(shortcut)
        }
        pressedShortcuts.removeAll()
        pressedControls.removeAll()
        pendingActions = nil
        controls = []
        status = .idle
    }

    private func handle(_ event: MouseControlEvent) {
        switch event.phase {
        case .down:
            guard pressedControls.insert(event.controlID).inserted else { return }
            onControlEvent?(event)
            if case let .shortcut(shortcut) = actions[event.controlID, default: .passthrough] {
                pressedShortcuts[event.controlID] = shortcut
                emitter.press(shortcut)
            }
        case .up:
            guard pressedControls.remove(event.controlID) != nil else { return }
            onControlEvent?(event)
            if let shortcut = pressedShortcuts.removeValue(forKey: event.controlID) {
                emitter.release(shortcut)
            }
            if pressedControls.isEmpty, let pendingActions {
                self.pendingActions = nil
                apply(pendingActions)
            }
        }
    }

    private func apply(_ updated: [MouseControlID: MouseButtonAction]) {
        actions = updated
        guard let backend else { return }
        Task { @MainActor [weak self, weak backend] in
            do {
                try await backend?.update(actions: updated)
            } catch {
                self?.status = .failed(error.localizedDescription)
            }
        }
    }

    private static func actions(from profile: MouseProfile?) -> [MouseControlID: MouseButtonAction] {
        Dictionary(uniqueKeysWithValues: (profile?.mappings ?? []).map {
            ($0.controlID, $0.action)
        })
    }
}
