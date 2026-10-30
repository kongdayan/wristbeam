import Foundation

/// WebKit content blockers support only a subset of regular expressions.
/// Keep each font MIME type separate: alternation makes the entire list fail to compile.
enum ConnectIQSettingsResourceRules {
    enum RuleError: Error { case invalidHost }

    static func encoded(host: String) throws -> String {
        guard ["apps.garmin.cn", "apps.garmin.com"].contains(host) else { throw RuleError.invalidHost }
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^https://" + NSRegularExpression.escapedPattern(for: host) + "/([^/]+/)?appSettings2/"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^https://cdn\\.jsdelivr\\.net/npm/bootstrap@5\\.0\\.1/dist/css/bootstrap\\.min\\.css$", "resource-type": ["style-sheet"]], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^data:image/", "resource-type": ["image"]], "action": ["type": "ignore-previous-rules"]]
        ]
        for format in ["woff", "ttf"] {
            rules.append(["trigger": ["url-filter": "^data:application/x-font-" + format + ";", "resource-type": ["font"]],
                          "action": ["type": "ignore-previous-rules"]])
        }
        let data = try JSONSerialization.data(withJSONObject: rules)
        return String(decoding: data, as: UTF8.self)
    }
}
