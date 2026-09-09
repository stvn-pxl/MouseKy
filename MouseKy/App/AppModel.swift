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

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var configuration: AppConfiguration
    @Published var saveError: String?
    @Published var isHIDDebugEnabled = false
    @Published private(set) var hidDebugEvents: [HIDDebugEvent] = []
    @Published private(set) var onboardStatus: G502OnboardMemoryService.Status = .readOnly("Select a supported G502 to inspect its onboard profile.")
    @Published private(set) var onboardSnapshot: G502OnboardProfileSnapshot?
    @Published private(set) var onboardBackupURL: URL?
    @Published private(set) var canResetOnboardProfile = false

    let scanner = MouseButtonScanner()
    let hidDevices = HIDDeviceManager()
    let recorder = ShortcutRecorder()
    private let store = ConfigurationStore()
    private let eventTap = EventTapManager()
    private let onboardMemory = G502OnboardMemoryService()
    private var onboardProbeStarted = false

    init() {
        configuration = store.load()
        hidDevices.activeMouseID = configuration.activeProfileID
        eventTap.buttonHandler = { [weak self] button in self?.observe(button: button) }
        eventTap.shortcutProvider = { [weak self] button in self?.shortcut(for: button) }
        eventTap.recorder = recorder
        recorder.onShortcutRecorded = { [weak self] shortcut in self?.applyRecorded(shortcut) }
        hidDevices.buttonUsageHandler = { [weak self] button in self?.observe(button: button) }
        hidDevices.debugInputEventHandler = { [weak self] page, usage, value in
            self?.recordHIDDebugEvent(usagePage: page, usage: usage, value: value)
        }
    }

    var activeProfile: MouseProfile? {
        guard let id = configuration.activeProfileID else { return nil }
        return configuration.profiles.first { $0.id == id }
    }

    var recordingButton: Int?

    func startEventTap() -> Bool { eventTap.start() }
    func refreshMice() {
        hidDevices.refresh()
        initializeOnboardProfileIfNeeded(force: true)
    }

    func initializeOnAppear() {
        hidDevices.refresh()
        if activeMouse == nil,
           let mouse = hidDevices.mice.first(where: {
               $0.identifier.vendorID == G502OnboardMemoryService.logitechVendorID &&
                   $0.identifier.productID == G502OnboardMemoryService.g502C08DProductID
           }) ?? hidDevices.mice.first {
            addProfile(for: mouse)
            return
        }
        initializeOnboardProfileIfNeeded()
    }

    func visibleMappings(for profile: MouseProfile) -> [MouseMapping] {
        let buttonNumbers: [Int]
        if profile.identifier.vendorID == G502OnboardMemoryService.logitechVendorID,
           profile.identifier.productID == G502OnboardMemoryService.g502C08DProductID {
            let count = onboardSnapshot.map { Int($0.descriptor.buttonCount) } ?? 11
            buttonNumbers = Array(0 ..< count)
        } else {
            buttonNumbers = hidDevices.declaredButtonNumbersByMouseID[profile.id] ?? profile.mappings.map(\.buttonNumber)
        }
        return buttonNumbers.map { number in
            profile.mappings.first(where: { $0.buttonNumber == number }) ??
                MouseMapping(buttonNumber: number, shortcut: nil)
        }
    }

    func displayedShortcut(for button: Int) -> KeyboardShortcut? {
        if let assignment = primaryOnboardAssignment(for: button) {
            return G502OnboardMemoryService.keyboardShortcut(from: assignment)
        }
        return activeProfile?.mappings.first(where: { $0.buttonNumber == button })?.shortcut
    }

    func displayName(for mapping: MouseMapping) -> String {
        guard activeMouse?.identifier.vendorID == G502OnboardMemoryService.logitechVendorID,
              activeMouse?.identifier.productID == G502OnboardMemoryService.g502C08DProductID
        else { return mapping.displayName }

        return Self.g502ButtonNames[mapping.buttonNumber] ?? mapping.displayName
    }

    func reloadOnboardProfile() {
        guard let mouse = activeMouse else { return }
        onboardProbeStarted = true
        onboardStatus = .probing
        Task {
            do {
                let snapshot = try await onboardMemory.probeAndBackup(mouse: mouse)
                onboardSnapshot = snapshot
                onboardBackupURL = onboardMemory.latestBackupURL
                canResetOnboardProfile = onboardMemory.canResetLatestSnapshot
                onboardStatus = .backupReady(onboardMemory.latestBackupURL?.path ?? "")
            } catch {
                onboardSnapshot = nil
                onboardBackupURL = nil
                canResetOnboardProfile = false
                onboardStatus = .failed(error.localizedDescription)
            }
        }
    }

    func addProfile(for mouse: ConnectedMouse) {
        if configuration.profiles.contains(where: { $0.id == mouse.id }) {
            configuration.activeProfileID = mouse.id
        } else {
            configuration.profiles.append(MouseProfile(identifier: mouse.identifier, name: mouse.name, mappings: []))
            configuration.activeProfileID = mouse.id
        }
        hidDevices.activeMouseID = mouse.id
        onboardStatus = onboardMemory.status(for: mouse)
        onboardSnapshot = nil
        onboardBackupURL = nil
        canResetOnboardProfile = false
        onboardProbeStarted = false
        save()
        initializeOnboardProfileIfNeeded()
    }

    func selectProfile(_ id: String) {
        configuration.activeProfileID = id
        hidDevices.activeMouseID = id
        if let mouse = hidDevices.mice.first(where: { $0.id == id }) {
            onboardStatus = onboardMemory.status(for: mouse)
        }
        onboardSnapshot = nil
        onboardBackupURL = nil
        canResetOnboardProfile = false
        save()
    }

    func startScan() {
        scanner.start()
        guard let activeID = configuration.activeProfileID,
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

    func clearShortcut(button: Int) {
        guard let mouse = activeMouse else { return }
        if primaryOnboardAssignment(for: button) != nil {
            onboardStatus = .resetting
            Task {
                do {
                    let snapshot = try await onboardMemory.setButtonAssignment(
                        mouse: mouse, index: button, bank: .primary, mouseButton: button
                    )
                    onboardSnapshot = snapshot
                    onboardBackupURL = onboardMemory.latestBackupURL
                    canResetOnboardProfile = onboardMemory.canResetLatestSnapshot
                    onboardStatus = .verified
                } catch {
                    onboardBackupURL = onboardMemory.latestBackupURL
                    onboardStatus = .failed(error.localizedDescription)
                }
            }
        } else {
            updateProfile { $0.setShortcut(nil, for: button) }
        }
    }

    func clearHIDDebugEvents() {
        hidDebugEvents = []
    }

    private func applyRecorded(_ shortcut: KeyboardShortcut) {
        guard let button = recordingButton else { return }
        recordingButton = nil
        guard let mouse = activeMouse else { return }
        if primaryOnboardAssignment(for: button) != nil {
            onboardStatus = .resetting
            Task {
                do {
                    let snapshot = try await onboardMemory.setButtonShortcut(
                        mouse: mouse, index: button, shortcut: shortcut
                    )
                    onboardSnapshot = snapshot
                    onboardBackupURL = onboardMemory.latestBackupURL
                    canResetOnboardProfile = onboardMemory.canResetLatestSnapshot
                    onboardStatus = .verified
                } catch {
                    onboardBackupURL = onboardMemory.latestBackupURL
                    onboardStatus = .failed(error.localizedDescription)
                }
            }
        } else {
            updateProfile { $0.setShortcut(shortcut, for: button) }
        }
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

    private func shortcut(for button: Int) -> KeyboardShortcut? {
        if activeMouse?.identifier.vendorID == G502OnboardMemoryService.logitechVendorID,
           activeMouse?.identifier.productID == G502OnboardMemoryService.g502C08DProductID {
            // The G502 firmware emits its onboard shortcut itself. Returning a
            // local mapping here would post it a second time through CGEventTap.
            return nil
        }
        return activeProfile?.mappings.first(where: { $0.buttonNumber == button })?.shortcut
    }

    private func primaryOnboardAssignment(
        for button: Int
    ) -> G502OnboardProfileSnapshot.ButtonAssignment? {
        onboardSnapshot?.buttonAssignments.first {
            $0.bank == .primary && $0.index == button
        }
    }

    private func initializeOnboardProfileIfNeeded(force: Bool = false) {
        guard let mouse = activeMouse,
              mouse.identifier.vendorID == G502OnboardMemoryService.logitechVendorID,
              mouse.identifier.productID == G502OnboardMemoryService.g502C08DProductID,
              force || !onboardProbeStarted
        else { return }
        reloadOnboardProfile()
    }

    private var activeMouse: ConnectedMouse? {
        guard let id = configuration.activeProfileID else { return nil }
        return hidDevices.mice.first { $0.id == id }
    }

    private func updateProfile(_ update: (inout MouseProfile) -> Void) {
        guard let id = configuration.activeProfileID,
              let index = configuration.profiles.firstIndex(where: { $0.id == id })
        else { return }
        update(&configuration.profiles[index])
        save()
    }

    private func save() {
        do {
            try store.save(configuration)
            saveError = nil
        } catch {
            saveError = "Configuration could not be saved: \(error.localizedDescription)"
        }
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
