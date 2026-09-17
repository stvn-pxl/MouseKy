import Foundation
import IOKit.hid
import os

@MainActor
final class HIDDeviceManager: ObservableObject {
    @Published private(set) var mice: [ConnectedMouse] = []
    @Published private(set) var declaredButtonNumbersByMouseID: [String: [Int]] = [:]
    /// Limits debug and raw-button events to the profile currently selected in the UI.
    var activeMouseID: String?
    /// Receives raw HID Button-page presses that CGEventTap may never expose.
    var buttonUsageHandler: ((Int) -> Void)?
    /// Receives all non-axis raw input reports for the selected device.
    var debugInputEventHandler: ((Int, Int, Int) -> Void)?
    var devicesChangedHandler: (() -> Void)?
    private static let logger = Logger(subsystem: "com.local.MouseKy", category: "HID")
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var knownDevices: [ObjectIdentifier: ConnectedMouse] = [:]
    private var deviceReferences: [String: IOHIDDevice] = [:]

    init() {
        // Logitech receivers expose some remapped buttons as separate keyboard,
        // consumer-control, or vendor HID interfaces. Observe all interfaces and
        // restrict their events to the user-selected mouse below.
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceAdded, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemoved, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterInputValueCallback(manager, Self.inputValueChanged, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        refresh()
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func refresh() {
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        knownDevices = [:]
        deviceReferences = [:]
        for device in devices {
            guard let mouse = makeMouse(from: device) else { continue }
            knownDevices[ObjectIdentifier(device)] = mouse
            deviceReferences[mouse.id] = device
        }
        publish()
        for mouse in mice {
            _ = declaredButtonNumbers(for: mouse)
        }
    }

    /// Returns every Button-page usage that the selected device declares, whether or
    /// not macOS later turns it into a CGEvent. HID usages are one-based; MouseKy uses
    /// CGEvent-compatible zero-based button numbers.
    func declaredButtonNumbers(for mouse: ConnectedMouse) -> [Int] {
        guard let device = deviceReferences[mouse.id],
              let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone))
        else { return [] }
        let buttons = Set((elements as NSArray).compactMap { value -> Int? in
            // IOHIDDeviceCopyMatchingElements returns an array of IOHIDElement objects.
            let element = value as! IOHIDElement
            guard IOHIDElementGetUsagePage(element) == kHIDPage_Button
            else { return nil }
            let usage = Int(IOHIDElementGetUsage(element))
            return usage > 0 ? usage - 1 : nil
        }).sorted()
        declaredButtonNumbersByMouseID[mouse.id] = buttons
        return buttons
    }

    private func publish() {
        let uniqueMice = Dictionary(
            knownDevices.values.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        mice = uniqueMice.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        devicesChangedHandler?()
    }

    private func makeMouse(from device: IOHIDDevice) -> ConnectedMouse? {
        func property<T>(_ key: CFString) -> T? {
            IOHIDDeviceGetProperty(device, key) as? T
        }
        guard let vendor: NSNumber = property(kIOHIDVendorIDKey as CFString),
              let product: NSNumber = property(kIOHIDProductIDKey as CFString),
              let usagePage: NSNumber = property(kIOHIDPrimaryUsagePageKey as CFString),
              let usage: NSNumber = property(kIOHIDPrimaryUsageKey as CFString),
              usagePage.intValue == kHIDPage_GenericDesktop,
              usage.intValue == kHIDUsage_GD_Mouse,
              !declaresKeyboardKeys(device)
        else { return nil }
        let name: String = property(kIOHIDProductKey as CFString) ?? "Unknown Mouse"
        let manufacturer: String? = property(kIOHIDManufacturerKey as CFString)
        let serial: String? = property(kIOHIDSerialNumberKey as CFString)
        let locationNumber: NSNumber? = property(kIOHIDLocationIDKey as CFString)
        let location = locationNumber?.intValue
        let transport: String = property(kIOHIDTransportKey as CFString) ?? "Unknown"
        return ConnectedMouse(
            identifier: HIDDeviceIdentifier(
                vendorID: vendor.intValue,
                productID: product.intValue,
                serialNumber: serial,
                locationID: location
            ),
            name: name, manufacturer: manufacturer, isConnected: true,
            connection: transport
        )
    }

    /// Some keyboards and macro pads expose a secondary Mouse collection for
    /// mouse-key emulation. It is not a separately configurable pointing device,
    /// so exclude a Mouse collection that also declares normal keyboard keys.
    private func declaresKeyboardKeys(_ device: IOHIDDevice) -> Bool {
        guard let elements = IOHIDDeviceCopyMatchingElements(
            device, nil, IOOptionBits(kIOHIDOptionsTypeNone)
        ) else {
            return false
        }
        return (elements as NSArray).contains { value in
            let element = value as! IOHIDElement
            return IOHIDElementGetUsagePage(element) == 0x07
        }
    }

    private static let deviceAdded: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let owner = Unmanaged<HIDDeviceManager>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in owner.add(device) }
    }

    private static let deviceRemoved: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let owner = Unmanaged<HIDDeviceManager>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in owner.remove(device) }
    }

    private static let inputValueChanged: IOHIDValueCallback = { context, _, _, value in
        guard let context else { return }
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        guard let sourceID = HIDDeviceManager.identifier(for: device)?.id else { return }
        let usagePage = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let integerValue = Int(IOHIDValueGetIntegerValue(value))
        guard !HIDDeviceManager.isPointerAxis(usagePage: usagePage, usage: usage) else { return }

        let owner = Unmanaged<HIDDeviceManager>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in
            guard owner.activeMouseID == sourceID else { return }
            owner.debugInputEventHandler?(usagePage, usage, integerValue)
            guard usagePage == kHIDPage_Button, integerValue != 0 else { return }
            // HID button usages begin at 1; CGEvent's buttonNumber begins at 0.
            let buttonNumber = usage - 1
            guard buttonNumber >= 0 else { return }
            owner.buttonUsageHandler?(buttonNumber)
        }
    }

    private static func identifier(for device: IOHIDDevice) -> HIDDeviceIdentifier? {
        func property<T>(_ key: CFString) -> T? {
            IOHIDDeviceGetProperty(device, key) as? T
        }
        guard let vendor: NSNumber = property(kIOHIDVendorIDKey as CFString),
              let product: NSNumber = property(kIOHIDProductIDKey as CFString)
        else { return nil }
        let serial: String? = property(kIOHIDSerialNumberKey as CFString)
        let locationNumber: NSNumber? = property(kIOHIDLocationIDKey as CFString)
        let location = locationNumber?.intValue
        return HIDDeviceIdentifier(
            vendorID: vendor.intValue,
            productID: product.intValue,
            serialNumber: serial,
            locationID: location
        )
    }

    private static func isPointerAxis(usagePage: Int, usage: Int) -> Bool {
        usagePage == kHIDPage_GenericDesktop && [0x30, 0x31, 0x32, 0x38].contains(usage)
    }

    private func add(_ device: IOHIDDevice) {
        if let mouse = makeMouse(from: device) {
            knownDevices[ObjectIdentifier(device)] = mouse
            deviceReferences[mouse.id] = device
            publish()
            _ = declaredButtonNumbers(for: mouse)
        }
    }

    private func remove(_ device: IOHIDDevice) {
        if let mouse = knownDevices.removeValue(forKey: ObjectIdentifier(device)) {
            deviceReferences.removeValue(forKey: mouse.id)
            declaredButtonNumbersByMouseID.removeValue(forKey: mouse.id)
        }
        publish()
    }
}
