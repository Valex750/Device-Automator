import Foundation

struct ConfigStore: Sendable {
    let url: URL

    static func `default`() throws -> ConfigStore {
        if let override = ProcessInfo.processInfo.environment["DEVICE_AUTOMATOR_CONFIG"],
           !override.isEmpty {
            return ConfigStore(url: URL(fileURLWithPath: override))
        }
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = root.appendingPathComponent("DeviceAutomator", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ConfigStore(url: dir.appendingPathComponent("config.json"))
    }

    func load() throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw DeviceAutomatorError.invalidConfig(error.localizedDescription)
        }
    }

    func save(_ config: Config) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
