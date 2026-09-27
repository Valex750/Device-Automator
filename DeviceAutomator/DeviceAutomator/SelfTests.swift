import Foundation

enum SelfTests {
    static func run() throws {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        var minted = Set<String>()
        for _ in 0..<20 {
            let id = SessionIdentity.mint(excluding: minted)
            expect(!id.isEmpty, "minted identifier should not be empty")
            expect(id != "default", "must never mint 'default'")
            expect(id != "Device Automator", "must never mint the bare leftover name")
            expect(id.hasPrefix("Device Automator "), "identifier should be Title Case with unique suffix: \(id)")
            expect(!minted.contains(id), "minted identifiers must be unique: \(id)")
            minted.insert(id)
        }

        expect(
            SessionFailure.classify("This session identifier is currently in use or was recently used. To recover, try a different one.") == .identifierInUse,
            "in-use classification"
        )
        expect(
            SessionFailure.classify("Session not found. It may have already been closed, or the identifier is wrong") == .sessionNotFound,
            "session-not-found classification"
        )
        expect(SessionFailure.classify("IDEKit.IDEStatefulActionError") == .statefulAction, "stateful classification")
        expect(
            SessionFailure.classify("Xcode started a device session but returned no session key.") == .missingKey,
            "missing-key classification"
        )
        expect(SessionFailure.isRecoverableStartFailure("currently in use or was recently used"), "in-use is recoverable")

        let inUseResult: [String: Any] = [
            "isError": true,
            "content": [[
                "type": "text",
                "text": "This session identifier is currently in use or was recently used.",
            ]],
        ]
        expect(!MCPResult.isUnavailable(inUseResult), "identifier-in-use must not look like a missing tool")
        expect(
            MCPResult.isUnavailable([
                "isError": true,
                "content": [["type": "text", "text": "Tool 'XcodeListWorkspaces' is not enabled."]],
            ]),
            "not-enabled is unavailable"
        )

        let liveJSON = """
        {"applicationState":"NotRun","hierarchyPath":"/tmp/hierarchy.txt","pid":62609}
        """
        let rewritten = ObserveNormalization.rewrite(liveJSON)
        expect(rewritten.contains("\"applicationState\" : \"Running\"") || rewritten.contains("\"applicationState\":\"Running\""), "NotRun with hierarchyPath becomes Running: \(rewritten)")
        expect(!rewritten.localizedCaseInsensitiveContains("NotRun"), "rewritten live observe must not say NotRun")

        let liveTree = """
        {"applicationState":"NotRun","hierarchy":"Application, pid: 62609, label: 'MyApp'"}
        """
        let treeRewritten = ObserveNormalization.rewrite(liveTree)
        expect(!treeRewritten.localizedCaseInsensitiveContains("NotRun"), "live hierarchy text must not stay NotRun: \(treeRewritten)")

        let actuallyNotRun = """
        {"applicationState":"NotRun"}
        """
        expect(
            ObserveNormalization.rewrite(actuallyNotRun).contains("NotRun"),
            "NotRun without hierarchy evidence is kept"
        )

        expect(ObserveNormalization.hasLiveApplication(in: "Application, pid: 62609, label: 'MyApp'"), "pid evidence")
        expect(!ObserveNormalization.hasLiveApplication(in: "Application, pid: 0, label: 'None'"), "pid 0 is not live")

        let twoWindows = """
        * tabIdentifier: windowtab1, workspacePath: /Users/me/Other/Other.xcodeproj
        * tabIdentifier: windowtab2, workspacePath: /Users/me/App/App.xcodeproj
        """
        expect(
            MCPResult.matchingIdentifier(in: twoWindows, pathHint: "/Users/me/App/App.xcodeproj") == "windowtab2",
            "workspace match uses the identifier from the matching window"
        )
        expect(
            MCPResult.matchingIdentifier(in: twoWindows, pathHint: "/Users/me/Missing/Missing.xcodeproj") == nil,
            "no match across several windows returns nil"
        )
        expect(
            MCPResult.matchingIdentifier(
                in: "tabIdentifier: windowtab1, workspacePath: /x/y.xcodeproj",
                pathHint: "/Users/me/App/App.xcodeproj"
            ) == "windowtab1",
            "a single window is still used when the path format differs"
        )
        let jsonWindows: [String: Any] = ["content": [["type": "text", "text": """
        {"windows":[{"tabIdentifier":"a","workspacePath":"/p/One.xcodeproj"},{"tabIdentifier":"b","workspacePath":"/p/Two/Two.xcodeproj"}]}
        """]]]
        expect(
            MCPResult.matchingIdentifier(in: jsonWindows, pathHint: "/p/Two/Two.xcodeproj") == "b",
            "JSON workspace records match per record"
        )

        var negative = Data("Content-Length: -5\r\n\r\n{}".utf8)
        expect((try? JSONRPC.extractContentLength(from: &negative)) == nil, "negative Content-Length is rejected")

        if failures.isEmpty {
            FileHandle.standardOutput.write(Data("self-test: ok\n".utf8))
            return
        }
        let report = "self-test: \(failures.count) failed\n" + failures.map { "- \($0)\n" }.joined()
        throw DeviceAutomatorError.commandFailed(report)
    }
}
