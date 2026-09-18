import Darwin
import Foundation

/// NDJSON MCP client for `xcrun mcpbridge` (Apple's Xcode tools).
final class XcodeMCPClient {
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var nextID = 1
    private var buffer = Data()

    var isConnected: Bool { process?.isRunning == true }

    func connect() throws {
        disconnect()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["mcpbridge"]
        var environment = ProcessInfo.processInfo.environment
        if let pid = Self.runningXcodePID() {
            environment["MCP_XCODE_PID"] = pid
        }
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let err = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = err
        try process.run()

        self.process = process
        stdinHandle = input.fileHandleForWriting
        stdoutHandle = output.fileHandleForReading
        setNonBlocking(output.fileHandleForReading.fileDescriptor)

        _ = try request(
            "initialize",
            params: [
                "protocolVersion": "2025-11-25",
                "capabilities": [:],
                "clientInfo": ["name": "DeviceAutomator", "version": "0.1.0"],
            ],
            timeout: 15
        )
        try notify("notifications/initialized")
    }

    func disconnect() {
        process?.terminate()
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        buffer = Data()
    }

    deinit { disconnect() }

    func callTool(_ name: String, arguments: [String: Any] = [:], timeout: TimeInterval = 90) throws -> Any {
        try request(
            "tools/call",
            params: ["name": name, "arguments": arguments],
            timeout: timeout
        )
    }

    @discardableResult
    func request(_ method: String, params: [String: Any] = [:], timeout: TimeInterval) throws -> Any {
        guard isConnected else {
            throw DeviceAutomatorError.commandFailed("Xcode MCP is not connected. Open Xcode and enable Intelligence → Allow external agents.")
        }
        let id = nextID
        nextID += 1
        var payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty {
            payload["params"] = params
        }
        try write(payload)
        let response = try readObject(matchingID: id, timeout: timeout)
        if let error = response["error"] as? [String: Any] {
            let message = error["message"] as? String ?? String(describing: error)
            throw DeviceAutomatorError.commandFailed("Xcode MCP \(method) failed: \(message)")
        }
        return response["result"] ?? [:]
    }

    func notify(_ method: String, params: [String: Any] = [:]) throws {
        var payload: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if !params.isEmpty { payload["params"] = params }
        try write(payload)
    }

    private func write(_ payload: [String: Any]) throws {
        guard let stdinHandle else {
            throw DeviceAutomatorError.commandFailed("Xcode MCP stdin is closed.")
        }
            try stdinHandle.write(contentsOf: JSONRPC.encode(payload, framing: .ndjson))
    }

    // Reads responses until one whose "id" matches this request is found, discarding any
    // stray/out-of-order message in between (e.g. a late response to an earlier call, or a
    // server-initiated notification) rather than mistaking it for this request's reply.
    private func readObject(matchingID id: Int, timeout: TimeInterval) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = JSONRPC.extractNDJSON(from: &buffer) {
                let object = try JSONValue.object(from: line)
                if let responseID = object["id"] as? Int, responseID != id {
                    continue
                }
                return object
            }
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(stdoutHandle!.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                buffer.append(contentsOf: bytes[0..<count])
            } else if count == 0 {
                throw DeviceAutomatorError.commandFailed("Xcode MCP closed the connection.")
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(50_000)
            } else {
                throw DeviceAutomatorError.commandFailed("Xcode MCP read failed (\(errno)).")
            }
        }
        throw DeviceAutomatorError.commandFailed("Xcode MCP timed out after \(Int(timeout))s.")
    }

    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    static func runningXcodePID() -> String? {
        let result = try? ProcessRunner.run(
            executable: "/usr/bin/pgrep",
            arguments: ["-f", "/Applications/Xcode.app/Contents/MacOS/Xcode"]
        )
        let pid = result?.stdout.split(whereSeparator: \.isNewline).first.map(String.init)
        return pid?.isEmpty == false ? pid : nil
    }
}
