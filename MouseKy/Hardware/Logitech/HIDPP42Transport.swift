import Foundation
import IOKit.hid
import os

private actor HIDPPRequestGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// HID++ 2.0/4.2 transport with serialized asynchronous requests.
/// Responses are correlated by a random, non-zero software ID, so unsolicited
/// reports can never complete an in-flight operation.
final class HIDPP42Transport: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.local.MouseKy", category: "HIDPP")
    static let rootFeatureIndex: UInt8 = 0x00
    static let rootGetFeatureFunction: UInt8 = 0x00
    static let shortReportID: UInt8 = 0x10
    static let longReportID: UInt8 = 0x11
    static let shortReportLength = 7
    static let longReportPayloadLength = 19
    static let longReportLength = 20

    enum TransportError: LocalizedError, Equatable {
        case unsupportedReport, malformedResponse, unexpectedResponse, disconnected, busy, timedOut
        case ioHIDError(IOReturn)
        case deviceNotOpen(IOReturn)
        case deviceError(UInt8)

        var errorDescription: String? {
            switch self {
            case .unsupportedReport: "The device does not expose the HID++ long report required for read-only discovery."
            case .malformedResponse: "The HID++ response was malformed."
            case .unexpectedResponse: "The HID++ response did not match the submitted read-only request."
            case .disconnected: "The HID++ device disconnected while the request was pending."
            case .busy: "Another HID++ request is already in progress."
            case .timedOut: "The HID++ device did not answer before the request timed out."
            case let .ioHIDError(result): Self.describeIOHIDFailure(result)
            case let .deviceNotOpen(result): Self.describeIOHIDFailure(result)
            case let .deviceError(code): "The Logitech device rejected the HID++ request (error 0x\(String(format: "%02X", code)))."
            }
        }

        private static func describeIOHIDFailure(_ result: IOReturn) -> String {
            switch result {
            case kIOReturnNotOpen:
                """
                The Logitech HID++ interface is not open (IOReturn \(result)). \
                Grant Input Monitoring to MouseKy in System Settings, quit Logitech G HUB if it holds the device, then choose Reload.
                """
            case kIOReturnNotPermitted:
                """
                macOS denied access to the Logitech HID++ interface (IOReturn \(result)). \
                Enable Input Monitoring for MouseKy, then restart the app and choose Reload.
                """
            default:
                "IOHID rejected the read-only HID++ query (IOReturn \(result))."
            }
        }
    }

    struct Packet: Equatable {
        let deviceIndex: UInt8
        let featureIndex: UInt8
        let functionID: UInt8
        let softwareID: UInt8
        let parameters: Data

        init(deviceIndex: UInt8, featureIndex: UInt8, functionID: UInt8, softwareID: UInt8 = 0x01, parameters: Data = Data()) {
            self.deviceIndex = deviceIndex
            self.featureIndex = featureIndex
            self.functionID = functionID
            self.softwareID = softwareID
            self.parameters = parameters
        }

        var preferredReportID: UInt8 {
            parameters.count <= 3 ? HIDPP42Transport.shortReportID : HIDPP42Transport.longReportID
        }

        /// Numbered reports include the report ID in the IOKit buffer. The same
        /// ID is also passed separately to IOHIDDeviceSetReport.
        func reportData(reportID: UInt8? = nil) throws -> Data {
            guard functionID <= 0x0F, softwareID <= 0x0F, parameters.count <= 16 else {
                throw TransportError.unsupportedReport
            }
            let reportID = reportID ?? preferredReportID
            let length: Int
            switch reportID {
            case HIDPP42Transport.shortReportID where parameters.count <= 3:
                length = HIDPP42Transport.shortReportLength
            case HIDPP42Transport.longReportID:
                length = HIDPP42Transport.longReportLength
            default:
                throw TransportError.unsupportedReport
            }
            var payload = Data([reportID, deviceIndex, featureIndex, (functionID << 4) | (softwareID & 0x0F)])
            payload.append(parameters)
            payload.append(contentsOf: repeatElement(0, count: length - payload.count))
            return payload
        }

        func longReportPayload() throws -> Data {
            try reportData(reportID: HIDPP42Transport.longReportID)
        }

        static func decode(reportID: UInt8, report: Data) throws -> Packet {
            let expectedLength: Int
            switch reportID {
            case HIDPP42Transport.shortReportID: expectedLength = HIDPP42Transport.shortReportLength
            case HIDPP42Transport.longReportID: expectedLength = HIDPP42Transport.longReportLength
            default: throw TransportError.unsupportedReport
            }
            let payload: Data
            if report.count == expectedLength, report.first == reportID {
                payload = Data(report.dropFirst())
            } else if report.count == expectedLength - 1 {
                payload = report
            } else {
                throw TransportError.malformedResponse
            }
            guard payload.count >= 3 else { throw TransportError.malformedResponse }
            return Packet(
                deviceIndex: payload[0], featureIndex: payload[1],
                functionID: payload[2] >> 4, softwareID: payload[2] & 0x0F,
                parameters: Data(payload.dropFirst(3))
            )
        }

        static func decodeLongResponse(_ report: Data) throws -> Packet {
            try decode(reportID: HIDPP42Transport.longReportID, report: report)
        }
    }

    struct Feature: Hashable {
        let identifier: UInt16
        let index: UInt8
        let type: UInt8
        let version: UInt8
    }

    struct FirmwareInfo: Codable, Equatable, Hashable {
        let kind: UInt8
        let name: String
        let major: UInt8
        let minor: UInt8
        let build: UInt16

        var displayName: String {
            let version = String(format: "%02X.%02X.B%04X", major, minor, build)
            return name.isEmpty ? version : "\(name) \(version)"
        }
    }

    struct Interface {
        let manager: IOHIDManager
        let device: IOHIDDevice
        let vendorID: Int
        let productID: Int
        let productName: String
        let usagePage: Int
        let maxInputReportSize: Int
        let maxOutputReportSize: Int
    }

    private let device: IOHIDDevice
    private let manager: IOHIDManager?
    private let deviceIndex: UInt8
    private let lock = NSLock()
    private var pending: CheckedContinuation<Packet, Error>?
    private var expected: Packet?
    private let inputBufferCapacity = 64
    private let inputBuffer: UnsafeMutablePointer<UInt8>
    private var isDisconnected = false
    private var isDeviceOpen = false
    private var nextSoftwareID = UInt8.random(in: 1 ... 15)
    private var notificationHandler: ((Packet) -> Void)?
    private var disconnectionHandler: (() -> Void)?
    private let requestGate = HIDPPRequestGate()

    var addressedDeviceIndex: UInt8 { deviceIndex }

    init(device: IOHIDDevice, manager: IOHIDManager? = nil, deviceIndex: UInt8 = 0xFF) throws {
        self.device = device
        self.manager = manager
        self.deviceIndex = deviceIndex
        inputBuffer = .allocate(capacity: inputBufferCapacity)
        inputBuffer.initialize(repeating: 0, count: inputBufferCapacity)
        try openDevice()
        IOHIDDeviceRegisterInputReportCallback(
            device, inputBuffer, inputBufferCapacity, Self.inputReportReceived,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDDeviceRegisterRemovalCallback(
            device, Self.deviceRemoved, Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    convenience init(interface: Interface, deviceIndex: UInt8 = 0xFF) throws {
        try self.init(device: interface.device, manager: interface.manager, deviceIndex: deviceIndex)
    }

    static func connect(interface: Interface, deviceIndex: UInt8 = 0xFF) async throws -> HIDPP42Transport {
        try HIDPP42Transport(interface: interface, deviceIndex: deviceIndex)
    }

    deinit {
        closeDevice()
        inputBuffer.deinitialize(count: inputBufferCapacity)
        inputBuffer.deallocate()
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        failPending(with: TransportError.disconnected)
    }

    private func closeDevice() {
        guard isDeviceOpen else { return }
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        isDeviceOpen = false
    }

    /// Finds only a vendor interface with both HID++ short and long report IDs.
    /// It never assumes the regular mouse interface carries HID++.
    static func discoverInterface(
        vendorID: Int,
        productID: Int,
        identifier: HIDDeviceIdentifier? = nil
    ) -> Interface? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [[
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID,
        ]]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return nil
        }
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        let selected = devices.compactMap { device -> (Int, Interface)? in
            let serial = IOHIDDeviceGetProperty(
                device, kIOHIDSerialNumberKey as CFString
            ) as? String
            let location = (
                IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber
            )?.intValue
            if let identifier {
                if let expectedSerial = identifier.serialNumber, !expectedSerial.isEmpty {
                    guard serial == expectedSerial else { return nil }
                } else if let expectedLocation = identifier.locationID {
                    guard location == expectedLocation else { return nil }
                }
            }
            guard let descriptor = IOHIDDeviceGetProperty(device, (kIOHIDReportDescriptorKey as NSString) as CFString) as? Data,
                  descriptorContainsHIDPPReports(descriptor)
            else { return nil }
            let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Logitech HID++"
            let usagePage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? 0
            let maxInput = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 0
            let maxOutput = (IOHIDDeviceGetProperty(device, kIOHIDMaxOutputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 0
            guard maxInput >= longReportLength, maxOutput >= longReportLength else { return nil }
            let rank = interfaceRank(usagePage: usagePage, productName: name)
            return (rank, Interface(
                manager: manager, device: device, vendorID: vendorID, productID: productID,
                productName: name, usagePage: usagePage,
                maxInputReportSize: maxInput, maxOutputReportSize: maxOutput
            ))
        }
        .sorted { $0.0 > $1.0 }
        .first?.1
        if selected == nil {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        return selected
    }

    private static func interfaceRank(usagePage: Int, productName: String) -> Int {
        var rank = 0
        if usagePage == 0xFF00 || usagePage == 0xFF43 { rank += 100 }
        if productName.localizedCaseInsensitiveContains("HID++") { rank += 50 }
        return rank
    }

    static func descriptorContainsHIDPPReports(_ descriptor: Data) -> Bool {
        let bytes = [UInt8](descriptor)
        var reportIDs = Set<UInt8>()
        var index = 0
        while index < bytes.count {
            let prefix = bytes[index]
            if prefix == 0xFE {
                guard index + 2 < bytes.count else { return false }
                index += 3 + Int(bytes[index + 1])
                continue
            }
            let code = Int(prefix & 3)
            let size = code == 3 ? 4 : code
            guard index + size < bytes.count else { return false }
            if prefix == 0x85 { reportIDs.insert(bytes[index + 1]) }
            index += 1 + size
        }
        return reportIDs.contains(0x10) && reportIDs.contains(longReportID)
    }

    func featureLookupRequest(for featureID: UInt16, deviceIndex: UInt8? = nil) -> Packet {
        Packet(deviceIndex: deviceIndex ?? self.deviceIndex, featureIndex: Self.rootFeatureIndex, functionID: Self.rootGetFeatureFunction, parameters: Data([UInt8(featureID >> 8), UInt8(featureID & 0xFF)]))
    }

    func lookupFeature(_ featureID: UInt16, deviceIndex: UInt8? = nil) async throws -> Feature? {
        let response = try await requestResponse(
            featureLookupRequest(for: featureID, deviceIndex: deviceIndex)
        )
        guard response.featureIndex == Self.rootFeatureIndex,
              response.functionID == Self.rootGetFeatureFunction,
              response.parameters.count >= 3
        else { throw TransportError.unexpectedResponse }
        let index = response.parameters[0]
        return index == 0 ? nil : Feature(
            identifier: featureID, index: index,
            type: response.parameters[1], version: response.parameters[2]
        )
    }

    func firmwareInformation() async throws -> [FirmwareInfo] {
        guard let feature = try await lookupFeature(0x0003) else { return [] }
        let countResponse = try await request(Packet(
            deviceIndex: deviceIndex, featureIndex: feature.index, functionID: 0
        ))
        guard let count = countResponse.parameters.first, count <= 8 else {
            throw TransportError.malformedResponse
        }
        var result: [FirmwareInfo] = []
        for index in 0 ..< count {
            let response = try await request(Packet(
                deviceIndex: deviceIndex, featureIndex: feature.index,
                functionID: 1, parameters: Data([index])
            ))
            guard response.parameters.count >= 8 else { throw TransportError.malformedResponse }
            let bytes = response.parameters
            let name = String(bytes: bytes[1 ... 3], encoding: .ascii)?
                .trimmingCharacters(in: .controlCharacters.union(.whitespaces)) ?? ""
            result.append(FirmwareInfo(
                kind: bytes[0] & 0x0F,
                name: name,
                major: bytes[4],
                minor: bytes[5],
                build: UInt16(bytes[6]) << 8 | UInt16(bytes[7])
            ))
        }
        return result
    }

    func readOnboardProfile(_ packet: Packet, onboardFeatureIndex: UInt8) async throws -> Packet {
        let isGetter = packet.parameters.isEmpty && [0x00, 0x02, 0x04].contains(packet.functionID)
        let isMemoryRead = packet.functionID == 0x05 && packet.parameters.count == 4
        guard packet.featureIndex == onboardFeatureIndex, isGetter || isMemoryRead else {
            throw TransportError.unexpectedResponse
        }
        return try await requestResponse(packet)
    }

    func request(_ packet: Packet) async throws -> Packet {
        try await requestResponse(packet)
    }

    func setNotificationHandler(_ handler: ((Packet) -> Void)?) {
        lock.lock()
        notificationHandler = handler
        lock.unlock()
    }

    func setDisconnectionHandler(_ handler: (() -> Void)?) {
        lock.lock()
        disconnectionHandler = handler
        lock.unlock()
    }

    /// Restricted escape hatch used exclusively by the revision-gated service,
    /// after an explicit UI confirmation.
    func writeVerifiedProfilePacket(_ packet: Packet) async throws -> Packet {
        try await requestResponse(packet)
    }

    private func requestResponse(_ original: Packet, timeout: TimeInterval = 2) async throws -> Packet {
        await requestGate.acquire()
        do {
            let response = try await performRequestResponse(original, timeout: timeout)
            await requestGate.release()
            return response
        } catch {
            await requestGate.release()
            throw error
        }
    }

    private func performRequestResponse(_ original: Packet, timeout: TimeInterval) async throws -> Packet {
        let request = Packet(
            deviceIndex: original.deviceIndex, featureIndex: original.featureIndex,
            functionID: original.functionID, softwareID: allocateSoftwareID(),
            parameters: original.parameters
        )
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !isDisconnected else {
                lock.unlock()
                continuation.resume(throwing: TransportError.disconnected)
                return
            }
            guard pending == nil else {
                lock.unlock()
                continuation.resume(throwing: TransportError.busy)
                return
            }
            pending = continuation
            expected = request
            lock.unlock()
            do {
                try submitReport(request.reportData())
            } catch {
                failPending(with: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.failPending(with: TransportError.timedOut, matching: request.softwareID)
            }
        }
    }

    private func allocateSoftwareID() -> UInt8 {
        lock.lock()
        defer { lock.unlock() }
        nextSoftwareID = nextSoftwareID == 15 ? 1 : nextSoftwareID + 1
        return nextSoftwareID
    }

    private func openDevice() throws {
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            Self.logger.error("IOHIDDeviceOpen failed with IOReturn \(result, privacy: .public)")
            throw TransportError.deviceNotOpen(result)
        }
        isDeviceOpen = true
    }

    private func submitReport(_ report: Data) throws {
        guard isDeviceOpen else { throw TransportError.deviceNotOpen(kIOReturnNotOpen) }
        guard let reportID = report.first,
              (reportID == Self.shortReportID && report.count == Self.shortReportLength) ||
              (reportID == Self.longReportID && report.count == Self.longReportLength)
        else { throw TransportError.unsupportedReport }
        Self.logger.debug("TX report=0x\(String(format: "%02X", reportID), privacy: .public) bytes=\(Self.hex(report), privacy: .public)")
        let result = report.withUnsafeBytes { bytes in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(reportID),
                bytes.bindMemory(to: UInt8.self).baseAddress!,
                report.count
            )
        }
        guard result == kIOReturnSuccess else {
            Self.logger.error("IOHIDDeviceSetReport failed with IOReturn \(result, privacy: .public)")
            throw TransportError.ioHIDError(result)
        }
    }

    private static let inputReportReceived: IOHIDReportCallback = { context, _, _, _, reportID, report, length in
        guard let context, reportID == shortReportID || reportID == longReportID else { return }
        let transport = Unmanaged<HIDPP42Transport>.fromOpaque(context).takeUnretainedValue()
        transport.receive(reportID: UInt8(reportID), report: Data(bytes: report, count: length))
    }

    private static let deviceRemoved: IOHIDCallback = { context, _, _ in
        guard let context else { return }
        Unmanaged<HIDPP42Transport>.fromOpaque(context).takeUnretainedValue().markDisconnected()
    }

    private func receive(reportID: UInt8, report: Data) {
        Self.logger.debug("RX report=0x\(String(format: "%02X", reportID), privacy: .public) bytes=\(Self.hex(report), privacy: .public)")
        guard let packet = try? Packet.decode(reportID: reportID, report: report) else {
            Self.logger.error("Discarding malformed HID++ report")
            return
        }
        if let error = decodeDeviceError(packet) {
            failPending(with: error.error, matching: error.softwareID)
            return
        }
        lock.lock()
        guard let expected, let continuation = pending,
              packet.softwareID == expected.softwareID,
              packet.deviceIndex == expected.deviceIndex,
              packet.featureIndex == expected.featureIndex,
              packet.functionID == expected.functionID
        else {
            let handler = notificationHandler
            lock.unlock()
            if packet.softwareID == 0 {
                handler?(packet)
            }
            return
        }
        pending = nil
        self.expected = nil
        lock.unlock()
        continuation.resume(returning: packet)
    }

    private func decodeDeviceError(_ packet: Packet) -> (softwareID: UInt8, error: TransportError)? {
        lock.lock()
        defer { lock.unlock() }
        guard let expected, let code = Self.deviceErrorCode(packet: packet, expected: expected)
        else { return nil }
        return (expected.softwareID, .deviceError(code))
    }

    static func deviceErrorCode(packet: Packet, expected: Packet) -> UInt8? {
        guard packet.deviceIndex == expected.deviceIndex,
              packet.featureIndex == 0xFF || packet.featureIndex == 0x8F,
              packet.functionID == expected.featureIndex >> 4,
              packet.softwareID == expected.featureIndex & 0x0F,
              packet.parameters.count >= 2,
              packet.parameters[0] == (expected.functionID << 4) | expected.softwareID
        else { return nil }
        return packet.parameters[1]
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func failPending(with error: Error, matching softwareID: UInt8? = nil) {
        lock.lock()
        guard let continuation = pending,
              softwareID == nil || expected?.softwareID == softwareID
        else { lock.unlock(); return }
        pending = nil
        expected = nil
        lock.unlock()
        continuation.resume(throwing: error)
    }

    func markDisconnected() {
        lock.lock()
        isDisconnected = true
        let handler = disconnectionHandler
        lock.unlock()
        failPending(with: TransportError.disconnected)
        handler?()
    }

    func decodeFeatureLookupResponse(_ report: Data, requestedFeatureID: UInt16) throws -> Feature? {
        let packet = try Packet.decodeLongResponse(report)
        guard packet.deviceIndex == deviceIndex || deviceIndex == 0xFF, packet.featureIndex == Self.rootFeatureIndex, packet.functionID == Self.rootGetFeatureFunction, packet.parameters.count >= 2 else {
            throw TransportError.unexpectedResponse
        }
        let index = packet.parameters[0]
        guard index != 0 else { return nil }
        return Feature(
            identifier: requestedFeatureID, index: index,
            type: packet.parameters[1],
            version: packet.parameters.count >= 3 ? packet.parameters[2] : 0
        )
    }
}
