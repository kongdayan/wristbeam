import Foundation
import CryptoKit
import Darwin
import CoreFoundation

/// FIT file_id.type is also the upload configuration's FIT_TYPE_n suffix.
struct GarminDataType: RawRepresentable, Codable, Hashable, Identifiable, CaseIterable {
    let rawValue: String
    var id: String { rawValue }

    init?(rawValue: String) {
        let prefix = "FIT_TYPE_"
        guard rawValue.hasPrefix(prefix), let subtype = UInt8(rawValue.dropFirst(prefix.count)),
              rawValue == "\(prefix)\(subtype)" else { return nil }
        self.rawValue = rawValue
    }

    init(fitSubtype: UInt8) { rawValue = "FIT_TYPE_\(fitSubtype)" }
    static func fromFITSubtype(_ subtype: UInt8) -> Self { Self(fitSubtype: subtype) }
    static let activity = Self(fitSubtype: 4)
    static let monitoring = Self(fitSubtype: 32)
    static let sleep = Self(fitSubtype: 49)
    static let biometric = Self(fitSubtype: 44)
    static let allCases: [Self] = [.activity, .monitoring, .sleep, .biometric]

    var label: String {
        switch self {
        case .activity: return "运动记录"
        case .monitoring: return "全天健康"
        case .sleep: return "睡眠"
        case .biometric: return "生理指标"
        default: return "手表数据"
        }
    }
}

struct GarminCloudDevice: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let productName: String

    static func parse(_ data: Data) throws -> [Self] {
        let object = try JSONSerialization.jsonObject(with: data)
        let array = (object as? [[String: Any]]) ?? (object as? [String: Any])?["devices"] as? [[String: Any]]
        guard let array else { throw GarminCloudError.invalidResponse("设备列表格式不正确") }
        return array.compactMap { item in
            guard let id = stringValue(item["deviceId"] ?? item["unitId"]), UInt64(id) != nil else { return nil }
            let product = stringValue(item["productDisplayName"] ?? item["productName"]) ?? "Garmin"
            let name = stringValue(item["displayName"] ?? item["deviceDisplayName"]) ?? product
            return Self(id: id, name: name, productName: product)
        }
    }
}

enum GarminUploadState: String, Codable {
    case pending, uploading, processing, accepted, duplicate, empty, failed
    var isComplete: Bool { self == .accepted || self == .duplicate || self == .empty }
    var label: String {
        switch self {
        case .pending: return "等待上传"
        case .uploading: return "正在上传"
        case .processing: return "云端处理中"
        case .accepted: return "云端已接收"
        case .duplicate: return "云端已存在"
        case .empty: return "云端跳过空数据"
        case .failed: return "上传未完成"
        }
    }
}

struct GarminUploadStatus: Identifiable, Codable {
    var id = UUID()
    let fileName: String
    var state: GarminUploadState
    var detail: String
    var httpStatus: Int?
    var processingURL: URL?
    var activityID: String?
    var date = Date()
}

enum GarminLoginMode: String, CaseIterable, Identifiable {
    case mobile, portal
    var id: String { rawValue }
    var label: String { self == .mobile ? "官方移动登录" : "官方网页登录" }
}

enum GarminRegion: String, CaseIterable, Identifiable, Codable {
    case china, global
    var id: String { rawValue }
    var title: String { self == .china ? "佳明中国" : "佳明国际" }
    var domain: String { self == .china ? "garmin.cn" : "garmin.com" }
    var preferencePrefix: String { self == .china ? "garmin.cn" : "garmin.com" }
    var sessionFileName: String { self == .china ? "china-session.json" : "global-session.json" }
    var apiBase: String { "https://connectapi.\(domain)" }
    var portal: URL { URL(string: "https://connect.\(domain)")! }
    var tokenURL: URL { URL(string: "https://diauth.\(domain)/di-oauth2-service/oauth/token")! }
    func receiveDirectory(root: URL) -> URL { self == .china ? root : root.appendingPathComponent(rawValue, isDirectory: true) }
    static func containing(_ url: URL) -> Self? {
        allCases.first { GarminChinaURLPolicy.isTrusted(url, region: $0) }
    }
}

enum GarminCloudError: LocalizedError {
    case invalidResponse(String)
    case authenticationRequired
    case incompleteMFA
    case http(Int, String)
    case untrustedURL
    case noUploadRoute(String)
    case invalidFIT(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let value), .invalidFIT(let value): return value
        case .authenticationRequired: return "请先登录当前区域的佳明账户"
        case .incompleteMFA: return "账户还需要验证，请在官方登录页完成验证后重新连接"
        case .http(let code, let operation): return "\(operation)返回 HTTP \(code)"
        case .untrustedURL: return "仅允许当前账户区域的 HTTPS 佳明服务地址"
        case .noUploadRoute(let type): return "该设备没有开放 \(type) 的云上传地址"
        }
    }
}

enum GarminChinaURLPolicy {
    static let mobileService = URL(string: "https://mobile.integration.garmin.cn/gcm/android")!
    static let portalService = URL(string: "https://connect.garmin.cn/app")!
    static let tokenURL = URL(string: "https://diauth.garmin.cn/di-oauth2-service/oauth/token")!
    // This URI names the grant type; it is never used as a network destination.
    static let ticketGrant = "https://connectapi.garmin.com/di-oauth2-service/oauth/grant/service_ticket"
    static let defaultDIClientID = "GARMIN_CONNECT_MOBILE_ANDROID_DI_2025Q2"

    static func isTrusted(_ url: URL, region: GarminRegion = .china) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return host == region.domain || host.hasSuffix(".\(region.domain)")
    }

    static func loginURL(mode: GarminLoginMode, clientID: String, region: GarminRegion = .china) -> URL {
        let path = mode == .mobile ? "/mobile/sso/zh-CN/sign-in" : "/portal/sso/zh-CN/sign-in"
        var components = URLComponents(string: "https://sso.\(region.domain)\(path)")!
        components.queryItems = [URLQueryItem(name: "clientId", value: mode == .mobile ? clientID : "GarminConnect"),
                                 URLQueryItem(name: "service", value: serviceURL(mode: mode, region: region).absoluteString)]
        return components.url!
    }

    static func serviceURL(mode: GarminLoginMode, region: GarminRegion = .china) -> URL {
        URL(string: mode == .mobile ? "https://mobile.integration.\(region.domain)/gcm/android" : "https://connect.\(region.domain)/app")!
    }

    /// Tickets are accepted only on the exact official service selected for this login.
    static func serviceTicket(from url: URL, expectedService: URL) -> String? {
        guard let region = GarminRegion.containing(expectedService), isTrusted(url, region: region), url.host?.lowercased() == expectedService.host?.lowercased(),
              url.path == expectedService.path,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let tickets = items.filter { $0.name == "ticket" }
        guard tickets.count == 1, let ticket = tickets[0].value, ticket.hasPrefix("ST-"),
              ticket.count <= 4096, ticket.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return ticket
    }

    /// Current Garmin mobile SSO sends the same service ticket over its documented page bridge.
    static func callbackURL(fromSSOEvent event: [String: Any], expectedService: URL) -> URL? {
        guard event["eventType"] as? String == "USER_AUTHENTICATED",
              let data = event["data"] as? [String: Any], let ticket = data["serviceTicket"] as? String,
              let service = data["serviceUrl"] as? String, let url = URL(string: service),
              let region = GarminRegion.containing(expectedService), isTrusted(url, region: region),
              url.host?.lowercased() == expectedService.host?.lowercased(), url.path == expectedService.path,
              url.query == nil, url.fragment == nil else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        guard let callback = components.url, serviceTicket(from: callback, expectedService: expectedService) != nil else { return nil }
        return callback
    }

    static func uploadConfigurationURL(deviceID: String, region: GarminRegion = .china) throws -> URL {
        guard UInt64(deviceID) != nil else { throw GarminCloudError.invalidResponse("请使用数字形式的手表 Unit ID") }
        var components = URLComponents(string: "https://omt.\(region.domain)/UploadConfigurationService/UnitUploadSettings/\(deviceID)")!
        components.queryItems = [URLQueryItem(name: "clientId", value: "ConnectMobile")]
        return components.url!
    }

    static func formData(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let value = fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        return Data(value.utf8)
    }

    static func validClientID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 120 && value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
}

struct GarminOAuthToken: Codable {
    let accessToken: String
    let refreshToken: String
    let clientID: String
    let expiresAt: Date
    let refreshExpiresAt: Date?
    let scopes: [String]

    static func parse(_ data: Data, clientID: String, now: Date = Date(), previous: Self? = nil) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GarminCloudError.invalidResponse("登录令牌格式不正确")
        }
        let hasAccess = (object["access_token"] as? String)?.isEmpty == false
        if object["mfa_required"] as? Bool == true || (!hasAccess && (object["mfa_token"] as? String)?.isEmpty == false) {
            throw GarminCloudError.incompleteMFA
        }
        guard let access = object["access_token"] as? String, !access.isEmpty,
              let refresh = (object["refresh_token"] as? String) ?? previous?.refreshToken, !refresh.isEmpty,
              let seconds = numberValue(object["expires_in"]), seconds > 0,
              seconds.isFinite, seconds <= 366 * 86400 else {
            throw GarminCloudError.invalidResponse("服务器没有返回完整的可续期令牌")
        }
        if let type = object["token_type"] as? String, type.lowercased() != "bearer" {
            throw GarminCloudError.invalidResponse("服务器返回了不支持的令牌类型")
        }
        let refreshExpiry: Date?
        if let seconds = numberValue(object["refresh_token_expires_in"]), seconds > 0, seconds.isFinite {
            refreshExpiry = now.addingTimeInterval(seconds)
        } else { refreshExpiry = previous?.refreshExpiresAt }
        return Self(accessToken: access, refreshToken: refresh, clientID: clientID,
                    expiresAt: now.addingTimeInterval(seconds), refreshExpiresAt: refreshExpiry,
                    scopes: (object["scope"] as? String ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }
}

struct GarminUploadConfiguration {
    let locations: [String: URL]
    static func parse(_ data: Data, region: GarminRegion = .china) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let types = object["DataTypes"] as? [[String: Any]] else {
            throw GarminCloudError.invalidResponse("未获得设备上传配置，请确认设备已关联此账户")
        }
        var locations: [String: URL] = [:]
        for type in types {
            guard let name = type["DataTypeName"] as? String,
                  let items = type["UploadLocations"] as? [[String: Any]],
                  let value = items.first?["Url"] as? String,
                  let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            guard GarminChinaURLPolicy.isTrusted(url, region: region) else { throw GarminCloudError.untrustedURL }
            locations[name.trimmingCharacters(in: .whitespacesAndNewlines)] = url
        }
        return Self(locations: locations)
    }
    func endpoint(for type: GarminDataType) throws -> URL {
        guard let url = locations[type.rawValue] else { throw GarminCloudError.noUploadRoute(type.rawValue) }
        return url
    }
}

enum GarminUploadResponse {
    static func classify(code: Int, data: Data, location: URL?, fileName: String) -> GarminUploadStatus {
        var result = GarminUploadStatus(fileName: fileName, state: .failed, detail: "云端返回 HTTP \(code)", httpStatus: code)
        if code == 202 {
            result.state = .processing
            result.detail = location == nil ? "云端接收后尚未返回处理地址；文件保留，稍后重新检查" : "云端仍在处理，等待处理结果"
            result.processingURL = location
            return result
        }
        if code == 409 { result.state = .duplicate; result.detail = "同一文件已在云端，无需再次上传"; return result }
        if code == 204 { result.state = .empty; result.detail = "云端跳过此文件的空记录"; return result }
        guard code == 200 || code == 201 else { return result }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let details = object["detailedImportResult"] as? [String: Any] {
            let failures = details["failures"] as? [[String: Any]] ?? []
            let messages = failures.flatMap { $0["messages"] as? [[String: Any]] ?? [] }
            let codes = messages.compactMap { numberValue($0["code"]).map(Int.init) }
            if !failures.isEmpty {
                result.state = !codes.isEmpty && codes.allSatisfy { $0 == 409 } ? .duplicate : .failed
                result.detail = result.state == .duplicate ? "云端已存在同一文件" : "云端接收请求，但未能导入文件（代码 \(codes.map(String.init).joined(separator: ", "))）"
                return result
            }
            let successes = details["successes"] as? [[String: Any]] ?? []
            result.activityID = successes.first.flatMap { stringValue($0["internalId"] ?? $0["activityId"]) }
        }
        result.state = .accepted
        result.detail = "服务器已接收并结束处理；可在当前区域的 Garmin Connect 核对记录"
        return result
    }
}

/// Private app files are written atomically with restrictive permissions from creation.
enum GarminPrivateFile {
    static func write(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let resource = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard resource.isSymbolicLink != true else { throw GarminCloudError.invalidResponse("本地会话目录不能是符号链接") }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard Darwin.rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? handle.close()
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

func stringValue(_ value: Any?) -> String? {
    if let text = value as? String, !text.isEmpty { return text }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

func numberValue(_ value: Any?) -> Double? {
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
    if let text = value as? String { return Double(text) }
    return nil
}
