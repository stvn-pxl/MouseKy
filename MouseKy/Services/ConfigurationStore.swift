import Foundation

final class ConfigurationStore {
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MouseKy", isDirectory: true)
        fileURL = directory.appendingPathComponent("config.json")
    }

    func load() -> AppConfiguration {
        guard let data = try? Data(contentsOf: fileURL) else { return AppConfiguration() }
        do {
            return try JSONDecoder().decode(AppConfiguration.self, from: data)
        } catch {
            let corruptURL = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: corruptURL)
            return AppConfiguration()
        }
    }

    func save(_ configuration: AppConfiguration) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: fileURL, options: .atomic)
    }
}
