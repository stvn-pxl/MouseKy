import XCTest
@testable import MouseKy

final class MouseKyTests: XCTestCase {
    func testShortcutRoundTrip() throws {
        let identifier = HIDDeviceIdentifier(vendorID: 0x046D, productID: 0xC08B, serialNumber: "test")
        let profile = MouseProfile(
            name: "Design",
            mappings: [MouseMapping(buttonNumber: 4, shortcut: KeyboardShortcut(keyCode: 1, modifiers: 1 << 20))]
        )
        let configuration = AppConfiguration(
            devices: [
                MouseDeviceConfiguration(
                    identifier: identifier,
                    name: "G502",
                    profiles: [.defaultProfile(), profile],
                    activeProfileID: profile.id
                )
            ],
            activeDeviceID: identifier.id
        )
        XCTAssertEqual(try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration)), configuration)
    }

    func testLegacyConfigurationMigratesToDeviceDefaultProfile() throws {
        let legacy = """
        {
          "activeProfileID": "1:2:test",
          "profiles": [{
            "identifier": { "vendorID": 1, "productID": 2, "serialNumber": "test" },
            "name": "Legacy Mouse",
            "mappings": [{ "buttonNumber": 4, "shortcut": null }]
          }]
        }
        """
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(legacy.utf8))
        let device = try XCTUnwrap(configuration.devices.first)
        XCTAssertEqual(configuration.selectedDeviceID, "1:2:test")
        XCTAssertEqual(configuration.managedDeviceID, "1:2:test")
        XCTAssertEqual(device.name, "Legacy Mouse")
        XCTAssertTrue(device.defaultProfile.isDefault)
        XCTAssertEqual(device.defaultProfile.mappings.map(\.buttonNumber), [4])
    }

    func testDeviceProfilesAreIsolatedAndDefaultIsAlwaysPresent() {
        let firstIdentifier = HIDDeviceIdentifier(vendorID: 1, productID: 2, serialNumber: nil)
        let secondIdentifier = HIDDeviceIdentifier(vendorID: 3, productID: 4, serialNumber: nil)
        let first = MouseDeviceConfiguration(
            identifier: firstIdentifier,
            name: "First",
            profiles: [MouseProfile(name: "Work")]
        )
        let second = MouseDeviceConfiguration(
            identifier: secondIdentifier,
            name: "Second",
            profiles: [MouseProfile(name: "Games")]
        )

        XCTAssertEqual(first.profiles.count, 2)
        XCTAssertEqual(second.profiles.count, 2)
        XCTAssertEqual(first.defaultProfile.name, MouseProfile.defaultName)
        XCTAssertEqual(second.defaultProfile.name, MouseProfile.defaultName)
        XCTAssertNotEqual(first.profiles.map(\.id), second.profiles.map(\.id))
    }

    func testPrimaryButtonsCannotBeRemapped() {
        var profile = MouseProfile(
            name: "Test Mouse",
            mappings: []
        )
        profile.setShortcut(KeyboardShortcut(keyCode: 1, modifiers: 0), for: 0)
        XCTAssertTrue(profile.mappings.isEmpty)
    }

    func testAdditionalButtonCanBeMapped() {
        var profile = MouseProfile(
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

    func testClearingOnboardShortcutsPreservesMouseAndDeviceBindings() throws {
        var sector = Data(repeating: 0xFF, count: 255)
        let shortcut = try XCTUnwrap(KeyboardShortcut(hidUsage: 0x08, hidModifiers: 0x01))
        try G502OnboardMemoryService.setKeyboardBinding(
            in: &sector, index: 3, bank: .primary, shortcut: shortcut
        )
        sector.replaceSubrange(48 ..< 52, with: Data([0x80, 0x03, 0x00, 0xE9]))
        G502OnboardMemoryService.setGenericMouseBinding(
            in: &sector, index: 5, bank: .primary, mouseButton: 4
        )
        sector.replaceSubrange(96 ..< 100, with: Data([0x80, 0x04, 0x01, 0x00]))

        G502OnboardMemoryService.clearShortcutBindings(in: &sector, buttonCount: 11)

        XCTAssertEqual(sector.subdata(in: 44 ..< 48), Data([0xFF, 0, 0, 0]))
        XCTAssertEqual(sector.subdata(in: 48 ..< 52), Data([0xFF, 0, 0, 0]))
        XCTAssertEqual(sector.subdata(in: 52 ..< 56), Data([0x80, 0x01, 0, 0x10]))
        XCTAssertEqual(sector.subdata(in: 96 ..< 100), Data([0x80, 0x04, 1, 0]))
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

    func testOnboardImportExposesKeyboardAndConsumerConflicts() {
        let descriptor = G502C08DOnboardProfileSnapshot.Descriptor(
            memoryModel: 1, profileCount: 5, romProfileCount: 1,
            profileFormat: 3, macroFormat: 1, buttonCount: 11,
            sectorCount: 16, sectorSize: 255, mechanicalLayout: 0x0A,
            variousInfo: 0x04
        )
        let snapshot = G502OnboardProfileSnapshot(
            deviceFingerprint: "046D:C08D:test", capturedAt: Date(),
            firmware: [], onboardFeatureVersion: 0,
            deviceResetFeatureAvailable: false, descriptor: descriptor,
            mode: .onboard, activeProfileSector: 1, directoryIsValid: true,
            canProvisionFromROM: false,
            buttonAssignments: [
                .init(
                    index: 3, bank: .primary, rawValue: Data([0x80, 0x02, 0x01, 0x08]),
                    description: "Keyboard"
                ),
                .init(
                    index: 4, bank: .primary, rawValue: Data([0x80, 0x03, 0, 0xE9]),
                    description: "Consumer"
                ),
                .init(
                    index: 5, bank: .primary, rawValue: Data([0x80, 0x01, 0, 4]),
                    description: "Mouse"
                )
            ],
            sectorAddresses: [0, 1], sectors: [], warnings: []
        )

        let bindings = G502OnboardMemoryService().importedBindings(from: snapshot)
        XCTAssertEqual(bindings.map(\.controlID), [.logitechButton(3), .logitechButton(4)])
        guard case let .keyboard(shortcut) = bindings[0].kind else {
            return XCTFail("Expected a keyboard shortcut")
        }
        XCTAssertEqual(shortcut.displayName, "⌃E")
        XCTAssertEqual(bindings[1].kind, .consumer)
    }

    func testCRC16CCITTKnownVector() {
        XCTAssertEqual(G502OnboardMemoryService.crc16CCITT(Data("123456789".utf8)), 0x29B1)
    }

    func testProfileWithoutAppFieldMigratesAndNormalizesAssignments() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "Legacy",
          "isDefault": false,
          "mappings": []
        }
        """
        let profile = try JSONDecoder().decode(MouseProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.appBundleIdentifiers, [])

        let normalized = MouseProfile(
            name: "Apps",
            appBundleIdentifiers: [" COM.APP.Editor ", "com.app.editor", ""]
        )
        XCTAssertEqual(normalized.appBundleIdentifiers, ["com.app.editor"])
    }

    func testDecodeEnforcesExactlyOneDefaultAndUniqueBundleAssignments() throws {
        let firstID = UUID()
        let secondID = UUID()
        let json = """
        {
          "identifier": { "vendorID": 1, "productID": 2 },
          "name": "Mouse",
          "profiles": [
            {
              "id": "\(firstID)", "name": "First", "isDefault": true,
              "mappings": [], "appBundleIdentifiers": ["com.example.app"]
            },
            {
              "id": "\(secondID)", "name": "Second", "isDefault": true,
              "mappings": [], "appBundleIdentifiers": ["COM.EXAMPLE.APP", "com.other"]
            }
          ],
          "selectedProfileID": "\(secondID)"
        }
        """
        let device = try JSONDecoder().decode(
            MouseDeviceConfiguration.self, from: Data(json.utf8)
        )
        XCTAssertEqual(device.profiles.filter(\.isDefault).count, 1)
        XCTAssertTrue(device.profiles[0].isDefault)
        XCTAssertEqual(device.profiles[1].appBundleIdentifiers, ["com.other"])
        XCTAssertEqual(device.selectedProfileID, secondID)
    }

    func testEffectiveProfileResolutionUsesManagedDeviceAndDefaultFallback() {
        let firstIdentifier = HIDDeviceIdentifier(vendorID: 1, productID: 2, serialNumber: "a")
        let secondIdentifier = HIDDeviceIdentifier(vendorID: 3, productID: 4, serialNumber: "b")
        let work = MouseProfile(
            name: "Work",
            appBundleIdentifiers: ["com.example.editor"]
        )
        let configuration = AppConfiguration(
            devices: [
                MouseDeviceConfiguration(identifier: firstIdentifier, name: "First"),
                MouseDeviceConfiguration(
                    identifier: secondIdentifier,
                    name: "Second",
                    profiles: [.defaultProfile(), work]
                )
            ],
            selectedDeviceID: firstIdentifier.id,
            managedDeviceID: secondIdentifier.id
        )

        XCTAssertEqual(
            EffectiveProfileResolver.resolve(
                configuration: configuration,
                foregroundBundleIdentifier: "COM.EXAMPLE.EDITOR"
            )?.id,
            work.id
        )
        XCTAssertEqual(
            EffectiveProfileResolver.resolve(
                configuration: configuration,
                foregroundBundleIdentifier: nil
            )?.id,
            configuration.devices[1].defaultProfile.id
        )
        XCTAssertEqual(
            EffectiveProfileResolver.resolve(
                configuration: configuration,
                foregroundBundleIdentifier: "com.local.MouseKy",
                applicationBundleIdentifier: "com.local.MouseKy"
            )?.id,
            configuration.devices[1].defaultProfile.id
        )
    }

    @MainActor
    func testAssignmentRequiresConfirmationAndFocusDoesNotSave() {
        let identifier = HIDDeviceIdentifier(vendorID: 1, productID: 2, serialNumber: "test")
        let source = MouseProfile(name: "Source", appBundleIdentifiers: ["com.example.app"])
        let target = MouseProfile(name: "Target")
        let configuration = AppConfiguration(
            devices: [
                MouseDeviceConfiguration(
                    identifier: identifier,
                    name: "Mouse",
                    profiles: [.defaultProfile(), source, target],
                    selectedProfileID: target.id
                )
            ],
            selectedDeviceID: identifier.id,
            managedDeviceID: identifier.id
        )
        let store = TestConfigurationStore(configuration: configuration)
        let model = AppModel(store: store)

        XCTAssertEqual(
            model.assignApplication(bundleIdentifier: "com.example.app"),
            .requiresConfirmation(sourceProfileName: "Source")
        )
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(
            model.assignApplication(bundleIdentifier: "com.example.app", confirmMove: true),
            .assigned
        )
        XCTAssertEqual(store.saveCount, 1)

        model.handleForegroundApplicationChange("com.example.app")
        model.handleForegroundApplicationChange("com.other")
        XCTAssertEqual(store.saveCount, 1)
    }

    func testLegacyMappingMigratesToExplicitPassthroughAction() throws {
        let json = """
        { "buttonNumber": 4, "shortcut": null }
        """
        let mapping = try JSONDecoder().decode(MouseMapping.self, from: Data(json.utf8))
        XCTAssertEqual(mapping.controlID, .logitechButton(4))
        XCTAssertEqual(mapping.action, .passthrough)
        XCTAssertEqual(
            try JSONDecoder().decode(
                MouseMapping.self, from: JSONEncoder().encode(mapping)
            ),
            mapping
        )
    }

    func testNewerConfigurationSchemaIsRejected() {
        let json = """
        { "schemaVersion": 999, "devices": [] }
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        ) { error in
            XCTAssertEqual(error as? ConfigurationDecodingError, .newerSchema(999))
        }
    }

    func testOnboardImportIsCreatedOnlyOnce() {
        let identifier = HIDDeviceIdentifier(
            vendorID: 0x046D, productID: 0xC08D, serialNumber: "onboard"
        )
        var device = MouseDeviceConfiguration(identifier: identifier, name: "G502")
        let shortcut = KeyboardShortcut(keyCode: 14, modifiers: 0)
        let mappings = [
            MouseMapping(
                controlID: .logitechButton(3),
                action: .shortcut(shortcut)
            )
        ]
        XCTAssertTrue(device.registerOnboardImport(
            fingerprint: "046D:C08D:onboard", profileSector: 1,
            mappings: mappings, conflictingControls: [.logitechButton(3)],
            allowsImport: true
        ))
        let importedID = device.onboardImport?.importedProfileID
        XCTAssertFalse(device.registerOnboardImport(
            fingerprint: "046D:C08D:onboard", profileSector: 1,
            mappings: mappings, conflictingControls: [.logitechButton(3)],
            allowsImport: true
        ))
        XCTAssertEqual(device.profiles.filter { $0.name == "Imported Onboard" }.count, 1)
        XCTAssertEqual(device.onboardImport?.importedProfileID, importedID)
    }

    @MainActor
    func testButtonSpyBackendFiltersVerifiesEmitsAndRestores() async throws {
        let feature = HIDPP42Transport.Feature(
            identifier: 0x8110, index: 9, type: 0, version: 0
        )
        let session = MockHIDPPSession(
            features: [0x8110: feature],
            buttonSpyTable: Data([1, 2, 3] + Array(repeating: 0, count: 13))
        )
        let backend = MouseButtonSpy8110Backend(session: session, feature: feature)
        var events: [MouseControlEvent] = []
        backend.onEvent = { events.append($0) }
        let shortcut = KeyboardShortcut(keyCode: 1, modifiers: 0)

        try await backend.start(actions: [
            .logitechButton(2): .shortcut(shortcut)
        ])
        XCTAssertEqual(session.buttonSpyTable[2], 0)
        XCTAssertEqual(backend.controls.count, 3)

        session.emit(.init(
            deviceIndex: 0xFF, featureIndex: 9, functionID: 0,
            softwareID: 0, parameters: Data([0, 4])
        ))
        session.emit(.init(
            deviceIndex: 0xFF, featureIndex: 9, functionID: 0,
            softwareID: 0, parameters: Data([0, 0])
        ))
        await Task.yield()
        XCTAssertEqual(events.map(\.phase), [.down, .up])

        await backend.stop()
        XCTAssertEqual(session.buttonSpyTable[2], 3)
    }

    @MainActor
    func testCoordinatorDoesNotDivertOnboardConflictControls() async {
        let feature = HIDPP42Transport.Feature(
            identifier: 0x8110, index: 9, type: 0, version: 0
        )
        let session = MockHIDPPSession(
            features: [0x8110: feature],
            buttonSpyTable: Data([1, 2, 3] + Array(repeating: 0, count: 13))
        )
        let coordinator = MouseInputCoordinator(
            sessionFactory: { _ in session },
            emitter: ShortcutEmitter.State()
        )
        let profile = MouseProfile(
            name: "Runtime",
            mappings: [
                MouseMapping(
                    controlID: .logitechButton(2),
                    action: .shortcut(KeyboardShortcut(keyCode: 1, modifiers: 0))
                )
            ]
        )
        coordinator.prepareSession = { _ in
            .init(profile: profile, blockedControls: [.logitechButton(2)])
        }
        let mouse = ConnectedMouse(
            identifier: .init(
                vendorID: 0x046D, productID: 0xC08D, serialNumber: "test"
            ),
            name: "G502", manufacturer: "Logitech", isConnected: true
        )

        await coordinator.start(mouse: mouse, profile: profile)
        XCTAssertEqual(session.buttonSpyTable[2], 3)
        await coordinator.stop()
    }

    @MainActor
    func testClearOnboardShortcutsVerifiesReadBackAndCRC() async throws {
        let fixture = try makeWritableOnboardFixture()
        let feature = HIDPP42Transport.Feature(
            identifier: 0x8100, index: 6, type: 0, version: 0
        )
        let session = MockHIDPPSession(features: [0x8100: feature])
        session.onboardSectors = [
            0: fixture.snapshot.sectors[0],
            1: fixture.snapshot.sectors[1]
        ]
        let service = G502OnboardMemoryService(
            backupDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )

        let updated = try await service.clearShortcutAssignments(
            mouse: fixture.mouse, session: session, snapshot: fixture.snapshot
        )

        XCTAssertEqual(updated.sectors[1].subdata(in: 44 ..< 48), Data([0xFF, 0, 0, 0]))
        XCTAssertEqual(updated.sectors[1].subdata(in: 52 ..< 56), Data([0x80, 1, 0, 0x10]))
        XCTAssertTrue(G502OnboardMemoryService.sectorHasValidCRC(updated.sectors[1]))
        XCTAssertEqual(session.onboardSectors[1], updated.sectors[1])
    }

    @MainActor
    func testClearOnboardShortcutsRestoresBackupAfterReadBackFailure() async throws {
        let fixture = try makeWritableOnboardFixture()
        let feature = HIDPP42Transport.Feature(
            identifier: 0x8100, index: 6, type: 0, version: 0
        )
        let session = MockHIDPPSession(features: [0x8100: feature])
        session.onboardSectors = [
            0: fixture.snapshot.sectors[0],
            1: fixture.snapshot.sectors[1]
        ]
        session.corruptNextOnboardRead = true
        let service = G502OnboardMemoryService(
            backupDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )

        do {
            _ = try await service.clearShortcutAssignments(
                mouse: fixture.mouse, session: session, snapshot: fixture.snapshot
            )
            XCTFail("Expected read-back validation to fail")
        } catch {
            XCTAssertEqual(
                error as? G502OnboardMemoryService.OnboardMemoryError,
                .readBackFailed
            )
        }
        XCTAssertEqual(session.onboardSectors[1], fixture.snapshot.sectors[1])
    }

    @MainActor
    func testReprogrammableControlsDivertAndRestore() async throws {
        let feature = HIDPP42Transport.Feature(
            identifier: 0x1B04, index: 7, type: 0, version: 4
        )
        let session = MockHIDPPSession(features: [0x1B04: feature])
        session.reprogrammableControls = [
            Data([0x00, 0x53, 0, 0, 0x20, 0, 1, 1])
        ]
        let backend = ReprogrammableControls1B04Backend(
            session: session, feature: feature
        )
        var events: [MouseControlEvent] = []
        backend.onEvent = { events.append($0) }

        try await backend.start(actions: [.hidppControl(0x0053): .disabled])
        XCTAssertTrue(session.reportingByCID[0x0053] ?? false)
        session.emit(.init(
            deviceIndex: 0xFF, featureIndex: 7, functionID: 0,
            softwareID: 0, parameters: Data([0, 0x53, 0, 0])
        ))
        session.emit(.init(
            deviceIndex: 0xFF, featureIndex: 7, functionID: 0,
            softwareID: 0, parameters: Data([0, 0, 0, 0])
        ))
        await Task.yield()
        XCTAssertEqual(events.map(\.phase), [.down, .up])

        await backend.stop()
        XCTAssertFalse(session.reportingByCID[0x0053] ?? true)
    }

    private func makeWritableOnboardFixture() throws -> (
        mouse: ConnectedMouse,
        snapshot: G502OnboardProfileSnapshot
    ) {
        let identifier = HIDDeviceIdentifier(
            vendorID: 0x046D, productID: 0xC08D, serialNumber: "fixture"
        )
        let mouse = ConnectedMouse(
            identifier: identifier, name: "G502", manufacturer: "Logitech",
            isConnected: true
        )
        let descriptor = G502C08DOnboardProfileSnapshot.Descriptor(
            memoryModel: 1, profileCount: 5, romProfileCount: 1,
            profileFormat: 3, macroFormat: 1, buttonCount: 11,
            sectorCount: 16, sectorSize: 255, mechanicalLayout: 0x0A,
            variousInfo: 0x04
        )
        var directory = Data(repeating: 0xFF, count: 255)
        var profile = Data(repeating: 0xFF, count: 255)
        let shortcut = try XCTUnwrap(
            KeyboardShortcut(hidUsage: 0x08, hidModifiers: 0x01)
        )
        try G502OnboardMemoryService.setKeyboardBinding(
            in: &profile, index: 3, bank: .primary, shortcut: shortcut
        )
        G502OnboardMemoryService.setGenericMouseBinding(
            in: &profile, index: 5, bank: .primary, mouseButton: 4
        )
        G502OnboardMemoryService.updateCRC(&directory)
        G502OnboardMemoryService.updateCRC(&profile)
        let firmware = HIDPP42Transport.FirmwareInfo(
            kind: 0, name: "MPM", major: 0x17, minor: 0, build: 8
        )
        let snapshot = G502OnboardProfileSnapshot(
            deviceFingerprint: "\(identifier.vendorID):\(identifier.productID):fixture:G502",
            capturedAt: Date(), firmware: [firmware], onboardFeatureVersion: 0,
            deviceResetFeatureAvailable: false, descriptor: descriptor,
            mode: .onboard, activeProfileSector: 1, directoryIsValid: true,
            canProvisionFromROM: false,
            buttonAssignments: [
                .init(
                    index: 3, bank: .primary,
                    rawValue: Data([0x80, 0x02, 0x01, 0x08]),
                    description: "Keyboard"
                )
            ],
            sectorAddresses: [0, 1], sectors: [directory, profile], warnings: []
        )
        return (mouse, snapshot)
    }

}

private final class TestConfigurationStore: ConfigurationStoring {
    var configuration: AppConfiguration
    var saveCount = 0

    init(configuration: AppConfiguration) {
        self.configuration = configuration
    }

    func load() -> AppConfiguration {
        configuration
    }

    func save(_ configuration: AppConfiguration) throws {
        self.configuration = configuration
        saveCount += 1
    }
}

@MainActor
private final class MockHIDPPSession: HIDPPDeviceSessionProtocol {
    let deviceIndex: UInt8 = 0xFF
    var features: [UInt16: HIDPP42Transport.Feature]
    var buttonSpyTable: Data
    var buttonSpyCount = 3
    var reprogrammableControls: [Data] = []
    var reportingByCID: [UInt16: Bool] = [:]
    var firmware: [HIDPP42Transport.FirmwareInfo] = []
    var onboardSectors: [UInt16: Data] = [:]
    var corruptNextOnboardRead = false
    private var stagedSector: UInt16?
    private var stagedLength = 0
    private var stagedData = Data()
    private var notificationHandler: ((HIDPP42Transport.Packet) -> Void)?
    private var disconnectionHandler: (() -> Void)?

    init(
        features: [UInt16: HIDPP42Transport.Feature],
        buttonSpyTable: Data = Data()
    ) {
        self.features = features
        self.buttonSpyTable = buttonSpyTable
    }

    func feature(_ identifier: UInt16) async throws -> HIDPP42Transport.Feature? {
        features[identifier]
    }

    func firmwareInformation() async throws -> [HIDPP42Transport.FirmwareInfo] {
        firmware
    }

    func call(
        feature: HIDPP42Transport.Feature,
        function: UInt8,
        parameters: Data
    ) async throws -> HIDPP42Transport.Packet {
        let response: Data
        switch (feature.identifier, function) {
        case (0x8110, 0):
            response = Data([UInt8(buttonSpyCount)])
        case (0x8110, 3):
            response = buttonSpyTable
        case (0x8110, 4):
            buttonSpyTable = parameters
            response = Data()
        case (0x8110, _):
            response = Data()
        case (0x1B04, 0):
            response = Data([UInt8(reprogrammableControls.count)])
        case (0x1B04, 1):
            response = reprogrammableControls[Int(parameters[0])]
        case (0x1B04, 2):
            response = Data([parameters[0], parameters[1], 0, 0, 0])
        case (0x1B04, 3):
            let cid = UInt16(parameters[0]) << 8 | UInt16(parameters[1])
            reportingByCID[cid] = parameters[2] & 1 != 0
            response = parameters
        case (0x8100, 5):
            let sector = UInt16(parameters[0]) << 8 | UInt16(parameters[1])
            let offset = Int(UInt16(parameters[2]) << 8 | UInt16(parameters[3]))
            var bytes = Data(
                (onboardSectors[sector] ?? Data(repeating: 0, count: 255))[
                    offset ..< offset + 16
                ]
            )
            if corruptNextOnboardRead {
                corruptNextOnboardRead = false
                bytes[0] ^= 1
            }
            response = bytes
        case (0x8100, 6):
            stagedSector = UInt16(parameters[0]) << 8 | UInt16(parameters[1])
            stagedLength = Int(UInt16(parameters[4]) << 8 | UInt16(parameters[5]))
            stagedData = Data()
            response = Data()
        case (0x8100, 7):
            stagedData.append(parameters)
            response = Data()
        case (0x8100, 8):
            if let stagedSector {
                onboardSectors[stagedSector] = Data(stagedData.prefix(stagedLength))
            }
            response = Data()
        default:
            response = Data()
        }
        return .init(
            deviceIndex: deviceIndex,
            featureIndex: feature.index,
            functionID: function,
            parameters: response
        )
    }

    func setNotificationHandler(_ handler: ((HIDPP42Transport.Packet) -> Void)?) {
        notificationHandler = handler
    }

    func setDisconnectionHandler(_ handler: (() -> Void)?) {
        disconnectionHandler = handler
    }

    func emit(_ packet: HIDPP42Transport.Packet) {
        notificationHandler?(packet)
    }
}
