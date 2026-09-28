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

        let scrolledList = """
         Window, {{0.0, 0.0}, {402.0, 874.0}}, hitPoint: {201.0, 437.0}
          Toolbar, {{0.0, 0.0}, {402.0, 874.0}}, hitPoint: {201.0, 437.0}
          Other, {{0.0, 0.0}, {402.0, 874.0}}, hitPoint: {201.0, 437.0}
           NavigationBar, {{0.0, 62.0}, {402.0, 54.0}}, identifier: 'Exercise Library', hitPoint: {201.0, 89.0}
            Button, {{15.9, 62.0}, {44.2, 44.0}}, identifier: 'BackButton', label: 'Back', hitPoint: {38.0, 84.0}
           Button, {{151.0, 58.0}, {100.0, 24.0}}, label: 'Sheet Grabber', hitPoint: {201.0, 70.0}
           ScrollView, {{0.0, 0.0}, {402.0, 874.0}}, hitPoint: {201.0, 437.0}
            Button, {{16.0, -45.7}, {370.0, 68.0}}, label: 'Dumbbell Bench Press, Dumbbell', hitPoint: {201.0, 11.2}
             Image, {{28.0, -33.7}, {44.0, 44.0}}, label: 'chest', hitPoint: {50.0, 5.2}
            Button, {{16.0, 486.3}, {370.0, 68.0}}, label: 'Pec Deck, Cable', hitPoint: {201.0, 520.3}
             Image, {{28.0, 498.3}, {44.0, 44.0}}, label: 'chest', hitPoint: {50.0, 520.3}
            Button, {{16.0, 769.3}, {370.0, 68.0}}, label: 'Barbell Shrugs, Barbell', hitPoint: {201.0, 803.3}
             Image, {{28.0, 781.3}, {44.0, 44.0}}, label: 'shoulders', hitPoint: {50.0, 803.3}
            StaticText, {{84.0, 874.0}, {31.0, 13.3}}, label: 'Cable', hitPoint: {99.5, 874.5}
           TabBar, {{0.0, 791.0}, {402.0, 83.0}}, label: 'Tab Bar', hitPoint: {201.0, 832.5}
            Button, {{110.7, 795.0}, {95.0, 54.0}}, label: 'Exercises', hitPoint: {158.2, 822.0}
        """
        let scrolled = TapTargets.adjust(scrolledList).components(separatedBy: "\n")
        expect(
            scrolled[7].hasSuffix("hitPoint: {201.0, 11.2}, hiddenBy: NavigationBar"),
            "a row scrolled under the NavigationBar is not moved onto a hidden child and is marked: \(scrolled[7])"
        )
        expect(scrolled[8].hasSuffix("hiddenBy: NavigationBar"), "a child under the NavigationBar is marked")
        expect(
            scrolled[9].hasSuffix("hitPoint: {50.0, 520.3}, boxCenter: {201.0, 520.3}"),
            "a visible dead-center row still moves onto its icon: \(scrolled[9])"
        )
        expect(
            scrolled[11].hasSuffix("hitPoint: {201.0, 803.3}, hiddenBy: TabBar"),
            "a row under the TabBar keeps its hitPoint and is marked: \(scrolled[11])"
        )
        expect(scrolled[13].hasSuffix("hiddenBy: offscreen"), "a point below the window is offscreen: \(scrolled[13])")
        expect(!scrolled[4].contains("hiddenBy"), "a bar's own buttons are not hidden by it")
        expect(!scrolled[5].contains("hiddenBy"), "a non-scrolling control over the NavigationBar is not hidden")
        expect(!scrolled[15].contains("hiddenBy"), "tab bar buttons are not hidden")
        expect(
            !scrolled[9].contains("hiddenBy"),
            "a full-screen Toolbar hosting view does not count as a bar: \(scrolled[9])"
        )

        expect(EngineDaemon.isVersion("0.2.10", newerThan: "0.2.9"), "versions compare numerically")
        expect(EngineDaemon.isVersion("0.3", newerThan: "0.2.9"), "a shorter newer version wins")
        expect(!EngineDaemon.isVersion("0.2.8", newerThan: "0.2.9"), "an older version is not newer")
        expect(!EngineDaemon.isVersion("0.2.9", newerThan: "0.2.9.0"), "equal versions are not newer")

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
