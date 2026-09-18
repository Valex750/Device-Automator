import Darwin
import Foundation

enum UnixSocket {
    static func listen(path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DeviceAutomatorError.commandFailed("Could not create unix socket (\(errno)).")
        }
        var option: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &option, socklen_t(MemoryLayout<Int32>.size))
        try withAddress(path) { addr, length in
            let result = Darwin.bind(fd, addr, length)
            if result != 0 {
                Darwin.close(fd)
                throw DeviceAutomatorError.commandFailed("Could not bind \(path) (\(errno)).")
            }
        }
        if Darwin.listen(fd, 8) != 0 {
            Darwin.close(fd)
            throw DeviceAutomatorError.commandFailed("Could not listen on \(path) (\(errno)).")
        }
        chmod(path, 0o600)
        return fd
    }

    static func accept(_ listenFD: Int32) throws -> Int32 {
        let client = Darwin.accept(listenFD, nil, nil)
        if client < 0 {
            throw DeviceAutomatorError.commandFailed("Accept failed (\(errno)).")
        }
        return client
    }

    static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DeviceAutomatorError.commandFailed("Could not create unix socket (\(errno)).")
        }
        do {
            try withAddress(path) { addr, length in
                let result = Darwin.connect(fd, addr, length)
                if result != 0 {
                    throw DeviceAutomatorError.commandFailed("Could not connect to \(path) (\(errno)).")
                }
            }
        } catch {
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    static func canConnect(path: String) -> Bool {
        guard let fd = try? connect(path: path) else { return false }
        Darwin.close(fd)
        return true
    }

    private static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Void) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = path.utf8CString
        guard bytes.count <= maxLen else {
            throw DeviceAutomatorError.commandFailed("Socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            bytes.withUnsafeBytes { src in
                dest.copyMemory(from: UnsafeRawBufferPointer(src))
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        try withUnsafePointer(to: &addr) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                try body(sockaddrPointer, length)
            }
        }
    }
}

enum FDCopy {
    static func pipe(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(source, &buffer, buffer.count)
            if count <= 0 { break }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { raw in
                    Darwin.write(destination, raw.baseAddress!.advanced(by: offset), count - offset)
                }
                if written <= 0 { return }
                offset += written
            }
        }
    }
}
