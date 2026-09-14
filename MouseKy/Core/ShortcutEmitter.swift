import CoreGraphics

enum ShortcutEmitter {
    static let syntheticEventMarker: Int64 = 0x4D4B_595F

    @MainActor
    final class State {
        private var modifierCounts: [UInt64: Int] = [:]
        private var shortcutCounts: [KeyboardShortcut: Int] = [:]

        func press(_ shortcut: KeyboardShortcut) {
            let shortcutCount = shortcutCounts[shortcut, default: 0]
            shortcutCounts[shortcut] = shortcutCount + 1
            guard shortcutCount == 0 else { return }
            let flags = CGEventFlags(rawValue: shortcut.modifiers)
            for (flag, key) in ShortcutEmitter.modifierKeys where flags.contains(flag) {
                let count = modifierCounts[flag.rawValue, default: 0]
                if count == 0 {
                    ShortcutEmitter.postModifier(
                        key, flags: activeFlags.union(flag), isKeyDown: true
                    )
                }
                modifierCounts[flag.rawValue] = count + 1
            }
            ShortcutEmitter.postKey(shortcut, flags: activeFlags, isKeyDown: true)
        }

        func release(_ shortcut: KeyboardShortcut) {
            let shortcutCount = max(shortcutCounts[shortcut, default: 0] - 1, 0)
            shortcutCounts[shortcut] = shortcutCount
            guard shortcutCount == 0 else { return }
            ShortcutEmitter.postKey(shortcut, flags: activeFlags, isKeyDown: false)
            let flags = CGEventFlags(rawValue: shortcut.modifiers)
            for (flag, key) in ShortcutEmitter.modifierKeys.reversed() where flags.contains(flag) {
                let count = max(modifierCounts[flag.rawValue, default: 0] - 1, 0)
                modifierCounts[flag.rawValue] = count
                if count == 0 {
                    ShortcutEmitter.postModifier(
                        key, flags: activeFlags, isKeyDown: false
                    )
                }
            }
        }

        func releaseAll() {
            for shortcut in shortcutCounts.keys {
                postKey(shortcut, flags: activeFlags, isKeyDown: false)
            }
            shortcutCounts.removeAll()
            for (flag, key) in ShortcutEmitter.modifierKeys.reversed()
            where modifierCounts[flag.rawValue, default: 0] > 0 {
                modifierCounts[flag.rawValue] = 0
                ShortcutEmitter.postModifier(key, flags: activeFlags, isKeyDown: false)
            }
        }

        private var activeFlags: CGEventFlags {
            modifierCounts.reduce(into: CGEventFlags()) {
                if $1.value > 0 { $0.insert(CGEventFlags(rawValue: $1.key)) }
            }
        }
    }

    static func post(_ shortcut: KeyboardShortcut, marker: Int64, isKeyDown: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        let modifierFlags = CGEventFlags(rawValue: shortcut.modifiers)

        // macOS requires modifier key events around the actual key event.
        if isKeyDown {
            postModifiers(modifierFlags, source: source, marker: marker, isKeyDown: true)
        }
        guard let keyEvent = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: isKeyDown) else {
            return
        }
        keyEvent.flags = modifierFlags
        keyEvent.setIntegerValueField(.eventSourceUserData, value: marker)
        keyEvent.post(tap: .cghidEventTap)
        if !isKeyDown {
            postModifiers(modifierFlags, source: source, marker: marker, isKeyDown: false)
        }
    }

    private static let modifierKeys: [(CGEventFlags, CGKeyCode)] = [
        (.maskCommand, 55), (.maskAlternate, 58), (.maskControl, 59), (.maskShift, 56)
    ]

    private static func postKey(
        _ shortcut: KeyboardShortcut,
        flags: CGEventFlags,
        isKeyDown: Bool
    ) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(shortcut.keyCode),
            keyDown: isKeyDown
        ) else { return }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        event.post(tap: .cghidEventTap)
    }

    private static func postModifier(
        _ key: CGKeyCode,
        flags: CGEventFlags,
        isKeyDown: Bool
    ) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            keyboardEventSource: source, virtualKey: key, keyDown: isKeyDown
        ) else { return }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        event.post(tap: .cghidEventTap)
    }

    private static func postModifiers(_ flags: CGEventFlags, source: CGEventSource?, marker: Int64, isKeyDown: Bool) {
        for (flag, key) in isKeyDown ? modifierKeys : modifierKeys.reversed() where flags.contains(flag) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isKeyDown) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.post(tap: .cghidEventTap)
        }
    }
}
