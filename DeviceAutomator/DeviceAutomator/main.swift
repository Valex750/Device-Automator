import Foundation

let args = CommandLine.arguments
do {
    if args.contains("--self-test") {
        try SelfTests.run()
    } else if args.contains("--daemon") {
        try EngineDaemon.run()
    } else {
        try EngineDaemon.proxyStdio()
    }
} catch {
    let line = "DeviceAutomator: \(error.localizedDescription)\n"
    FileHandle.standardError.write(Data(line.utf8))
    exit(1)
}
