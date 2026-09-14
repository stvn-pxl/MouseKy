import Foundation

@MainActor
protocol LogitechInputBackend: AnyObject {
    var kind: LogitechBackendKind { get }
    var controls: [MouseControl] { get }
    var onEvent: ((MouseControlEvent) -> Void)? { get set }

    func start(actions: [MouseControlID: MouseButtonAction]) async throws
    func update(actions: [MouseControlID: MouseButtonAction]) async throws
    func stop() async
}

enum LogitechInputBackendError: LocalizedError, Equatable {
    case malformedResponse
    case verificationFailed
    case unsupported

    var errorDescription: String? {
        switch self {
        case .malformedResponse: "Das Logitech-Gerät lieferte eine ungültige HID++-Antwort."
        case .verificationFailed: "Die temporäre Button-Konfiguration konnte nicht verifiziert werden."
        case .unsupported: "Das Gerät bietet kein unterstütztes Logitech-Button-Feature."
        }
    }
}

@MainActor
final class MouseButtonSpy8110Backend: LogitechInputBackend {
    let kind: LogitechBackendKind = .buttonSpy8110
    private(set) var controls: [MouseControl] = []
    var onEvent: ((MouseControlEvent) -> Void)?

    private let session: HIDPPDeviceSessionProtocol
    private let feature: HIDPP42Transport.Feature
    private var originalTable = Data()
    private var appliedTable = Data()
    private var previousMask: UInt16 = 0
    private var isStarted = false

    init(session: HIDPPDeviceSessionProtocol, feature: HIDPP42Transport.Feature) {
        self.session = session
        self.feature = feature
    }

    func start(actions: [MouseControlID: MouseButtonAction]) async throws {
        let countResponse = try await session.call(
            feature: feature, function: 0, parameters: Data()
        )
        guard let rawCount = countResponse.parameters.first else {
            throw LogitechInputBackendError.malformedResponse
        }
        let count = min(Int(rawCount), 16)
        let mappingResponse = try await session.call(
            feature: feature, function: 3, parameters: Data()
        )
        guard mappingResponse.parameters.count >= count else {
            throw LogitechInputBackendError.malformedResponse
        }
        originalTable = Data(mappingResponse.parameters.prefix(16))
        while originalTable.count < 16 { originalTable.append(0) }
        controls = (0 ..< count).map { index in
            MouseControl(
                id: .logitechButton(index),
                name: Self.buttonName(index),
                source: kind.rawValue,
                isPrimary: index == 0 || index == 1,
                isControllable: index > 1
            )
        }
        session.setNotificationHandler { [weak self] packet in
            Task { @MainActor [weak self] in self?.handle(packet) }
        }
        session.setDisconnectionHandler { [weak self] in
            Task { @MainActor [weak self] in self?.handleDisconnect() }
        }
        appliedTable = originalTable
        if actions.values.contains(where: { $0 != .passthrough }) {
            try await update(actions: actions)
        }
        _ = try await session.call(feature: feature, function: 1, parameters: Data())
        isStarted = true
    }

    func update(actions: [MouseControlID: MouseButtonAction]) async throws {
        guard !originalTable.isEmpty else { return }
        var table = originalTable
        for control in controls where control.isControllable {
            if actions[control.id, default: .passthrough] != .passthrough,
               case let .logitechButton(index) = control.id,
               index < table.count {
                table[index] = 0
            }
        }
        guard table != appliedTable else { return }
        _ = try await session.call(feature: feature, function: 4, parameters: table)
        appliedTable = table
        let readBack = try await session.call(feature: feature, function: 3, parameters: Data())
        guard Data(readBack.parameters.prefix(controls.count)) ==
                Data(table.prefix(controls.count)) else {
            if (try? await session.call(
                feature: feature, function: 4, parameters: originalTable
            )) != nil {
                appliedTable = originalTable
            }
            throw LogitechInputBackendError.verificationFailed
        }
    }

    func stop() async {
        session.setNotificationHandler(nil)
        session.setDisconnectionHandler(nil)
        if isStarted {
            _ = try? await session.call(feature: feature, function: 2, parameters: Data())
        }
        if !originalTable.isEmpty, appliedTable != originalTable {
            _ = try? await session.call(feature: feature, function: 4, parameters: originalTable)
        }
        previousMask = 0
        isStarted = false
    }

    private func handle(_ packet: HIDPP42Transport.Packet) {
        guard packet.featureIndex == feature.index, packet.functionID == 0,
              packet.parameters.count >= 2 else { return }
        let mask = UInt16(packet.parameters[0]) << 8 | UInt16(packet.parameters[1])
        let changed = mask ^ previousMask
        for index in controls.indices where changed & (UInt16(1) << UInt16(index)) != 0 {
            onEvent?(.init(
                controlID: .logitechButton(index),
                phase: mask & (UInt16(1) << UInt16(index)) == 0 ? .up : .down,
                timestamp: Date()
            ))
        }
        previousMask = mask
    }

    private func handleDisconnect() {
        for index in controls.indices where previousMask & (UInt16(1) << UInt16(index)) != 0 {
            onEvent?(.init(
                controlID: .logitechButton(index), phase: .up, timestamp: Date()
            ))
        }
        previousMask = 0
        isStarted = false
    }

    private static func buttonName(_ index: Int) -> String {
        let names = [
            "Linksklick", "Rechtsklick", "Mittelklick", "Zurück", "Vor",
            "DPI-Umschaltung", "DPI herunter", "DPI hoch", "Batteriestatus",
            "Rad rechts", "Rad links"
        ]
        return names.indices.contains(index) ? names[index] : "Taste \(index + 1)"
    }
}

@MainActor
final class ReprogrammableControls1B04Backend: LogitechInputBackend {
    let kind: LogitechBackendKind = .reprogrammableControls1B04
    private(set) var controls: [MouseControl] = []
    var onEvent: ((MouseControlEvent) -> Void)?

    private struct ReportingState {
        let diverted: Bool
        let remapHigh: UInt8
        let remapLow: UInt8
    }

    private let session: HIDPPDeviceSessionProtocol
    private let feature: HIDPP42Transport.Feature
    private var originalStates: [UInt16: ReportingState] = [:]
    private var pressed = Set<UInt16>()

    init(session: HIDPPDeviceSessionProtocol, feature: HIDPP42Transport.Feature) {
        self.session = session
        self.feature = feature
    }

    func start(actions: [MouseControlID: MouseButtonAction]) async throws {
        let countResponse = try await session.call(
            feature: feature, function: 0, parameters: Data()
        )
        guard let rawCount = countResponse.parameters.first else {
            throw LogitechInputBackendError.malformedResponse
        }
        var discovered: [MouseControl] = []
        for index in 0 ..< Int(rawCount) {
            let response = try await session.call(
                feature: feature, function: 1, parameters: Data([UInt8(index)])
            )
            guard response.parameters.count >= 8 else {
                throw LogitechInputBackendError.malformedResponse
            }
            let cid = UInt16(response.parameters[0]) << 8 | UInt16(response.parameters[1])
            let flags = response.parameters[4]
            let isPrimary = cid == 0x0050 || cid == 0x0051
            discovered.append(.init(
                id: .hidppControl(cid),
                name: String(format: "Control 0x%04X", cid),
                source: kind.rawValue,
                isPrimary: isPrimary,
                isControllable: flags & 0x20 != 0 && !isPrimary
            ))
            let state = try await session.call(
                feature: feature,
                function: 2,
                parameters: Data([UInt8(cid >> 8), UInt8(cid & 0xFF)])
            )
            if state.parameters.count >= 5 {
                originalStates[cid] = ReportingState(
                    diverted: state.parameters[2] & 0x01 != 0,
                    remapHigh: state.parameters[3],
                    remapLow: state.parameters[4]
                )
            }
        }
        controls = discovered
        session.setNotificationHandler { [weak self] packet in
            Task { @MainActor [weak self] in self?.handle(packet) }
        }
        session.setDisconnectionHandler { [weak self] in
            Task { @MainActor [weak self] in self?.releasePressedControls() }
        }
        try await update(actions: actions)
    }

    func update(actions: [MouseControlID: MouseButtonAction]) async throws {
        for control in controls where control.isControllable {
            guard case let .hidppControl(cid) = control.id else { continue }
            let shouldDivert = actions[control.id, default: .passthrough] != .passthrough
            let original = originalStates[cid]
            try await setReporting(
                cid: cid,
                diverted: shouldDivert || original?.diverted == true,
                remap: shouldDivert ? nil : original.map { ($0.remapHigh, $0.remapLow) }
            )
        }
    }

    func stop() async {
        session.setNotificationHandler(nil)
        session.setDisconnectionHandler(nil)
        releasePressedControls()
        for (cid, state) in originalStates {
            try? await setReporting(
                cid: cid,
                diverted: state.diverted,
                remap: (state.remapHigh, state.remapLow)
            )
        }
    }

    private func setReporting(
        cid: UInt16,
        diverted: Bool,
        remap: (UInt8, UInt8)?
    ) async throws {
        let flags: UInt8 = diverted ? 0x03 : 0x02
        let target = remap ?? (0, 0)
        _ = try await session.call(
            feature: feature,
            function: 3,
            parameters: Data([
                UInt8(cid >> 8), UInt8(cid & 0xFF), flags, target.0, target.1
            ])
        )
    }

    private func handle(_ packet: HIDPP42Transport.Packet) {
        guard packet.featureIndex == feature.index, packet.functionID == 0 else { return }
        var current = Set<UInt16>()
        for offset in stride(from: 0, to: min(packet.parameters.count, 8), by: 2) {
            guard offset + 1 < packet.parameters.count else { break }
            let cid = UInt16(packet.parameters[offset]) << 8 |
                UInt16(packet.parameters[offset + 1])
            if cid != 0 { current.insert(cid) }
        }
        for cid in current.subtracting(pressed) {
            onEvent?(.init(controlID: .hidppControl(cid), phase: .down, timestamp: Date()))
        }
        for cid in pressed.subtracting(current) {
            onEvent?(.init(controlID: .hidppControl(cid), phase: .up, timestamp: Date()))
        }
        pressed = current
    }

    private func releasePressedControls() {
        for cid in pressed {
            onEvent?(.init(controlID: .hidppControl(cid), phase: .up, timestamp: Date()))
        }
        pressed.removeAll()
    }
}
