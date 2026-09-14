import Foundation

protocol ConfigurationStoring {
    func load() -> AppConfiguration
    func save(_ configuration: AppConfiguration) throws
}

final class ConfigurationStore: ConfigurationStoring {
    private let fileURL: URL
    private let fileManager: FileManager
    private var protectsNewerSchema = false

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MouseKy", isDirectory: true)
        fileURL = directory.appendingPathComponent("config.json")
    }

    func load() -> AppConfiguration {
        guard let data = try? Data(contentsOf: fileURL) else { return AppConfiguration() }
        do {
            let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
            if configuration.schemaVersion < AppConfiguration.currentSchemaVersion {
                persistMigrationBackup(data)
            }
            return configuration
        } catch ConfigurationDecodingError.newerSchema {
            protectsNewerSchema = true
            return AppConfiguration()
        } catch {
            let corruptURL = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? fileManager.moveItem(at: fileURL, to: corruptURL)
            return AppConfiguration()
        }
    }

    func save(_ configuration: AppConfiguration) throws {
        guard !protectsNewerSchema else {
            throw ConfigurationStoreError.newerSchemaIsReadOnly
        }
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: fileURL, options: .atomic)
    }

    private func persistMigrationBackup(_ data: Data) {
        let milliseconds = Int(Date().timeIntervalSince1970 * 1_000)
        let backupURL = fileURL.deletingPathExtension()
            .appendingPathExtension("migration-\(milliseconds).json")
        try? data.write(to: backupURL, options: .atomic)
    }
}

enum ConfigurationStoreError: LocalizedError {
    case newerSchemaIsReadOnly

    var errorDescription: String? {
        "Die Konfiguration stammt aus einer neueren MouseKy-Version und wird nicht überschrieben."
    }
}
