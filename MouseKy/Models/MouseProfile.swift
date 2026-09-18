import Foundation

struct HIDDeviceIdentifier: Codable, Hashable, Identifiable {
    let vendorID: Int
    let productID: Int
    let serialNumber: String?
    let locationID: Int?

    init(vendorID: Int, productID: Int, serialNumber: String?, locationID: Int? = nil) {
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.locationID = locationID
    }

    var id: String {
        let instance = serialNumber.flatMap { $0.isEmpty ? nil : $0 } ?? ""
        return "\(vendorID):\(productID):\(instance)"
    }
}

struct ConnectedMouse: Identifiable, Hashable {
    let identifier: HIDDeviceIdentifier
    let name: String
    let manufacturer: String?
    let isConnected: Bool
    let connection: String

    var id: String { identifier.id }

    init(
        identifier: HIDDeviceIdentifier,
        name: String,
        manufacturer: String?,
        isConnected: Bool,
        connection: String = "Unknown"
    ) {
        self.identifier = identifier
        self.name = name
        self.manufacturer = manufacturer
        self.isConnected = isConnected
        self.connection = connection
    }
}

struct MouseProfile: Codable, Identifiable, Equatable {
    static let defaultName = "Default"

    let id: UUID
    var name: String
    var isDefault: Bool
    var mappings: [MouseMapping]
    var appBundleIdentifiers: [String]

    private enum CodingKeys: String, CodingKey {
        case id, name, isDefault, mappings, appBundleIdentifiers
    }

    init(
        id: UUID = UUID(),
        name: String,
        isDefault: Bool = false,
        mappings: [MouseMapping] = [],
        appBundleIdentifiers: [String] = []
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.mappings = mappings
        self.appBundleIdentifiers = Self.normalizedBundleIdentifiers(appBundleIdentifiers)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        mappings = try container.decodeIfPresent([MouseMapping].self, forKey: .mappings) ?? []
        appBundleIdentifiers = Self.normalizedBundleIdentifiers(
            try container.decodeIfPresent([String].self, forKey: .appBundleIdentifiers) ?? []
        )
    }

    static func normalizeBundleIdentifier(_ identifier: String) -> String? {
        let normalized = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedBundleIdentifiers(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers.compactMap(normalizeBundleIdentifier).filter { seen.insert($0).inserted }
    }

    static func defaultProfile(mappings: [MouseMapping] = []) -> MouseProfile {
        MouseProfile(name: defaultName, isDefault: true, mappings: mappings)
    }

    mutating func mapping(for buttonNumber: Int) -> MouseMapping {
        if let existing = mappings.first(where: { $0.buttonNumber == buttonNumber }) {
            return existing
        }
        let mapping = MouseMapping(buttonNumber: buttonNumber, shortcut: nil)
        mappings.append(mapping)
        mappings.sort { $0.buttonNumber < $1.buttonNumber }
        return mapping
    }

    mutating func mapping(for controlID: MouseControlID) -> MouseMapping {
        if let existing = mappings.first(where: { $0.controlID == controlID }) {
            return existing
        }
        let mapping = MouseMapping(controlID: controlID)
        mappings.append(mapping)
        return mapping
    }

    mutating func setAction(_ action: MouseButtonAction, for controlID: MouseControlID) {
        guard controlID != .logitechButton(0), controlID != .logitechButton(1) else { return }
        _ = mapping(for: controlID)
        guard let index = mappings.firstIndex(where: { $0.controlID == controlID }) else { return }
        mappings[index].action = action
    }

    mutating func setShortcut(_ shortcut: KeyboardShortcut?, for buttonNumber: Int) {
        guard buttonNumber != 0, buttonNumber != 1 else { return }
        _ = mapping(for: buttonNumber)
        guard let index = mappings.firstIndex(where: { $0.buttonNumber == buttonNumber }) else { return }
        mappings[index].shortcut = shortcut
    }
}

struct MouseDeviceConfiguration: Codable, Identifiable, Equatable {
    struct OnboardImport: Codable, Equatable {
        var fingerprint: String
        var profileSector: UInt16?
        var importedProfileID: UUID?
        var conflictingControls: Set<MouseControlID>
    }

    let identifier: HIDDeviceIdentifier
    var name: String
    var profiles: [MouseProfile]
    var selectedProfileID: UUID
    var onboardImport: OnboardImport?

    var id: String { identifier.id }

    init(
        identifier: HIDDeviceIdentifier,
        name: String,
        profiles: [MouseProfile] = [MouseProfile.defaultProfile()],
        selectedProfileID: UUID? = nil,
        activeProfileID: UUID? = nil,
        onboardImport: OnboardImport? = nil
    ) {
        self.identifier = identifier
        self.name = name
        self.profiles = profiles
        self.selectedProfileID = selectedProfileID ?? activeProfileID ?? profiles.first?.id ?? UUID()
        self.onboardImport = onboardImport
        normalize()
    }

    var selectedProfile: MouseProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    var defaultProfile: MouseProfile {
        profiles.first(where: \.isDefault) ?? MouseProfile.defaultProfile()
    }

    mutating func normalize() {
        if profiles.isEmpty {
            profiles = [.defaultProfile()]
        }
        if let firstDefault = profiles.firstIndex(where: \.isDefault) {
            for index in profiles.indices {
                profiles[index].isDefault = index == firstDefault
            }
        } else {
            profiles.insert(.defaultProfile(), at: 0)
        }

        var assignedBundleIDs = Set<String>()
        for index in profiles.indices {
            profiles[index].appBundleIdentifiers = profiles[index].appBundleIdentifiers.filter {
                assignedBundleIDs.insert($0).inserted
            }
        }
        if !profiles.contains(where: { $0.id == selectedProfileID }) {
            selectedProfileID = defaultProfile.id
        }
    }

    @discardableResult
    mutating func registerOnboardImport(
        fingerprint: String,
        profileSector: UInt16?,
        mappings: [MouseMapping],
        conflictingControls: Set<MouseControlID>,
        allowsImport: Bool
    ) -> Bool {
        if onboardImport == nil {
            onboardImport = OnboardImport(
                fingerprint: fingerprint,
                profileSector: profileSector,
                importedProfileID: nil,
                conflictingControls: conflictingControls
            )
        } else {
            onboardImport?.conflictingControls = conflictingControls
        }
        guard allowsImport, onboardImport?.importedProfileID == nil else { return false }
        let imported = MouseProfile(name: "Imported Onboard", mappings: mappings)
        profiles.append(imported)
        onboardImport?.importedProfileID = imported.id
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case identifier, name, profiles, selectedProfileID, activeProfileID, onboardImport
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(HIDDeviceIdentifier.self, forKey: .identifier)
        name = try container.decode(String.self, forKey: .name)
        profiles = try container.decodeIfPresent([MouseProfile].self, forKey: .profiles) ?? []
        selectedProfileID =
            try container.decodeIfPresent(UUID.self, forKey: .selectedProfileID) ??
            container.decodeIfPresent(UUID.self, forKey: .activeProfileID) ??
            profiles.first?.id ?? UUID()
        onboardImport = try container.decodeIfPresent(OnboardImport.self, forKey: .onboardImport)
        normalize()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identifier, forKey: .identifier)
        try container.encode(name, forKey: .name)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(selectedProfileID, forKey: .selectedProfileID)
        try container.encodeIfPresent(onboardImport, forKey: .onboardImport)
    }
}

struct AppConfiguration: Codable, Equatable {
    static let currentSchemaVersion = 4

    var schemaVersion = currentSchemaVersion
    var devices: [MouseDeviceConfiguration] = []
    var selectedDeviceID: String?
    var managedDeviceID: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, devices, selectedDeviceID, managedDeviceID, activeDeviceID
        case profiles, activeProfileID
    }

    init(
        devices: [MouseDeviceConfiguration] = [],
        selectedDeviceID: String? = nil,
        managedDeviceID: String? = nil,
        activeDeviceID: String? = nil
    ) {
        self.devices = devices
        schemaVersion = Self.currentSchemaVersion
        self.selectedDeviceID = selectedDeviceID ?? activeDeviceID
        self.managedDeviceID = managedDeviceID ?? activeDeviceID
        normalize()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw ConfigurationDecodingError.newerSchema(schemaVersion)
        }
        if let devices = try container.decodeIfPresent([MouseDeviceConfiguration].self, forKey: .devices) {
            self.devices = devices
            let legacyID = try container.decodeIfPresent(String.self, forKey: .activeDeviceID)
            self.selectedDeviceID =
                try container.decodeIfPresent(String.self, forKey: .selectedDeviceID) ?? legacyID
            self.managedDeviceID =
                try container.decodeIfPresent(String.self, forKey: .managedDeviceID) ?? legacyID
            normalize()
            return
        }

        let legacyProfiles = try container.decodeIfPresent([LegacyMouseProfile].self, forKey: .profiles) ?? []
        self.devices = legacyProfiles.map {
            MouseDeviceConfiguration(
                identifier: $0.identifier,
                name: $0.name,
                profiles: [.defaultProfile(mappings: $0.mappings)]
            )
        }
        let legacyID = try container.decodeIfPresent(String.self, forKey: .activeProfileID)
        self.selectedDeviceID = legacyID
        self.managedDeviceID = legacyID
        normalize()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(devices, forKey: .devices)
        try container.encodeIfPresent(selectedDeviceID, forKey: .selectedDeviceID)
        try container.encodeIfPresent(managedDeviceID, forKey: .managedDeviceID)
    }

    mutating func normalize() {
        for index in devices.indices {
            devices[index].normalize()
        }
        if let selectedDeviceID, !devices.contains(where: { $0.id == selectedDeviceID }) {
            self.selectedDeviceID = nil
        }
        if let managedDeviceID, !devices.contains(where: { $0.id == managedDeviceID }) {
            self.managedDeviceID = nil
        }
    }

    private struct LegacyMouseProfile: Decodable {
        let identifier: HIDDeviceIdentifier
        let name: String
        let mappings: [MouseMapping]
    }
}

enum ConfigurationDecodingError: Error, Equatable {
    case newerSchema(Int)
}

enum EffectiveProfileResolver {
    static func resolve(
        device: MouseDeviceConfiguration,
        foregroundBundleIdentifier: String?,
        applicationBundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.local.mouseky"
    ) -> MouseProfile {
        guard let bundleID = foregroundBundleIdentifier.flatMap(MouseProfile.normalizeBundleIdentifier),
              bundleID != MouseProfile.normalizeBundleIdentifier(applicationBundleIdentifier)
        else { return device.defaultProfile }
        return device.profiles.first(where: { $0.appBundleIdentifiers.contains(bundleID) }) ??
            device.defaultProfile
    }

    static func resolve(
        configuration: AppConfiguration,
        foregroundBundleIdentifier: String?,
        applicationBundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.local.mouseky"
    ) -> MouseProfile? {
        guard let managedID = configuration.managedDeviceID,
              let device = configuration.devices.first(where: { $0.id == managedID })
        else { return nil }
        return resolve(
            device: device,
            foregroundBundleIdentifier: foregroundBundleIdentifier,
            applicationBundleIdentifier: applicationBundleIdentifier
        )
    }
}
