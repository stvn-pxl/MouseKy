import Foundation
import os

struct HIDDebugEvent: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let usagePage: Int
    let usage: Int
    let value: Int

    var displayText: String {
        let action = value == 0 ? "up" : "down"
        return String(format: "%@  page 0x%02X  usage %d  value %d", action, usagePage, usage, value)
    }
}

enum AppAssignmentResult: Equatable {
    case assigned
    case requiresConfirmation(sourceProfileName: String)
    case invalid
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var configuration: AppConfiguration
    @Published var saveError: String?
    @Published var isHIDDebugEnabled = false
    @Published private(set) var hidDebugEvents: [HIDDebugEvent] = []
    @Published private(set) var onboardStatus: G502OnboardMemoryService.Status = .readOnly("Select a supported G502 to inspect its onboard profile.")
    @Published private(set) var onboardSnapshot: G502OnboardProfileSnapshot?
    @Published private(set) var canResetOnboardProfile = false
    @Published private(set) var onboardShortcutCount = 0
    @Published private(set) var foregroundBundleIdentifier: String?
    @Published private(set) var backendStatuses: [String: MouseBackendStatus] = [:]
    @Published private(set) var availableControlsByDeviceID: [String: [MouseControl]] = [:]
    @Published private(set) var recentlyPressedControlIDs = Set<MouseControlID>()

    let scanner = MouseButtonScanner()
    let hidDevices = HIDDeviceManager()
    let recorder = ShortcutRecorder()
    let loginItem = LoginItemManager()
    private let store: ConfigurationStoring
    private let eventTap = EventTapManager()
    private let onboardMemory = G502OnboardMemoryService()
    private let foregroundMonitor: ForegroundApplicationMonitor
    private let shortcutEmitter = ShortcutEmitter.State()
    private var inputCoordinators: [String: MouseInputCoordinator] = [:]
    private var inputSessions: [String: HIDPPDeviceSessionProtocol] = [:]
    private var onboardSnapshotsByDeviceID: [String: G502OnboardProfileSnapshot] = [:]
    private var hasInitialized = false

    init(
        store: ConfigurationStoring = ConfigurationStore(),
        foregroundMonitor: ForegroundApplicationMonitor? = nil
    ) {
        self.store = store
        self.foregroundMonitor = foregroundMonitor ?? ForegroundApplicationMonitor()
        configuration = store.load()
        hidDevices.activeMouseID = configuration.managedDeviceID
        eventTap.recorder = recorder
        recorder.onShortcutRecorded = { [weak self] shortcut in self?.applyRecorded(shortcut) }
        hidDevices.buttonUsageHandler = { [weak self] button in self?.observe(button: button) }
        hidDevices.debugInputEventHandler = { [weak self] page, usage, value in
            self?.recordHIDDebugEvent(usagePage: page, usage: usage, value: value)
        }
        hidDevices.devicesChangedHandler = { [weak self] in
            guard self?.hasInitialized == true else { return }
            self?.synchronizeInputs()
        }
    }

    var selectedProfile: MouseProfile? {
        selectedDevice?.selectedProfile
    }

    var selectedDevice: MouseDeviceConfiguration? {
        guard let id = configuration.selectedDeviceID else { return nil }
        return configuration.devices.first { $0.id == id }
    }

    var managedDevice: MouseDeviceConfiguration? {
        guard let id = configuration.managedDeviceID else { return nil }
        return configuration.devices.first { $0.id == id }
    }

    var effectiveProfile: MouseProfile? {
        selectedDevice.map {
            EffectiveProfileResolver.resolve(
                device: $0,
                foregroundBundleIdentifier: foregroundBundleIdentifier
            )
        }
    }

    var backendStatus: MouseBackendStatus {
        guard let selectedDeviceID = configuration.selectedDeviceID else { return .idle }
        return backendStatuses[selectedDeviceID] ?? .idle
    }

    var availableControls: [MouseControl] {
        guard let selectedDeviceID = configuration.selectedDeviceID else { return [] }
        return availableControlsByDeviceID[selectedDeviceID] ?? []
    }

    var shouldShowButtonScan: Bool {
        Self.shouldShowButtonScan(status: backendStatus, controls: availableControls)
    }

    static func shouldShowButtonScan(
        status: MouseBackendStatus,
        controls: [MouseControl]
    ) -> Bool {
        guard case .active = status else { return true }
        return controls.isEmpty
    }

    func effectiveProfile(for device: MouseDeviceConfiguration) -> MouseProfile {
        EffectiveProfileResolver.resolve(
            device: device,
            foregroundBundleIdentifier: foregroundBundleIdentifier
        )
    }

    var onboardStatusText: String {
        switch onboardStatus {
        case .notLogitech: "Not a Logitech Device"
        case .unsupportedDevice: "This Logitech Device Is Not Supported"
        case .probing: "Reading Onboard Memory…"
        case let .readOnly(message): message
        case .resetting: "Updating Onboard Profile…"
        case .verified: "Onboard Profile Verified by Read-Back"
        case let .failed(message): "Error: \(message)"
        }
    }

    var recordingButton: Int?
    var recordingControlID: MouseControlID?

    func startEventTap() -> Bool { eventTap.start() }
    func refreshMice() {
        hidDevices.refresh()
        synchronizeInputs()
    }

    func initializeOnAppear() {
        guard !hasInitialized else { return }
        hasInitialized = true
        foregroundMonitor.start { [weak self] bundleIdentifier in
            self?.handleForegroundApplicationChange(bundleIdentifier)
        }
        loginItem.initialize()
        hidDevices.refresh()
        if selectedMouse == nil,
           let mouse = hidDevices.mice.first(where: {
               $0.identifier.vendorID == G502OnboardMemoryService.logitechVendorID &&
                   $0.identifier.productID == G502OnboardMemoryService.g502C08DProductID
           }) ?? hidDevices.mice.first {
            addProfile(for: mouse)
            return
        }
        synchronizeInputs()
    }

    func visibleMappings(for profile: MouseProfile) -> [MouseMapping] {
        let fallbackButtonNumbers: [Int]
        if selectedDevice?.identifier.vendorID == G502OnboardMemoryService.logitechVendorID,
           selectedDevice?.identifier.productID == G502OnboardMemoryService.g502C08DProductID {
            let count = onboardSnapshot.map { Int($0.descriptor.buttonCount) } ?? 11
            fallbackButtonNumbers = Array(0 ..< count)
        } else {
            fallbackButtonNumbers = selectedDevice.flatMap {
                hidDevices.declaredButtonNumbersByMouseID[$0.id]
            } ?? profile.mappings.map(\.buttonNumber)
        }
        return Self.visibleMappings(
            for: profile,
            controls: availableControls,
            fallbackButtonNumbers: fallbackButtonNumbers
        )
    }

    static func visibleMappings(
        for profile: MouseProfile,
        controls: [MouseControl],
        fallbackButtonNumbers: [Int]
    ) -> [MouseMapping] {
        if !controls.isEmpty {
            return controls.map { control in
                profile.mappings.first(where: { $0.controlID == control.id }) ??
                    MouseMapping(controlID: control.id)
            }
        }
        return fallbackButtonNumbers.map { number in
            profile.mappings.first(where: { $0.buttonNumber == number }) ??
                MouseMapping(buttonNumber: number, shortcut: nil)
        }
    }

    func displayedShortcut(for button: Int) -> KeyboardShortcut? {
        return selectedProfile?.mappings.first(where: { $0.buttonNumber == button })?.shortcut
    }

    func displayedAction(for controlID: MouseControlID) -> MouseButtonAction {
        selectedProfile?.mappings.first(where: { $0.controlID == controlID })?.action ??
            .passthrough
    }

    func control(for mapping: MouseMapping) -> MouseControl? {
        availableControls.first { $0.id == mapping.controlID }
    }

    func wasRecentlyPressed(_ controlID: MouseControlID) -> Bool {
        recentlyPressedControlIDs.contains(controlID)
    }

    func displayName(for mapping: MouseMapping) -> String {
        if let control = control(for: mapping) {
            return control.name
        }
        guard selectedMouse?.identifier.vendorID == G502OnboardMemoryService.logitechVendorID,
              selectedMouse?.identifier.productID == G502OnboardMemoryService.g502C08DProductID
        else { return mapping.displayName }

        return Self.g502ButtonNames[mapping.buttonNumber] ?? mapping.displayName
    }

    func reloadOnboardProfile() {
        guard let mouse = selectedMouse, let session = inputSessions[mouse.id] else { return }
        onboardStatus = .probing
        Task {
            do {
                let snapshot = try await onboardMemory.probe(
                    mouse: mouse, session: session
                )
                updateOnboardState(snapshot, for: mouse.id)
                canResetOnboardProfile = onboardMemory.isWritable(snapshot)
                onboardStatus = .verified
            } catch {
                onboardSnapshot = nil
                canResetOnboardProfile = false
                onboardShortcutCount = 0
                onboardStatus = .failed(error.localizedDescription)
            }
        }
    }

    func clearOnboardShortcuts() {
        guard let mouse = selectedMouse, let session = inputSessions[mouse.id],
              let snapshot = onboardSnapshotsByDeviceID[mouse.id]
        else { return }
        onboardStatus = .resetting
        Task {
            do {
                let updated = try await onboardMemory.clearShortcutAssignments(
                    mouse: mouse, session: session, snapshot: snapshot
                )
                updateOnboardState(updated, for: mouse.id)
                if let index = configuration.devices.firstIndex(where: { $0.id == mouse.id }) {
                    configuration.devices[index].onboardImport?.conflictingControls = []
                    save()
                    inputCoordinators[mouse.id]?.updateBlockedControls(
                        [], profile: effectiveProfile(for: configuration.devices[index])
                    )
                }
                onboardStatus = .verified
            } catch {
                onboardStatus = .failed(error.localizedDescription)
            }
        }
    }

    func isBlockedByOnboardAssignment(_ controlID: MouseControlID) -> Bool {
        selectedDevice?.onboardImport?.conflictingControls.contains(controlID) == true
    }

    func addProfile(for mouse: ConnectedMouse) {
        selectDevice(mouse)
    }

    func selectDevice(_ mouse: ConnectedMouse) {
        if !configuration.devices.contains(where: { $0.id == mouse.id }) {
            configuration.devices.append(
                MouseDeviceConfiguration(identifier: mouse.identifier, name: mouse.name)
            )
        }
        configuration.selectedDeviceID = mouse.id
        recentlyPressedControlIDs.removeAll()
        onboardStatus = onboardMemory.status(for: mouse)
        onboardSnapshot = onboardSnapshotsByDeviceID[mouse.id]
        onboardShortcutCount = onboardSnapshot.map {
            onboardMemory.importedBindings(from: $0).count
        } ?? 0
        canResetOnboardProfile = onboardSnapshot.map(onboardMemory.isWritable) ?? false
        save()
        synchronizeInputs()
    }

    func selectProfile(_ id: UUID) {
        guard let deviceIndex = selectedDeviceIndex,
              configuration.devices[deviceIndex].profiles.contains(where: { $0.id == id })
        else { return }
        configuration.devices[deviceIndex].selectedProfileID = id
        recordingButton = nil
        recorder.cancel()
        save()
    }

    func useSelectedDeviceForInput() {
        guard let deviceID = configuration.selectedDeviceID else { return }
        // Kept as a compatibility preference for older configurations. Runtime
        // remapping always runs for every configured, connected Logitech mouse.
        configuration.managedDeviceID = deviceID
        hidDevices.activeMouseID = deviceID
        save()
        synchronizeInputs()
    }

    func setSelectedProfileAsDefault() {
        guard let deviceIndex = selectedDeviceIndex,
              let profileIndex = configuration.devices[deviceIndex].profiles.firstIndex(where: {
                  $0.id == configuration.devices[deviceIndex].selectedProfileID
              })
        else { return }
        for index in configuration.devices[deviceIndex].profiles.indices {
            configuration.devices[deviceIndex].profiles[index].isDefault = index == profileIndex
        }
        save()
    }

    @discardableResult
    func assignApplication(
        bundleIdentifier: String,
        to profileID: UUID? = nil,
        confirmMove: Bool = false
    ) -> AppAssignmentResult {
        guard let bundleID = MouseProfile.normalizeBundleIdentifier(bundleIdentifier),
              let deviceIndex = selectedDeviceIndex,
              let targetIndex = configuration.devices[deviceIndex].profiles.firstIndex(where: {
                  $0.id == (profileID ?? configuration.devices[deviceIndex].selectedProfileID)
              })
        else { return .invalid }

        let sourceIndex = configuration.devices[deviceIndex].profiles.firstIndex {
            $0.appBundleIdentifiers.contains(bundleID)
        }
        if let sourceIndex, sourceIndex != targetIndex, !confirmMove {
            return .requiresConfirmation(
                sourceProfileName: configuration.devices[deviceIndex].profiles[sourceIndex].name
            )
        }
        if let sourceIndex {
            configuration.devices[deviceIndex].profiles[sourceIndex]
                .appBundleIdentifiers.removeAll { $0 == bundleID }
        }
        configuration.devices[deviceIndex].profiles[targetIndex]
            .appBundleIdentifiers.append(bundleID)
        configuration.devices[deviceIndex].normalize()
        save()
        return .assigned
    }

    func removeApplication(bundleIdentifier: String, from profileID: UUID? = nil) {
        guard let bundleID = MouseProfile.normalizeBundleIdentifier(bundleIdentifier),
              let deviceIndex = selectedDeviceIndex,
              let profileIndex = configuration.devices[deviceIndex].profiles.firstIndex(where: {
                  $0.id == (profileID ?? configuration.devices[deviceIndex].selectedProfileID)
              })
        else { return }
        configuration.devices[deviceIndex].profiles[profileIndex]
            .appBundleIdentifiers.removeAll { $0 == bundleID }
        save()
    }

    @discardableResult
    func createProfile(name: String, copyingActiveProfile: Bool) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let deviceIndex = selectedDeviceIndex else { return false }
        let source = copyingActiveProfile ? configuration.devices[deviceIndex].selectedProfile : nil
        let profile = MouseProfile(
            name: name,
            mappings: source?.mappings ?? []
        )
        configuration.devices[deviceIndex].profiles.append(profile)
        configuration.devices[deviceIndex].selectedProfileID = profile.id
        save()
        return true
    }

    @discardableResult
    func renameActiveProfile(to name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let deviceIndex = selectedDeviceIndex,
              let profileIndex = configuration.devices[deviceIndex].profiles.firstIndex(where: {
                  $0.id == configuration.devices[deviceIndex].selectedProfileID
              })
        else { return false }
        configuration.devices[deviceIndex].profiles[profileIndex].name = name
        save()
        return true
    }

    func deleteActiveProfile() {
        guard let deviceIndex = selectedDeviceIndex,
              let profileIndex = configuration.devices[deviceIndex].profiles.firstIndex(where: {
                  $0.id == configuration.devices[deviceIndex].selectedProfileID
              }),
              !configuration.devices[deviceIndex].profiles[profileIndex].isDefault
        else { return }
        let defaultID = configuration.devices[deviceIndex].defaultProfile.id
        configuration.devices[deviceIndex].profiles.remove(at: profileIndex)
        configuration.devices[deviceIndex].selectedProfileID = defaultID
        recordingButton = nil
        recorder.cancel()
        save()
    }

    func startScan() {
        scanner.start()
        guard let activeID = configuration.selectedDeviceID,
              let mouse = hidDevices.mice.first(where: { $0.id == activeID })
        else { return }
        let declaredButtons = hidDevices.declaredButtonNumbers(for: mouse)
        guard !declaredButtons.isEmpty else { return }
        for button in declaredButtons {
            scanner.observe(buttonNumber: button)
        }
        updateProfile { profile in
            for button in declaredButtons {
                _ = profile.mapping(for: button)
            }
        }
    }

    func stopScan() {
        scanner.stop()
        save()
    }

    func startRecording(button: Int) {
        guard button != 0, button != 1 else { return }
        recordingButton = button
        recorder.start()
    }

    func startRecording(controlID: MouseControlID) {
        guard availableControls.first(where: { $0.id == controlID })?.isPrimary != true else {
            return
        }
        recordingControlID = controlID
        recordingButton = controlID.legacyButtonNumber
        recorder.start()
    }

    func clearShortcut(button: Int) {
        updateProfile { $0.setShortcut(nil, for: button) }
    }

    func setAction(_ action: MouseButtonAction, for controlID: MouseControlID) {
        updateProfile { $0.setAction(action, for: controlID) }
    }

    func clearHIDDebugEvents() {
        hidDebugEvents = []
    }

    func handleForegroundApplicationChange(_ bundleIdentifier: String?) {
        foregroundBundleIdentifier = bundleIdentifier
        for device in configuration.devices {
            inputCoordinators[device.id]?.update(profile: effectiveProfile(for: device))
        }
    }

    func shutdown() async {
        for coordinator in inputCoordinators.values {
            await coordinator.stop()
        }
    }

    private func applyRecorded(_ shortcut: KeyboardShortcut) {
        if let controlID = recordingControlID {
            recordingControlID = nil
            recordingButton = nil
            setAction(.shortcut(shortcut), for: controlID)
            return
        }
        guard let button = recordingButton else { return }
        recordingButton = nil
        updateProfile { $0.setShortcut(shortcut, for: button) }
    }

    private func observe(button: Int) {
        scanner.observe(buttonNumber: button)
        guard scanner.isScanning else { return }
        updateProfile { _ = $0.mapping(for: button) }
    }

    private func recordHIDDebugEvent(usagePage: Int, usage: Int, value: Int) {
        guard isHIDDebugEnabled else { return }
        let event = HIDDebugEvent(usagePage: usagePage, usage: usage, value: value)
        hidDebugEvents.insert(event, at: 0)
        hidDebugEvents = Array(hidDebugEvents.prefix(30))
        Logger(subsystem: "com.local.MouseKy", category: "HID")
            .notice("HID button event: page=\(usagePage, privacy: .public) usage=\(usage, privacy: .public) value=\(value, privacy: .public)")
    }

    private var selectedMouse: ConnectedMouse? {
        guard let id = configuration.selectedDeviceID else { return nil }
        return hidDevices.mice.first { $0.id == id }
    }

    private var managedMouse: ConnectedMouse? {
        guard let id = configuration.managedDeviceID else { return nil }
        return hidDevices.mice.first { $0.id == id }
    }

    private func updateProfile(_ update: (inout MouseProfile) -> Void) {
        guard let deviceIndex = selectedDeviceIndex,
              let profileIndex = configuration.devices[deviceIndex].profiles.firstIndex(where: {
                  $0.id == configuration.devices[deviceIndex].selectedProfileID
              })
        else { return }
        update(&configuration.devices[deviceIndex].profiles[profileIndex])
        save()
        let device = configuration.devices[deviceIndex]
        if device.profiles[profileIndex].id == effectiveProfile(for: device).id {
            inputCoordinators[device.id]?.update(profile: effectiveProfile(for: device))
        }
    }

    private var selectedDeviceIndex: Int? {
        guard let id = configuration.selectedDeviceID else { return nil }
        return configuration.devices.firstIndex { $0.id == id }
    }

    private func save() {
        do {
            try store.save(configuration)
            saveError = nil
        } catch {
            saveError = "Configuration could not be saved: \(error.localizedDescription)"
        }
    }

    private func synchronizeInputs() {
        registerConnectedMice()
        let connectedByID = Dictionary(uniqueKeysWithValues: hidDevices.mice.map { ($0.id, $0) })
        let configuredIDs = Set(configuration.devices.map(\.id))
        for (deviceID, coordinator) in inputCoordinators where connectedByID[deviceID] == nil ||
            !configuredIDs.contains(deviceID) {
            Task { await coordinator.stop() }
            inputCoordinators.removeValue(forKey: deviceID)
            inputSessions.removeValue(forKey: deviceID)
            onboardSnapshotsByDeviceID.removeValue(forKey: deviceID)
            backendStatuses.removeValue(forKey: deviceID)
            availableControlsByDeviceID.removeValue(forKey: deviceID)
        }
        for device in configuration.devices {
            guard let mouse = connectedByID[device.id] else { continue }
            let coordinator = coordinator(for: device.id)
            Task {
                await coordinator.start(
                    mouse: mouse,
                    profile: effectiveProfile(for: device)
                )
            }
        }
    }

    private func registerConnectedMice() {
        var changed = false
        for mouse in hidDevices.mice where !configuration.devices.contains(where: { $0.id == mouse.id }) {
            configuration.devices.append(
                MouseDeviceConfiguration(identifier: mouse.identifier, name: mouse.name)
            )
            changed = true
        }
        if configuration.selectedDeviceID == nil, let firstMouse = hidDevices.mice.first {
            configuration.selectedDeviceID = firstMouse.id
            changed = true
        }
        if changed {
            save()
        }
    }

    private func coordinator(for deviceID: String) -> MouseInputCoordinator {
        if let coordinator = inputCoordinators[deviceID] { return coordinator }
        let coordinator = MouseInputCoordinator(emitter: shortcutEmitter)
        coordinator.onStatusChanged = { [weak self] status in
            guard let self else { return }
            self.backendStatuses[deviceID] = status
            if self.configuration.selectedDeviceID == deviceID,
               !self.shouldShowButtonScan {
                self.scanner.stop()
            }
        }
        coordinator.onControlsChanged = { [weak self] controls in
            self?.availableControlsByDeviceID[deviceID] = controls
        }
        coordinator.onControlEvent = { [weak self] event in
            self?.updatePressedControl(event, for: deviceID)
        }
        coordinator.prepareSession = { [weak self] session in
            guard let self,
                  let mouse = self.hidDevices.mice.first(where: { $0.id == deviceID })
            else {
                return .init(profile: nil, blockedControls: [])
            }
            self.inputSessions[deviceID] = session
            return await self.prepareOnboard(mouse: mouse, session: session)
        }
        inputCoordinators[deviceID] = coordinator
        return coordinator
    }

    private func updatePressedControl(_ event: MouseControlEvent, for deviceID: String) {
        guard configuration.selectedDeviceID == deviceID else { return }
        switch event.phase {
        case .down:
            recentlyPressedControlIDs.insert(event.controlID)
        case .up:
            recentlyPressedControlIDs.remove(event.controlID)
        }
    }

    private func prepareOnboard(
        mouse: ConnectedMouse,
        session: HIDPPDeviceSessionProtocol
    ) async -> MouseInputCoordinator.SessionPreparation {
        guard mouse.identifier.productID == G502OnboardMemoryService.g502C08DProductID else {
            let profile = configuration.devices.first(where: { $0.id == mouse.id })
                .map { effectiveProfile(for: $0) }
            return .init(profile: profile, blockedControls: [])
        }
        do {
            let snapshot = try await onboardMemory.probe(mouse: mouse, session: session)
            updateOnboardState(snapshot, for: mouse.id)
            let bindings = onboardMemory.importedBindings(from: snapshot)
            let conflicts = Set(bindings.map(\.controlID))
            if let index = configuration.devices.firstIndex(where: { $0.id == mouse.id }) {
                let mappings = bindings.compactMap { binding -> MouseMapping? in
                    guard case let .keyboard(shortcut) = binding.kind else { return nil }
                    return MouseMapping(controlID: binding.controlID, action: .shortcut(shortcut))
                }
                configuration.devices[index].registerOnboardImport(
                    fingerprint: snapshot.deviceFingerprint,
                    profileSector: snapshot.activeProfileSector,
                    mappings: mappings,
                    conflictingControls: conflicts,
                    allowsImport: onboardMemory.isWritable(snapshot)
                )
                save()
                let profile = effectiveProfile(for: configuration.devices[index])
                return .init(profile: profile, blockedControls: conflicts)
            }
        } catch {
            if configuration.selectedDeviceID == mouse.id {
                onboardStatus = .failed(error.localizedDescription)
            }
        }
        let profile = configuration.devices.first(where: { $0.id == mouse.id })
            .map { effectiveProfile(for: $0) }
        return .init(profile: profile, blockedControls: [])
    }

    private func updateOnboardState(
        _ snapshot: G502OnboardProfileSnapshot,
        for deviceID: String
    ) {
        onboardSnapshotsByDeviceID[deviceID] = snapshot
        guard configuration.selectedDeviceID == deviceID else { return }
        onboardSnapshot = snapshot
        onboardShortcutCount = onboardMemory.importedBindings(from: snapshot).count
        canResetOnboardProfile = onboardMemory.isWritable(snapshot)
        onboardStatus = .verified
    }

    private static let g502ButtonNames: [Int: String] = [
        0: "Left Click",
        1: "Right Click",
        2: "Middle Click",
        3: "Back",
        4: "Forward",
        5: "DPI Shift / Sniper",
        6: "DPI Down",
        7: "DPI Up",
        8: "Battery Status",
        9: "Wheel Tilt Right",
        10: "Wheel Tilt Left"
    ]
}
