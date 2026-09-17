import Foundation

do {
    try MCPRuntime.run()
} catch {
    let line = "DeviceAutomator: \(error.localizedDescription)\n"
    FileHandle.standardError.write(Data(line.utf8))
    exit(1)
}
