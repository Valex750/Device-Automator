import Foundation

struct AppTarget: Codable, Equatable, Sendable {
    /// Stable id used by `set_target` / `get_target`.
    var name: String
    /// Absolute path to an `.xcodeproj` or `.xcworkspace` the agent is developing.
    var projectPath: String?
    var scheme: String?
    var bundleId: String?
    /// `devicectl` device selector: UDID, name, ECID, or DNS name.
    var device: String?
}

struct Config: Codable, Equatable, Sendable {
    var currentTarget: String?
    var targets: [AppTarget]

    static let empty = Config(currentTarget: nil, targets: [])

    func target(named name: String) -> AppTarget? {
        targets.first { $0.name == name }
    }

    func resolvedCurrent() throws -> AppTarget {
        guard let currentTarget, let target = target(named: currentTarget) else {
            throw DeviceAutomatorError.noCurrentTarget
        }
        return target
    }

    mutating func upsert(_ target: AppTarget) {
        if let index = targets.firstIndex(where: { $0.name == target.name }) {
            targets[index] = target
        } else {
            targets.append(target)
        }
        if currentTarget == nil {
            currentTarget = target.name
        }
    }

    mutating func remove(named name: String) {
        targets.removeAll { $0.name == name }
        if currentTarget == name {
            currentTarget = targets.first?.name
        }
    }
}

enum DeviceAutomatorError: Error, LocalizedError {
    case noCurrentTarget
    case unknownTarget(String)
    case missingArgument(String)
    case commandFailed(String)
    case invalidConfig(String)

    var errorDescription: String? {
        switch self {
        case .noCurrentTarget:
            return "No current app target. Use add_target, then set_target."
        case .unknownTarget(let name):
            return "Unknown target '\(name)'."
        case .missingArgument(let name):
            return "Missing required argument '\(name)'."
        case .commandFailed(let message):
            return message
        case .invalidConfig(let message):
            return "Invalid config: \(message)"
        }
    }
}
