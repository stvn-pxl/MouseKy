import Foundation

@MainActor
protocol HIDPPDeviceSessionProtocol: AnyObject {
    var deviceIndex: UInt8 { get }
    func feature(_ identifier: UInt16) async throws -> HIDPP42Transport.Feature?
    func call(feature: HIDPP42Transport.Feature, function: UInt8, parameters: Data) async throws -> HIDPP42Transport.Packet
    func firmwareInformation() async throws -> [HIDPP42Transport.FirmwareInfo]
    func setNotificationHandler(_ handler: ((HIDPP42Transport.Packet) -> Void)?)
    func setDisconnectionHandler(_ handler: (() -> Void)?)
}

@MainActor
final class HIDPPDeviceSession: HIDPPDeviceSessionProtocol {
    static let logitechVendorID = 0x046D

    let deviceIndex: UInt8
    private let transport: HIDPP42Transport
    private var featureCache: [UInt16: HIDPP42Transport.Feature] = [:]

    init(transport: HIDPP42Transport, deviceIndex: UInt8) {
        self.transport = transport
        self.deviceIndex = deviceIndex
    }

    static func connect(mouse: ConnectedMouse) async throws -> HIDPPDeviceSession {
        guard mouse.identifier.vendorID == logitechVendorID,
              let interface = HIDPP42Transport.discoverInterface(
                  vendorID: mouse.identifier.vendorID,
                  productID: mouse.identifier.productID,
                  identifier: mouse.identifier
              )
        else { throw HIDPP42Transport.TransportError.unsupportedReport }

        let transport = try await HIDPP42Transport.connect(interface: interface)
        let candidates = [UInt8(0xFF)] + Array(UInt8(1) ... UInt8(6))
        for candidate in candidates {
            do {
                let hasButtonSpy =
                    try await transport.lookupFeature(0x8110, deviceIndex: candidate) != nil
                let hasReprogrammableControls =
                    try await transport.lookupFeature(0x1B04, deviceIndex: candidate) != nil
                if hasButtonSpy || hasReprogrammableControls {
                    return HIDPPDeviceSession(transport: transport, deviceIndex: candidate)
                }
            } catch {
                continue
            }
        }
        return HIDPPDeviceSession(transport: transport, deviceIndex: 0xFF)
    }

    func feature(_ identifier: UInt16) async throws -> HIDPP42Transport.Feature? {
        let cached = featureCache[identifier]
        if let cached { return cached }
        guard let feature = try await transport.lookupFeature(identifier, deviceIndex: deviceIndex)
        else { return nil }
        featureCache[identifier] = feature
        return feature
    }

    func call(
        feature: HIDPP42Transport.Feature,
        function: UInt8,
        parameters: Data = Data()
    ) async throws -> HIDPP42Transport.Packet {
        try await transport.request(.init(
            deviceIndex: deviceIndex,
            featureIndex: feature.index,
            functionID: function,
            parameters: parameters
        ))
    }

    func firmwareInformation() async throws -> [HIDPP42Transport.FirmwareInfo] {
        try await transport.firmwareInformation()
    }

    func setNotificationHandler(_ handler: ((HIDPP42Transport.Packet) -> Void)?) {
        transport.setNotificationHandler { [deviceIndex] packet in
            guard packet.deviceIndex == deviceIndex else { return }
            handler?(packet)
        }
    }

    func setDisconnectionHandler(_ handler: (() -> Void)?) {
        transport.setDisconnectionHandler(handler)
    }
}
