import Foundation

struct ConnectIQAppText: Codable, Equatable {
    let locale: String
    let name: String
    let description: String
}

struct ConnectIQApp: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let description: String
    let version: String
    let internalVersion: Int
    let isWatchFace: Bool
    let compatiblePartNumbers: [String]
    let permissions: [String]
    let paymentModel: Int?
    let hasTrialMode: Bool
    let iconFileID: String?
    var iconURL: URL? = nil
    var screenshotURLs: [URL] = []
    var localizations: [ConnectIQAppText]? = nil

    var localizedName: String { localizedText?.name ?? name }
    var localizedDescription: String { localizedText?.description ?? description }
    private var localizedText: ConnectIQAppText? { Self.preferredText(localizations ?? []) }

    private static func preferredText(_ texts: [ConnectIQAppText]) -> ConnectIQAppText? {
        func match(_ tag: String) -> ConnectIQAppText? { texts.first { $0.locale == tag } }
        if !L10n.isEnglish, let chinese = match("zh-cn") ?? texts.first(where: { $0.locale == "zh" || $0.locale.hasPrefix("zh-") }) {
            return chinese
        }
        return match("en-us") ?? texts.first(where: { $0.locale == "en" || $0.locale.hasPrefix("en-") }) ?? texts.first
    }

    static func parse(_ data: Data, region: GarminRegion = .china) throws -> Self {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectIQError.invalidData }
        return try parse(value, region: region)
    }
    static func parse(_ value: [String: Any], region: GarminRegion = .china) throws -> Self {
        guard let raw = value["id"] as? String, let id = UUID(uuidString: raw),
              let version = value["latestInternalVersion"] as? Int, version > 0,
              let names = value["appLocalizations"] as? [[String: Any]], !names.isEmpty else { throw ConnectIQError.invalidData }
        let texts: [ConnectIQAppText] = names.compactMap { row in
            guard let name = row["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ConnectIQAppText(locale: (row["locale"] as? String ?? "").lowercased().replacingOccurrences(of: "_", with: "-"),
                                    name: name, description: row["description"] as? String ?? "")
        }
        guard let localized = preferredText(texts) else { throw ConnectIQError.invalidData }
        return Self(id: id.uuidString.lowercased(), name: localized.name, description: localized.description,
                    version: value["latestExternalVersion"] as? String ?? String(version), internalVersion: version,
                    isWatchFace: stringValue(value["typeId"]) == "1", compatiblePartNumbers: value["compatibleDevicePartNumbers"] as? [String] ?? [],
                    permissions: value["permissions"] as? [String] ?? [], paymentModel: value["paymentModel"] as? Int,
                    hasTrialMode: value["hasTrialMode"] as? Bool ?? false, iconFileID: value["iconFileId"] as? String,
                    iconURL: ConnectIQService.imageURL(fileID: value["iconFileId"] as? String, kind: "icons", region: region),
                    screenshotURLs: (value["screenshotFileIds"] as? [String] ?? []).prefix(12).compactMap {
                        ConnectIQService.imageURL(fileID: $0, kind: "screenshots", region: region)
                    }, localizations: texts)
    }
}

struct ConnectIQDownloadRecord: Codable, Equatable {
    let appID: String
    let internalVersion: Int
    let version: String
    let date: Date
    static func parse(_ data: Data) throws -> [Self] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ConnectIQError.invalidData }
        return try rows.map { row in
            guard let raw = row["appId"] as? String, let id = UUID(uuidString: raw),
                  let version = row["internalAppVersion"] as? Int, version > 0,
                  let timestamp = row["date"] as? Double, timestamp.isFinite else { throw ConnectIQError.invalidData }
            return Self(appID: id.uuidString.lowercased(), internalVersion: version,
                        version: row["externalAppVersion"] as? String ?? String(version), date: Date(timeIntervalSince1970: timestamp / 1000))
        }
    }
}

enum ConnectIQError: LocalizedError, Equatable {
    case invalidData, invalidAppID, selectDevice, missingPartNumber, incompatible, queueConsentRequired, packagePending, invalidPackage, downloadHostUnsupported, busy, installationContextMissing, packageChanged
    var errorDescription: String? {
        switch self {
        case .invalidData: return "表盘数据格式不正确"
        case .invalidAppID: return "请输入有效的表盘编号或佳明商店链接"
        case .selectDevice: return "请先选择当前账户中的手表"
        case .missingPartNumber: return "设备型号资料不完整，请刷新账户设备"
        case .incompatible: return "此表盘尚未确认兼容所选手表"
        case .queueConsentRequired: return "下载需要创建佳明安装队列，请先确认"
        case .packagePending: return "佳明队列已提交，文件尚未就绪；请稍后重试下载"
        case .invalidPackage: return "服务器没有返回有效的表盘文件"
        case .downloadHostUnsupported: return "此表盘的下载地址暂不支持，请使用佳明官方应用"
        case .installationContextMissing: return "未找到此表盘的安装任务，请重新下载后再安装"
        case .packageChanged: return "本地程序包与当前手表的安装文件不同，请重新下载"
        case .busy: return "已有表盘下载正在进行"
        }
    }
}

/// APK zka/cz/j80/an5/is6; observed China cloud responses. No device-write semantics.
struct ConnectIQQueuedPackage {
    let url: URL
    let messageID: UInt64?
}

enum ConnectIQService {
    static func searchKeywords(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 128, !text.contains("://"),
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }
    /// Public store media uses UUIDs, never caller-provided URLs or account credentials.
    static func imageURL(fileID: String?, kind: String, region: GarminRegion) -> URL? {
        guard ["icons", "screenshots"].contains(kind), let fileID, let uuid = UUID(uuidString: fileID) else { return nil }
        return URL(string: "https://services.\(region.domain)/appstore/api/\(kind)/\(uuid.uuidString.lowercased())")
    }
    static let pageSize = 30
    static let maximumJSONBytes = 4 * 1024 * 1024
    static let maximumPackageBytes = 32 * 1024 * 1024
    static func appID(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: text) { return id.uuidString.lowercased() }
        guard let url = URL(string: text), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              ["apps.garmin.cn", "apps.garmin.com"].contains(url.host?.lowercased() ?? "") else { return nil }
        let parts = url.pathComponents
        guard let apps = parts.firstIndex(of: "apps"), apps + 1 == parts.count - 1,
              let id = UUID(uuidString: parts[apps + 1]) else { return nil }
        return id.uuidString.lowercased()
    }
    static func storeURL(region: GarminRegion, path: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(string: "https://services.\(region.domain)/appstore/api/v2/asm/" + path)!
        components.queryItems = query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
    static func validatePackage(_ data: Data, contentType: String?) throws {
        guard !data.isEmpty, data.count <= maximumPackageBytes else { throw ConnectIQError.invalidPackage }
        let type = contentType?.lowercased() ?? ""
        let prefix = String(decoding: data.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !type.contains("json"), !type.contains("html"), !type.hasPrefix("text/"),
              !prefix.hasPrefix("<"), !prefix.hasPrefix("{"), !prefix.hasPrefix("[") else { throw ConnectIQError.invalidPackage }
    }
    /// Download only the requested app's pending install message; never process unrelated files.
    static func packageURL(_ data: Data, appID: String, deviceID: String, region: GarminRegion) throws -> URL? {
        try queuedPackage(data, appID: appID, deviceID: deviceID, region: region)?.url
    }
    static func queuedPackage(_ data: Data, appID: String, deviceID: String, region: GarminRegion) throws -> ConnectIQQueuedPackage? {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = envelope["messages"] as? [[String: Any]] else { throw ConnectIQError.invalidData }
        for message in messages {
            guard message["messageType"] as? String == "install_app",
                  stringValue(message["deviceId"]) == deviceID,
                  let metadata = message["metaData"] as? [String: Any],
                  let details = metadata["appDetails"] as? [String: Any],
                  (details["id"] as? String)?.lowercased() == appID.lowercased(),
                  let raw = metadata["messageUrl"] as? String, !raw.isEmpty else { continue }
            // APK i33 -> aua -> fta resolves relative downloads against the region Connect API.
            let base = URL(string: region.apiBase)!
            guard let url = URL(string: raw, relativeTo: base)?.absoluteURL,
                  GarminChinaURLPolicy.isTrusted(url, region: region),
                  ["connectapi.\(region.domain)", "services.\(region.domain)"].contains(url.host?.lowercased() ?? "") else { throw ConnectIQError.downloadHostUnsupported }
            return ConnectIQQueuedPackage(url: url, messageID: stringValue(message["messageId"]).flatMap(UInt64.init))
        }
        return nil
    }
}
