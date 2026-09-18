import Darwin
import Foundation

private var engineListenFD: Int32 = -1
private var engineStopFlag: Int32 = 0

private func engineHandleSignal(_ signal: Int32) {
    _ = signal
    engineStopFlag = 1
    let fd = engineListenFD
    engineListenFD = -1
    if fd >= 0 {
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        _ = Darwin.close(fd)
    }
}

/// One DeviceInteraction owner per machine. MCP stdio processes attach as proxies.
enum EngineDaemon {
    static func run() throws {
        _ = Darwin.setsid()
        signal(SIGHUP, SIG_IGN)
        signal(SIGTERM, engineHandleSignal)
        signal(SIGINT, engineHandleSignal)

        let socketURL = try AppSupport.engineSocket()
        if isForeignDaemonLive() {
            EngineLog.write("daemon: another live daemon owns the socket, exiting")
            return
        }
        if let pidURL = try? AppSupport.enginePID(),
           let text = try? String(contentsOf: pidURL, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid != getpid(),
           !ProcessLiveness.isAlive(pid) {
            unlink(socketURL.path)
        }

        let listenFD = try UnixSocket.listen(path: socketURL.path)
        engineListenFD = listenFD
        try writePID()
        EngineLog.write("daemon: listening pid=\(getpid()) version=\(MCPRuntime.version)")

        let state = try ServerState.load()
        state.engine.reclaimOrphanedSessionIfNeeded()

        while engineStopFlag == 0 {
            let client: Int32
            do {
                client = try UnixSocket.accept(listenFD)
            } catch {
                if engineStopFlag != 0 { break }
                EngineLog.write("daemon: accept \(error.localizedDescription)")
                continue
            }
            EngineLog.write("daemon: client connected")
            DispatchQueue.global(qos: .userInitiated).async {
                serveClient(client, state: state)
            }
        }

        state.engine.endSession(disconnectClient: true)
        if engineListenFD >= 0 {
            Darwin.close(listenFD)
        }
        unlink(socketURL.path)
        if let pidURL = try? AppSupport.enginePID() {
            try? FileManager.default.removeItem(at: pidURL)
        }
        EngineLog.write("daemon: stopped")
    }

    static func proxyStdio() throws {
        let fd = try connectOrSpawn()
        let stdinFD = FileHandle.standardInput.fileDescriptor
        let stdoutFD = FileHandle.standardOutput.fileDescriptor
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            FDCopy.pipe(from: stdinFD, to: fd)
            _ = Darwin.shutdown(fd, SHUT_WR)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            FDCopy.pipe(from: fd, to: stdoutFD)
            fflush(stdout)
            group.leave()
        }
        group.wait()
        Darwin.close(fd)
    }

    private static func serveClient(_ client: Int32, state: ServerState) {
        let input = FileHandle(fileDescriptor: client, closeOnDealloc: false)
        let output = FileHandle(fileDescriptor: client, closeOnDealloc: false)
        defer {
            Darwin.close(client)
            EngineLog.write("daemon: client disconnected")
        }
        do {
            try MCPRuntime.serve(from: input, to: output, state: state)
        } catch {
            EngineLog.write("daemon: client error \(error.localizedDescription)")
        }
    }

    private static func connectOrSpawn() throws -> Int32 {
        let socketURL = try AppSupport.engineSocket()
        if let fd = try connectIfCurrent(path: socketURL.path) {
            return fd
        }
        let lockURL = try AppSupport.engineLock()
        let lockFD = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else {
            throw DeviceAutomatorError.commandFailed("Could not open engine lock (\(errno)).")
        }
        _ = fcntl(lockFD, F_SETFD, FD_CLOEXEC)
        defer {
            _ = flock(lockFD, LOCK_UN)
            Darwin.close(lockFD)
        }
        while flock(lockFD, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw DeviceAutomatorError.commandFailed("Could not lock engine.lock (\(errno)).")
        }
        if let fd = try connectIfCurrent(path: socketURL.path) {
            return fd
        }
        try replaceStaleDaemon()
        if let fd = try connectIfCurrent(path: socketURL.path) {
            return fd
        }
        try spawnDaemon()
        return try waitForConnect(path: socketURL.path)
    }

    /// Attach only to a live daemon running this same protocol version.
    private static func connectIfCurrent(path: String) throws -> Int32? {
        if let info = readPIDFile(),
           ProcessLiveness.isAlive(info.pid),
           info.version != MCPRuntime.version {
            return nil
        }
        return try? UnixSocket.connect(path: path)
    }

    private static func replaceStaleDaemon() throws {
        guard let info = readPIDFile(), ProcessLiveness.isAlive(info.pid) else { return }
        if info.version == MCPRuntime.version {
            return
        }
        EngineLog.write("proxy: stopping stale daemon pid=\(info.pid) version=\(info.version)")
        kill(info.pid, SIGTERM)
        for _ in 0..<30 {
            if !ProcessLiveness.isAlive(info.pid) { break }
            usleep(100_000)
        }
        if ProcessLiveness.isAlive(info.pid) {
            kill(info.pid, SIGKILL)
            usleep(200_000)
        }
        if let socket = try? AppSupport.engineSocket() {
            unlink(socket.path)
        }
    }

    private static func spawnDaemon() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--daemon"]
        process.standardInput = FileHandle.nullDevice
        let logURL = try AppSupport.engineLog()
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: logURL)
        _ = try? log.seekToEnd()
        process.standardOutput = log
        process.standardError = log
        process.qualityOfService = .userInitiated
        try process.run()
        EngineLog.write("proxy: spawned daemon pid=\(process.processIdentifier)")
    }

    private static func waitForConnect(path: String, attempts: Int = 50) throws -> Int32 {
        for _ in 0..<attempts {
            if let fd = try? UnixSocket.connect(path: path) {
                return fd
            }
            usleep(100_000)
        }
        let log = (try? AppSupport.engineLog().path) ?? "engine.log"
        throw DeviceAutomatorError.commandFailed("Device Automator daemon did not start. See \(log).")
    }

    private static func isForeignDaemonLive() -> Bool {
        guard let info = readPIDFile(),
              info.pid != getpid(),
              ProcessLiveness.isAlive(info.pid),
              let socket = try? AppSupport.engineSocket() else {
            return false
        }
        return UnixSocket.canConnect(path: socket.path)
    }

    private static func writePID() throws {
        let url = try AppSupport.enginePID()
        try "\(getpid())\n\(MCPRuntime.version)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    private static func readPIDFile() -> (pid: Int32, version: String)? {
        guard let url = try? AppSupport.enginePID(),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let first = lines.first, let pid = Int32(first) else { return nil }
        let version = lines.count > 1 ? lines[1] : "0.1.0"
        return (pid, version)
    }
}
