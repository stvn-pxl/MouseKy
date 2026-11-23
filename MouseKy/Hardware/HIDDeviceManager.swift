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
    private static let logger = Logger(subsystem: "io.github.stvn-pxl.MouseKy", category: "HID")
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var knownDevices: [ObjectIdentifier: ConnectedMouse] = [:]
    private var deviceReferences: [String: IOHIDDevice] = [:]
    /// Every attached HID interface. Classification needs the sibling interfaces of a
    /// device, so mice are always derived from this complete set.
    private var attachedDevices: Set<IOHIDDevice> = []

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
        attachedDevices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        rebuildMice()
    }

    private func rebuildMice() {
        let devices = Array(attachedDevices)
        let interfaces = devices.map(Self.interfaceInfo(for:))
        let isMouse = HIDDeviceClassifier.mouseFlags(for: interfaces)
        knownDevices = [:]
        deviceReferences = [:]
        // Several interfaces of one mouse can qualify and share its id. Visit the
        // pointing interface first so button discovery always reads the same one.
        for index in HIDDeviceClassifier.preferenceOrder(of: interfaces) where isMouse[index] {
            let device = devices[index]
            guard let mouse = makeMouse(from: device) else { continue }
            knownDevices[ObjectIdentifier(device)] = mouse
            if deviceReferences[mouse.id] == nil {
                deviceReferences[mouse.id] = device
            }
        }
        declaredButtonNumbersByMouseID = declaredButtonNumbersByMouseID.filter { deviceReferences[$0.key] != nil }
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
              let product: NSNumber = property(kIOHIDProductIDKey as CFString)
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

    private static func interfaceInfo(for device: IOHIDDevice) -> HIDInterfaceInfo {
        func integer(_ key: String) -> Int? {
            (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
        }
        let pairs = (IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] ?? [])
            .compactMap { pair -> HIDUsage? in
                guard let page = (pair[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue,
                      let usage = (pair[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue
                else { return nil }
                return HIDUsage(page: page, usage: usage)
            }
        return HIDInterfaceInfo(
            vendorID: integer(kIOHIDVendorIDKey) ?? 0,
            productID: integer(kIOHIDProductIDKey) ?? 0,
            locationID: integer(kIOHIDLocationIDKey),
            interfaceNumber: usbInterfaceNumber(for: device),
            primaryUsage: HIDUsage(
                page: integer(kIOHIDPrimaryUsagePageKey) ?? 0,
                usage: integer(kIOHIDPrimaryUsageKey) ?? 0
            ),
            usagePairs: pairs,
            declaresKeyboardKeys: declaresKeyboardKeys(device)
        )
    }

    private static func declaresKeyboardKeys(_ device: IOHIDDevice) -> Bool {
        guard let elements = IOHIDDeviceCopyMatchingElements(
            device, nil, IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement] else { return false }
        return elements.contains { IOHIDElementGetUsagePage($0) == kHIDPage_KeyboardOrKeypad }
    }

    /// USB HID devices sit below their IOUSBHostInterface, which carries the interface
    /// number. Bluetooth and built-in devices have none.
    private static func usbInterfaceNumber(for device: IOHIDDevice) -> Int? {
        var entry = IOHIDDeviceGetService(device)
        guard entry != IO_OBJECT_NULL else { return nil }
        IOObjectRetain(entry)
        defer { IOObjectRelease(entry) }
        for _ in 0..<3 {
            if let number = IORegistryEntryCreateCFProperty(
                entry, "bInterfaceNumber" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? NSNumber {
                return number.intValue
            }
            var parent: io_registry_entry_t = IO_OBJECT_NULL
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS
            else { return nil }
            IOObjectRelease(entry)
            entry = parent
        }
        return nil
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
        attachedDevices.insert(device)
        rebuildMice()
    }

    private func remove(_ device: IOHIDDevice) {
        attachedDevices.remove(device)
        rebuildMice()
    }
}

struct HIDUsage: Hashable {
    let page: Int
    let usage: Int

    static let mouse = HIDUsage(page: 0x01, usage: 0x02)
    static let keyboard = HIDUsage(page: 0x01, usage: 0x06)
    static let keypad = HIDUsage(page: 0x01, usage: 0x07)
}

/// The IORegistry facts MouseKy needs to tell mice and keyboards apart.
struct HIDInterfaceInfo: Equatable {
    var vendorID: Int
    var productID: Int
    var locationID: Int?
    /// USB interface number; nil for Bluetooth and built-in devices.
    var interfaceNumber: Int?
    var primaryUsage: HIDUsage
    var usagePairs: [HIDUsage]
    /// Whether the interface itself reports keyboard keys (usage page 0x07).
    var declaresKeyboardKeys = false

    var usages: Set<HIDUsage> { Set(usagePairs).union([primaryUsage]) }
}

/// Decides which HID interfaces are configurable mice.
///
/// Many keyboards (for example QMK keyboards with mouse keys) expose an extra
/// interface with a Mouse collection, and many mice (for example Logitech's
/// Bluetooth mice) carry Keyboard collections so buttons can send keystrokes.
/// Neither the presence of a Mouse nor of a Keyboard collection decides it, so a
/// physical device is classified by its lead interface: the lowest USB interface
/// number. Keyboards put their keyboard first. Without interface numbers
/// (Bluetooth, or when the registry lookup fails) any keyboard in the device, or
/// keyboard keys on the interface itself, rule it out. Logitech receivers also put a keyboard first, so Logitech
/// devices with a HID++ interface are always treated as mouse-capable.
enum HIDDeviceClassifier {
    static let logitechVendorID = 0x046D
    static let hidppUsagePages: Set<Int> = [0xFF00, 0xFF43]

    static func mouseFlags(for interfaces: [HIDInterfaceInfo]) -> [Bool] {
        struct FamilyKey: Hashable {
            let vendorID: Int
            let productID: Int
            let locationID: Int
        }
        var families: [FamilyKey: [HIDInterfaceInfo]] = [:]
        for interface in interfaces {
            guard let key = interface.locationID.map({
                FamilyKey(vendorID: interface.vendorID, productID: interface.productID, locationID: $0)
            }) else { continue }
            families[key, default: []].append(interface)
        }
        return interfaces.map { interface in
            let family = interface.locationID.flatMap {
                families[FamilyKey(vendorID: interface.vendorID, productID: interface.productID, locationID: $0)]
            } ?? [interface]
            return isMouse(interface, family: family)
        }
    }

    static func isMouse(_ interface: HIDInterfaceInfo, family: [HIDInterfaceInfo]) -> Bool {
        guard interface.usages.contains(.mouse) else { return false }
        if isLogitechHIDPP(family) { return true }
        if let lead = lead(of: family) { return !isKeyboard(lead) }
        return !family.contains(where: isKeyboard) && !interface.declaresKeyboardKeys
    }

    /// Interface indices ordered so the main pointing interface of a device comes
    /// first: primary usage Mouse, then the lowest USB interface number, then
    /// interfaces without keyboard keys. Ties keep a stable vendor/product order.
    static func preferenceOrder(of interfaces: [HIDInterfaceInfo]) -> [Int] {
        interfaces.indices.sorted { lhs, rhs in
            let a = interfaces[lhs], b = interfaces[rhs]
            let aPrimary = a.primaryUsage == .mouse, bPrimary = b.primaryUsage == .mouse
            if aPrimary != bPrimary { return aPrimary }
            let aNumber = a.interfaceNumber ?? Int.max, bNumber = b.interfaceNumber ?? Int.max
            if aNumber != bNumber { return aNumber < bNumber }
            if a.declaresKeyboardKeys != b.declaresKeyboardKeys { return !a.declaresKeyboardKeys }
            return (a.vendorID, a.productID, a.locationID ?? 0, a.usagePairs.count, lhs)
                < (b.vendorID, b.productID, b.locationID ?? 0, b.usagePairs.count, rhs)
        }
    }

    private static func lead(of family: [HIDInterfaceInfo]) -> HIDInterfaceInfo? {
        family
            .filter { $0.interfaceNumber != nil }
            .min { $0.interfaceNumber! < $1.interfaceNumber! }
    }

    private static func isKeyboard(_ interface: HIDInterfaceInfo) -> Bool {
        interface.primaryUsage == .keyboard || interface.primaryUsage == .keypad
    }

    private static func isLogitechHIDPP(_ family: [HIDInterfaceInfo]) -> Bool {
        family.contains { interface in
            interface.vendorID == logitechVendorID &&
                interface.usages.contains { hidppUsagePages.contains($0.page) }
        }
    }
}
