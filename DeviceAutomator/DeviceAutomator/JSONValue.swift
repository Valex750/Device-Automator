import Foundation

enum JSONValue {
    static func encodePretty<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func object(from data: Data) throws -> [String: Any] {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let object = raw as? [String: Any] else {
            throw DeviceAutomatorError.commandFailed("Expected a JSON object.")
        }
        return object
    }

    static func data(from object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: sanitize(object), options: [.sortedKeys])
    }

    static func sanitize(_ value: Any) -> Any {
        // NSNumber bridges to Bool/Int (`NSNumber(1) as? Bool == true`).
        // Leave decoded JSON numbers/bools alone so JSON-RPC ids stay integers.
        if value is NSNumber {
            return value
        }
        if let dict = value as? [String: Any] {
            return dict.mapValues(sanitize)
        }
        if let array = value as? [Any] {
            return array.map(sanitize)
        }
        if let bool = value as? Bool {
            return NSNumber(value: bool)
        }
        if let int = value as? Int {
            return NSNumber(value: int)
        }
        if let double = value as? Double {
            return NSNumber(value: double)
        }
        return value
    }

    static func string(_ arguments: [String: Any]?, _ key: String) -> String? {
        guard let value = arguments?[key] else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func double(_ arguments: [String: Any]?, _ key: String) -> Double? {
        guard let value = arguments?[key] else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
