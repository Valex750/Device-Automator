import Foundation

/// Apple DeviceInteraction session plus xcodebuild/devicectl fallbacks.
/// Never writes into a target app's source tree.
final class InteractionEngine {
    private var client: XcodeMCPClient?
    private(set) var sessionKey: String?
    private var workspaceID: String?

    func endSession() {
        if let sessionKey, let client {
            _ = try? client.callTool(
                "DeviceInteractionEndSession",
                arguments: ["interactionSessionKey": sessionKey],
                timeout: 30
            )
        }
        sessionKey = nil
        client?.disconnect()
        client = nil
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
        do {
            try ensureSession(target: target, device: device)
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
            return try MCPResult.flatten(result)
        } catch {
            let fallback = try buildInstallLaunch(target: target, device: device, config: config)
            return "Apple DeviceInteraction install failed (\(error.localizedDescription)). Fell back to xcodebuild/devicectl.\n\(fallback)"
        }
    }

    func synthesize(target: AppTarget, device: String, command: String) throws -> String {
        try ensureSession(target: target, device: device)
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
        return try MCPResult.flatten(result)
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
        // Fall through to DeviceInteraction command if CoreDevice rejects it.
        try result.throwIfFailed(label: "devicectl orientation")
        return "Set orientation to \(orientation)."
    }

    func launchInstalled(target: AppTarget, device: String) throws -> String {
        guard let bundleId = target.bundleId else {
            throw DeviceAutomatorError.missingArgument("bundle_id")
        }
        let result = try ProcessRunner.xcrun([
            "devicectl", "device", "process", "launch",
            "--device", device,
            bundleId,
        ])
        try result.throwIfFailed(label: "devicectl process launch")
        return result.stdout.isEmpty ? "Launched \(bundleId)." : result.stdout
    }

    private func ensureSession(target: AppTarget, device: String) throws {
        if sessionKey != nil, client?.isConnected == true { return }
        let client = try connected()
        workspaceID = try resolveWorkspace(client: client, target: target)

        var startArgs: [String: Any] = [
            "sessionIdentifier": "Device Automator",
        ]
        if let workspaceID {
            startArgs["workspaceIdentifier"] = workspaceID
            startArgs["tabIdentifier"] = workspaceID
        }
        if !device.isEmpty {
            startArgs["deviceIdentifier"] = device
        }

        let started: Any
        do {
            started = try client.callTool("DeviceInteractionStartWorkspaceSession", arguments: startArgs, timeout: 120)
        } catch {
            started = try client.callTool("DeviceInteractionStartSession", arguments: startArgs, timeout: 120)
        }
        guard let key = MCPResult.sessionKey(in: started) else {
            throw DeviceAutomatorError.commandFailed(
                "Xcode started a device session but returned no session key. Open Lift Planner in Xcode, enable Intelligence → Allow external agents, then retry.\n\(try MCPResult.flatten(started))"
            )
        }
        sessionKey = key
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
            ) {
                if let id = MCPResult.firstString(in: opened, keys: ["workspaceIdentifier", "tabIdentifier", "identifier"]) {
                    return id
                }
            }
            let listed = (try? client.callTool("XcodeListWorkspaces", timeout: 30))
                ?? (try? client.callTool("XcodeListWindows", timeout: 30))
            if let listed,
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
        let install = try ProcessRunner.xcrun([
            "devicectl", "device", "install", "app",
            "--device", device,
            app.path,
        ])
        try install.throwIfFailed(label: "devicectl install app")
        let launch = try ProcessRunner.xcrun([
            "devicectl", "device", "process", "launch",
            "--device", device,
            bundleId,
        ])
        try launch.throwIfFailed(label: "devicectl process launch")
        return "Built \(scheme), installed \(app.lastPathComponent), launched \(bundleId) on \(device)."
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
