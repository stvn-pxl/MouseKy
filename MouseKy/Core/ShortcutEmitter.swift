import CoreGraphics

enum ShortcutEmitter {
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

    private static func postModifiers(_ flags: CGEventFlags, source: CGEventSource?, marker: Int64, isKeyDown: Bool) {
        let keys: [(CGEventFlags, CGKeyCode)] = [
            (.maskCommand, 55), (.maskAlternate, 58), (.maskControl, 59), (.maskShift, 56)
        ]
        for (flag, key) in isKeyDown ? keys : keys.reversed() where flags.contains(flag) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isKeyDown) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.post(tap: .cghidEventTap)
        }
    }
}
