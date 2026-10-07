import Foundation

/// Folding an iPhone Duo means moving the simulated hinge. The only control for that is SpringBoard's
/// private display-tool service (`SBSDisplayToolService`, hinge position 0...1), which accepts
/// Apple-internal callers only: a plain client gets "Insufficient authorization", and the simulator
/// refuses to launch a tool that signs itself with the entitlement ("Security policy issue"). simctl,
/// devicectl, Xcode's DeviceInteraction commands and XCUIAutomation have no fold option. So set_fold
/// checks its input and the device, reports the lit display, and fails. Wire the real call into
/// `setFold` if Xcode ever exposes one.
enum FoldControl {
    /// Apple's internal swap tool names "book" as roughly 100 degrees of a 180 degree hinge.
    static let bookPosition = 100.0 / 180.0

    /// closed = 0, book = 100/180, open = 1, or a number in [0, 1].
    static func parsePosition(_ text: String) -> Double? {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch word {
        case "closed": return 0
        case "book": return bookPosition
        case "open": return 1
        default:
            guard let value = Double(word), value.isFinite, (0.0...1.0).contains(value) else { return nil }
            return value
        }
    }

    static func setFold(device: String, position: String?) throws -> String {
        let requested = position?.trimmingCharacters(in: .whitespacesAndNewlines)
        var target: Double?
        if let requested, !requested.isEmpty {
            guard let value = parsePosition(requested) else {
                throw DeviceAutomatorError.commandFailed(
                    "Invalid position '\(requested)'. Use closed, book, open, or a number from 0.0 to 1.0."
                )
            }
            target = value
        }
        let displays = DeviceControl.displays(device: device)
        guard displays.filter(\.integrated).count > 1 else {
            throw DeviceAutomatorError.commandFailed(notFoldableMessage(device: device, displays: displays))
        }
        throw DeviceAutomatorError.commandFailed(
            unavailableMessage(position: requested, target: target, displays: displays)
        )
    }

    static func notFoldableMessage(device: String, displays: [DisplayInfo]) -> String {
        if displays.isEmpty {
            return "set_fold only applies to a foldable (iPhone Duo), and devicectl could not list the displays of \(device) to check. Nothing was changed."
        }
        return "\(device) does not report two built-in displays, so it is not a foldable and there is nothing to fold. Nothing was changed."
    }

    static func unavailableMessage(position: String?, target: Double?, displays: [DisplayInfo]) -> String {
        let request: String
        if let target {
            let value = String(format: "%.2f", target)
            if let word = position?.lowercased(), ["closed", "book", "open"].contains(word) {
                request = "\(word) (hinge \(value))"
            } else {
                request = "hinge \(value)"
            }
        } else {
            request = "swap to the other display"
        }
        return """
        Cannot change the fold: nothing available to automation can move the device's simulated hinge. Nothing was changed.
        Why: the only control is SpringBoard's private display-tool service, which accepts Apple-internal callers only (private entitlement). simctl, devicectl, Xcode's interaction commands and XCUITest have no fold option, and the simulator refuses to launch a tool that signs itself with that entitlement.
        Requested: \(request).
        Lit display now: \(litDisplayDescription(displays)).
        Ask the user to move the hinge themselves, then continue; screenshot follows the lit display. Do not retry set_fold.
        """
    }

    /// "cover (1398x2034)" or "inner (2007x2853)": on a Duo the smaller built-in display is the cover.
    static func litDisplayDescription(_ displays: [DisplayInfo]) -> String {
        guard let lit = DeviceControl.activeDisplay(in: displays) else { return "none reported" }
        func area(_ display: DisplayInfo) -> Int { (display.width ?? 0) * (display.height ?? 0) }
        let builtIn = displays.filter(\.integrated)
        var role: String?
        if lit.integrated, builtIn.count > 1 {
            role = area(lit) == builtIn.map(area).min() ? "cover" : "inner"
        }
        var size: String?
        if let width = lit.width, let height = lit.height {
            size = "\(width)x\(height)"
        }
        switch (role, size) {
        case let (role?, size?): return "\(role) (\(size))"
        case let (role?, nil): return role
        case let (nil, size?): return size
        case (nil, nil): return "unknown"
        }
    }
}
