import Foundation
import Darwin

enum JSONRPC {
    enum Framing {
        case contentLength
        case ndjson
    }

    static func encode(_ object: [String: Any], framing: Framing) throws -> Data {
        let payload = JSONValue.sanitize(object) as? [String: Any] ?? object
        switch framing {
        case .ndjson:
            return try JSONValue.data(from: payload) + Data([0x0A])
        case .contentLength:
            let body = try JSONValue.data(from: payload)
            let header = "Content-Length: \(body.count)\r\n\r\n"
            return Data(header.utf8) + body
        }
    }

    static func extractNDJSON(from buffer: inout Data) -> Data? {
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = buffer.subdata(in: buffer.startIndex..<newline)
        let next = buffer.index(after: newline)
        buffer.removeSubrange(buffer.startIndex..<next)
        let trimmed = line.filter { $0 != 0x0D }
        return trimmed.isEmpty ? extractNDJSON(from: &buffer) : Data(trimmed)
    }

    static func extractContentLength(from buffer: inout Data) throws -> Data? {
        guard let headerEnd = blankLineRange(in: buffer) else { return nil }
        let header = String(data: buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound), encoding: .utf8) ?? ""
        var length: Int?
        for line in header.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.first?.trimmingCharacters(in: .whitespaces).lowercased() == "content-length",
               parts.count == 2 {
                length = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        guard let length else {
            throw DeviceAutomatorError.commandFailed("MCP message missing Content-Length.")
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.count >= bodyStart + length else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        buffer.removeSubrange(0..<(bodyStart + length))
        return body
    }

    static func extractMessage(from buffer: inout Data, framing: inout Framing) throws -> Data? {
        if blankLineRange(in: buffer) != nil {
            framing = .contentLength
            return try extractContentLength(from: &buffer)
        }
        if buffer.first == 0x7B, let line = extractNDJSON(from: &buffer) {
            framing = .ndjson
            return line
        }
        return nil
    }

    private static func blankLineRange(in buffer: Data) -> Range<Data.Index>? {
        if let range = buffer.range(of: Data("\r\n\r\n".utf8)) { return range }
        if let range = buffer.range(of: Data("\n\n".utf8)) { return range }
        return nil
    }
}

enum AppSupport {
    static func root() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = root.appendingPathComponent("DeviceAutomator", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func screenshots() throws -> URL {
        let dir = try root().appendingPathComponent("screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func derivedData(for targetName: String) throws -> URL {
        let dir = try root().appendingPathComponent("derived/\(targetName)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func timestampedPNG() throws -> URL {
        let name = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return try screenshots().appendingPathComponent("\(name).png")
    }
}
