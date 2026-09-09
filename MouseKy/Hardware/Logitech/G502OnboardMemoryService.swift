import Foundation
import IOKit.hid
import CryptoKit

struct G502OnboardProfileSnapshot: Codable, Equatable {
    struct ButtonAssignment: Codable, Equatable, Identifiable {
        enum Bank: String, Codable {
            case primary
            case gShift
        }

        let index: Int
        let bank: Bank
        let rawValue: Data
        let description: String
        var id: String { "\(bank.rawValue)-\(index)" }
    }

    let deviceFingerprint: String
    let capturedAt: Date
    let firmware: [HIDPP42Transport.FirmwareInfo]
    let onboardFeatureVersion: UInt8
    let deviceResetFeatureAvailable: Bool
    let descriptor: G502C08DOnboardProfileSnapshot.Descriptor
    let mode: G502C08DOnboardProfileSnapshot.Mode
    let activeProfileSector: UInt16?
    let directoryIsValid: Bool
    let canProvisionFromROM: Bool
    let buttonAssignments: [ButtonAssignment]
    let sectorAddresses: [UInt16]
    let sectors: [Data]
    let warnings: [String]
}

/// Revision-gated access to G502 onboard memory. Probing and backup are read-only.
/// The write path has no default schema: an unknown firmware/profile layout cannot
/// be reset merely because it shares the C08D USB product identifier.
final class G502OnboardMemoryService {
    enum Status: Equatable {
        case notLogitech
        case unsupportedDevice
        case probing
        case readOnly(String)
        case backupReady(String)
        case resetting
        case verified
        case failed(String)
    }

    static let logitechVendorID = 0x046D
    static let g502C08DProductID = 0xC08D
    private(set) var latestSnapshot: G502OnboardProfileSnapshot?
    private(set) var latestBackupURL: URL?
    var canResetLatestSnapshot: Bool {
        guard let snapshot = latestSnapshot else { return false }
        return snapshot.descriptor.isVerifiedC08DLayout &&
            Self.isVerifiedFirmware(snapshot.firmware) &&
            snapshot.onboardFeatureVersion == 0 &&
            snapshot.activeProfileSector != nil &&
            snapshot.sectors.count >= 2 &&
            snapshot.directoryIsValid &&
            (snapshot.activeProfileSector ?? 0) < 0x0100
    }

    static func isVerifiedFirmware(_ firmware: [HIDPP42Transport.FirmwareInfo]) -> Bool {
        firmware.contains {
            $0.name == "MPM" && $0.major == 0x17 && $0.minor == 0 && $0.build == 8
        }
    }

    static func crc16CCITT(_ bytes: Data) -> UInt16 {
        bytes.reduce(UInt16(0xFFFF)) { crc, byte in
            var value = crc ^ (UInt16(byte) << 8)
            for _ in 0 ..< 8 {
                value = value & 0x8000 == 0 ? value &<< 1 : (value &<< 1) ^ 0x1021
            }
            return value
        }
    }

    func status(for mouse: ConnectedMouse) -> Status {
        guard mouse.identifier.vendorID == Self.logitechVendorID else { return .notLogitech }
        guard mouse.identifier.productID == Self.g502C08DProductID else { return .unsupportedDevice }
        return .readOnly(
            "Connect and select this G502, then choose Reload to create a read-only onboard snapshot."
        )
    }

    func probeAndBackup(mouse: ConnectedMouse) async throws -> G502OnboardProfileSnapshot {
        guard mouse.identifier.vendorID == Self.logitechVendorID,
              mouse.identifier.productID == Self.g502C08DProductID,
              let interface = HIDPP42Transport.discoverInterface(
                vendorID: mouse.identifier.vendorID, productID: mouse.identifier.productID
              )
        else { throw OnboardMemoryError.interfaceNotFound }

        let transport = try await HIDPP42Transport.connect(interface: interface)
        let firmware = try await transport.firmwareInformation()
        guard !firmware.isEmpty else { throw OnboardMemoryError.firmwareUnavailable }
        guard let feature = try await transport.lookupFeature(G502C08DOnboardProfileSnapshotDecoder.onboardProfilesFeatureID) else {
            throw OnboardMemoryError.onboardProfilesUnavailable
        }
        let resetFeatureAvailable = try await transport.lookupFeature(0x1802) != nil
        var decoder = G502C08DOnboardProfileSnapshotDecoder(featureIndex: feature.index)
        for request in decoder.readOnlyRequests() {
            try decoder.consume(try await transport.readOnboardProfile(request, onboardFeatureIndex: feature.index))
        }
        guard let basicSnapshot = decoder.snapshot() else { throw OnboardMemoryError.incompleteSnapshot }
        guard basicSnapshot.descriptor.profileCount <= 8,
              basicSnapshot.descriptor.sectorCount > 0,
              basicSnapshot.descriptor.readSize <= 256
        else { throw OnboardMemoryError.invalidProfileFormat }

        let directory = try await readSector(
            0, decoder: decoder, transport: transport, size: basicSnapshot.descriptor.readSize
        )
        let directoryIsValid = Self.sectorHasValidCRC(directory)
        guard let reportedActiveSector = basicSnapshot.currentProfileSector,
              reportedActiveSector != 0xFFFF
        else { throw OnboardMemoryError.noActiveProfile }
        let entries = decodeDirectory(directory, count: Int(basicSnapshot.descriptor.profileCount))
        let canProvisionFromROM = !directoryIsValid && isBlankDirectory(directory)
        let activeSector: UInt16
        if directoryIsValid {
            guard entries.contains(where: { $0.enabled && $0.sector == reportedActiveSector })
            else { throw OnboardMemoryError.noActiveProfile }
            activeSector = reportedActiveSector
        } else if canProvisionFromROM {
            guard reportedActiveSector >= 0x0101,
                  reportedActiveSector <= 0x0100 + UInt16(basicSnapshot.descriptor.romProfileCount)
            else {
                throw OnboardMemoryError.noActiveProfile
            }
            activeSector = reportedActiveSector
        } else {
            throw OnboardMemoryError.invalidDirectory
        }
        let profile = try await readSector(
            activeSector, decoder: decoder, transport: transport,
            size: basicSnapshot.descriptor.readSize
        )
        guard Self.sectorHasValidCRC(profile) else { throw OnboardMemoryError.invalidSectorCRC }
        let assignments = basicSnapshot.descriptor.isVerifiedC08DLayout
            ? decodeButtonAssignments(
                profile, count: min(Int(basicSnapshot.descriptor.buttonCount), 16)
            )
            : []
        var warnings: [String] = []
        if basicSnapshot.mode == .host {
            warnings.append("The mouse is in Host mode. The stored onboard profile is shown, but it is not currently active.")
        }
        if canProvisionFromROM {
            warnings.append("The active profile is a factory ROM profile and remains read-only.")
        }
        if !basicSnapshot.descriptor.isVerifiedC08DLayout {
            warnings.append("This memory/profile format is displayed read-only; MouseKy will not write an unverified layout.")
        } else {
            warnings.append(Self.isVerifiedFirmware(firmware)
                ? "Reset changes only known four-byte button bindings. DPI, report rate, LEDs, names, macros, and unknown bytes are preserved."
                : "This firmware revision is not in MouseKy's write allowlist; the snapshot remains read-only.")
        }
        if resetFeatureAvailable { warnings.append("Device Reset feature 0x1802 is present but is never used.") }
        let snapshot = G502OnboardProfileSnapshot(
            deviceFingerprint: fingerprint(for: mouse, interfaceName: interface.productName),
            capturedAt: Date(),
            firmware: firmware,
            onboardFeatureVersion: feature.version,
            deviceResetFeatureAvailable: resetFeatureAvailable,
            descriptor: basicSnapshot.descriptor,
            mode: basicSnapshot.mode,
            activeProfileSector: activeSector,
            directoryIsValid: directoryIsValid,
            canProvisionFromROM: canProvisionFromROM,
            buttonAssignments: assignments,
            sectorAddresses: [0, activeSector],
            sectors: [directory, profile],
            warnings: warnings
        )
        latestSnapshot = snapshot
        latestBackupURL = try persistBackup(snapshot)
        return snapshot
    }

    func setButtonAssignment(
        mouse: ConnectedMouse,
        index: Int,
        bank: G502OnboardProfileSnapshot.ButtonAssignment.Bank,
        mouseButton: Int?
    ) async throws -> G502OnboardProfileSnapshot {
        guard canResetLatestSnapshot else { throw OnboardMemoryError.protocolNotVerified }
        let updated = try await updating(mouse: mouse) { sector, count in
            guard (0 ..< count).contains(index) else { throw OnboardMemoryError.invalidButton }
            if let mouseButton {
                Self.setGenericMouseBinding(in: &sector, index: index, bank: bank, mouseButton: mouseButton)
            } else {
                Self.setDisabledBinding(in: &sector, index: index, bank: bank)
            }
        }
        latestSnapshot = updated
        return updated
    }

    func setButtonShortcut(
        mouse: ConnectedMouse,
        index: Int,
        bank: G502OnboardProfileSnapshot.ButtonAssignment.Bank = .primary,
        shortcut: KeyboardShortcut
    ) async throws -> G502OnboardProfileSnapshot {
        guard canResetLatestSnapshot else { throw OnboardMemoryError.protocolNotVerified }
        let updated = try await updating(mouse: mouse) { sector, count in
            guard (0 ..< count).contains(index) else { throw OnboardMemoryError.invalidButton }
            try Self.setKeyboardBinding(
                in: &sector, index: index, bank: bank, shortcut: shortcut
            )
        }
        latestSnapshot = updated
        return updated
    }

    private func updating(
        mouse: ConnectedMouse,
        mutate: (inout Data, Int) throws -> Void
    ) async throws -> G502OnboardProfileSnapshot {
        guard let snapshot = latestSnapshot, latestBackupURL != nil,
              let activeSector = snapshot.activeProfileSector, snapshot.sectors.count >= 2
        else { throw OnboardMemoryError.backupRequired }
        guard snapshot.deviceFingerprint.hasPrefix("\(mouse.identifier.vendorID):\(mouse.identifier.productID):") else {
            throw OnboardMemoryError.snapshotBelongsToAnotherDevice
        }
        guard snapshot.descriptor.isVerifiedC08DLayout else {
            throw OnboardMemoryError.protocolNotVerified
        }
        guard Self.isVerifiedFirmware(snapshot.firmware), snapshot.onboardFeatureVersion == 0 else {
            throw OnboardMemoryError.protocolNotVerified
        }
        latestBackupURL = try persistBackup(snapshot)
        var profile = snapshot.sectors[1]
        try mutate(&profile, min(Int(snapshot.descriptor.buttonCount), 16))
        Self.updateCRC(&profile)

        guard let interface = HIDPP42Transport.discoverInterface(vendorID: mouse.identifier.vendorID, productID: mouse.identifier.productID) else {
            throw OnboardMemoryError.interfaceNotFound
        }
        let transport = try await HIDPP42Transport.connect(interface: interface)
        guard let feature = try await transport.lookupFeature(G502C08DOnboardProfileSnapshotDecoder.onboardProfilesFeatureID) else {
            throw OnboardMemoryError.onboardProfilesUnavailable
        }
        guard feature.version == snapshot.onboardFeatureVersion else { throw OnboardMemoryError.protocolNotVerified }
        let decoder = G502C08DOnboardProfileSnapshotDecoder(featureIndex: feature.index)
        guard snapshot.directoryIsValid, activeSector < 0x0100 else { throw OnboardMemoryError.romProfileReadOnly }
        let targetSector = activeSector
        try await writeSector(profile, sector: targetSector, decoder: decoder, transport: transport)
        let readBack = try await readSector(targetSector, decoder: decoder, transport: transport, size: snapshot.descriptor.readSize)
        guard readBack == profile, Self.sectorHasValidCRC(readBack) else { throw OnboardMemoryError.readBackFailed }

        let directory = snapshot.sectors[0]
        try await writeSector(directory, sector: 0, decoder: decoder, transport: transport)
        let directoryReadBack = try await readSector(0, decoder: decoder, transport: transport, size: snapshot.descriptor.readSize)
        guard directoryReadBack == directory else { throw OnboardMemoryError.readBackFailed }

        return G502OnboardProfileSnapshot(
            deviceFingerprint: snapshot.deviceFingerprint, capturedAt: Date(),
            firmware: snapshot.firmware,
            onboardFeatureVersion: snapshot.onboardFeatureVersion,
            deviceResetFeatureAvailable: snapshot.deviceResetFeatureAvailable,
            descriptor: snapshot.descriptor,
            mode: snapshot.mode, activeProfileSector: targetSector,
            directoryIsValid: true, canProvisionFromROM: false,
            buttonAssignments: decodeButtonAssignments(readBack, count: min(Int(snapshot.descriptor.buttonCount), 16)),
            sectorAddresses: [0, targetSector],
            sectors: [directoryReadBack, readBack],
            warnings: snapshot.warnings.filter { !$0.contains("factory ROM profile") }
        )
    }

    private func readSector(_ sector: UInt16, decoder: G502C08DOnboardProfileSnapshotDecoder, transport: HIDPP42Transport, size: Int) async throws -> Data {
        var bytes = Data(repeating: 0, count: size)
        for requestOffset in Self.readOffsets(sectorSize: size) {
            let request = decoder.memoryReadRequest(sector: sector, offset: UInt16(requestOffset))
            let response = try await transport.readOnboardProfile(request, onboardFeatureIndex: decoder.featureIndex)
            let block = try G502C08DOnboardProfileSnapshotDecoder.sectorData(from: response, requestedSector: sector, offset: UInt16(requestOffset))
            bytes.replaceSubrange(requestOffset ..< requestOffset + 16, with: block)
        }
        return bytes
    }

    private func writeSector(_ sectorData: Data, sector: UInt16, decoder: G502C08DOnboardProfileSnapshotDecoder, transport: HIDPP42Transport) async throws {
        // fn6 establishes target sector/offset/length, fn7 appends one 16-byte
        // chunk, fn8 commits the staged sector. These are the sector-model 0x8100
        // operations used by libratbag/Solaar.
        let packets = Self.writePackets(
            sectorData: sectorData, sector: sector, featureIndex: decoder.featureIndex
        )
        for packet in packets {
            _ = try await transport.writeVerifiedProfilePacket(packet)
        }
    }

    static func readOffsets(sectorSize: Int) -> [Int] {
        guard sectorSize >= 16 else { return [] }
        return stride(from: 0, to: sectorSize, by: 16).map {
            min($0, sectorSize - 16)
        }
    }

    static func writePackets(
        sectorData: Data,
        sector: UInt16,
        featureIndex: UInt8,
        deviceIndex: UInt8 = 0xFF
    ) -> [HIDPP42Transport.Packet] {
        var packets = [
            HIDPP42Transport.Packet(
                deviceIndex: deviceIndex, featureIndex: featureIndex, functionID: 0x06,
                parameters: Data([
                    UInt8(sector >> 8), UInt8(sector & 0xFF), 0, 0,
                    UInt8(sectorData.count >> 8), UInt8(sectorData.count & 0xFF)
                ])
            )
        ]
        for offset in stride(from: 0, to: sectorData.count, by: 16) {
            let upperBound = min(offset + 16, sectorData.count)
            var chunk = sectorData.subdata(in: offset ..< upperBound)
            if chunk.count < 16 {
                chunk.append(contentsOf: repeatElement(0xFF, count: 16 - chunk.count))
            }
            packets.append(HIDPP42Transport.Packet(
                deviceIndex: deviceIndex, featureIndex: featureIndex,
                functionID: 0x07, parameters: chunk
            ))
        }
        packets.append(HIDPP42Transport.Packet(
            deviceIndex: deviceIndex, featureIndex: featureIndex, functionID: 0x08
        ))
        return packets
    }

    private func decodeButtonAssignments(_ sector: Data, count: Int) -> [G502OnboardProfileSnapshot.ButtonAssignment] {
        [.primary, .gShift].flatMap { bank in
            (0 ..< count).compactMap { index in
                decodeButtonAssignment(sector, index: index, bank: bank)
            }
        }
    }

    private func decodeButtonAssignment(
        _ sector: Data,
        index: Int,
        bank: G502OnboardProfileSnapshot.ButtonAssignment.Bank
    ) -> G502OnboardProfileSnapshot.ButtonAssignment? {
            let offset = Self.buttonOffset(index: index, bank: bank)
            guard sector.count >= offset + 4 else { return nil }
            let raw = sector.subdata(in: offset ..< offset + 4)
            let description: String
            switch (raw[0], raw[1]) {
            case (0x80, 0x01):
                description = String(format: "Mouse buttons 0x%04X", UInt16(raw[2]) << 8 | UInt16(raw[3]))
            case (0x80, 0x02):
                description = String(format: "Keyboard key 0x%02X", raw[3])
            case (0x80, 0x03):
                description = String(format: "Consumer control 0x%04X", UInt16(raw[2]) << 8 | UInt16(raw[3]))
            case (0x90, _):
                description = String(format: "Device function 0x%02X", raw[1])
            case (0xFF, _):
                description = "Disabled"
            default:
                description = "Unknown (read-only)"
            }
            return .init(index: index, bank: bank, rawValue: raw, description: description)
    }

    static func keyboardShortcut(
        from assignment: G502OnboardProfileSnapshot.ButtonAssignment
    ) -> KeyboardShortcut? {
        guard assignment.rawValue.count == 4,
              assignment.rawValue[0] == 0x80,
              assignment.rawValue[1] == 0x02
        else { return nil }
        return KeyboardShortcut(
            hidUsage: assignment.rawValue[3],
            hidModifiers: assignment.rawValue[2]
        )
    }

    static func setGenericMouseBinding(
        in sector: inout Data,
        index: Int,
        bank: G502OnboardProfileSnapshot.ButtonAssignment.Bank,
        mouseButton: Int
    ) {
        let offset = buttonOffset(index: index, bank: bank)
        guard (0 ... 15).contains(mouseButton), sector.count >= offset + 4 else { return }
        let mask = UInt16(1) << UInt16(mouseButton)
        sector.replaceSubrange(
            offset ..< offset + 4,
            with: [0x80, 0x01, UInt8(mask >> 8), UInt8(mask & 0xFF)]
        )
    }

    static func setDisabledBinding(
        in sector: inout Data,
        index: Int,
        bank: G502OnboardProfileSnapshot.ButtonAssignment.Bank
    ) {
        let offset = buttonOffset(index: index, bank: bank)
        guard sector.count >= offset + 4 else { return }
        sector.replaceSubrange(offset ..< offset + 4, with: [0xFF, 0, 0, 0])
    }

    static func setKeyboardBinding(
        in sector: inout Data,
        index: Int,
        bank: G502OnboardProfileSnapshot.ButtonAssignment.Bank,
        shortcut: KeyboardShortcut
    ) throws {
        guard let encoding = shortcut.hidEncoding else {
            throw OnboardMemoryError.unsupportedKeyboardKey
        }
        let offset = buttonOffset(index: index, bank: bank)
        guard sector.count >= offset + 4 else { throw OnboardMemoryError.invalidButton }
        sector.replaceSubrange(
            offset ..< offset + 4,
            with: [0x80, 0x02, encoding.modifiers, encoding.usage]
        )
    }

    private static func buttonOffset(
        index: Int,
        bank: G502OnboardProfileSnapshot.ButtonAssignment.Bank
    ) -> Int {
        (bank == .primary ? 32 : 96) + index * 4
    }

    private struct DirectoryEntry {
        let sector: UInt16
        let enabled: Bool
    }

    private func decodeDirectory(_ sector: Data, count: Int) -> [DirectoryEntry] {
        (0 ..< count).compactMap { index in
            let offset = index * 4
            guard sector.count >= offset + 4 else { return nil }
            return DirectoryEntry(
                sector: UInt16(sector[offset]) << 8 | UInt16(sector[offset + 1]),
                enabled: sector[offset + 2] == 1
            )
        }
    }

    private func isBlankDirectory(_ sector: Data) -> Bool {
        guard sector.count >= 2 else { return false }
        return sector.dropLast(2).allSatisfy { $0 == 0xFF }
    }

    private func makeProvisionedDirectory(size: Int, profileIndex: Int, profileSector: UInt16) -> Data {
        var directory = Data(repeating: 0xFF, count: size)
        let offset = (profileIndex - 1) * 4
        directory.replaceSubrange(
            offset ..< offset + 4,
            with: [UInt8(profileSector >> 8), UInt8(profileSector & 0xFF), 1, 0]
        )
        Self.updateCRC(&directory)
        return directory
    }

    static func sectorHasValidCRC(_ sector: Data) -> Bool {
        guard sector.count >= 2 else { return false }
        let expected = UInt16(sector[sector.count - 2]) << 8 | UInt16(sector[sector.count - 1])
        return Self.crc16CCITT(sector.dropLast(2)) == expected
    }

    static func updateCRC(_ sector: inout Data) {
        guard sector.count >= 2 else { return }
        let crc = Self.crc16CCITT(sector.dropLast(2))
        sector[sector.count - 2] = UInt8(crc >> 8)
        sector[sector.count - 1] = UInt8(crc & 0xFF)
    }

    private func persistBackup(_ snapshot: G502OnboardProfileSnapshot) throws -> URL {
        let manager = FileManager.default
        let directory = try manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        .appendingPathComponent("MouseKy/Backups", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let milliseconds = Int(snapshot.capturedAt.timeIntervalSince1970 * 1_000)
        let stem = "g502-\(milliseconds)-\(UUID().uuidString.prefix(8))"
        let backupURL = directory.appendingPathComponent(stem).appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: backupURL, options: .atomic)
        let rawURL = directory.appendingPathComponent(stem).appendingPathExtension("bin")
        try snapshot.sectors.reduce(into: Data()) { $0.append($1) }.write(to: rawURL, options: .atomic)
        let rawData = snapshot.sectors.reduce(into: Data()) { $0.append($1) }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let rawDigest = SHA256.hash(data: rawData).map { String(format: "%02x", $0) }.joined()
        let manifest = [
            "deviceFingerprint": snapshot.deviceFingerprint,
            "schema": snapshot.descriptor.schemaIdentifier,
            "firmware": snapshot.firmware.map(\.displayName).joined(separator: ", "),
            "sha256": digest,
            "rawSha256": rawDigest,
            "snapshot": backupURL.lastPathComponent,
            "rawSectors": rawURL.lastPathComponent,
            "createdAt": ISO8601DateFormatter().string(from: snapshot.capturedAt),
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: directory.appendingPathComponent(stem).appendingPathExtension("manifest.json"), options: .atomic)
        return backupURL
    }

    private func fingerprint(for mouse: ConnectedMouse, interfaceName: String?) -> String {
        "\(mouse.identifier.vendorID):\(mouse.identifier.productID):\(mouse.identifier.serialNumber ?? ""):\(interfaceName ?? "")"
    }

    enum OnboardMemoryError: LocalizedError, Equatable {
        case protocolNotVerified, invalidSectorCRC, invalidDirectory, noActiveProfile, invalidButton, readBackFailed
        case unsupportedKeyboardKey
        case romProfileReadOnly
        case interfaceNotFound, firmwareUnavailable, onboardProfilesUnavailable, incompleteSnapshot, invalidProfileFormat
        case backupRequired, snapshotBelongsToAnotherDevice

        var errorDescription: String? {
            switch self {
            case .protocolNotVerified:
                "This G502 firmware has no verified sector schema, so MouseKy will not send an onboard-memory write."
            case .invalidSectorCRC:
                "The onboard sector CRC is invalid, so MouseKy will not modify it."
            case .invalidDirectory:
                "The onboard profile directory is neither valid nor safely recognizable as blank."
            case .noActiveProfile:
                "The G502 did not report an active onboard profile sector."
            case .invalidButton:
                "The selected onboard button index is invalid."
            case .unsupportedKeyboardKey:
                "This key cannot be represented as a standard HID keyboard shortcut."
            case .readBackFailed:
                "The written sector did not match the verified read-back; no further writes were attempted."
            case .romProfileReadOnly:
                "The active factory ROM profile cannot be modified or safely provisioned."
            case .interfaceNotFound:
                "No Logitech HID++ interface with reports 0x10 and 0x11 was found for this mouse."
            case .firmwareUnavailable:
                "The G502 firmware identity could not be read, so profile access remains disabled."
            case .onboardProfilesUnavailable:
                "This HID++ interface does not expose onboard profiles (feature 0x8100)."
            case .incompleteSnapshot:
                "The G502 did not return a complete onboard-profile snapshot."
            case .invalidProfileFormat:
                "The reported onboard-profile format is invalid and remains read-only."
            case .backupRequired:
                "A complete snapshot and atomic backup are required before a reset can be considered."
            case .snapshotBelongsToAnotherDevice:
                "The available backup does not belong to the selected G502."
            }
        }
    }
}
