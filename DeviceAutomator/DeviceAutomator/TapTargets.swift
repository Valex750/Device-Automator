import CoreGraphics
import Foundation

/// Accessibility frames are boxes, not tappable areas. A SwiftUI `.menu` Picker
/// in a List reports one Button spanning the whole row, but only its trailing
/// value opens the menu; a `.plain` List row Button has a Spacer gap at its
/// center. Xcode still reports the box center as `hitPoint`, so agents tap dead
/// space. A List Toggle is the same: a row-wide Switch whose center misses both
/// the label and the inner Switch, and only the inner Switch toggles. When a
/// Button/Cell/Link/Switch center misses every descendant, move its hitPoint to
/// a descendant of the same type (the real control) if there is one, otherwise
/// to the first descendant.
enum TapTargets {
    static let header = "# Device Automator: a Button/Cell/Link/Switch whose box center misses all its children has hitPoint moved onto a child (a same-type child first); boxCenter is the original.\n"

    private static let adjustable: Set<String> = ["Button", "Cell", "Link", "Switch"]

    private struct Node {
        let indent: Int
        let type: String
        let frame: CGRect?
        let hitPoint: CGPoint?
    }

    /// Writes an adjusted sibling copy of the dump and returns its path, or
    /// `path` unchanged when nothing needed moving or the file is unreadable.
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
        for index in nodes.indices {
            let node = nodes[index]
            guard adjustable.contains(node.type),
                  let frame = node.frame, let center = node.hitPoint else { continue }
            var descendants: [Node] = []
            var next = index + 1
            while next < nodes.count, nodes[next].indent > node.indent {
                descendants.append(nodes[next])
                next += 1
            }
            let childFrames = descendants.compactMap(\.frame).filter { $0.width > 0 && $0.height > 0 }
            guard !childFrames.isEmpty, !childFrames.contains(where: { $0.contains(center) }) else { continue }
            let candidates = descendants.filter { child in
                guard let point = child.hitPoint, let childFrame = child.frame,
                      childFrame.width > 0, childFrame.height > 0 else { return false }
                return frame.contains(point)
            }
            guard let target = (candidates.first { $0.type == node.type } ?? candidates.first)?.hitPoint else { continue }
            let line = lines[index]
            guard let range = line.range(of: #"hitPoint: \{[^}]*\}"#, options: .regularExpression) else { continue }
            let original = line[range].dropFirst("hitPoint: ".count)
            lines[index] = line.replacingCharacters(
                in: range,
                with: "hitPoint: \(format(target)), boxCenter: \(original)"
            )
        }
        return lines.joined(separator: "\n")
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
