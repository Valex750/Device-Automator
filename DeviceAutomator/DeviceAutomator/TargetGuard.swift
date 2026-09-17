import Foundation

enum TargetGuard {
    /// Device Automator never writes into a configured app project. Screenshots and
    /// config live under Application Support (or an explicit destination outside those trees).
    static func ensureWriteIsOutsideTargets(destination: URL, config: Config) throws {
        let destinationPath = destination.standardizedFileURL.path
        for target in config.targets {
            guard let projectPath = target.projectPath, !projectPath.isEmpty else { continue }
            let projectURL = URL(fileURLWithPath: projectPath).standardizedFileURL
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

enum DefaultTargets {
    /// Host-side seed only. Does not open or modify Lift Planner source.
    static let liftPlanner = AppTarget(
        name: "Lift Planner",
        projectPath: "/Users/alexeyvinnik/Develop/Lift Planner/Lift Planner.xcodeproj",
        scheme: "Lift Planner",
        bundleId: "vinalex.lift-planner",
        device: "6ADCEE06-1AFB-4B91-84A3-5C20418FAFA7"
    )

    static func seededConfig(existing: Config) -> Config {
        var config = existing
        if config.target(named: liftPlanner.name) == nil {
            config.upsert(liftPlanner)
        }
        if config.currentTarget == nil {
            config.currentTarget = liftPlanner.name
        }
        return config
    }
}
