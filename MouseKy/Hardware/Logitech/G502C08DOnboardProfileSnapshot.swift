import Foundation

/// Values and read-only wire operations for HID++ feature 0x8100.
struct G502C08DOnboardProfileSnapshot: Equatable {
    enum Mode: Codable, Equatable {
        case onboard
        case host
        case unknown(UInt8)
    }

    struct Descriptor: Codable, Equatable {
        let memoryModel: UInt8
        let profileCount: UInt8
        let romProfileCount: UInt8
        let profileFormat: UInt8
        let macroFormat: UInt8
        let buttonCount: UInt8
        let sectorCount: UInt8
        /// Number of meaningful bytes in a sector, including its two CRC bytes.
        /// A 255-byte sector is read in overlapping 16-byte windows.
        let sectorSize: UInt16
        let mechanicalLayout: UInt8
        let variousInfo: UInt8

        var readSize: Int { Int(sectorSize) }
        /// Captured descriptor for G502 LIGHTSPEED C08D, profile format 3.
        /// Other devices and future layouts remain readable but never writable.
        var isVerifiedC08DLayout: Bool {
            memoryModel == 1 &&
                profileFormat == 3 &&
                macroFormat == 1 &&
                profileCount == 5 &&
                romProfileCount == 1 &&
                buttonCount == 11 &&
                sectorCount == 16 &&
                sectorSize == 255 &&
                mechanicalLayout == 0x0A &&
                variousInfo == 0x04
        }

        var schemaIdentifier: String {
            String(
                format: "m%u-p%u-macro%u-profiles%u-rom%u-buttons%u-sectors%u-size%u-layout%02X-info%02X",
                memoryModel, profileFormat, macroFormat, profileCount, romProfileCount,
                buttonCount, sectorCount, readSize, mechanicalLayout, variousInfo
            )
        }
    }

    let descriptor: Descriptor
    let mode: Mode
    /// The device addresses profiles by flash sector, e.g. 0x0001.
    let currentProfileSector: UInt16?
}

/// Accumulates the three non-mutating 0x8100 responses for a UI snapshot.
struct G502C08DOnboardProfileSnapshotDecoder {
    static let onboardProfilesFeatureID: UInt16 = 0x8100

    enum Function: UInt8 {
        case profileDescriptor = 0x00
        case onboardMode = 0x02
        case currentProfile = 0x04
        case memoryRead = 0x05
    }

    enum DecodeError: LocalizedError, Equatable {
        case wrongFeature, missingParameters, malformedProfileCount

        var errorDescription: String? {
            switch self {
            case .wrongFeature: "The HID++ response belongs to a different feature."
            case .missingParameters: "The HID++ onboard-profile response did not contain the required fields."
            case .malformedProfileCount: "The G502 reported an invalid onboard-profile count."
            }
        }
    }

    let featureIndex: UInt8
    private(set) var descriptor: G502C08DOnboardProfileSnapshot.Descriptor?
    private(set) var mode: G502C08DOnboardProfileSnapshot.Mode?
    private(set) var currentProfileSector: UInt16?

    init(featureIndex: UInt8) {
        self.featureIndex = featureIndex
    }

    /// Only documented getter functions can be constructed: 0x00, 0x02, and 0x04.
    func readOnlyRequests(deviceIndex: UInt8 = 0xFF) -> [HIDPP42Transport.Packet] {
        [Function.profileDescriptor, .onboardMode, .currentProfile].map {
            HIDPP42Transport.Packet(deviceIndex: deviceIndex, featureIndex: featureIndex, functionID: $0.rawValue)
        }
    }

    mutating func consume(_ packet: HIDPP42Transport.Packet) throws {
        guard packet.featureIndex == featureIndex else { throw DecodeError.wrongFeature }
        guard let function = Function(rawValue: packet.functionID) else { return }
        guard let first = packet.parameters.first else { throw DecodeError.missingParameters }

        switch function {
        case .profileDescriptor:
            guard packet.parameters.count >= 11, packet.parameters[3] > 0 else { throw DecodeError.malformedProfileCount }
            descriptor = .init(
                memoryModel: first,
                profileCount: packet.parameters[3],
                romProfileCount: packet.parameters[4],
                profileFormat: packet.parameters[1],
                macroFormat: packet.parameters[2],
                buttonCount: packet.parameters[5],
                sectorCount: packet.parameters[6],
                sectorSize: UInt16(packet.parameters[7]) << 8 | UInt16(packet.parameters[8]),
                mechanicalLayout: packet.parameters[9],
                variousInfo: packet.parameters[10]
            )
        case .onboardMode:
            mode = first == 1 ? .onboard : first == 2 ? .host : .unknown(first)
        case .currentProfile:
            guard packet.parameters.count >= 2 else { throw DecodeError.missingParameters }
            // Byte 0 is reserved in this format; byte 1 identifies the
            // active classic-G502 profile sector.
            let sector = UInt16(packet.parameters[1])
            currentProfileSector = sector == 0 ? nil : sector
        case .memoryRead:
            break
        }
    }

    func snapshot() -> G502C08DOnboardProfileSnapshot? {
        guard let descriptor, let mode else { return nil }
        return .init(descriptor: descriptor, mode: mode, currentProfileSector: currentProfileSector)
    }

    func memoryReadRequest(sector: UInt16, offset: UInt16, deviceIndex: UInt8 = 0xFF) -> HIDPP42Transport.Packet {
        HIDPP42Transport.Packet(
            deviceIndex: deviceIndex, featureIndex: featureIndex, functionID: Function.memoryRead.rawValue,
            parameters: Data([
                UInt8(sector >> 8), UInt8(sector & 0xFF),
                UInt8(offset >> 8), UInt8(offset & 0xFF)
            ])
        )
    }

    static func sectorData(from response: HIDPP42Transport.Packet, requestedSector: UInt16, offset: UInt16) throws -> Data {
        guard response.functionID == Function.memoryRead.rawValue, response.parameters.count >= 16 else {
            throw DecodeError.missingParameters
        }
        // HID++ repeats the requested address when implemented according to the
        // spec. Older G firmware returns payload only, so accept that known form.
        if response.parameters.count >= 20 {
            let sector = UInt16(response.parameters[0]) << 8 | UInt16(response.parameters[1])
            let returnedOffset = UInt16(response.parameters[2]) << 8 | UInt16(response.parameters[3])
            guard sector == requestedSector, returnedOffset == offset else { throw DecodeError.wrongFeature }
            return Data(response.parameters.dropFirst(4).prefix(16))
        }
        return Data(response.parameters.prefix(16))
    }
}
