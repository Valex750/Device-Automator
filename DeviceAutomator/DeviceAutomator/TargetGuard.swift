import Foundation

enum TargetGuard {
    /// Device Automator never writes into a configured app project. Screenshots and
    /// config live under Application Support (or an explicit destination outside those trees).
    static func ensureWriteIsOutsideTargets(destination: URL, config: Config) throws {
        let destinationPath = destination.standardizedFileURL.resolvingSymlinksInPath().path
        for target in config.targets {
            guard let projectPath = target.projectPath, !projectPath.isEmpty else { continue }
            let projectURL = URL(fileURLWithPath: projectPath).standardizedFileURL.resolvingSymlinksInPath()
            let projectRoot = projectURL.deletingLastPathComponent().path
            if destinationPath == projectRoot
                || destinationPath.hasPrefix(projectRoot.hasSuffix("/") ? projectRoot : projectRoot + "/")
                || destinationPath == projectURL.path
                || destinationPath.hasPrefix(projectURL.path + "/") {
                throw DeviceAutomatorError.commandFailed(
                    "Refusing to write \(destinationPath) inside target app '\(target.name)' (\(projectRoot))."
                )
            }
        }
    }
}
