import Foundation

struct CommandResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { status == 0 }

    func throwIfFailed(label: String) throws {
        guard succeeded else {
            let detail = [stderr, stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "exit \(status)"
            throw DeviceAutomatorError.commandFailed("\(label) failed: \(detail)")
        }
    }
}

enum ProcessRunner {
    static func run(
        executable: String,
        arguments: [String],
        extraEnvironment: [String: String] = [:]
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        extraEnvironment.forEach { environment[$0] = $1 }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        try process.run()

        // Drain both pipes on the side. Waiting for exit first deadlocks when
        // xcrun writes more than the kernel pipe buffer (~64KB).
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let group = DispatchGroup()
        let lock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = stdoutHandle.readDataToEndOfFile()
            lock.lock()
            stdoutData = data
            lock.unlock()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = stderrHandle.readDataToEndOfFile()
            lock.lock()
            stderrData = data
            lock.unlock()
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    static func xcrun(_ arguments: [String]) throws -> CommandResult {
        try run(executable: "/usr/bin/xcrun", arguments: arguments)
    }
}
