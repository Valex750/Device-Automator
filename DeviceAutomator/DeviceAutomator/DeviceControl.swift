import Foundation

struct DeviceSummary: Codable, Sendable {
    var name: String?
    var identifier: String?
    var reality: String?
    var deviceType: String?
    var platform: String?
    var bootState: String?
    var connectionState: String?
    var transport: String?
}

enum DeviceControl {
    static func listDevices() throws -> [DeviceSummary] {
        let result = try ProcessRunner.xcrun([
            "devicectl", "list", "devices",
            "--json-output", "-",
            "--omit-deprecated-fields-in-json",
        ])
        try result.throwIfFailed(label: "devicectl list devices")
        return try parseDeviceList(result.stdout)
    }

    static func screenshot(device: String, destination: URL) throws -> URL {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        var arguments = [
            "devicectl", "device", "capture", "screenshot",
            "--device", device,
            "--destination", destination.path,
        ]
        // devicectl's default pick on a foldable is the inner display even while it is dark.
        if let display = activeDisplayID(device: device) {
            arguments += ["--display-unique-id", display]
        }
        let result = try ProcessRunner.xcrun(arguments)
        try result.throwIfFailed(label: "devicectl capture screenshot")
        return destination
    }

    /// The display to capture on a multi-display device (iPhone Duo): the one that is lit.
    /// nil leaves the choice to devicectl (one display, query failed, or none reports active).
    static func activeDisplayID(device: String) -> String? {
        guard let result = try? ProcessRunner.xcrun([
            "devicectl", "device", "info", "displays",
            "--device", device,
            "--json-output", "-",
            "--quiet",
            "--timeout", "10",
        ]), result.succeeded else {
            return nil
        }
        return parseActiveDisplayID(result.stdout)
    }

    static func parseActiveDisplayID(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let displays = (object["result"] as? [String: Any])?["displays"] as? [[String: Any]],
              displays.count > 1
        else {
            return nil
        }
        let active = displays.filter { $0["active"] as? Bool == true }
        let chosen = active.first { $0["primary"] as? Bool == true } ?? active.first
        return chosen?["uniqueId"] as? String
    }

    static func parseDeviceList(_ json: String) throws -> [DeviceSummary] {
        guard let data = json.data(using: .utf8) else {
            throw DeviceAutomatorError.commandFailed("devicectl produced non-UTF8 JSON.")
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let devices = ((object?["result"] as? [String: Any])?["devices"] as? [[String: Any]]) ?? []
        return devices.map(summarize(device:))
    }

    private static func summarize(device: [String: Any]) -> DeviceSummary {
        let properties = device["properties"] as? [String: Any] ?? [:]
        let hardware = properties["hardware"] as? [String: Any] ?? [:]
        let state = properties["state"] as? [String: Any] ?? [:]
        let connection = properties["connection"] as? [String: Any] ?? [:]
        let identifier = (device["identifier"] as? String)
            ?? (properties["identifier"] as? String)
            ?? (hardware["udid"] as? String)
        return DeviceSummary(
            name: properties["name"] as? String ?? hardware["marketingName"] as? String,
            identifier: identifier,
            reality: hardware["reality"] as? String,
            deviceType: hardware["deviceType"] as? String,
            platform: hardware["platform"] as? String,
            bootState: state["bootState"] as? String,
            connectionState: connection["state"] as? String,
            transport: connection["transportType"] as? String
        )
    }
}
