import Foundation

struct HIDDeviceIdentifier: Codable, Hashable, Identifiable {
    let vendorID: Int
    let productID: Int
    let serialNumber: String?

    var id: String { "\(vendorID):\(productID):\(serialNumber ?? "")" }
}

struct ConnectedMouse: Identifiable, Hashable {
    let identifier: HIDDeviceIdentifier
    let name: String
    let manufacturer: String?
    let isConnected: Bool

    var id: String { identifier.id }
}

struct MouseProfile: Codable, Identifiable, Equatable {
    let identifier: HIDDeviceIdentifier
    var name: String
    var mappings: [MouseMapping]

    var id: String { identifier.id }

    mutating func mapping(for buttonNumber: Int) -> MouseMapping {
        if let existing = mappings.first(where: { $0.buttonNumber == buttonNumber }) {
            return existing
        }
        let mapping = MouseMapping(buttonNumber: buttonNumber, shortcut: nil)
        mappings.append(mapping)
        mappings.sort { $0.buttonNumber < $1.buttonNumber }
        return mapping
    }

    mutating func setShortcut(_ shortcut: KeyboardShortcut?, for buttonNumber: Int) {
        guard buttonNumber != 0, buttonNumber != 1 else { return }
        _ = mapping(for: buttonNumber)
        guard let index = mappings.firstIndex(where: { $0.buttonNumber == buttonNumber }) else { return }
        mappings[index].shortcut = shortcut
    }
}

struct AppConfiguration: Codable {
    var profiles: [MouseProfile] = []
    var activeProfileID: String?
}
