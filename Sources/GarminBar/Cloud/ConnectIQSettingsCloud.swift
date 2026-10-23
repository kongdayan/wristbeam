import Foundation

/// Public routing information only. Current settings stay in request bodies and memory.
struct ConnectIQSettingsContext: Equatable {
    let appID: String
    let version: UInt32
    let partNumber: String
    let region: GarminRegion
    let locale: String

    init(appID: String, version: UInt32, partNumber: String, region: GarminRegion, locale: String) throws {
        guard let uuid = UUID(uuidString: appID), version > 0,
              partNumber.range(of: "^006-B[0-9]+-[0-9]+$", options: .regularExpression) != nil,
              ["zh-CN", "en-US"].contains(locale) else { throw ConnectIQSettingsCloudError.invalidContext }
        self.appID = uuid.uuidString.lowercased(); self.version = version
        self.partNumber = partNumber; self.region = region; self.locale = locale
    }

    static let maximumBytes = 512 * 1024

    var binaryURL: URL {
        URL(string: "https://apps.\(region.domain)/\(locale)/appSettings2/\(appID)/versions/\(version)/devices/\(partNumber)/binary")!
    }

    func editorRequest(settingsJSON: Data, dark: Bool) throws -> URLRequest {
        try Self.validateJSON(settingsJSON)
        let url = URL(string: "https://apps.\(region.domain)/\(locale)/appSettings2/android/\(appID)/versions/\(version)/devices/\(partNumber)/edit?theme=\(dark ? "dark" : "light")")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("GarminPulse/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.httpBody = Data(("userSettings=" + Self.formEncode(settingsJSON)).utf8)
        return request
    }

    func binaryRequest(settingsJSON: Data) throws -> URLRequest {
        try Self.validateJSON(settingsJSON)
        var request = URLRequest(url: binaryURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"; request.httpBody = settingsJSON
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("GarminPulse/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func validateJSON(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumBytes,
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw ConnectIQSettingsCloudError.invalidSettings
        }
    }

    /// Form-encoding bytes avoids losing literal plus signs, ampersands or Unicode.
    private static func formEncode(_ data: Data) -> String {
        data.map { byte in
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126: return String(UnicodeScalar(byte))
            case 32: return "+"
            default: return String(format: "%%%02X", byte)
            }
        }.joined()
    }
}

enum ConnectIQSettingsCloudError: LocalizedError {
    case invalidContext, invalidSettings, invalidResponse, contextChanged, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidContext: return "表盘或设备资料不完整，请重新读取手表表盘"
        case .invalidSettings: return "表盘配置数据无效，请检查输入"
        case .invalidResponse: return "佳明未返回有效的表盘配置，请稍后重试"
        case .contextChanged: return "设备或账户已变化，请重新打开表盘设置"
        case .unavailable: return "请连接所选手表并等待同步完成后打开设置"
        }
    }
}

/// Shared by the hosted editor and its core/native regression tests.
enum ConnectIQSettingsEditorPolicy {
    // WebKit URL filters reject alternation (woff|ttf); keep each font rule separate.
    static func contentRuleListJSON(host: String) throws -> String {
        let rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^https://" + NSRegularExpression.escapedPattern(for: host) + "/([^/]+/)?appSettings2/"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^https://cdn\\.jsdelivr\\.net/npm/bootstrap@5\\.0\\.1/dist/css/bootstrap\\.min\\.css$", "resource-type": ["style-sheet"]], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^data:image/", "resource-type": ["image"]], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^data:application/x-font-woff;", "resource-type": ["font"]], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^data:application/x-font-ttf;", "resource-type": ["font"]], "action": ["type": "ignore-previous-rules"]]
        ]
        let data = try JSONSerialization.data(withJSONObject: rules)
        return String(decoding: data, as: UTF8.self)
    }

    struct NavigationPolicy {
        let host: String
        let appPrefix: [String]
        init?(_ url: URL) {
            guard url.scheme == "https", let host = url.host?.lowercased(), ["apps.garmin.cn", "apps.garmin.com"].contains(host),
                  url.user == nil, url.password == nil, url.port == nil || url.port == 443,
                  let path = Self.settingsPath(url), path.count >= 6,
                  UUID(uuidString: path[0]) != nil, path[1] == "versions", Int(path[2]) != nil,
                  path[3] == "devices", !path[4].isEmpty else { return nil }
            self.host = host; appPrefix = Array(path.prefix(5))
        }
        private static func settingsPath(_ url: URL) -> [String]? {
            let path = url.pathComponents.filter { $0 != "/" }
            guard let start = path.firstIndex(of: "appSettings2") else { return nil }
            var settings = Array(path.dropFirst(start + 1))
            if settings.first == "android" { settings.removeFirst() }
            return settings
        }
        func allowsPage(_ url: URL) -> Bool {
            guard url.scheme == "https", url.host?.lowercased() == host, url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443, let path = Self.settingsPath(url), path.count >= 6 else { return false }
            return Array(path.prefix(5)) == appPrefix
        }
    }
}
