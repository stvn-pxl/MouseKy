import Foundation

@MainActor
final class MouseButtonScanner: ObservableObject {
    @Published private(set) var isScanning = false
    @Published private(set) var discoveredButtons: Set<Int> = []

    func start() {
        discoveredButtons = []
        isScanning = true
    }

    func stop() {
        isScanning = false
    }

    func observe(buttonNumber: Int) {
        guard isScanning else { return }
        discoveredButtons.insert(buttonNumber)
    }
}
