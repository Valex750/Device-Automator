import Foundation

/// Xcode often reports `applicationState: NotRun` even when the hierarchy dump
/// is a live app tree. Agents then call `install_and_run` and poison the session.
enum ObserveNormalization {
    static func rewrite(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeJSONObject(trimmed),
           let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            let rewritten = rewriteValue(json)
            if JSONSerialization.isValidJSONObject(rewritten),
               let out = try? JSONSerialization.data(withJSONObject: rewritten, options: [.prettyPrinted, .sortedKeys]),
               let string = String(data: out, encoding: .utf8) {
                return string
            }
        }
        return rewriteRawText(text)
    }

    static func rewriteValue(_ value: Any) -> Any {
        if var dict = value as? [String: Any] {
            dict = dict.mapValues { rewriteValue($0) }
            if shouldSuppressNotRun(in: dict) {
                dict["applicationState"] = inferredState(in: dict)
            }
            return dict
        }
        if let array = value as? [Any] {
            return array.map { rewriteValue($0) }
        }
        if let text = value as? String, looksLikeJSONObject(text) {
            if let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) {
                let rewritten = rewriteValue(json)
                if JSONSerialization.isValidJSONObject(rewritten),
                   let out = try? JSONSerialization.data(withJSONObject: rewritten, options: [.prettyPrinted, .sortedKeys]),
                   let string = String(data: out, encoding: .utf8) {
                    return string
                }
            }
            return rewriteRawText(text)
        }
        return value
    }

    static func hasLiveApplication(in text: String) -> Bool {
        if text.range(of: #"Application,\s*pid:\s*[1-9]"#, options: .regularExpression) != nil {
            return true
        }
        if text.localizedCaseInsensitiveContains("hierarchyPath") {
            return true
        }
        return false
    }

    private static func shouldSuppressNotRun(in dict: [String: Any]) -> Bool {
        guard let state = dict["applicationState"] as? String,
              state.compare("NotRun", options: .caseInsensitive) == .orderedSame else {
            return false
        }
        return hasHierarchyEvidence(dict)
    }

    private static func hasHierarchyEvidence(_ dict: [String: Any]) -> Bool {
        if let path = dict["hierarchyPath"] as? String, !path.isEmpty { return true }
        if let hierarchy = dict["hierarchy"] as? String, hasLiveApplication(in: hierarchy) { return true }
        for nested in dict.values {
            if let nestedDict = nested as? [String: Any], hasHierarchyEvidence(nestedDict) {
                return true
            }
            if let text = nested as? String, hasLiveApplication(in: text) {
                return true
            }
        }
        return false
    }

    private static func inferredState(in dict: [String: Any]) -> String {
        if let path = dict["hierarchyPath"] as? String,
           let contents = try? String(contentsOfFile: path, encoding: .utf8),
           hasLiveApplication(in: contents) {
            return "Running"
        }
        return "Running"
    }

    private static func rewriteRawText(_ text: String) -> String {
        guard text.localizedCaseInsensitiveContains("NotRun") else { return text }
        guard hasLiveApplication(in: text) else { return text }
        return text.replacingOccurrences(
            of: #""applicationState"\s*:\s*"NotRun""#,
            with: "\"applicationState\":\"Running\"",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func looksLikeJSONObject(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first == "{" && trimmed.last == "}"
    }
}
