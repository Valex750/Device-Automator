import Darwin
import Foundation

/// Minimal MCP stdio server (JSON-RPC, Content-Length framing, NDJSON fallback).
enum MCPRuntime {
    static func run() throws {
        let store = try ConfigStore.default()
        var config = DefaultTargets.seededConfig(existing: try store.load())
        try store.save(config)
        let engine = InteractionEngine()
        defer { engine.endSession() }

        var buffer = Data()
        var framing: JSONRPC.Framing = .contentLength
        let input = FileHandle.standardInput
        while true {
            let chunk = input.availableData
            if chunk.isEmpty {
                break
            }
            buffer.append(chunk)
            while let message = try JSONRPC.extractMessage(from: &buffer, framing: &framing) {
                try handle(message: message, store: store, config: &config, engine: engine, framing: framing)
            }
        }
    }

    private static func handle(
        message: Data,
        store: ConfigStore,
        config: inout Config,
        engine: InteractionEngine,
        framing: JSONRPC.Framing
    ) throws {
        let object = try JSONValue.object(from: message)
        let method = object["method"] as? String
        let id = object["id"]
        let params = object["params"] as? [String: Any] ?? [:]

        if method == "notifications/initialized" || method?.hasPrefix("notifications/") == true {
            return
        }

        guard let method else {
            if id != nil {
                try reply(id: id, error: ("Invalid Request", -32600), framing: framing)
            }
            return
        }

        do {
            let result: Any
            switch method {
            case "initialize":
                let requested = JSONValue.string(params, "protocolVersion") ?? "2025-06-18"
                result = [
                    "protocolVersion": requested,
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "DeviceAutomator", "version": "0.1.0"],
                    "instructions": "Drive a configured iOS app (default: Lift Planner) like a person. Use observe hitPoints for taps. Never modify the target app source.",
                ]
            case "ping":
                result = [:]
            case "tools/list":
                result = ["tools": tools]
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                result = try callTool(name, arguments: arguments, store: store, config: &config, engine: engine)
            default:
                try reply(id: id, error: ("Method not found: \(method)", -32601), framing: framing)
                return
            }
            try reply(id: id, result: result, framing: framing)
        } catch {
            let text = error.localizedDescription
            if method == "tools/call" {
                try reply(id: id, result: toolResult(text, isError: true), framing: framing)
            } else {
                try reply(id: id, error: (text, -32000), framing: framing)
            }
        }
    }

    private static let tools: [[String: Any]] = [
        tool("list_targets", "List configured app targets. Target app source is never modified."),
        tool("get_target", "Show the current app target (project path, scheme, bundle id, device)."),
        tool(
            "set_target",
            "Select which configured app to drive.",
            properties: ["name": stringProperty("Target name, e.g. Lift Planner")],
            required: ["name"]
        ),
        tool(
            "add_target",
            "Add or update a named app target. Only stores paths/ids; does not edit that app.",
            properties: [
                "name": stringProperty("Short name for this target"),
                "project_path": stringProperty("Absolute path to .xcodeproj or .xcworkspace"),
                "scheme": stringProperty("Xcode scheme name"),
                "bundle_id": stringProperty("App bundle identifier"),
                "device": stringProperty("devicectl device selector (UDID or name)"),
            ],
            required: ["name"]
        ),
        tool(
            "remove_target",
            "Remove a configured app target from Device Automator config (does not delete the app).",
            properties: ["name": stringProperty("Target name")],
            required: ["name"]
        ),
        tool("list_devices", "List simulators and physical devices known to CoreDevice."),
        tool(
            "boot_simulator",
            "Boot the current target's simulator (or an explicit UDID).",
            properties: ["device": stringProperty("Override device UDID")]
        ),
        tool(
            "shutdown_simulator",
            "Shut down the current target's simulator (or an explicit UDID).",
            properties: ["device": stringProperty("Override device UDID")]
        ),
        tool(
            "screenshot",
            "Capture a PNG. Never writes into a target app tree.",
            properties: [
                "device": stringProperty("Override device selector"),
                "destination": stringProperty("Absolute .png path outside any target app project"),
            ]
        ),
        tool(
            "install_and_run",
            "Build, install, and launch the current target app. Prefers Xcode DeviceInteraction; falls back to xcodebuild + devicectl. Does not modify app source.",
            properties: ["device": stringProperty("Override device selector")]
        ),
        tool(
            "observe",
            "Screenshot + accessibility hierarchy from DeviceInteraction. Use hitPoints from this tree for taps.",
            properties: ["device": stringProperty("Override device selector")]
        ),
        tool(
            "tap",
            "Tap at coordinates from the latest observe hitPoint.",
            properties: [
                "x": numberProperty("X coordinate"),
                "y": numberProperty("Y coordinate"),
                "duration": numberProperty("Optional hold duration in seconds"),
                "device": stringProperty("Override device selector"),
            ],
            required: ["x", "y"]
        ),
        tool(
            "double_tap",
            "Double-tap at coordinates from the latest observe hitPoint.",
            properties: [
                "x": numberProperty("X coordinate"),
                "y": numberProperty("Y coordinate"),
                "device": stringProperty("Override device selector"),
            ],
            required: ["x", "y"]
        ),
        tool(
            "swipe",
            "Swipe from one hitPoint to another.",
            properties: [
                "from_x": numberProperty("Start X"),
                "from_y": numberProperty("Start Y"),
                "to_x": numberProperty("End X"),
                "to_y": numberProperty("End Y"),
                "duration": numberProperty("Optional duration in seconds"),
                "device": stringProperty("Override device selector"),
            ],
            required: ["from_x", "from_y", "to_x", "to_y"]
        ),
        tool(
            "type",
            "Type text into the focused field. Must follow a tap that focused the field.",
            properties: [
                "text": stringProperty("Literal text to type"),
                "device": stringProperty("Override device selector"),
            ],
            required: ["text"]
        ),
        tool(
            "press_button",
            "Press a hardware button.",
            properties: [
                "button": stringProperty("home, power, volume_up, or volume_down"),
                "device": stringProperty("Override device selector"),
            ],
            required: ["button"]
        ),
        tool(
            "set_orientation",
            "Set device orientation.",
            properties: [
                "orientation": stringProperty("portrait, portraitUpsideDown, landscapeLeft, landscapeRight, faceUp, faceDown"),
                "device": stringProperty("Override device selector"),
            ],
            required: ["orientation"]
        ),
        tool("end_session", "Close the DeviceInteraction session. Call when the flow is finished."),
    ]

    private static func callTool(
        _ name: String,
        arguments: [String: Any],
        store: ConfigStore,
        config: inout Config,
        engine: InteractionEngine
    ) throws -> [String: Any] {
        switch name {
        case "list_targets":
            return try toolResult(JSONValue.encodePretty(config))
        case "get_target":
            return try toolResult(JSONValue.encodePretty(config.resolvedCurrent()))
        case "set_target":
            let targetName = try requireString(arguments, "name")
            guard config.target(named: targetName) != nil else {
                throw DeviceAutomatorError.unknownTarget(targetName)
            }
            config.currentTarget = targetName
            try store.save(config)
            engine.endSession()
            return try toolResult(JSONValue.encodePretty(config.resolvedCurrent()))
        case "add_target":
            let targetName = try requireString(arguments, "name")
            var target = config.target(named: targetName) ?? AppTarget(name: targetName)
            if let projectPath = JSONValue.string(arguments, "project_path") { target.projectPath = projectPath }
            if let scheme = JSONValue.string(arguments, "scheme") { target.scheme = scheme }
            if let bundleId = JSONValue.string(arguments, "bundle_id") { target.bundleId = bundleId }
            if let device = JSONValue.string(arguments, "device") { target.device = device }
            config.upsert(target)
            try store.save(config)
            return try toolResult(JSONValue.encodePretty(config))
        case "remove_target":
            let targetName = try requireString(arguments, "name")
            config.remove(named: targetName)
            try store.save(config)
            return try toolResult(JSONValue.encodePretty(config))
        case "list_devices":
            return try toolResult(JSONValue.encodePretty(DeviceControl.listDevices()))
        case "boot_simulator":
            return try toolResult(engine.boot(device: try resolveDevice(arguments, config: config)))
        case "shutdown_simulator":
            return try toolResult(engine.shutdown(device: try resolveDevice(arguments, config: config)))
        case "screenshot":
            let device = try resolveDevice(arguments, config: config)
            let destination: URL
            if let raw = JSONValue.string(arguments, "destination"), !raw.isEmpty {
                destination = URL(fileURLWithPath: raw)
            } else {
                destination = try AppSupport.timestampedPNG()
            }
            try TargetGuard.ensureWriteIsOutsideTargets(destination: destination, config: config)
            let url = try DeviceControl.screenshot(device: device, destination: destination)
            return toolResult("Saved screenshot to \(url.path)")
        case "install_and_run":
            let target = try config.resolvedCurrent()
            let device = try resolveDevice(arguments, config: config)
            return try toolResult(engine.installAndRun(target: target, device: device, config: config))
        case "observe":
            return try synthesize("", arguments: arguments, config: config, engine: engine)
        case "tap":
            let x = try requireDouble(arguments, "x")
            let y = try requireDouble(arguments, "y")
            var command = "t \(format(x)) \(format(y))"
            if let duration = JSONValue.double(arguments, "duration") {
                command += " \(format(duration))"
            }
            return try synthesize(command, arguments: arguments, config: config, engine: engine)
        case "double_tap":
            let x = try requireDouble(arguments, "x")
            let y = try requireDouble(arguments, "y")
            return try synthesize("d \(format(x)) \(format(y))", arguments: arguments, config: config, engine: engine)
        case "swipe":
            let fromX = try requireDouble(arguments, "from_x")
            let fromY = try requireDouble(arguments, "from_y")
            let toX = try requireDouble(arguments, "to_x")
            let toY = try requireDouble(arguments, "to_y")
            var command = "t \(format(fromX)) \(format(fromY)) f \(format(toX)) \(format(toY))"
            if let duration = JSONValue.double(arguments, "duration") {
                command += " \(format(duration))"
            }
            return try synthesize(command, arguments: arguments, config: config, engine: engine)
        case "type":
            let text = try requireString(arguments, "text")
            return try synthesize("sender keyboard kbd \(text)", arguments: arguments, config: config, engine: engine)
        case "press_button":
            let button = try requireString(arguments, "button").lowercased()
            let token: String
            switch button {
            case "home", "h": token = "h"
            case "power", "p": token = "p"
            case "volume_up", "volup", "u": token = "u"
            case "volume_down", "voldown", "d": token = "d"
            default:
                throw DeviceAutomatorError.commandFailed("Unknown button '\(button)'. Use home, power, volume_up, volume_down.")
            }
            return try synthesize("b \(token)", arguments: arguments, config: config, engine: engine)
        case "set_orientation":
            let orientation = try requireString(arguments, "orientation")
            let device = try resolveDevice(arguments, config: config)
            do {
                return try toolResult(engine.setOrientation(device: device, orientation: orientation))
            } catch {
                return try synthesize("orientation \(orientation)", arguments: arguments, config: config, engine: engine)
            }
        case "end_session":
            engine.endSession()
            return toolResult("Device interaction session closed.")
        default:
            throw DeviceAutomatorError.commandFailed("Unknown tool '\(name)'.")
        }
    }

    private static func synthesize(
        _ command: String,
        arguments: [String: Any],
        config: Config,
        engine: InteractionEngine
    ) throws -> [String: Any] {
        let target = try config.resolvedCurrent()
        let device = try resolveDevice(arguments, config: config)
        return try toolResult(engine.synthesize(target: target, device: device, command: command))
    }

    private static func resolveDevice(_ arguments: [String: Any], config: Config) throws -> String {
        if let override = JSONValue.string(arguments, "device"), !override.isEmpty {
            return override
        }
        if let device = try config.resolvedCurrent().device, !device.isEmpty {
            return device
        }
        throw DeviceAutomatorError.missingArgument("device")
    }

    private static func requireString(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = JSONValue.string(arguments, key), !value.isEmpty else {
            throw DeviceAutomatorError.missingArgument(key)
        }
        return value
    }

    private static func requireDouble(_ arguments: [String: Any], _ key: String) throws -> Double {
        guard let value = JSONValue.double(arguments, key) else {
            throw DeviceAutomatorError.missingArgument(key)
        }
        return value
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private static func tool(
        _ name: String,
        _ description: String,
        properties: [String: Any] = [:],
        required: [String] = []
    ) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return [
            "name": name,
            "description": description,
            "inputSchema": schema,
        ]
    }

    private static func stringProperty(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func numberProperty(_ description: String) -> [String: Any] {
        ["type": "number", "description": description]
    }

    private static func toolResult(_ text: String, isError: Bool = false) -> [String: Any] {
        [
            "content": [["type": "text", "text": text]],
            "isError": isError,
        ]
    }

    private static func reply(id: Any?, result: Any, framing: JSONRPC.Framing) throws {
        guard id != nil else { return }
        try write(["jsonrpc": "2.0", "id": id as Any, "result": result], framing: framing)
    }

    private static func reply(id: Any?, error: (String, Int), framing: JSONRPC.Framing) throws {
        guard id != nil else { return }
        try write([
            "jsonrpc": "2.0",
            "id": id as Any,
            "error": ["code": error.1, "message": error.0],
        ], framing: framing)
    }

    private static func write(_ payload: [String: Any], framing: JSONRPC.Framing) throws {
        FileHandle.standardOutput.write(try JSONRPC.encode(payload, framing: framing))
        fflush(stdout)
    }
}
