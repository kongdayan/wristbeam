import Foundation
import Combine

private final class GarminNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never silently forward credentials, FIT contents, or a POST body to another endpoint.
        completionHandler(nil)
    }
}

@MainActor
final class GarminChinaCloud: ObservableObject {
    @Published private(set) var networkEnabled: Bool
    private(set) var requestCount = 0
    @Published private(set) var region: GarminRegion
    @Published private(set) var status = "尚未登录佳明中国"
    @Published private(set) var accountName = ""
    @Published private(set) var accountGUID = ""
    @Published var deviceId = "" {
        didSet { preferences.set(deviceId, forKey: "\(region.preferencePrefix).selectedDeviceID") }
    }
    @Published private(set) var isAuthenticated = false
    @Published private(set) var devices: [GarminCloudDevice] = []
    @Published private(set) var profileDisplayName = ""
    @Published private(set) var uploadStatuses: [GarminUploadStatus] = []
    @Published var loginMode: GarminLoginMode = .mobile
    @Published private(set) var ssoClientID = "GCM_ANDROID_LIGHT"
    @Published private(set) var diClientID = GarminChinaURLPolicy.defaultDIClientID
    @Published private(set) var loginRevision = UUID()
    @Published private(set) var expiresAt: Date?

    private var connectIQDownloadID: UUID?
    private var token: GarminOAuthToken?
    private var refreshTask: Task<GarminOAuthToken, Error>?
    private var refreshIdentity = UUID()
    private var renewalTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var lastTicketDigest: String?
    private var authenticationGeneration = UUID()
    private var loginGeneration = UUID()
    private var configurationCache: [String: (Date, GarminUploadConfiguration)] = [:]
    private var session: URLSession
    private var storageURL: URL
    private let initialStorageURL: URL
    private let initialRegion: GarminRegion
    private let preferences: AppPreferences
    private let automaticRestorationEnabled: Bool

    init(storageURL: URL? = nil, session: URLSession? = nil, automaticallyRestore: Bool = true, networkEnabled: Bool = true, initialRegion: GarminRegion? = nil, preferences: AppPreferences = .shared) {
        self.networkEnabled = networkEnabled
        self.preferences = preferences; self.automaticRestorationEnabled = automaticallyRestore
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GarminPulse", isDirectory: true).appendingPathComponent("auth", isDirectory: true)
        let region = initialRegion ?? (storageURL != nil ? .china : GarminRegion(rawValue: preferences.string(forKey: "garmin.region") ?? "china") ?? .china)
        self.region = region; self.initialRegion = region
        self.storageURL = storageURL ?? directory.appendingPathComponent(region.sessionFileName)
        self.initialStorageURL = self.storageURL
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 90
            config.httpCookieStorage = nil
            config.urlCache = nil
            self.session = URLSession(configuration: config, delegate: GarminNoRedirectDelegate(), delegateQueue: nil)
        }
        deviceId = preferences.string(forKey: "\(region.preferencePrefix).selectedDeviceID") ?? ""
        if let sso = preferences.string(forKey: "\(region.preferencePrefix).ssoClientID"), GarminChinaURLPolicy.validClientID(sso) { ssoClientID = sso }
        if let di = preferences.string(forKey: "\(region.preferencePrefix).diClientID"), GarminChinaURLPolicy.validClientID(di) { diClientID = di }
        status = "尚未登录\(region.title)"
        if !preferences.bool(forKey: "\(region.preferencePrefix).signedOut"),
           let data = try? Data(contentsOf: self.storageURL), let saved = try? JSONDecoder().decode(GarminOAuthToken.self, from: data) {
            token = saved
            expiresAt = saved.expiresAt
            status = "正在验证本地保存的\(region.title)会话"
            if automaticallyRestore && networkEnabled {
                Task { [weak self] in await self?.refreshAccount() }
            }
        }
        if !networkEnabled { status = "仅本地，云访问已暂停" }
    }

    deinit { renewalTask?.cancel(); refreshTask?.cancel(); loginTask?.cancel() }

    /// Pause every Garmin request without deleting the saved login session.
    func setNetworkEnabled(_ enabled: Bool) {
        guard enabled != networkEnabled else { return }
        networkEnabled = enabled
        if enabled {
            status = "云同步已开启"
            if token != nil { Task { [weak self] in await self?.refreshAccount() } }
        } else {
            authenticationGeneration = UUID(); loginGeneration = UUID(); refreshIdentity = UUID()
            loginTask?.cancel(); loginTask = nil; refreshTask?.cancel(); refreshTask = nil
            renewalTask?.cancel(); renewalTask = nil
            let configuration = session.configuration
            session.invalidateAndCancel()
            session = URLSession(configuration: configuration, delegate: GarminNoRedirectDelegate(), delegateQueue: nil)
            isAuthenticated = false
            accountName = ""; accountGUID = ""; profileDisplayName = ""; devices = []
            configurationCache.removeAll(); loginRevision = UUID()
            status = "仅本地，云访问已暂停"
        }
    }

    func makeLoginURL() -> URL { GarminChinaURLPolicy.loginURL(mode: loginMode, clientID: ssoClientID, region: region) }

    func switchRegion(_ next: GarminRegion) {
        guard next != region else { return }
        authenticationGeneration = UUID(); loginGeneration = UUID(); refreshIdentity = UUID()
        loginTask?.cancel(); loginTask = nil; refreshTask?.cancel(); refreshTask = nil; renewalTask?.cancel(); renewalTask = nil
        isAuthenticated = false; token = nil; expiresAt = nil
        accountName = ""; accountGUID = ""; profileDisplayName = ""; devices = []
        configurationCache.removeAll(); uploadStatuses.removeAll(); lastTicketDigest = nil
        region = next
        preferences.set(next.rawValue, forKey: "garmin.region")
        storageURL = next == initialRegion ? initialStorageURL : initialStorageURL.deletingLastPathComponent().appendingPathComponent(next.sessionFileName)
        deviceId = preferences.string(forKey: "\(next.preferencePrefix).selectedDeviceID") ?? ""
        ssoClientID = preferences.string(forKey: "\(next.preferencePrefix).ssoClientID") ?? "GCM_ANDROID_LIGHT"
        diClientID = preferences.string(forKey: "\(next.preferencePrefix).diClientID") ?? GarminChinaURLPolicy.defaultDIClientID
        loginRevision = UUID(); loginMode = .mobile
        status = "尚未登录\(next.title)；其他区域的会话保留在本机"
        if !preferences.bool(forKey: "\(next.preferencePrefix).signedOut"),
           let data = try? Data(contentsOf: storageURL), let saved = try? JSONDecoder().decode(GarminOAuthToken.self, from: data) {
            token = saved; expiresAt = saved.expiresAt
            status = "正在验证\(next.title)会话"
            if automaticRestorationEnabled && networkEnabled { Task { [weak self] in await self?.refreshAccount() } }
        }
    }

    func prepareLogin(mode: GarminLoginMode? = nil) {
        guard networkEnabled else { return }
        loginGeneration = UUID()
        loginTask?.cancel(); loginTask = nil
        if let mode { loginMode = mode }
        loginRevision = UUID()
        lastTicketDigest = nil
        status = "请在\(region.title)官方页面完成登录和账户验证"
    }

    func applyLoginConfiguration(ssoClientID: String, diClientID: String) throws {
        guard GarminChinaURLPolicy.validClientID(ssoClientID), GarminChinaURLPolicy.validClientID(diClientID) else {
            throw GarminCloudError.invalidResponse("登录 Client ID 只能包含字母、数字、横线和下划线")
        }
        self.ssoClientID = ssoClientID
        self.diClientID = diClientID
        preferences.set(ssoClientID, forKey: "\(region.preferencePrefix).ssoClientID")
        preferences.set(diClientID, forKey: "\(region.preferencePrefix).diClientID")
        prepareLogin()
    }

    /// Returns true only for a callback that this app must consume instead of navigating.
    @discardableResult
    func handleNavigation(_ url: URL) -> Bool {
        guard networkEnabled else { return true }
        let service = GarminChinaURLPolicy.serviceURL(mode: loginMode, region: region)
        guard let ticket = GarminChinaURLPolicy.serviceTicket(from: url, expectedService: service) else { return false }
        let digest = GarminPrivateFile.digest(Data(ticket.utf8))
        guard loginTask == nil, digest != lastTicketDigest else { return true }
        lastTicketDigest = digest
        let clientID = diClientID
        let generation = authenticationGeneration
        let loginGeneration = self.loginGeneration
        status = "正在交换\(region.title)授权，并验证账户身份"
        loginTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.loginGeneration == loginGeneration { self.loginTask = nil } }
            do {
                let newToken = try await self.requestToken(fields: ["client_id": clientID, "service_ticket": ticket,
                                                                   "service_url": service.absoluteString,
                                                                   "grant_type": GarminChinaURLPolicy.ticketGrant], clientID: clientID)
                guard self.authenticationGeneration == generation, self.loginGeneration == loginGeneration, !Task.isCancelled else { return }
                // A token alone is insufficient: validate it with the real authenticated profile endpoint.
                let profile = try await self.loadProfile(accessToken: newToken.accessToken)
                guard self.authenticationGeneration == generation, self.loginGeneration == loginGeneration, !Task.isCancelled else { return }
                try self.save(newToken)
                self.refreshIdentity = UUID()
                self.refreshTask?.cancel(); self.refreshTask = nil
                self.authenticationGeneration = UUID()
                self.accept(profile: profile, token: newToken)
                await self.loadDevices()
            } catch {
                guard self.authenticationGeneration == generation, self.loginGeneration == loginGeneration else { return }
                self.status = "登录未完成：\(self.safeMessage(error))"
            }
        }
        return true
    }

    func loginPageFailed(_ error: Error) {
        status = "官方登录页未能加载：\(safeMessage(error))。可切换官方网页登录或在浏览器打开登录配置链接。"
    }

    func loginCommunication(_ message: String) {
        // This is the official page's visible message, never its API payload or logMessage.
        status = "佳明官方登录：\(message.prefix(600))"
    }

    func refresh() async {
        do {
            _ = try await validToken(forceRefresh: true)
            status = "\(region.title)会话已续期"
        } catch { status = "会话续期未完成：\(safeMessage(error))" }
    }

    func refreshAccount() async {
        let generation = authenticationGeneration
        do {
            let current = try await validToken()
            let profile = try await loadProfile(accessToken: current.accessToken)
            guard authenticationGeneration == generation else { return }
            accept(profile: profile, token: current)
            await loadDevices()
        } catch {
            guard authenticationGeneration == generation else { return }
            if case GarminCloudError.http(let code, _) = error, code == 401 || code == 403 { isAuthenticated = false }
            status = "账户验证未完成：\(safeMessage(error))"
        }
    }

    func logout() {
        authenticationGeneration = UUID()
        loginGeneration = UUID()
        preferences.set(true, forKey: "\(region.preferencePrefix).signedOut")
        loginTask?.cancel(); loginTask = nil
        refreshTask?.cancel(); refreshTask = nil
        refreshIdentity = UUID()
        renewalTask?.cancel(); renewalTask = nil
        token = nil; expiresAt = nil
        isAuthenticated = false
        accountName = ""; accountGUID = ""; profileDisplayName = ""; devices = []; deviceId = ""
        configurationCache.removeAll()
        do {
            if FileManager.default.fileExists(atPath: storageURL.path) { try FileManager.default.removeItem(at: storageURL) }
            status = "已退出\(region.title)，已清除该区域的本地会话"
        } catch { status = "已退出并停用会话，但本地会话文件未能清除" }
        loginRevision = UUID()
        lastTicketDigest = nil
    }

    func healthMetrics(deviceID: String, sunlightThreshold: Double = 20) async -> GarminHealthRefresh {
        let generation = authenticationGeneration
        let requestRegion = region
        var result = GarminHealthRefresh()
        guard isAuthenticated else { result.detail = "登录\(region.title)后读取同步指标"; return result }
        guard devices.contains(where: { $0.id == deviceID }) else { result.detail = "等待确认当前手表属于已登录账户"; return result }
        let now = Date(), date = GarminHealthMetrics.calendarDate(Date())
        if !profileDisplayName.isEmpty {
            do {
                var components = URLComponents(string: requestRegion.apiBase)!
                components.path = "/usersummary-service/usersummary/daily/\(profileDisplayName)"
                components.queryItems = [URLQueryItem(name: "calendarDate", value: date)]
                let response = try await authenticatedRequest(url: components.url!)
                guard response.1.statusCode == 200 else { throw GarminCloudError.http(response.1.statusCode, "今日健康汇总") }
                result.samples += try GarminHealthMetrics.daily(response.0, now: now)
            } catch { result.detail = "今日指标读取未完成：\(safeMessage(error))" }
        }
        do {
            let url = URL(string: "\(requestRegion.apiBase)/mobile-gateway/solar/\(deviceID)/\(date)/\(date)")!
            let response = try await authenticatedRequest(url: url)
            guard response.1.statusCode == 200 else { throw GarminCloudError.http(response.1.statusCode, "太阳能记录") }
            let series = try GarminHealthMetrics.solarTimeline(response.0, day: now, now: now)
            result.solarSeries = series
            let samples = GarminHealthMetrics.solarSamples(series, threshold: sunlightThreshold)
            result.samples += samples
            if samples.isEmpty {
                for kind in [MetricKind.solarIntensity, .sunlightMinutes, .solarChargingMinutes] { result.notes[kind] = "今日太阳能记录尚未同步" }
            }
        } catch {
            for kind in [MetricKind.solarIntensity, .sunlightMinutes, .solarChargingMinutes] { result.notes[kind] = "太阳能记录暂不可用" }
            if result.detail.isEmpty { result.detail = "太阳能记录读取未完成：\(safeMessage(error))" }
        }
        do {
            result.hrv = try await overnightHRV(day: now)
            result.samples += result.hrv?.samples ?? []
        } catch {
            if result.detail.isEmpty { result.detail = "HRV 读取未完成：\(safeMessage(error))" }
        }
        if result.detail.isEmpty { result.detail = "已刷新 \(result.samples.count) 项云端同步指标" }
        guard generation == authenticationGeneration else { return GarminHealthRefresh() }
        result.samples = result.samples.map { MetricSample(kind: $0.kind, value: $0.value, source: $0.source.replacingOccurrences(of: "佳明中国", with: region.title), timestamp: $0.timestamp, origin: $0.origin) }
        if var solar = result.solarSeries { solar.source = solar.source.replacingOccurrences(of: "佳明中国", with: region.title); result.solarSeries = solar }
        return result
    }

    func overnightHRV(day: Date) async throws -> GarminHRVReport {
        guard isAuthenticated else { throw GarminCloudError.authenticationRequired }
        let generation = authenticationGeneration, requestRegion = region
        let end = GarminHealthMetrics.calendarDate(day)
        let start = GarminHealthMetrics.calendarDate(Calendar.current.date(byAdding: .day, value: -27, to: day)!)
        let response = try await authenticatedRequest(url: URL(string: "\(requestRegion.apiBase)/hrv-service/hrv/daily/\(start)/\(end)")!)
        guard [200, 204].contains(response.1.statusCode) else { throw GarminCloudError.http(response.1.statusCode, "HRV 历史") }
        var report = GarminHRVReport(summaries: response.1.statusCode == 204 ? [] : try GarminHRV.history(response.0), nights: [:], refreshedAt: Date())
        let target = report.latest?.day ?? day
        let date = GarminHealthMetrics.calendarDate(target)
        guard authenticationGeneration == generation else { throw CancellationError() }
        do {
            let (summary, points) = try await overnightHRVNight(day: target)
            if let summary { report.summaries.removeAll { $0.day == summary.day }; report.summaries.append(summary); report.summaries.sort { $0.day < $1.day } }
            report.nights[date] = points
        } catch {
            guard authenticationGeneration == generation, !Task.isCancelled else { throw CancellationError() }
            report.nightWarning = "夜间 HRV 暂时无法读取，请稍后重试。"
        }
        guard authenticationGeneration == generation else { throw CancellationError() }
        return report
    }

    func overnightHRVNight(day: Date) async throws -> (GarminHRVSummary?, [MetricSeriesPoint]) {
        guard isAuthenticated else { throw GarminCloudError.authenticationRequired }
        let generation = authenticationGeneration
        let date = GarminHealthMetrics.calendarDate(day)
        let response = try await authenticatedRequest(url: URL(string: "\(region.apiBase)/hrv-service/hrv/\(date)")!)
        guard generation == authenticationGeneration else { throw CancellationError() }
        if response.1.statusCode == 204 { return (nil, []) }
        guard response.1.statusCode == 200 else { throw GarminCloudError.http(response.1.statusCode, "夜间 HRV") }
        return try GarminHRV.night(response.0, expectedDay: day)
    }

    func dailySeries(deviceID: String, day: Date) async -> GarminSeriesRefresh {
        var result = GarminSeriesRefresh()
        guard isAuthenticated, !profileDisplayName.isEmpty else { result.detail = "登录\(region.title)后读取全天曲线"; return result }
        guard devices.contains(where: { $0.id == deviceID }) else { result.detail = "当前账户未关联此手表"; return result }
        let generation = authenticationGeneration, owner = accountGUID, profile = profileDisplayName, now = Date(), requestRegion = region
        await withTaskGroup(of: (GarminSeriesEndpoint, [MetricKind: MetricDaySeries]?, String?).self) { group in
            for endpoint in GarminSeriesEndpoint.allCases {
                group.addTask { @MainActor [self] in
                    do {
                        guard authenticationGeneration == generation else { throw CancellationError() }
                        let response = try await authenticatedRequest(url: endpoint.url(day: day, profile: profile, region: requestRegion))
                        guard response.1.statusCode == 200 else { throw GarminCloudError.http(response.1.statusCode, "全天记录") }
                        return (endpoint, try GarminDailySeries.parse(response.0, endpoint: endpoint, day: day, now: now), nil)
                    } catch { return (endpoint, nil, safeMessage(error)) }
                }
            }
            for await (endpoint, series, error) in group {
                if let series {
                    for (kind, incoming) in series { result.series[kind] = result.series[kind].map { $0.merging(incoming) } ?? incoming }
                } else {
                    for kind in endpoint.kinds { result.notes[kind] = "全天记录暂不可用：\(error ?? "请稍后重试")" }
                }
            }
        }
        do {
            let date = GarminHealthMetrics.calendarDate(day)
            guard authenticationGeneration == generation else { throw CancellationError() }
            let url = URL(string: "\(requestRegion.apiBase)/mobile-gateway/solar/\(deviceID)/\(date)/\(date)")!
            let response = try await authenticatedRequest(url: url)
            guard response.1.statusCode == 200 else { throw GarminCloudError.http(response.1.statusCode, "全天光照") }
            result.series[.solarIntensity] = try GarminHealthMetrics.solarTimeline(response.0, day: day, now: now)
        } catch { result.notes[.solarIntensity] = "光照记录暂不可用：\(safeMessage(error))" }
        guard authenticationGeneration == generation, accountGUID == owner, isAuthenticated else { return GarminSeriesRefresh(detail: "账户已变化，请重新读取曲线") }
        for kind in Array(result.series.keys) {
            if var series = result.series[kind] { series.source = series.source.replacingOccurrences(of: "佳明中国", with: region.title); result.series[kind] = series }
        }
        let measured = result.series.values.filter { !$0.values.isEmpty }
        result.detail = "已读取 \(measured.count) 项全天趋势 · \(measured.reduce(0) { $0 + $1.values.count }) 条真实记录"
        if !result.notes.isEmpty { result.detail += " · 部分记录暂不可用" }
        return result
    }

    func upload(fileURL: URL, deviceID: String, dataType: GarminDataType) async -> GarminUploadStatus {
        let generation = authenticationGeneration
        var result = GarminUploadStatus(fileName: fileURL.lastPathComponent, state: .uploading, detail: "正在读取设备上传配置")
        publish(result)
        do {
            guard isAuthenticated else { throw GarminCloudError.authenticationRequired }
            let metadata = try GarminFITFileClassifier.inspect(Data(contentsOf: fileURL, options: .mappedIfSafe))
            guard dataType == GarminDataType(fitSubtype: metadata.subtype) else {
                throw GarminCloudError.invalidFIT("上传类别与 FIT file_id.type 不一致")
            }
            let endpoint = try await uploadConfiguration(deviceID: deviceID).endpoint(for: dataType)
            guard generation == authenticationGeneration else { throw CancellationError() }
            let boundary = "GarminPulse-\(UUID().uuidString)"
            let bytes = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard bytes.count <= 64 * 1024 * 1024 else { throw GarminCloudError.invalidFIT("单份 FIT 超出最小版本的 64 MB 上限") }
            let body = Self.multipart(fileName: fileURL.lastPathComponent, bytes: bytes, boundary: boundary)
            var response = try await authenticatedRequest(url: endpoint, method: "POST", body: body,
                                                          contentType: "multipart/form-data; boundary=\(boundary)")
            let deadline = Date().addingTimeInterval(45)
            while true {
                guard generation == authenticationGeneration else { throw CancellationError() }
                let location = try validatedLocation(response.1)
                let classified = GarminUploadResponse.classify(code: response.1.statusCode, data: response.0,
                                                                location: location, fileName: fileURL.lastPathComponent)
                result.state = classified.state; result.detail = classified.detail
                result.httpStatus = classified.httpStatus; result.processingURL = classified.processingURL
                result.activityID = classified.activityID; result.date = Date()
                publish(result)
                guard result.state == .processing, let location, Date() < deadline else { return result }
                let milliseconds = Double(response.1.value(forHTTPHeaderField: "location-in-milliseconds") ?? "") ?? 1000
                let delay = milliseconds.isFinite ? min(5, max(1, milliseconds / 1000)) : 1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                response = try await authenticatedRequest(url: location)
            }
        } catch {
            // An interrupted 202 check must retain its processing URL, preventing a fresh POST on retry.
            if result.state != .processing { result.state = .failed }
            result.detail = safeMessage(error)
            result.date = Date()
            publish(result)
            return result
        }
    }

    func checkUploadStatus(_ previous: GarminUploadStatus) async -> GarminUploadStatus {
        guard let url = previous.processingURL else { return previous }
        var result = previous
        do {
            let response = try await authenticatedRequest(url: url)
            let location = try validatedLocation(response.1) ?? (response.1.statusCode == 202 ? url : nil)
            let new = GarminUploadResponse.classify(code: response.1.statusCode, data: response.0, location: location, fileName: previous.fileName)
            result.state = new.state; result.detail = new.detail; result.httpStatus = new.httpStatus
            result.processingURL = new.processingURL; result.activityID = new.activityID
        } catch { result.detail = safeMessage(error) }
        result.date = Date()
        publish(result)
        return result
    }

    private func requestToken(fields: [String: String], clientID: String, previous: GarminOAuthToken? = nil) async throws -> GarminOAuthToken {
        var request = URLRequest(url: region.tokenURL)
        request.httpMethod = "POST"
        request.httpBody = GarminChinaURLPolicy.formData(fields)
        request.setValue("Basic \(Data((clientID + ":").utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        setClientHeaders(&request)
        let response = try await perform(request)
        guard response.1.statusCode == 200 else { throw GarminCloudError.http(response.1.statusCode, "\(region.title)令牌服务") }
        return try GarminOAuthToken.parse(response.0, clientID: clientID, previous: previous)
    }

    private func validToken(forceRefresh: Bool = false) async throws -> GarminOAuthToken {
        guard networkEnabled else { throw CancellationError() }
        if let refreshTask { return try await refreshTask.value }
        guard let current = token else { throw GarminCloudError.authenticationRequired }
        if !forceRefresh && current.expiresAt > Date().addingTimeInterval(90) { return current }
        if let expiry = current.refreshExpiresAt, expiry <= Date() { throw GarminCloudError.authenticationRequired }
        let generation = authenticationGeneration
        let task = Task { [weak self] () throws -> GarminOAuthToken in
            guard let self else { throw CancellationError() }
            let renewed = try await self.requestToken(fields: ["grant_type": "refresh_token", "client_id": current.clientID,
                                                               "refresh_token": current.refreshToken], clientID: current.clientID, previous: current)
            guard self.authenticationGeneration == generation, !Task.isCancelled else { throw CancellationError() }
            // Persist a rotating refresh token before allowing concurrent API calls to continue.
            try self.save(renewed)
            self.token = renewed; self.expiresAt = renewed.expiresAt
            return renewed
        }
        let identity = UUID()
        refreshIdentity = identity
        refreshTask = task
        defer { if refreshIdentity == identity { refreshTask = nil } }
        return try await task.value
    }

    private func loadProfile(accessToken: String) async throws -> (name: String, guid: String, displayName: String) {
        var request = URLRequest(url: URL(string: "\(region.apiBase)/userprofile-service/socialProfile")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        setClientHeaders(&request)
        let response = try await perform(request)
        guard response.1.statusCode == 200 else { throw GarminCloudError.http(response.1.statusCode, "账户身份验证") }
        guard let profile = try JSONSerialization.jsonObject(with: response.0) as? [String: Any],
              let guid = profile["garminGUID"] as? String, !guid.isEmpty else {
            throw GarminCloudError.invalidResponse("服务器没有返回 Garmin 账户 GUID，登录尚未完成")
        }
        return (stringValue(profile["userProfileFullName"] ?? profile["displayName"]) ?? "\(region.title)账户", guid, stringValue(profile["displayName"]) ?? "")
    }

    private func accept(profile: (name: String, guid: String, displayName: String), token: GarminOAuthToken) {
        profileDisplayName = profile.displayName
        preferences.set(false, forKey: "\(region.preferencePrefix).signedOut")
        self.token = token; expiresAt = token.expiresAt
        accountName = profile.name; accountGUID = profile.guid
        isAuthenticated = true
        status = "已连接\(region.title)：\(profile.name)"
        startRenewal()
    }

    private func loadDevices() async {
        let generation = authenticationGeneration
        do {
            let response = try await authenticatedRequest(url: URL(string: "\(region.apiBase)/device-service/deviceregistration/devices")!)
            guard response.1.statusCode == 200 else { throw GarminCloudError.http(response.1.statusCode, "关联设备列表") }
            let found = try GarminCloudDevice.parse(response.0)
            guard authenticationGeneration == generation else { return }
            devices = found
            if !found.contains(where: { $0.id == deviceId }) {
                deviceId = found.first(where: { ($0.name + $0.productName).localizedCaseInsensitiveContains("instinct") })?.id ?? found.first?.id ?? ""
            }
        } catch {
            guard authenticationGeneration == generation else { return }
            status = "账户已验证，设备列表未能读取：\(safeMessage(error))"
        }
    }

    private func uploadConfiguration(deviceID: String) async throws -> GarminUploadConfiguration {
        if let (date, config) = configurationCache[deviceID], Date().timeIntervalSince(date) < 3600 { return config }
        let url = try GarminChinaURLPolicy.uploadConfigurationURL(deviceID: deviceID, region: region)
        let response = try await authenticatedRequest(url: url)
        guard response.1.statusCode == 200 else { throw GarminCloudError.http(response.1.statusCode, "设备上传配置") }
        let config = try GarminUploadConfiguration.parse(response.0, region: region)
        configurationCache[deviceID] = (Date(), config)
        return config
    }

    /// Weather entitlement is separate from Connect account validity. A rejected weather
    /// endpoint must not invalidate a healthy health-sync session or expose its error body.
    func fetchWeather(latitude: Double, longitude: Double, city: String, forecastHours: Int = 24) async throws -> WatchWeatherSnapshot {
        guard networkEnabled, !Task.isCancelled else { throw CancellationError() }
        guard isAuthenticated else { throw GarminCloudError.authenticationRequired }
        let generation = authenticationGeneration, requestRegion = region, now = Date()
        func fetch(_ section: GarminWeatherAPI.Section) async throws -> Data {
            guard networkEnabled, authenticationGeneration == generation, region == requestRegion, !Task.isCancelled else { throw CancellationError() }
            let url = try GarminWeatherAPI.url(section: section, region: requestRegion, latitude: latitude, longitude: longitude, forecastHours: forecastHours)
            let response: (Data, HTTPURLResponse)
            do {
                response = try await authenticatedRequest(url: url, authFailureInvalidatesSession: false,
                    additionalHeaders: ["X-Garmin-Paired-App-Version": "WristBeam/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1")"])
            } catch {
                if error is CancellationError || !networkEnabled || authenticationGeneration != generation || Task.isCancelled { throw CancellationError() }
                if error is GarminCloudError { throw GarminWeatherError.accessDenied }
                throw GarminWeatherError.unavailable
            }
            guard networkEnabled, authenticationGeneration == generation, region == requestRegion, !Task.isCancelled else { throw CancellationError() }
            switch response.1.statusCode {
            case 200: break
            case 401, 403: throw GarminWeatherError.accessDenied
            case 300..<400: throw GarminWeatherError.redirected
            default: throw GarminWeatherError.unavailable
            }
            guard response.0.count <= GarminWeatherAPI.maximumResponseBytes else { throw GarminWeatherError.invalidResponse }
            return response.0
        }
        let current = try GarminWeatherAPI.current(try await fetch(.current), now: now)
        var snapshot = WatchWeatherSnapshot(location: .init(name: String(city.prefix(100)), latitude: latitude, longitude: longitude),
                                            fetchedAt: now, current: current)
        for section in [GarminWeatherAPI.Section.hourly, .daily, .alerts] {
            do {
                let data = try await fetch(section)
                switch section {
                case .hourly: snapshot.hourly = try GarminWeatherAPI.hourly(data, now: now)
                case .daily: snapshot.daily = try GarminWeatherAPI.daily(data, now: now)
                case .alerts: snapshot.alerts = try GarminWeatherAPI.alerts(data, now: now)
                case .current: break
                }
            } catch {
                guard networkEnabled, authenticationGeneration == generation, region == requestRegion, !Task.isCancelled,
                      !(error is CancellationError) else { throw CancellationError() }
                // nil alerts means unavailable, never the confirmed empty list that clears alerts.
                snapshot.unavailableSections.append(section.rawValue)
            }
        }
        guard networkEnabled, authenticationGeneration == generation, region == requestRegion, !Task.isCancelled else { throw CancellationError() }
        // APK is2.a uses the first daily forecast for today's high/low in current conditions.
        snapshot.current.highC = snapshot.daily.first?.highC
        snapshot.current.lowC = snapshot.daily.first?.lowC
        snapshot.current.precipitationProbability = snapshot.daily.first?.precipitationProbability
        return snapshot
    }

    func fetchActivityPage(offset: Int) async throws -> [GarminActivity] {
        let url = try GarminActivities.listURL(region: region, offset: offset)
        return try GarminActivities.list(try await activityRequest(url, limit: GarminActivities.maximumJSONBytes))
    }

    func fetchActivityDetail(id: String) async throws -> GarminActivityDetail {
        guard GarminActivities.validID(id) else { throw GarminActivityError.invalidResponse }
        let generation = authenticationGeneration, requestRegion = region
        let base = requestRegion.apiBase + "/activity-service/activity/" + id
        let summary = try await activityRequest(URL(string: base)!, limit: GarminActivities.maximumJSONBytes)
        guard generation == authenticationGeneration, requestRegion == region else { throw CancellationError() }
        let chart = try await activityRequest(URL(string: base + "/details?maxChartSize=\(GarminActivities.chartLimit)&maxPolylineSize=0")!, limit: GarminActivities.maximumJSONBytes)
        guard generation == authenticationGeneration, requestRegion == region else { throw CancellationError() }
        var result = try GarminActivities.detail(summary: summary, chart: chart, expectedID: id)
        result.unavailableSections = []
        for section in ["hrTimeInZones", "splits"] {
            do {
                let data = try await activityRequest(URL(string: base + "/" + section)!, limit: GarminActivities.maximumJSONBytes)
                guard generation == authenticationGeneration, requestRegion == region, networkEnabled, !Task.isCancelled else { throw CancellationError() }
                if section == "hrTimeInZones" { result.heartRateZones = try GarminActivities.zones(data) }
                else { result.laps = try GarminActivities.laps(data, expectedID: id) }
            } catch {
                guard generation == authenticationGeneration, requestRegion == region, networkEnabled, !Task.isCancelled,
                      !(error is CancellationError) else { throw CancellationError() }
                result.unavailableSections?.append(section)
            }
        }
        return result
    }

    func fetchActivityFile(id: String, format: GarminActivityFormat) async throws -> Data {
        guard GarminActivities.validID(id) else { throw GarminActivityError.invalidResponse }
        let data = try await activityRequest(URL(string: region.apiBase + format.endpoint + id)!, limit: GarminActivities.maximumFileBytes, accept: "*/*")
        try GarminActivities.validateFile(data, format: format)
        return data
    }

    private func activityRequest(_ url: URL, limit: Int, accept: String = "application/json") async throws -> Data {
        guard networkEnabled, !Task.isCancelled else { throw CancellationError() }
        guard isAuthenticated, !accountGUID.isEmpty else { throw GarminCloudError.authenticationRequired }
        let response = try await authenticatedRequest(url: url, authFailureInvalidatesSession: false, additionalHeaders: ["Accept": accept], maximumBytes: limit)
        guard response.1.statusCode == 200 else { throw GarminActivityError.unavailable }
        return response.0
    }

    private func authenticatedRequest(url: URL, method: String = "GET", body: Data? = nil, contentType: String? = nil,
                                      authFailureInvalidatesSession: Bool = true, additionalHeaders: [String: String] = [:], maximumBytes: Int? = nil) async throws -> (Data, HTTPURLResponse) {
        let generation = authenticationGeneration
        guard GarminChinaURLPolicy.isTrusted(url, region: region) else { throw GarminCloudError.untrustedURL }
        let current = try await validToken()
        guard authenticationGeneration == generation else { throw CancellationError() }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        setClientHeaders(&request)
        for (key, value) in additionalHeaders { request.setValue(value, forHTTPHeaderField: key) }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
        var response = try await perform(request, maximumBytes: maximumBytes)
        guard authenticationGeneration == generation else { throw CancellationError() }
        if response.1.statusCode == 401 {
            let renewed = try await validToken(forceRefresh: true)
            guard authenticationGeneration == generation else { throw CancellationError() }
            request.setValue("Bearer \(renewed.accessToken)", forHTTPHeaderField: "Authorization")
            response = try await perform(request, maximumBytes: maximumBytes)
            guard authenticationGeneration == generation else { throw CancellationError() }
        }
        if authFailureInvalidatesSession && (response.1.statusCode == 401 || response.1.statusCode == 403) { isAuthenticated = false }
        return response
    }

    private func perform(_ request: URLRequest, maximumBytes: Int? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, GarminChinaURLPolicy.isTrusted(url, region: region) else { throw GarminCloudError.untrustedURL }
        guard networkEnabled, !Task.isCancelled else { throw CancellationError() }
        let generation = authenticationGeneration
        requestCount += 1
        let data: Data, response: URLResponse
        if let maximumBytes {
            (data, response) = try await Self.activityBytes(session: session, request: request, maximumBytes: maximumBytes)
        } else { (data, response) = try await session.data(for: request) }
        guard networkEnabled, generation == authenticationGeneration, !Task.isCancelled else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw GarminCloudError.invalidResponse("没有收到 HTTP 响应") }
        return (data, http)
    }

    // Reading a potentially large export must not monopolize the menu bar's main actor.
    private nonisolated static func activityBytes(session: URLSession, request: URLRequest, maximumBytes: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw GarminActivityError.invalidResponse }
        var buffer = Data()
        for try await byte in bytes {
            guard buffer.count < maximumBytes else { throw GarminActivityError.invalidResponse }
            if buffer.count % 65536 == 0 { try Task.checkCancellation() }
            buffer.append(byte)
        }
        return (buffer, response)
    }

    private func setClientHeaders(_ request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GarminPulse/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("GarminPulse/0.1; macOS", forHTTPHeaderField: "X-Garmin-User-Agent")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("zh", forHTTPHeaderField: "X-Lang")
        request.setValue("GC5", forHTTPHeaderField: "X-GCExperience")
        request.setValue("background", forHTTPHeaderField: "Sync-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    }

    private func validatedLocation(_ response: HTTPURLResponse) throws -> URL? {
        guard let value = response.value(forHTTPHeaderField: "Location"),
              let base = response.url, let location = URL(string: value, relativeTo: base)?.absoluteURL else { return nil }
        guard GarminChinaURLPolicy.isTrusted(location, region: region) else { throw GarminCloudError.untrustedURL }
        return location
    }

    private func save(_ value: GarminOAuthToken) throws { try GarminPrivateFile.write(JSONEncoder().encode(value), to: storageURL) }

    private func startRenewal() {
        renewalTask?.cancel()
        renewalTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                guard let self else { return }
                guard let token = self.token, token.expiresAt < Date().addingTimeInterval(300) else { continue }
                do { _ = try await self.validToken(forceRefresh: true) }
                catch { self.status = "后台续期未完成：\(self.safeMessage(error))" }
            }
        }
    }

    private func publish(_ value: GarminUploadStatus) {
        if let index = uploadStatuses.firstIndex(where: { $0.id == value.id }) { uploadStatuses[index] = value }
        else { uploadStatuses.insert(value, at: 0) }
        if uploadStatuses.count > 50 { uploadStatuses.removeLast(uploadStatuses.count - 50) }
    }

    private func safeMessage(_ error: Error) -> String {
        if let known = error as? GarminCloudError { return known.localizedDescription }
        if let urlError = error as? URLError { return "网络请求未完成（\(urlError.code.rawValue)）" }
        if error is CancellationError { return "操作已取消，文件仍保留在本地" }
        // Foundation errors can embed URLs carrying tickets: never surface their full text.
        return "操作未完成（\((error as NSError).domain)，\((error as NSError).code)）"
    }

    static func multipart(fileName: String, bytes: Data, boundary: String) -> Data {
        let name = fileName.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        var data = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"userfile\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        data.append(bytes)
        data.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return data
    }
}

// Connect IQ reuses the existing DI token, refresh serialization and region/pause guards.
// Tested China read path: Bearer DI + APPSTORE_MOBILE, not the OAuth client ID or IT token.
extension GarminChinaCloud {
    private func connectIQDevice(_ id: String) throws -> GarminCloudDevice {
        guard networkEnabled, !Task.isCancelled else { throw CancellationError() }
        guard isAuthenticated, !accountGUID.isEmpty else { throw GarminCloudError.authenticationRequired }
        guard id == deviceId, let device = devices.first(where: { $0.id == id }), UInt64(id) != nil else { throw ConnectIQError.selectDevice }
        guard let part = device.partNumber, part.range(of: "^006-B[0-9]+-[0-9]+$", options: .regularExpression) != nil else { throw ConnectIQError.missingPartNumber }
        return device
    }
    private func connectIQQuery(_ id: String) -> [URLQueryItem] {
        [URLQueryItem(name: "countryCode", value: region == .china ? "CN" : Locale.current.region?.identifier ?? "US"),
         URLQueryItem(name: "unitId", value: id)]
    }
    private func connectIQRequest(path: String, deviceID: String, query: [URLQueryItem], method: String = "GET") async throws -> Data {
        let device = try connectIQDevice(deviceID), generation = authenticationGeneration
        let url = ConnectIQService.storeURL(region: region, path: path, query: query)
        let response = try await authenticatedRequest(url: url, method: method, authFailureInvalidatesSession: false,
            additionalHeaders: ["X-garmin-client-id": "APPSTORE_MOBILE", "X-Garmin-SW-Part-Number": device.partNumber!],
            maximumBytes: ConnectIQService.maximumJSONBytes)
        guard generation == authenticationGeneration, self.deviceId == deviceID else { throw CancellationError() }
        guard (200...299).contains(response.1.statusCode) else { throw GarminCloudError.http(response.1.statusCode, "Connect IQ") }
        return response.0
    }
    func fetchConnectIQHistory(deviceID: String, page: Int = 0) async throws -> [ConnectIQDownloadRecord] {
        guard (0...1000).contains(page) else { throw ConnectIQError.invalidData }
        let data = try await connectIQRequest(path: "apps/downloads", deviceID: deviceID, query: [
            URLQueryItem(name: "unitId", value: deviceID), URLQueryItem(name: "startPageIndex", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(ConnectIQService.pageSize))])
        return try ConnectIQDownloadRecord.parse(data)
    }
    func fetchConnectIQApp(id: String, deviceID: String) async throws -> ConnectIQApp {
        guard let id = UUID(uuidString: id)?.uuidString.lowercased() else { throw ConnectIQError.invalidAppID }
        let data = try await connectIQRequest(path: "apps/" + id, deviceID: deviceID,
            query: connectIQQuery(deviceID) + [URLQueryItem(name: "ignoreCompatibility", value: "false")])
        let app = try ConnectIQApp.parse(data, region: region)
        guard app.id == id else { throw ConnectIQError.invalidData }
        return app
    }
    func fetchConnectIQFeatured(deviceID: String, page: Int = 0) async throws -> [ConnectIQApp] {
        guard (0...1000).contains(page) else { throw ConnectIQError.invalidData }
        let data = try await connectIQRequest(path: "apps", deviceID: deviceID, query: connectIQQuery(deviceID) + [
            URLQueryItem(name: "sortType", value: "mostPopular"), URLQueryItem(name: "appType", value: "watchface"),
            URLQueryItem(name: "pageSize", value: String(ConnectIQService.pageSize)), URLQueryItem(name: "startPageIndex", value: String(page)),
            URLQueryItem(name: "companionAppPlatform", value: "android")])
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ConnectIQError.invalidData }
        return try rows.map { try ConnectIQApp.parse($0, region: region) }.filter(\.isWatchFace)
    }

    /// Store APK sr9.b / vs9: keyword search with device compatibility and relevance ordering.
    func searchConnectIQApps(keywords: String, deviceID: String, page: Int = 0) async throws -> [ConnectIQApp] {
        guard let keywords = ConnectIQService.searchKeywords(from: keywords), (0...1000).contains(page) else {
            throw ConnectIQError.invalidData
        }
        let data = try await connectIQRequest(path: "apps/keywords", deviceID: deviceID, query: connectIQQuery(deviceID) + [
            URLQueryItem(name: "keywords", value: keywords), URLQueryItem(name: "sortType", value: "mostRelevant"),
            URLQueryItem(name: "filterType", value: "ALL"), URLQueryItem(name: "appType", value: "watchface"),
            URLQueryItem(name: "locale", value: L10n.languageTag),
            URLQueryItem(name: "pageSize", value: String(ConnectIQService.pageSize)), URLQueryItem(name: "startPageIndex", value: String(page)),
            URLQueryItem(name: "companionAppPlatform", value: "android")])
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              rows.count <= ConnectIQService.pageSize else { throw ConnectIQError.invalidData }
        return try rows.map { try ConnectIQApp.parse($0, region: region) }.filter(\.isWatchFace)
    }

    func connectIQSettingsContext(for face: GFDIInstalledWatchFace) throws -> ConnectIQSettingsContext {
        let device = try connectIQDevice(String(face.unitID))
        guard let version = face.version, version > 0 else { throw ConnectIQSettingsCloudError.invalidContext }
        return try ConnectIQSettingsContext(appID: face.id, version: version, partNumber: device.partNumber!,
                                            region: region, locale: L10n.languageTag)
    }

    /// APK x60/a10 uses HTTP_CLIENT_NO_AUTH. Never attach account tokens to the editor/serializer.
    func serializeConnectIQSettings(_ jsonData: Data, context: ConnectIQSettingsContext, deviceID: String) async throws -> Data {
        let device = try connectIQDevice(deviceID), generation = authenticationGeneration
        guard context.region == region, context.partNumber == device.partNumber else {
            throw ConnectIQSettingsCloudError.contextChanged
        }
        let request = try context.binaryRequest(settingsJSON: jsonData)
        requestCount += 1
        let (data, response) = try await Self.activityBytes(session: session, request: request, maximumBytes: 256 * 1024)
        guard generation == authenticationGeneration, self.deviceId == deviceID, networkEnabled, !Task.isCancelled else {
            throw ConnectIQSettingsCloudError.contextChanged
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty,
              !(http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("html") else {
            throw ConnectIQSettingsCloudError.invalidResponse
        }
        return data
    }
    /// Bind a local package to the current device's real cloud installation task.
    /// Read-only: never creates, acknowledges or deletes a queue entry.
    func fetchConnectIQInstallMessageID(appID: String, deviceID: String, expectedSHA256: String) async throws -> UInt64 {
        guard expectedSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw ConnectIQError.packageChanged }
        let device = try connectIQDevice(deviceID), generation = authenticationGeneration
        let requestRegion = region
        func checkContext() throws {
            guard generation == self.authenticationGeneration, self.deviceId == deviceID,
                  self.networkEnabled, !Task.isCancelled else { throw CancellationError() }
        }
        let app = try await fetchConnectIQApp(id: appID, deviceID: deviceID)
        try checkContext()
        guard app.isWatchFace, app.compatiblePartNumbers.contains(device.partNumber!) else { throw ConnectIQError.incompatible }
        var url = URLComponents(string: requestRegion.apiBase + "/device-service/devicemessage/messages")!
        url.queryItems = [URLQueryItem(name: "device_id", value: deviceID)]
        let queue = try await authenticatedRequest(url: url.url!, authFailureInvalidatesSession: false,
                                                   maximumBytes: ConnectIQService.maximumJSONBytes)
        try checkContext()
        guard queue.1.statusCode == 200 else { throw GarminCloudError.http(queue.1.statusCode, "Connect IQ") }
        guard let item = try ConnectIQService.queuedPackage(queue.0, appID: app.id, deviceID: deviceID, region: requestRegion),
              let id = item.messageID, id > 0, id < (UInt64(1) << 54) else { throw ConnectIQError.installationContextMissing }
        let file = try await authenticatedRequest(url: item.url, authFailureInvalidatesSession: false,
            additionalHeaders: ["Accept": "*/*", "X-garmin-client-id": "APPSTORE_MOBILE"], maximumBytes: ConnectIQService.maximumPackageBytes)
        try checkContext()
        guard file.1.statusCode == 200 else { throw GarminCloudError.http(file.1.statusCode, "Connect IQ") }
        try ConnectIQService.validatePackage(file.0, contentType: file.1.value(forHTTPHeaderField: "Content-Type"))
        guard GarminPrivateFile.digest(file.0) == expectedSHA256 else { throw ConnectIQError.packageChanged }
        return id
    }

    /// This can create a cloud installation queue ONLY after explicit UI confirmation.
    /// The returned bytes are an opaque server package. No queue completion or BLE write occurs here.
    func downloadConnectIQApp(app: ConnectIQApp, deviceID: String, allowQueueCreation: Bool) async throws -> Data {
        guard connectIQDownloadID == nil else { throw ConnectIQError.busy }
        let operation = UUID(); connectIQDownloadID = operation
        defer { if connectIQDownloadID == operation { connectIQDownloadID = nil } }
        let device = try connectIQDevice(deviceID), generation = authenticationGeneration
        let region = self.region
        func checkContext() throws {
            guard self.authenticationGeneration == generation, self.deviceId == deviceID, self.networkEnabled, !Task.isCancelled else { throw CancellationError() }
        }
        // Refresh compatibility/version from the server; do not trust a stale view or caller-supplied model.
        let current = try await fetchConnectIQApp(id: app.id, deviceID: deviceID)
        try checkContext()
        guard current.isWatchFace, current.compatiblePartNumbers.contains(device.partNumber!) else { throw ConnectIQError.incompatible }
        var messagesURL = URLComponents(string: region.apiBase + "/device-service/devicemessage/messages")!
        messagesURL.queryItems = [URLQueryItem(name: "device_id", value: deviceID)]
        func queuedURL() async throws -> URL? {
            try checkContext()
            let response = try await self.authenticatedRequest(url: messagesURL.url!, authFailureInvalidatesSession: false, maximumBytes: ConnectIQService.maximumJSONBytes)
            try checkContext()
            guard response.1.statusCode == 200 else { throw GarminCloudError.http(response.1.statusCode, "Connect IQ") }
            return try ConnectIQService.packageURL(response.0, appID: current.id, deviceID: deviceID, region: region)
        }
        var fileURL = try await queuedURL()
        if fileURL == nil {
            guard allowQueueCreation else { throw ConnectIQError.queueConsentRequired }
            try checkContext()
            _ = try await connectIQRequest(path: "apps/\(current.id)/install", deviceID: deviceID, query: [
                URLQueryItem(name: "internalAppVersion", value: String(current.internalVersion)),
                URLQueryItem(name: "locale", value: "zh-CN"), URLQueryItem(name: "unitId", value: deviceID)], method: "POST")
            for attempt in 0..<6 {
                try checkContext()
                if attempt > 0 { try await Task.sleep(nanoseconds: 1_000_000_000) }
                fileURL = try await queuedURL()
                if fileURL != nil { break }
            }
        }
        guard let fileURL else { throw ConnectIQError.packagePending }
        try checkContext()
        // Exact host allowlist was checked while parsing metadata. Redirects remain disabled.
        let response = try await authenticatedRequest(url: fileURL, authFailureInvalidatesSession: false,
            additionalHeaders: ["Accept": "*/*", "X-garmin-client-id": "APPSTORE_MOBILE"], maximumBytes: ConnectIQService.maximumPackageBytes)
        try checkContext()
        guard response.1.statusCode == 200 else { throw GarminCloudError.http(response.1.statusCode, "Connect IQ") }
        try ConnectIQService.validatePackage(response.0, contentType: response.1.value(forHTTPHeaderField: "Content-Type"))
        return response.0
    }
}
