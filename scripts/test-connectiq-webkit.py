#!/usr/bin/env python3
"""Compile the production resource rules using macOS WebKit, without network or a watch."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="wristbeam-webkit-") as directory:
    work = Path(directory)
    harness = work / "RuleChecks.swift"
    harness.write_text(r'''
import Foundation
import WebKit

@main enum RuleChecks {
    static func main() throws {
        var pending = 0
        var failures = [String]()
        for host in ["apps.garmin.cn", "apps.garmin.com"] {
            let json = try ConnectIQSettingsResourceRules.encoded(host: host)
            let rules = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
            // Keep the deny-by-default policy while fixing WebKit's unsupported alternation.
            let filters = rules.dropFirst().map { ($0["trigger"] as! [String: Any])["url-filter"] as! String }
            let samples: [(String, Bool)] = [
                ("https://\(host)/zh-CN/appSettings2/android/fixture/edit", true),
                ("https://\(host)/appSettings2/js/editor.js", true),
                ("data:application/x-font-woff;base64,AA==", true),
                ("data:application/x-font-ttf;base64,AA==", true),
                ("https://cdn.jsdelivr.net/npm/bootstrap@5.0.1/dist/css/bootstrap.min.css", true),
                ("https://\(host)/other/script.js", false),
                ("https://\(host).example.com/appSettings2/script.js", false),
                ("https://example.com/appSettings2/script.js", false),
                ("https://cdn.jsdelivr.net/npm/other/script.js", false)
            ]
            for (url, expected) in samples {
                let allowed = try filters.contains { filter in
                    try NSRegularExpression(pattern: filter).firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
                }
                if allowed != expected { failures.append("Resource boundary: \(url)") }
            }
            pending += 1
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "WristBeam.Settings.RuleTest.\(host)", encodedContentRuleList: json
            ) { list, error in
                if list == nil { failures.append("WebKit compilation for \(host): \(String(describing: error))") }
                else { print("PASS WebKit compiled production rules: \(host)") }
                pending -= 1
            }
        }
        do {
            _ = try ConnectIQSettingsResourceRules.encoded(host: "example.com")
            failures.append("Unexpected host accepted")
        } catch ConnectIQSettingsResourceRules.RuleError.invalidHost {}
        let deadline = Date().addingTimeInterval(30)
        while pending > 0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        if pending > 0 { failures.append("WebKit compilation timed out") }
        guard failures.isEmpty else { failures.forEach { print("FAIL \($0)") }; exit(1) }
        print("PASS resource boundaries and host validation; no network requests or device writes")
    }
}
''')
    executable = work / "rule-checks"
    subprocess.run([
        "swiftc", str(root / "Sources/GarminBar/UI/ConnectIQSettingsResourceRules.swift"),
        str(harness), "-o", str(executable)
    ], check=True)
    subprocess.run([str(executable)], check=True, timeout=40)
