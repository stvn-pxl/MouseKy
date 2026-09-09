import AppKit
import CoreGraphics

final class EventTapManager {
    var buttonHandler: ((Int) -> Void)?
    var shortcutProvider: ((Int) -> KeyboardShortcut?)?
    var recorder: ShortcutRecorder?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let syntheticEventMarker: Int64 = 0x4D4B_595F

    func start() -> Bool {
        guard eventTap == nil else { return true }
        let mouseEvents: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)
        let keyboardEvents: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mouseEvents | keyboardEvents,
            callback: Self.callback,
            userInfo: context
        ) else { return false }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()
        return owner.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown || type == .keyUp {
            return recorder?.handle(type: type, event: event) == true ? nil : Unmanaged.passUnretained(event)
        }
        guard type == .leftMouseDown || type == .leftMouseUp ||
              type == .rightMouseDown || type == .rightMouseUp ||
              type == .otherMouseDown || type == .otherMouseUp
        else { return Unmanaged.passUnretained(event) }

        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            DispatchQueue.main.async { [weak self] in self?.buttonHandler?(button) }
        }
        guard button != 0, button != 1, let shortcut = shortcutProvider?(button) else {
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            ShortcutEmitter.post(shortcut, marker: syntheticEventMarker, isKeyDown: true)
        } else {
            ShortcutEmitter.post(shortcut, marker: syntheticEventMarker, isKeyDown: false)
        }
        return nil
    }
}
