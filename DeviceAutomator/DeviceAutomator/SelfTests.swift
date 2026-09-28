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
        expect(!ObserveNormalization.hasLiveApplication(in: "Observe failed: missing hierarchyPath"), "a bare hierarchyPath mention is not evidence")
        expect(!ObserveNormalization.hasLiveApplication(in: #"{"hierarchyPath":"","applicationState":"NotRun"}"#), "an empty hierarchyPath is not evidence")
        expect(ObserveNormalization.hasLiveApplication(in: #"{"hierarchyPath" : "/tmp/h.txt"}"#), "a hierarchyPath value is evidence")
        expect(
            ObserveNormalization.rewrite(#"{"applicationState":"NotRun","hierarchyPath":"   "}"#).contains("NotRun"),
            "a whitespace-only hierarchyPath keeps NotRun"
        )
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
            ) == nil,
            "a single window reporting a different workspace path is rejected"
        )
        expect(
            MCPResult.matchingIdentifier(in: "tabIdentifier: windowtab1", pathHint: "/Users/me/App/App.xcodeproj") == "windowtab1",
            "a single window with no path data is still used"
        )
        let jsonWindows: [String: Any] = ["content": [["type": "text", "text": """
        {"windows":[{"tabIdentifier":"a","workspacePath":"/p/One.xcodeproj"},{"tabIdentifier":"b","workspacePath":"/p/Two/Two.xcodeproj"}]}
        """]]]
        expect(
            MCPResult.matchingIdentifier(in: jsonWindows, pathHint: "/p/Two/Two.xcodeproj") == "b",
            "JSON workspace records match per record"
        )

        let menuPickerRow = """
                        Other, {{23.4, 521.0}, {355.3, 49.9}}, hitPoint: {201.0, 545.9}
                         Button, {{38.7, 529.6}, {324.5, 33.0}}, label: 'Muscle Group, All Muscles', hitPoint: {201.0, 546.1}
                          StaticText, {{264.7, 536.3}, {82.9, 19.5}}, label: 'All Muscles', hitPoint: {306.1, 546.1}
                         StaticText, {{38.7, 536.2}, {102.1, 19.5}}, label: 'Muscle Group', hitPoint: {89.8, 545.9}
                         Button, {{23.4, 793.7}, {355.3, 49.9}}, label: 'Clear All Filters', hitPoint: {201.0, 818.6}
                          StaticText, {{140.0, 808.0}, {122.0, 20.0}}, label: 'Clear All Filters', hitPoint: {201.0, 818.0}
                        Cell, {{23.4, 587.9}, {355.3, 38.7}}, hitPoint: {201.0, 607.2}
                         Other, {{23.4, 587.9}, {355.3, 38.7}}, hitPoint: {201.0, 607.2}
                        Button, {{10.0, 900.0}, {40.0, 40.0}}, identifier: 'plus', hitPoint: {30.0, 920.0}
                        Switch, {{23.4, 710.1}, {355.3, 49.9}}, label: 'Show Favorites Only', value: 0, hitPoint: {201.0, 735.1}
                         StaticText, {{38.7, 725.3}, {148.2, 19.5}}, label: 'Show Favorites Only', hitPoint: {112.8, 735.1}
                         Switch, {{304.7, 721.7}, {60.5, 26.9}}, value: 0, hitPoint: {334.9, 735.1}
        """
        let adjustedTree = TapTargets.adjust(menuPickerRow).components(separatedBy: "\n")
        expect(
            adjustedTree[1].contains("hitPoint: {306.1, 546.1}, boxCenter: {201.0, 546.1}"),
            "menu Picker row Button moves onto its value text: \(adjustedTree[1])"
        )
        expect(adjustedTree[4].hasSuffix("hitPoint: {201.0, 818.6}"), "a Button whose center hits its label is unchanged")
        expect(adjustedTree[6].hasSuffix("hitPoint: {201.0, 607.2}"), "a Cell covered by a child is unchanged")
        expect(adjustedTree[8].hasSuffix("hitPoint: {30.0, 920.0}"), "a Button with no children is unchanged")
        expect(
            adjustedTree[9].contains("hitPoint: {334.9, 735.1}, boxCenter: {201.0, 735.1}"),
            "a List Toggle row moves onto its inner Switch, not its label: \(adjustedTree[9])"
        )
        expect(adjustedTree[11].hasSuffix("hitPoint: {334.9, 735.1}"), "the inner Switch itself is unchanged")
        expect(
            TapTargets.adjust(menuPickerRow).components(separatedBy: "boxCenter").count == 3,
            "only the dead-center Button and Switch are rewritten"
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
