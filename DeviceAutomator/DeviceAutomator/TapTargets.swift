import CoreGraphics
import Foundation

/// Accessibility frames are boxes, not tappable areas. A SwiftUI `.menu` Picker
/// in a List reports one Button spanning the whole row, but only its trailing
/// value opens the menu; a `.plain` List row Button has a Spacer gap at its
/// center. Xcode still reports the box center as `hitPoint`, so agents tap dead
/// space. A List Toggle is the same: a row-wide Switch whose center misses both
/// the label and the inner Switch, and only the inner Switch toggles. When a
/// Button/Cell/Link/Switch center misses every descendant, move its hitPoint to
/// a visible descendant of the same type (the real control) if there is one,
/// otherwise to the first visible descendant.
///
/// Rows scrolled under a NavigationBar/TabBar/Toolbar, or off the window, keep
/// their frames in the tree but cannot be tapped. Such hitPoints get
/// `hiddenBy: <bar>` (or `offscreen`) so agents scroll before tapping. Only
/// content inside a scroll container can slide under a bar, and only bars in the
/// same Window outside that container count. Sheets and menus hide what is
/// underneath from accessibility, so their bars never cover the presenter.
enum TapTargets {
    static let header = "# Device Automator: a Button/Cell/Link/Switch whose box center misses all its children has hitPoint moved onto a visible child (a same-type child first); boxCenter is the original. hiddenBy marks a hitPoint under a bar or offscreen, on the element and on each of its children: scroll the row into view before tapping any of them.\n"

    private static let adjustable: Set<String> = ["Button", "Cell", "Link", "Switch"]
    private static let bars: Set<String> = ["NavigationBar", "TabBar", "Toolbar"]
    /// Only scrolled content can slide under a bar.
    private static let scrollers: Set<String> = ["ScrollView", "Table", "CollectionView", "WebView"]
    /// SwiftUI often reports full-screen hosting views as Toolbar; real bars are
    /// at most a large-title NavigationBar (about 160pt) tall.
    private static let maxBarHeight: CGFloat = 200
    /// Element types an agent taps; containers such as Other or ScrollView are not marked.
    private static let tappable: Set<String> = [
        "Button", "Cell", "Link", "Switch", "Toggle", "StaticText", "Image", "Icon",
        "TextField", "SecureTextField", "SearchField", "TextView", "Slider", "Stepper",
        "SegmentedControl", "Picker", "PickerWheel", "MenuItem",
    ]

    private struct Node {
        let indent: Int
        let type: String
        let frame: CGRect?
        let hitPoint: CGPoint?
    }

    /// Writes an adjusted sibling copy of the dump and returns its path, or
    /// `path` unchanged when nothing needed changing or the file is unreadable.
    static func adjustFile(atPath path: String) -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return path }
        let adjusted = adjust(text)
        guard adjusted != text else { return path }
        let url = URL(fileURLWithPath: path)
        let base = url.deletingPathExtension().lastPathComponent
        let out = url.deletingLastPathComponent().appendingPathComponent("\(base)-taps.\(url.pathExtension.isEmpty ? "txt" : url.pathExtension)")
        do {
            try (header + adjusted).write(to: out, atomically: true, encoding: .utf8)
            return out.path
        } catch {
            EngineLog.write("tap-targets: could not write \(out.path): \(error.localizedDescription)")
            return path
        }
    }

    static func adjust(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let nodes = lines.map(parse)
        let parents = parentIndices(nodes)
        // Index one past each node's subtree.
        var subtreeEnd = Array(repeating: nodes.count, count: nodes.count)
        for index in nodes.indices {
            var next = index + 1
            while next < nodes.count, nodes[next].indent > nodes[index].indent { next += 1 }
            subtreeEnd[index] = next
        }
        func window(of index: Int) -> Int? {
            var current = parents[index]
            while let i = current {
                if nodes[i].type == "Window" { return i }
                current = parents[i]
            }
            return nil
        }
        let barIndices = nodes.indices.filter {
            bars.contains(nodes[$0].type) && (nodes[$0].frame.map { $0.height <= maxBarHeight } ?? false)
        }
        func scroller(of index: Int) -> Int? {
            var current = parents[index]
            while let i = current {
                if scrollers.contains(nodes[i].type) { return i }
                if nodes[i].type == "Window" { return nil }
                current = parents[i]
            }
            return nil
        }
        func hiddenBy(_ point: CGPoint, node index: Int) -> String? {
            guard let windowIndex = window(of: index), let bounds = nodes[windowIndex].frame else { return nil }
            if !bounds.contains(point) { return "offscreen" }
            guard let scroll = scroller(of: index) else { return nil }
            for bar in barIndices where window(of: bar) == windowIndex {
                let barInsideScroller = scroll < bar && bar < subtreeEnd[scroll]
                guard !barInsideScroller, let barFrame = nodes[bar].frame else { continue }
                // Content scrolls under a NavigationBar up to the window top (status
                // bar area), and under a TabBar/Toolbar down to the window bottom.
                let covered = nodes[bar].type == "NavigationBar"
                    ? CGRect(x: barFrame.minX, y: bounds.minY, width: barFrame.width, height: barFrame.maxY - bounds.minY)
                    : CGRect(x: barFrame.minX, y: barFrame.minY, width: barFrame.width, height: bounds.maxY - barFrame.minY)
                if covered.contains(point) { return nodes[bar].type }
            }
            return nil
        }

        for index in nodes.indices {
            let node = nodes[index]
            guard tappable.contains(node.type), var target = node.hitPoint else { continue }
            var original: Substring?
            if adjustable.contains(node.type), let frame = node.frame {
                let descendants = (index + 1)..<subtreeEnd[index]
                let childFrames = descendants.compactMap { nodes[$0].frame }.filter { $0.width > 0 && $0.height > 0 }
                if !childFrames.isEmpty, !childFrames.contains(where: { $0.contains(target) }) {
                    let candidates = descendants.filter { child in
                        guard let point = nodes[child].hitPoint, let childFrame = nodes[child].frame,
                              childFrame.width > 0, childFrame.height > 0 else { return false }
                        return frame.contains(point) && hiddenBy(point, node: child) == nil
                    }
                    if let pick = candidates.first(where: { nodes[$0].type == node.type }) ?? candidates.first,
                       let point = nodes[pick].hitPoint {
                        let line = lines[index]
                        if let range = line.range(of: #"hitPoint: \{[^}]*\}"#, options: .regularExpression) {
                            original = line[range].dropFirst("hitPoint: ".count)
                        }
                        target = point
                    }
                }
            }
            let hidden = hiddenBy(target, node: index)
            guard original != nil || hidden != nil else { continue }
            let line = lines[index]
            guard let range = line.range(of: #"hitPoint: \{[^}]*\}"#, options: .regularExpression) else { continue }
            var replacement = original.map { "hitPoint: \(format(target)), boxCenter: \($0)" } ?? String(line[range])
            if let hidden { replacement += ", hiddenBy: \(hidden)" }
            lines[index] = line.replacingCharacters(in: range, with: replacement)
        }
        return lines.joined(separator: "\n")
    }

    private static func parentIndices(_ nodes: [Node]) -> [Int?] {
        var stack: [Int] = []
        var parents: [Int?] = []
        for (index, node) in nodes.enumerated() {
            while let last = stack.last, nodes[last].indent >= node.indent { stack.removeLast() }
            parents.append(stack.last)
            stack.append(index)
        }
        return parents
    }

    private static func parse(_ line: String) -> Node {
        let indent = line.prefix(while: { $0 == " " }).count
        let body = line.dropFirst(indent)
        let type = body.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
        return Node(indent: indent, type: type, frame: frame(in: line), hitPoint: point(after: "hitPoint: ", in: line))
    }

    private static func frame(in line: String) -> CGRect? {
        let numbers = captures(#"\{\{(-?[\d.]+), (-?[\d.]+)\}, \{(-?[\d.]+), (-?[\d.]+)\}\}"#, in: line)
        guard numbers.count == 4 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    private static func point(after key: String, in line: String) -> CGPoint? {
        let numbers = captures(NSRegularExpression.escapedPattern(for: key) + #"\{(-?[\d.]+), (-?[\d.]+)\}"#, in: line)
        guard numbers.count == 2 else { return nil }
        return CGPoint(x: numbers[0], y: numbers[1])
    }

    private static func captures(_ pattern: String, in line: String) -> [Double] {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return [] }
        return (1..<match.numberOfRanges).compactMap { i in
            Range(match.range(at: i), in: line).flatMap { Double(line[$0]) }
        }
    }

    private static func format(_ point: CGPoint) -> String {
        String(format: "{%.1f, %.1f}", point.x, point.y)
    }
}
