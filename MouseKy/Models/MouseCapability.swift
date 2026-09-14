import Foundation

enum MouseControlID: Hashable, Codable, Identifiable {
    case hidButton(Int)
    case logitechButton(Int)
    case hidppControl(UInt16)

    var id: String {
        switch self {
        case let .hidButton(value): "hid:\(value)"
        case let .logitechButton(value): "logitech-button:\(value)"
        case let .hidppControl(value): String(format: "hidpp-control:%04X", value)
        }
    }

    var legacyButtonNumber: Int? {
        switch self {
        case let .hidButton(value), let .logitechButton(value): value
        case .hidppControl: nil
        }
    }
}

enum MouseButtonAction: Equatable, Codable {
    case passthrough
    case shortcut(KeyboardShortcut)
    case disabled
}

struct MouseControl: Identifiable, Equatable {
    let id: MouseControlID
    let name: String
    let source: String
    let isPrimary: Bool
    let isControllable: Bool
}

enum MouseControlPhase: Equatable {
    case down
    case up
}

struct MouseControlEvent: Equatable {
    let controlID: MouseControlID
    let phase: MouseControlPhase
    let timestamp: Date
}

enum LogitechBackendKind: String, Equatable {
    case buttonSpy8110 = "HID++ 0x8110"
    case reprogrammableControls1B04 = "HID++ 0x1B04"
}

enum MouseBackendStatus: Equatable {
    case idle
    case probing
    case active(LogitechBackendKind)
    case unsupported(String)
    case blocked(String)
    case failed(String)

    var displayText: String {
        switch self {
        case .idle: "Inaktiv"
        case .probing: "Logitech-Funktionen werden geprüft …"
        case let .active(kind): "Aktiv über \(kind.rawValue)"
        case let .unsupported(reason): "Nicht unterstützt: \(reason)"
        case let .blocked(reason): "Blockiert: \(reason)"
        case let .failed(reason): "Fehler: \(reason)"
        }
    }
}

struct MouseDeviceCapabilities: Equatable {
    let backend: LogitechBackendKind?
    let controls: [MouseControl]
    let connectionDescription: String
}
