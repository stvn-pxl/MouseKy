import XCTest
@testable import MouseKy

final class MouseKyTests: XCTestCase {
    func testShortcutRoundTrip() throws {
        let configuration = AppConfiguration(
            profiles: [
                MouseProfile(
                    identifier: HIDDeviceIdentifier(vendorID: 0x046D, productID: 0xC08B, serialNumber: "test"),
                    name: "G502",
                    mappings: [MouseMapping(buttonNumber: 4, shortcut: KeyboardShortcut(keyCode: 1, modifiers: 1 << 20))]
                )
            ],
            activeProfileID: "1133:49291:test"
        )
        XCTAssertEqual(try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration)).profiles, configuration.profiles)
    }

    func testPrimaryButtonsCannotBeRemapped() {
        var profile = MouseProfile(
            identifier: HIDDeviceIdentifier(vendorID: 1, productID: 2, serialNumber: nil),
            name: "Test Mouse",
            mappings: []
        )
        profile.setShortcut(KeyboardShortcut(keyCode: 1, modifiers: 0), for: 0)
        XCTAssertTrue(profile.mappings.isEmpty)
    }

    func testAdditionalButtonCanBeMapped() {
        var profile = MouseProfile(
            identifier: HIDDeviceIdentifier(vendorID: 1, productID: 2, serialNumber: nil),
            name: "Test Mouse",
            mappings: []
        )
        let shortcut = KeyboardShortcut(keyCode: 1, modifiers: 0)
        profile.setShortcut(shortcut, for: 4)
        XCTAssertEqual(profile.mappings.first?.shortcut, shortcut)
    }

    func testHIDPPPacketRoundTripAndCorrelationFields() throws {
        let packet = HIDPP42Transport.Packet(
            deviceIndex: 0xFF, featureIndex: 0x03, functionID: 0x04,
            softwareID: 0x0B, parameters: Data([0x12, 0x34])
        )
        let decoded = try HIDPP42Transport.Packet.decodeLongResponse(packet.longReportPayload())
        XCTAssertEqual(decoded.deviceIndex, packet.deviceIndex)
        XCTAssertEqual(decoded.featureIndex, packet.featureIndex)
        XCTAssertEqual(decoded.functionID, packet.functionID)
        XCTAssertEqual(decoded.softwareID, packet.softwareID)
        XCTAssertEqual(decoded.parameters.prefix(packet.parameters.count), packet.parameters)
    }

    func testHIDPPNumberedReportsIncludeIDAndFullLength() throws {
        let short = HIDPP42Transport.Packet(
            deviceIndex: 0xFF, featureIndex: 0, functionID: 0,
            softwareID: 0x0B, parameters: Data([0x81, 0x00])
        )
        let shortData = try short.reportData()
        XCTAssertEqual(shortData.count, 7)
        XCTAssertEqual(shortData.first, 0x10)
        XCTAssertEqual(
            try HIDPP42Transport.Packet.decode(
                reportID: 0x10, report: Data(shortData.dropFirst())
            ),
            HIDPP42Transport.Packet(
                deviceIndex: 0xFF, featureIndex: 0, functionID: 0,
                softwareID: 0x0B, parameters: Data([0x81, 0x00, 0])
            )
        )

        let long = HIDPP42Transport.Packet(
            deviceIndex: 0xFF, featureIndex: 9, functionID: 5,
            softwareID: 3, parameters: Data([0, 1, 0, 0])
        )
        XCTAssertEqual(try long.reportData().count, 20)
        XCTAssertEqual(try long.reportData().first, 0x11)
    }

    func testC08DDescriptorModeAndActiveProfileFixture() throws {
        var decoder = G502C08DOnboardProfileSnapshotDecoder(featureIndex: 9)
        try decoder.consume(.init(
            deviceIndex: 0xFF, featureIndex: 9, functionID: 0,
            parameters: Data([1, 3, 1, 5, 1, 11, 16, 0, 255, 0x0A, 0x04])
        ))
        try decoder.consume(.init(
            deviceIndex: 0xFF, featureIndex: 9, functionID: 2,
            parameters: Data([2])
        ))
        try decoder.consume(.init(
            deviceIndex: 0xFF, featureIndex: 9, functionID: 4,
            parameters: Data([0, 1])
        ))

        let snapshot = try XCTUnwrap(decoder.snapshot())
        XCTAssertTrue(snapshot.descriptor.isVerifiedC08DLayout)
        XCTAssertEqual(snapshot.descriptor.readSize, 255)
        XCTAssertEqual(snapshot.mode, .host)
        XCTAssertEqual(snapshot.currentProfileSector, 1)
    }

    func testHIDPPErrorFramesCorrelateToOriginalRequest() {
        let expected = HIDPP42Transport.Packet(
            deviceIndex: 0xFF, featureIndex: 0x09,
            functionID: 0x05, softwareID: 0x0B
        )
        for errorFeature in [UInt8(0xFF), UInt8(0x8F)] {
            let error = HIDPP42Transport.Packet(
                deviceIndex: 0xFF,
                featureIndex: errorFeature,
                functionID: 0,
                softwareID: 9,
                parameters: Data([0x5B, 0x02])
            )
            XCTAssertEqual(
                HIDPP42Transport.deviceErrorCode(packet: error, expected: expected),
                0x02
            )
        }
    }

    func testC08DReadOffsetsOverlapFinalWindow() {
        let offsets = G502OnboardMemoryService.readOffsets(sectorSize: 255)
        XCTAssertEqual(offsets.first, 0)
        XCTAssertEqual(offsets.last, 239)
        XCTAssertEqual(offsets.count, 16)
    }

    func testC08DWritePacketsPadWithoutChangingDeclaredLength() {
        let sector = Data((0 ..< 255).map { UInt8($0 & 0xFF) })
        let packets = G502OnboardMemoryService.writePackets(
            sectorData: sector, sector: 1, featureIndex: 9
        )
        XCTAssertEqual(packets.first?.functionID, 6)
        XCTAssertEqual(packets.first?.parameters, Data([0, 1, 0, 0, 0, 255]))
        XCTAssertEqual(packets.filter { $0.functionID == 7 }.count, 16)
        XCTAssertEqual(packets[16].parameters.count, 16)
        XCTAssertEqual(packets[16].parameters.last, 0xFF)
        XCTAssertEqual(packets.last?.functionID, 8)
    }

    func testButtonWritesPreserveOtherProfileBytesAndBanks() {
        var sector = Data(repeating: 0xA5, count: 255)
        let original = sector
        G502OnboardMemoryService.setGenericMouseBinding(
            in: &sector, index: 10, bank: .primary, mouseButton: 10
        )
        XCTAssertEqual(sector.subdata(in: 72 ..< 76), Data([0x80, 0x01, 0x04, 0x00]))
        XCTAssertEqual(sector.subdata(in: 116 ..< 120), original.subdata(in: 116 ..< 120))

        G502OnboardMemoryService.setDisabledBinding(
            in: &sector, index: 5, bank: .gShift
        )
        XCTAssertEqual(sector.subdata(in: 116 ..< 120), Data([0xFF, 0, 0, 0]))
        XCTAssertEqual(sector.prefix(32), original.prefix(32))
    }

    func testSectorCRCUpdateAndValidation() {
        var sector = Data(repeating: 0xFF, count: 255)
        G502OnboardMemoryService.updateCRC(&sector)
        XCTAssertTrue(G502OnboardMemoryService.sectorHasValidCRC(sector))
        sector[32] ^= 1
        XCTAssertFalse(G502OnboardMemoryService.sectorHasValidCRC(sector))
    }

    func testOnboardControlEShortcutRoundTrip() throws {
        let shortcut = try XCTUnwrap(KeyboardShortcut(hidUsage: 0x08, hidModifiers: 0x01))
        XCTAssertEqual(shortcut.displayName, "⌃E")
        XCTAssertEqual(shortcut.hidEncoding?.usage, 0x08)
        XCTAssertEqual(shortcut.hidEncoding?.modifiers, 0x01)

        var sector = Data(repeating: 0xFF, count: 255)
        try G502OnboardMemoryService.setKeyboardBinding(
            in: &sector, index: 3, bank: .primary, shortcut: shortcut
        )
        XCTAssertEqual(sector.subdata(in: 44 ..< 48), Data([0x80, 0x02, 0x01, 0x08]))
    }

    func testCRC16CCITTKnownVector() {
        XCTAssertEqual(G502OnboardMemoryService.crc16CCITT(Data("123456789".utf8)), 0x29B1)
    }

}
