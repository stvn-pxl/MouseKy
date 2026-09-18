import AppKit
import CoreGraphics

@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    var onShortcutRecorded: ((KeyboardShortcut) -> Void)?
    private let stateLock = NSLock()
    nonisolated(unsafe) private var acceptingEvents = false

    func start() {
        stateLock.lock()
        acceptingEvents = true
        stateLock.unlock()
        isRecording = true
    }

    func cancel() {
        stateLock.lock()
        acceptingEvents = false
        stateLock.unlock()
        isRecording = false
    }

    nonisolated func handle(type: CGEventType, event: CGEvent) -> Bool {
        stateLock.lock()
        let shouldBlock = acceptingEvents
        if type == .keyDown { acceptingEvents = false }
        stateLock.unlock()
        guard shouldBlock, type == .keyDown else { return shouldBlock }
        let shortcut = KeyboardShortcut(
            keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            modifiers: event.flags.rawValue
        )
        Task { @MainActor in
            isRecording = false
            onShortcutRecorded?(shortcut)
        }
        return true
    }
}
