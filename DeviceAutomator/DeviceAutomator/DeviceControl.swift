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
        let result = try ProcessRunner.xcrun([
            "devicectl", "device", "capture", "screenshot",
            "--device", device,
            "--destination", destination.path,
        ])
        try result.throwIfFailed(label: "devicectl capture screenshot")
        return destination
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
