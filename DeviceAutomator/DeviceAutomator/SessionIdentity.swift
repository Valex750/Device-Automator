import Darwin
import Foundation

/// Unique Title Case identifiers for Xcode DeviceInteraction.
/// Xcode refuses to reuse a name that is live or in a short "recently used" cooldown.
enum SessionIdentity {
    static let cooldown: TimeInterval = 45

    static func mint(excluding used: Set<String> = [], now: Date = Date()) -> String {
        var blocked = used
        blocked.formUnion(CooldownStore.active(now: now))
        blocked.insert("default")
        blocked.insert("Device Automator")
        for _ in 0..<32 {
            let token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
            let identifier = "Device Automator \(token)"
            if !blocked.contains(identifier) {
                return identifier
            }
        }
        return "Device Automator \(UUID().uuidString)"
    }

    static func remember(_ identifier: String, now: Date = Date()) {
        CooldownStore.remember(identifier, until: now.addingTimeInterval(cooldown))
    }
}

enum SessionFailureKind: Equatable {
    case identifierInUse
    case sessionNotFound
    case missingKey
    case statefulAction
    case other
}

enum SessionFailure {
    static func classify(_ text: String) -> SessionFailureKind {
        let lowered = text.lowercased()
        if lowered.contains("currently in use") || lowered.contains("recently used") {
            return .identifierInUse
        }
        if lowered.contains("session not found")
            || lowered.contains("already been closed")
            || lowered.contains("identifier is wrong") {
            return .sessionNotFound
        }
        if lowered.contains("idestatefulactionerror") || lowered.contains("stateful action") {
            return .statefulAction
        }
        if lowered.contains("returned no session key") || lowered.contains("no session key") {
            return .missingKey
        }
        return .other
    }

    static func isRecoverableStartFailure(_ text: String) -> Bool {
        switch classify(text) {
        case .identifierInUse, .sessionNotFound, .missingKey, .statefulAction:
            return true
        case .other:
            return false
        }
    }
}

enum CooldownStore {
    static func active(now: Date) -> Set<String> {
        let records = load().filter { $0.expiry > now.timeIntervalSince1970 }
        save(records)
        return Set(records.map(\.identifier))
    }

    static func remember(_ identifier: String, until: Date) {
        var records = load().filter { $0.expiry > Date().timeIntervalSince1970 }
        records.removeAll { $0.identifier == identifier }
        records.append(Record(identifier: identifier, expiry: until.timeIntervalSince1970))
        save(records)
    }

    private struct Record: Codable {
        var identifier: String
        var expiry: TimeInterval
    }

    private static func load() -> [Record] {
        guard let url = try? AppSupport.identifierCooldown(),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([Record].self, from: data) else {
            return []
        }
        return records
    }

    private static func save(_ records: [Record]) {
        guard let url = try? AppSupport.identifierCooldown() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

struct PersistedSession: Codable, Equatable {
    var identifier: String
    var key: String
    var workspaceID: String?
    var ownerPID: Int32
    var updatedAt: TimeInterval
}

enum PersistedSessionStore {
    static func load() -> PersistedSession? {
        guard let url = try? AppSupport.persistedSession(),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(PersistedSession.self, from: data)
    }

    static func save(_ session: PersistedSession) {
        guard let url = try? AppSupport.persistedSession() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear() {
        guard let url = try? AppSupport.persistedSession() else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

enum ProcessLiveness {
    static func isAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
