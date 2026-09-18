import Darwin
import Foundation

/// Apple DeviceInteraction session plus xcodebuild/devicectl fallbacks.
/// Never writes into a target app's source tree.
///
/// One InteractionEngine lives in the Device Automator daemon. MCP stdio
/// processes attach to that daemon instead of each opening their own Xcode session.
final class InteractionEngine {
    private var client: XcodeMCPClient?
    private(set) var sessionKey: String?
    private var workspaceID: String?
    private var currentIdentifier: String?

    var hasLiveSession: Bool { sessionKey != nil && client?.isConnected == true }

    func endSession(disconnectClient: Bool = false) {
        if let client {
            if let sessionKey {
                _ = try? client.callTool(
                    "DeviceInteractionEndSession",
                    arguments: ["interactionSessionKey": sessionKey],
                    timeout: 30
                )
            }
            if let currentIdentifier, currentIdentifier != sessionKey {
                _ = try? client.callTool(
                    "DeviceInteractionEndSession",
                    arguments: ["interactionSessionKey": currentIdentifier],
                    timeout: 30
                )
            }
        }
        if let currentIdentifier {
            SessionIdentity.remember(currentIdentifier)
        }
        sessionKey = nil
        currentIdentifier = nil
        workspaceID = nil
        PersistedSessionStore.clear()
        if disconnectClient {
            client?.disconnect()
            client = nil
        }
    }

    func resetSession() {
        endSession(disconnectClient: false)
    }

    /// If a previous daemon died while Xcode still held a session, release it
    /// so the next observe can start a *new* identifier immediately.
    func reclaimOrphanedSessionIfNeeded() {
        guard let persisted = PersistedSessionStore.load() else { return }
        if ProcessLiveness.isAlive(persisted.ownerPID), persisted.ownerPID != getpid() {
            return
        }
        EngineLog.write("session: reclaiming orphan '\(persisted.identifier)'")
        SessionIdentity.remember(persisted.identifier)
        if let client = try? connected() {
            _ = try? client.callTool(
                "DeviceInteractionEndSession",
                arguments: ["interactionSessionKey": persisted.key],
                timeout: 30
            )
            if persisted.key != persisted.identifier {
                _ = try? client.callTool(
                    "DeviceInteractionEndSession",
                    arguments: ["interactionSessionKey": persisted.identifier],
                    timeout: 30
                )
            }
        }
        PersistedSessionStore.clear()
        sessionKey = nil
        currentIdentifier = nil
        workspaceID = nil
    }

    func boot(device: String) throws -> String {
        let result = try ProcessRunner.xcrun(["simctl", "boot", device])
        let combined = (result.stdout + "\n" + result.stderr).lowercased()
        if result.succeeded || combined.contains("already booted") || combined.contains("current state: booted") {
            return "Booted \(device)."
        }
        try result.throwIfFailed(label: "simctl boot")
        return "Booted \(device)."
    }

    func shutdown(device: String) throws -> String {
        let result = try ProcessRunner.xcrun(["simctl", "shutdown", device])
        if result.succeeded || result.stderr.lowercased().contains("already shut down") {
            return "Shut down \(device)."
        }
        try result.throwIfFailed(label: "simctl shutdown")
        return "Shut down \(device)."
    }

    func installAndRun(target: AppTarget, device: String, config: Config) throws -> String {
        // A live DeviceInteraction session must not be replaced. Rebuild through
        // that session, or via xcodebuild + simctl/devicectl, then keep observe/tap on it.
        if hasLiveSession {
            do {
                return try deviceInteractionInstall(target: target, device: device)
            } catch {
                let fallback = try buildInstallLaunch(target: target, device: device, config: config)
                return "Apple DeviceInteraction install failed on the existing session (\(error.localizedDescription)). Rebuilt with xcodebuild/devicectl without opening a second session.\n\(fallback)"
            }
        }
        return try buildInstallLaunch(target: target, device: device, config: config)
    }

    func synthesize(target: AppTarget, device: String, command: String) throws -> String {
        try ensureSession(target: target, device: device)
        do {
            return try ObserveNormalization.rewrite(try sendSynthesize(target: target, device: device, command: command))
        } catch {
            let text = error.localizedDescription
            let kind = SessionFailure.classify(text)
            guard kind == .sessionNotFound || kind == .identifierInUse || kind == .statefulAction else {
                throw error
            }
            EngineLog.write("session: synthesize recovered from \(kind)")
            endSession(disconnectClient: false)
            try ensureSession(target: target, device: device)
            return try ObserveNormalization.rewrite(try sendSynthesize(target: target, device: device, command: command))
        }
    }

    func setOrientation(device: String, orientation: String) throws -> String {
        let result = try ProcessRunner.xcrun([
            "devicectl", "device", "orientation", "set",
            "--device", device,
            orientation,
        ])
        if result.succeeded {
            return result.stdout.isEmpty ? "Set orientation to \(orientation)." : result.stdout
        }
        try result.throwIfFailed(label: "devicectl orientation")
        return "Set orientation to \(orientation)."
    }

    func launchInstalled(target: AppTarget, device: String) throws -> String {
        guard let bundleId = target.bundleId else {
            throw DeviceAutomatorError.missingArgument("bundle_id")
        }
        try launchApp(bundleId: bundleId, device: device)
        return "Launched \(bundleId)."
    }

    private func deviceInteractionInstall(target: AppTarget, device: String) throws -> String {
        guard let sessionKey else {
            throw DeviceAutomatorError.commandFailed("No DeviceInteraction session key.")
        }
        let arguments = try appleArguments(target: target, device: device, extra: [
            "interactionSessionKey": sessionKey,
        ])
        let result = try connected().callTool(
            "DeviceInteractionInstallAndRun",
            arguments: arguments,
            timeout: 300
        )
        let text = try MCPResult.flatten(result)
        if let dict = result as? [String: Any], dict["isError"] as? Bool == true {
            throw DeviceAutomatorError.commandFailed(text)
        }
        return text
    }

    private func sendSynthesize(target: AppTarget, device: String, command: String) throws -> String {
        guard let sessionKey else {
            throw DeviceAutomatorError.commandFailed("No DeviceInteraction session key.")
        }
        let arguments = try appleArguments(target: target, device: device, extra: [
            "interactSessionKey": sessionKey,
            "interactionCommand": command,
        ])
        let result = try connected().callTool(
            "DeviceInteractionSynthesize",
            arguments: arguments,
            timeout: 90
        )
        let text = try MCPResult.flatten(result)
        if let dict = result as? [String: Any], dict["isError"] as? Bool == true {
            throw DeviceAutomatorError.commandFailed(text)
        }
        let kind = SessionFailure.classify(text)
        if kind == .sessionNotFound || kind == .identifierInUse {
            throw DeviceAutomatorError.commandFailed(text)
        }
        return text
    }

    private func ensureSession(target: AppTarget, device: String) throws {
        if hasLiveSession { return }
        let client = try connected()
        workspaceID = try resolveWorkspace(client: client, target: target)

        var used = Set<String>()
        var lastError = "Could not start a DeviceInteraction session."
        let delays: [useconds_t] = [0, 400_000, 800_000, 1_500_000, 2_500_000, 4_000_000]
        for (attempt, delay) in delays.enumerated() {
            if delay > 0 {
                EngineLog.write("session: retrying with a new identifier (attempt \(attempt + 1)/\(delays.count))")
                usleep(delay)
            }
            let identifier = SessionIdentity.mint(excluding: used)
            used.insert(identifier)
            do {
                switch try startOnce(client: client, target: target, device: device, identifier: identifier) {
                case .started(let key):
                    sessionKey = key
                    currentIdentifier = identifier
                    persist(identifier: identifier, key: key)
                    EngineLog.write("session: ready id='\(identifier)' key='\(key)'")
                    return
                case .burned(let text):
                    lastError = text
                    bestEffortEnd(client: client, identifier: identifier)
                    EngineLog.write("session: identifier '\(identifier)' burned: \(text)")
                }
            } catch {
                lastError = error.localizedDescription
                bestEffortEnd(client: client, identifier: identifier)
                if !SessionFailure.isRecoverableStartFailure(lastError) {
                    throw error
                }
                EngineLog.write("session: start failed '\(identifier)': \(lastError)")
            }
        }
        throw DeviceAutomatorError.commandFailed(
            "Could not open a DeviceInteraction session after \(delays.count) attempts with new identifiers (Xcode cooldown). Last error: \(lastError)"
        )
    }

    private enum StartResult {
        case started(key: String)
        case burned(String)
    }

    /// One Xcode start per identifier. Never call a second start tool on an id
    /// that may already be live or in cooldown.
    private func startOnce(
        client: XcodeMCPClient,
        target: AppTarget,
        device: String,
        identifier: String
    ) throws -> StartResult {
        _ = target
        SessionIdentity.remember(identifier)
        var startArgs: [String: Any] = [
            "sessionIdentifier": identifier,
        ]
        if let workspaceID {
            startArgs["workspaceIdentifier"] = workspaceID
            startArgs["tabIdentifier"] = workspaceID
        }
        if !device.isEmpty {
            startArgs["deviceIdentifier"] = device
        }

        var workspaceUnavailable = false
        do {
            let workspace = try client.callTool("DeviceInteractionStartWorkspaceSession", arguments: startArgs, timeout: 120)
            if MCPResult.isUnavailable(workspace) {
                workspaceUnavailable = true
            } else {
                return interpretStart(workspace, identifier: identifier)
            }
        } catch {
            let text = error.localizedDescription
            if SessionFailure.classify(text) == .identifierInUse {
                return .burned(text)
            }
            workspaceUnavailable = true
            EngineLog.write("session: workspace start threw, trying StartSession: \(text)")
        }

        guard workspaceUnavailable else {
            return .burned("Workspace session start returned no usable key.")
        }

        do {
            let started = try client.callTool("DeviceInteractionStartSession", arguments: startArgs, timeout: 120)
            if MCPResult.isUnavailable(started) {
                return .burned(try MCPResult.flatten(started))
            }
            return interpretStart(started, identifier: identifier)
        } catch {
            let text = error.localizedDescription
            if SessionFailure.isRecoverableStartFailure(text) {
                return .burned(text)
            }
            throw error
        }
    }

    private func interpretStart(_ started: Any, identifier: String) -> StartResult {
        let text = (try? MCPResult.flatten(started)) ?? String(describing: started)
        if let key = MCPResult.sessionKey(in: started) {
            return .started(key: key)
        }
        switch SessionFailure.classify(text) {
        case .identifierInUse, .sessionNotFound, .statefulAction:
            return .burned(text)
        case .missingKey, .other:
            // Apple's own skills pass the human-friendly sessionIdentifier as the
            // later interactionSessionKey. Prefer that over leaving an orphan.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .started(key: identifier)
            }
            if SessionFailure.classify(text) == .other, text.count < 400, !text.localizedCaseInsensitiveContains("error") {
                return .started(key: identifier)
            }
            if text.localizedCaseInsensitiveContains("error") || text.localizedCaseInsensitiveContains("failed") {
                return .burned(text)
            }
            return .started(key: identifier)
        }
    }

    private func persist(identifier: String, key: String) {
        PersistedSessionStore.save(
            PersistedSession(
                identifier: identifier,
                key: key,
                workspaceID: workspaceID,
                ownerPID: getpid(),
                updatedAt: Date().timeIntervalSince1970
            )
        )
    }

    private func bestEffortEnd(client: XcodeMCPClient, identifier: String) {
        _ = try? client.callTool(
            "DeviceInteractionEndSession",
            arguments: ["interactionSessionKey": identifier],
            timeout: 15
        )
        SessionIdentity.remember(identifier)
    }

    private func connected() throws -> XcodeMCPClient {
        if let client, client.isConnected { return client }
        let client = XcodeMCPClient()
        try client.connect()
        self.client = client
        return client
    }

    private func resolveWorkspace(client: XcodeMCPClient, target: AppTarget) throws -> String {
        if let path = target.projectPath {
            if let opened = try? client.callTool(
                "XcodeOpenWorkspace",
                arguments: ["path": path],
                timeout: 60
            ), !MCPResult.isUnavailable(opened),
               let id = MCPResult.firstString(in: opened, keys: ["workspaceIdentifier", "tabIdentifier", "identifier"]) {
                return id
            }
            var listed = try? client.callTool("XcodeListWorkspaces", timeout: 30)
            if listed == nil || MCPResult.isUnavailable(listed!) {
                listed = try? client.callTool("XcodeListWindows", timeout: 30)
            }
            if let listed, !MCPResult.isUnavailable(listed),
               let id = MCPResult.matchingIdentifier(in: listed, pathHint: path) {
                return id
            }
            return path
        }
        throw DeviceAutomatorError.missingArgument("project_path")
    }

    private func appleArguments(target: AppTarget, device: String, extra: [String: Any]) throws -> [String: Any] {
        var arguments = extra
        if let workspaceID {
            arguments["workspaceIdentifier"] = workspaceID
            arguments["tabIdentifier"] = workspaceID
        } else if let path = target.projectPath {
            arguments["workspaceIdentifier"] = path
            arguments["tabIdentifier"] = path
        }
        _ = device
        return arguments
    }

    private func buildInstallLaunch(target: AppTarget, device: String, config: Config) throws -> String {
        guard let projectPath = target.projectPath, let scheme = target.scheme, let bundleId = target.bundleId else {
            throw DeviceAutomatorError.commandFailed("install_and_run needs project_path, scheme, and bundle_id on the target.")
        }
        let derived = try AppSupport.derivedData(for: target.name)
        try TargetGuard.ensureWriteIsOutsideTargets(destination: derived, config: config)

        var arguments = ["-scheme", scheme, "-destination", "id=\(device)", "-derivedDataPath", derived.path, "-configuration", "Debug", "build"]
        if projectPath.hasSuffix(".xcworkspace") {
            arguments = ["-workspace", projectPath] + arguments
        } else {
            arguments = ["-project", projectPath] + arguments
        }
        let build = try ProcessRunner.run(executable: "/usr/bin/xcodebuild", arguments: arguments)
        try build.throwIfFailed(label: "xcodebuild")

        let app = try Self.findApp(in: derived)
        try TargetGuard.ensureWriteIsOutsideTargets(destination: app, config: config)
        try installApp(app: app, device: device)
        try launchApp(bundleId: bundleId, device: device)
        return "Built \(scheme), installed \(app.lastPathComponent), launched \(bundleId) on \(device)."
    }

    private func installApp(app: URL, device: String) throws {
        let install = try ProcessRunner.xcrun([
            "devicectl", "device", "install", "app",
            "--device", device,
            app.path,
        ])
        if install.succeeded { return }
        let sim = try ProcessRunner.xcrun(["simctl", "install", device, app.path])
        if sim.succeeded { return }
        try install.throwIfFailed(label: "devicectl install app")
    }

    private func launchApp(bundleId: String, device: String) throws {
        let launch = try ProcessRunner.xcrun([
            "devicectl", "device", "process", "launch",
            "--device", device,
            bundleId,
        ])
        if launch.succeeded { return }
        let sim = try ProcessRunner.xcrun(["simctl", "launch", device, bundleId])
        if sim.succeeded { return }
        try launch.throwIfFailed(label: "devicectl process launch")
    }

    private static func findApp(in derived: URL) throws -> URL {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: derived, includingPropertiesForKeys: nil) else {
            throw DeviceAutomatorError.commandFailed("Could not search derived data at \(derived.path).")
        }
        var candidates: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "app", url.path.contains("Build/Products/") {
                candidates.append(url)
            }
        }
        let preferred = candidates.first { $0.path.contains("iphonesimulator") || $0.path.contains("iphoneos") }
        guard let app = preferred ?? candidates.first else {
            throw DeviceAutomatorError.commandFailed("No .app found under \(derived.path) after xcodebuild.")
        }
        return app
    }
}

enum MCPResult {
    static func flatten(_ result: Any) throws -> String {
        if let text = stringifyContent(result) { return text }
        if JSONSerialization.isValidJSONObject(result) {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        return String(describing: result)
    }

    /// Xcode reports an unsupported/disabled tool as a normal (non-throwing) result.
    /// Do not treat every `isError` as "tool missing" — identifier-in-use is a
    /// real session failure and must not fall through to a second start on the same id.
    static func isUnavailable(_ result: Any) -> Bool {
        let text = ((try? flatten(result)) ?? "").lowercased()
        if text.contains("is not enabled") { return true }
        if text.contains("tool") && (text.contains("unknown") || text.contains("not available")) {
            return true
        }
        return false
    }

    static func sessionKey(in result: Any) -> String? {
        firstString(in: result, keys: ["interactionSessionKey", "interactSessionKey", "sessionKey", "key"])
    }

    static func matchingIdentifier(in result: Any, pathHint: String) -> String? {
        let text = (try? flatten(result)) ?? ""
        if text.contains(pathHint) || text.contains((pathHint as NSString).deletingLastPathComponent) {
            return firstString(in: result, keys: ["workspaceIdentifier", "tabIdentifier", "identifier"]) ?? pathHint
        }
        return firstString(in: result, keys: ["workspaceIdentifier", "tabIdentifier", "identifier"])
    }

    static func firstString(in value: Any, keys: [String]) -> String? {
        if let dict = value as? [String: Any] {
            for key in keys {
                if let string = dict[key] as? String, !string.isEmpty { return string }
            }
            for nested in dict.values {
                if let found = firstString(in: nested, keys: keys) { return found }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let found = firstString(in: nested, keys: keys) { return found }
            }
        } else if let text = value as? String {
            for key in keys {
                if let range = text.range(of: "\"\(key)\"\\s*:\\s*\"([^\"]+)\"", options: .regularExpression) {
                    let matched = String(text[range])
                    if let valueRange = matched.range(of: "\"[^\"]+\"$", options: .regularExpression) {
                        return String(matched[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    }
                }
                if let range = text.range(of: "\\b\(key)\\s*:\\s*([^,\\n]+)", options: .regularExpression) {
                    let matched = String(text[range])
                    if let colonRange = matched.range(of: ":") {
                        let value = matched[matched.index(after: colonRange.lowerBound)...]
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { return trimmed }
                    }
                }
            }
        }
        return nil
    }

    private static func stringifyContent(_ result: Any) -> String? {
        guard let dict = result as? [String: Any], let content = dict["content"] as? [[String: Any]] else {
            return nil
        }
        var parts: [String] = []
        for item in content {
            switch item["type"] as? String {
            case "text":
                if let text = item["text"] as? String { parts.append(text) }
            case "image":
                if let data = item["data"] as? String, let url = try? saveImage(data) {
                    parts.append("Saved screenshot to \(url.path)")
                } else {
                    parts.append("Received an image from DeviceInteraction.")
                }
            default:
                if let path = item["path"] as? String ?? item["uri"] as? String {
                    parts.append(path)
                }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func saveImage(_ base64: String) throws -> URL {
        let trimmed = base64.replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: trimmed) else {
            throw DeviceAutomatorError.commandFailed("DeviceInteraction image was not valid base64.")
        }
        let url = try AppSupport.timestampedPNG()
        try data.write(to: url)
        return url
    }
}
