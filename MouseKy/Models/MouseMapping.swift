import Foundation
import AppKit
import Carbon.HIToolbox

struct KeyboardShortcut: Codable, Equatable, Hashable {
    let keyCode: UInt16
    let modifiers: UInt64

    var displayName: String {
        let modifierText = [
            (NSEvent.ModifierFlags.command.rawValue, "⌘"),
            (NSEvent.ModifierFlags.option.rawValue, "⌥"),
            (NSEvent.ModifierFlags.control.rawValue, "⌃"),
            (NSEvent.ModifierFlags.shift.rawValue, "⇧")
        ].compactMap { modifiers & UInt64($0.0) != 0 ? $0.1 : nil }.joined()
        return modifierText + KeyName.name(for: keyCode)
    }

    init(keyCode: UInt16, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(hidUsage: UInt8, hidModifiers: UInt8) {
        guard let keyCode = Self.keyCodeByHIDUsage[hidUsage] else { return nil }
        var modifiers: UInt64 = 0
        if hidModifiers & 0x11 != 0 { modifiers |= UInt64(NSEvent.ModifierFlags.control.rawValue) }
        if hidModifiers & 0x22 != 0 { modifiers |= UInt64(NSEvent.ModifierFlags.shift.rawValue) }
        if hidModifiers & 0x44 != 0 { modifiers |= UInt64(NSEvent.ModifierFlags.option.rawValue) }
        if hidModifiers & 0x88 != 0 { modifiers |= UInt64(NSEvent.ModifierFlags.command.rawValue) }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }

    var hidEncoding: (usage: UInt8, modifiers: UInt8)? {
        guard let usage = Self.hidUsageByKeyCode[keyCode] else { return nil }
        var hidModifiers: UInt8 = 0
        if modifiers & UInt64(NSEvent.ModifierFlags.control.rawValue) != 0 { hidModifiers |= 0x01 }
        if modifiers & UInt64(NSEvent.ModifierFlags.shift.rawValue) != 0 { hidModifiers |= 0x02 }
        if modifiers & UInt64(NSEvent.ModifierFlags.option.rawValue) != 0 { hidModifiers |= 0x04 }
        if modifiers & UInt64(NSEvent.ModifierFlags.command.rawValue) != 0 { hidModifiers |= 0x08 }
        return (usage, hidModifiers)
    }

    private static let hidUsageByKeyCode: [UInt16: UInt8] = [
        UInt16(kVK_ANSI_A): 0x04, UInt16(kVK_ANSI_B): 0x05, UInt16(kVK_ANSI_C): 0x06,
        UInt16(kVK_ANSI_D): 0x07, UInt16(kVK_ANSI_E): 0x08, UInt16(kVK_ANSI_F): 0x09,
        UInt16(kVK_ANSI_G): 0x0A, UInt16(kVK_ANSI_H): 0x0B, UInt16(kVK_ANSI_I): 0x0C,
        UInt16(kVK_ANSI_J): 0x0D, UInt16(kVK_ANSI_K): 0x0E, UInt16(kVK_ANSI_L): 0x0F,
        UInt16(kVK_ANSI_M): 0x10, UInt16(kVK_ANSI_N): 0x11, UInt16(kVK_ANSI_O): 0x12,
        UInt16(kVK_ANSI_P): 0x13, UInt16(kVK_ANSI_Q): 0x14, UInt16(kVK_ANSI_R): 0x15,
        UInt16(kVK_ANSI_S): 0x16, UInt16(kVK_ANSI_T): 0x17, UInt16(kVK_ANSI_U): 0x18,
        UInt16(kVK_ANSI_V): 0x19, UInt16(kVK_ANSI_W): 0x1A, UInt16(kVK_ANSI_X): 0x1B,
        UInt16(kVK_ANSI_Y): 0x1C, UInt16(kVK_ANSI_Z): 0x1D,
        UInt16(kVK_ANSI_1): 0x1E, UInt16(kVK_ANSI_2): 0x1F, UInt16(kVK_ANSI_3): 0x20,
        UInt16(kVK_ANSI_4): 0x21, UInt16(kVK_ANSI_5): 0x22, UInt16(kVK_ANSI_6): 0x23,
        UInt16(kVK_ANSI_7): 0x24, UInt16(kVK_ANSI_8): 0x25, UInt16(kVK_ANSI_9): 0x26,
        UInt16(kVK_ANSI_0): 0x27, UInt16(kVK_Return): 0x28, UInt16(kVK_Escape): 0x29,
        UInt16(kVK_Delete): 0x2A, UInt16(kVK_Tab): 0x2B, UInt16(kVK_Space): 0x2C,
        UInt16(kVK_ANSI_Minus): 0x2D, UInt16(kVK_ANSI_Equal): 0x2E,
        UInt16(kVK_ANSI_LeftBracket): 0x2F, UInt16(kVK_ANSI_RightBracket): 0x30,
        UInt16(kVK_ANSI_Backslash): 0x31, UInt16(kVK_ANSI_Semicolon): 0x33,
        UInt16(kVK_ANSI_Quote): 0x34, UInt16(kVK_ANSI_Grave): 0x35,
        UInt16(kVK_ANSI_Comma): 0x36, UInt16(kVK_ANSI_Period): 0x37,
        UInt16(kVK_ANSI_Slash): 0x38
    ]

    private static let keyCodeByHIDUsage = Dictionary(
        uniqueKeysWithValues: hidUsageByKeyCode.map { ($1, $0) }
    )
}

enum KeyName {
    static func name(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        default:
            guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { return "Key \(keyCode)" }
            let layout = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue()
            guard let bytes = CFDataGetBytePtr(layout) else { return "Key \(keyCode)" }
            let keyboardLayout = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                keyboardLayout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), 0,
                &deadKeyState, characters.count, &length, &characters
            )
            return status == noErr && length > 0
                ? String(utf16CodeUnits: characters, count: length).uppercased()
                : "Key \(keyCode)"
        }
    }
}

struct MouseMapping: Codable, Identifiable, Equatable {
    var id: Int { buttonNumber }
    let buttonNumber: Int
    var shortcut: KeyboardShortcut?

    var isPrimaryButton: Bool { buttonNumber == 0 || buttonNumber == 1 }
    var displayName: String {
        switch buttonNumber {
        case 0: return "Left Click"
        case 1: return "Right Click"
        case 2: return "Middle Click"
        default: return "Button \(buttonNumber)"
        }
    }
}
