import Foundation
import XCTest
@testable import GarminBar

private final class ConnectIQHTTP: URLProtocol {
    static let appID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    static let part = "006-B9999-00"
    static let package = Data([0xD0, 0x00, 0xAB, 0x12, 0x01])
    struct Options {
        var queued = false
        var packageURL = "/packages/synthetic.prg"
        var packageBody: Data = ConnectIQHTTP.package
        var packageType = "application/octet-stream"
        var oversized = false
        var redirect = false
        var wrongApp = false
        var incompatible = false
        var missingPart = false
        var stallHistory = false
    }
    private static let lock = NSLock()
    private static var options = Options()
    private static var installed = false
    private static var seen: [URLRequest] = []
    private static var pending: [ConnectIQHTTP] = []
    static func reset(_ options: Options = Options()) {
        lock.lock(); defer { lock.unlock() }
        self.options = options; installed = false; seen = []; pending = []
    }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    static func releaseHistory() {
        lock.lock(); let waiting = pending; pending = []; lock.unlock()
        for protocolInstance in waiting { protocolInstance.respond() }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request)
        let stall = Self.options.stallHistory && request.url!.path.hasSuffix("apps/downloads")
        if stall { Self.pending.append(self) }
        Self.lock.unlock()
        if !stall { respond() }
    }
    private func respond() {
        let url = request.url!, path = url.path
        Self.lock.lock()
        let options = Self.options
        if path.hasSuffix("/install") && request.httpMethod == "POST" { Self.installed = true }
        let queued = options.queued || Self.installed
        Self.lock.unlock()
        var status = 200, headers = ["Content-Type": "application/json"]
        let body: Data
        if path.contains("socialProfile") {
            body = Data(#"{"garminGUID":"ciq-synthetic-account","displayName":"Fixture"}"#.utf8)
        } else if path.contains("deviceregistration") {
            var device: [String: Any] = ["deviceId": "101", "displayName": "Synthetic watch", "productName": "Synthetic"]
            if !options.missingPart { device["partNumber"] = Self.part }
            body = Self.json([device, ["deviceId": "202", "displayName": "Second fixture", "partNumber": Self.part]])
        } else if path.hasSuffix("apps/downloads") {
            body = Self.json([["appId": Self.appID, "internalAppVersion": 7, "externalAppVersion": "1.7", "date": 120_000]])
            if options.oversized { headers["Content-Length"] = String(ConnectIQService.maximumJSONBytes + 1) }
        } else if path.contains("devicemessage") {
            let messages: [[String: Any]] = queued ? [["messageId": 12345, "messageType": "install_app", "deviceId": "101",
                "metaData": ["appDetails": ["id": Self.appID], "messageUrl": options.packageURL]]] : []
            body = Self.json(["serviceHost": "https://services.garmin.cn", "messages": messages])
        } else if path.hasSuffix("/install") {
            body = Data(); status = 204
        } else if path.hasPrefix("/packages/") {
            body = options.packageBody; headers["Content-Type"] = options.packageType
            if options.oversized { headers["Content-Length"] = String(ConnectIQService.maximumPackageBytes + 1) }
            if options.redirect { status = 302; headers["Location"] = "https://example.org/never-follow" }
        } else if path == "/appstore/api/v2/asm/apps" || path == "/appstore/api/v2/asm/apps/keywords" {
            body = Self.json([Self.appObject(options)])
        } else if path == "/appstore/api/v2/asm/apps/\(Self.appID)" {
            body = Self.json(Self.appObject(options))
        } else { body = Data("{}".utf8); status = 404 }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    static func appObject(_ options: Options = Options()) -> [String: Any] {
        ["id": options.wrongApp ? "11111111-2222-3333-4444-555555555555" : appID,
         "latestInternalVersion": 7, "latestExternalVersion": "1.7", "typeId": 1,
         "appLocalizations": [["locale": "zh-CN", "name": "合成表盘"]],
         "compatibleDevicePartNumbers": options.incompatible ? [] : [part]]
    }
    private static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    override func stopLoading() {}
}

@MainActor final class ConnectIQCloudTests: XCTestCase {
    func testKeywordSearchEncodesTextAndKeepsDeviceAndWatchFaceFilters() async throws {
        try await withFixture { cloud in
            let rows = try await cloud.searchConnectIQApps(keywords: "  山水 + Digital&A  ", deviceID: "101", page: 2)
            XCTAssertEqual(rows.map(\.id), [ConnectIQHTTP.appID])
            let request = try XCTUnwrap(ConnectIQHTTP.requests.last), parameters = query(request)
            XCTAssertEqual(request.url?.path, "/appstore/api/v2/asm/apps/keywords")
            XCTAssertEqual(request.url?.host, "services.garmin.cn")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(parameters["keywords"], "山水 + Digital&A")
            XCTAssertTrue(request.url!.absoluteString.contains("%2B"))
            XCTAssertTrue(request.url!.absoluteString.contains("%26"))
            XCTAssertEqual(parameters["sortType"], "mostRelevant")
            XCTAssertEqual(parameters["filterType"], "ALL")
            XCTAssertEqual(parameters["appType"], "watchface")
            XCTAssertEqual(parameters["unitId"], "101")
            XCTAssertEqual(parameters["countryCode"], "CN")
            XCTAssertEqual(parameters["startPageIndex"], "2")
            XCTAssertEqual(parameters["pageSize"], "30")
            XCTAssertEqual(parameters["locale"], L10n.isEnglish ? "en-US" : "zh-CN")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Garmin-SW-Part-Number"), ConnectIQHTTP.part)
            XCTAssertFalse(ConnectIQHTTP.requests.contains { $0.httpMethod == "POST" })
        }
    }

    func testKeywordSearchRejectsInvalidInputAndHonorsOfflineGate() async throws {
        try await withFixture { cloud in
            let count = ConnectIQHTTP.requests.count
            for keywords in [" ", String(repeating: "x", count: 129)] {
                await expectError(.invalidData) { _ = try await cloud.searchConnectIQApps(keywords: keywords, deviceID: "101") }
            }
            await expectError(.invalidData) { _ = try await cloud.searchConnectIQApps(keywords: "Digital", deviceID: "101", page: -1) }
            await expectError(.selectDevice) { _ = try await cloud.searchConnectIQApps(keywords: "Digital", deviceID: "202") }
            cloud.setNetworkEnabled(false)
            do { _ = try await cloud.searchConnectIQApps(keywords: "Digital", deviceID: "101"); XCTFail("Expected offline rejection") }
            catch {}
            XCTAssertEqual(ConnectIQHTTP.requests.count, count)
        }
    }

    func testHistoryUsesDIStoreIdentityDevicePartAndPagination() async throws {
        try await withFixture { cloud in
            let records = try await cloud.fetchConnectIQHistory(deviceID: "101", page: 3)
            XCTAssertEqual(records.first?.appID, ConnectIQHTTP.appID)
            let request = try XCTUnwrap(ConnectIQHTTP.requests.last)
            XCTAssertEqual(request.url?.host, "services.garmin.cn")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-ciq-access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-garmin-client-id"), "APPSTORE_MOBILE")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Garmin-SW-Part-Number"), ConnectIQHTTP.part)
            XCTAssertEqual(query(request), ["unitId": "101", "startPageIndex": "3", "pageSize": "30"])
        }
    }

    func testDetailsAndFeaturedUseDeviceCompatibilityAndWatchfaceFilter() async throws {
        try await withFixture { cloud in
            let app = try await cloud.fetchConnectIQApp(id: ConnectIQHTTP.appID.uppercased(), deviceID: "101")
            XCTAssertEqual(app.id, ConnectIQHTTP.appID)
            XCTAssertEqual(query(try XCTUnwrap(ConnectIQHTTP.requests.last))["ignoreCompatibility"], "false")
            let featured = try await cloud.fetchConnectIQFeatured(deviceID: "101", page: 2)
            XCTAssertEqual(featured.map(\.id), [ConnectIQHTTP.appID])
            let parameters = query(try XCTUnwrap(ConnectIQHTTP.requests.last))
            XCTAssertEqual(parameters["appType"], "watchface"); XCTAssertEqual(parameters["countryCode"], "CN")
            XCTAssertEqual(parameters["unitId"], "101"); XCTAssertEqual(parameters["startPageIndex"], "2")
        }
    }

    func testDeviceOwnershipSelectionInputBoundsAndPauseGateRequests() async throws {
        try await withFixture { cloud in
            let count = ConnectIQHTTP.requests.count
            for deviceID in ["202", "999", "not-a-device"] {
                await expectError(.selectDevice) { _ = try await cloud.fetchConnectIQHistory(deviceID: deviceID) }
            }
            cloud.deviceId = "999"
            await expectError(.selectDevice) { _ = try await cloud.fetchConnectIQHistory(deviceID: "999") }
            cloud.deviceId = "101"
            for page in [-1, 1001] {
                await expectError(.invalidData) { _ = try await cloud.fetchConnectIQHistory(deviceID: "101", page: page) }
                await expectError(.invalidData) { _ = try await cloud.fetchConnectIQFeatured(deviceID: "101", page: page) }
            }
            await expectError(.invalidAppID) { _ = try await cloud.fetchConnectIQApp(id: "bad", deviceID: "101") }
            cloud.setNetworkEnabled(false)
            do { _ = try await cloud.fetchConnectIQHistory(deviceID: "101"); XCTFail("Paused request succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(ConnectIQHTTP.requests.count, count)
        }
    }

    func testMissingPartNumberCannotIssueStoreRequest() async throws {
        var options = ConnectIQHTTP.Options(); options.missingPart = true
        try await withFixture(options) { cloud in
            let count = ConnectIQHTTP.requests.count
            await expectError(.missingPartNumber) { _ = try await cloud.fetchConnectIQHistory(deviceID: "101") }
            XCTAssertEqual(ConnectIQHTTP.requests.count, count)
        }
    }

    func testMismatchedDetailIdentityAndOversizedHistoryAreRejected() async throws {
        var options = ConnectIQHTTP.Options(); options.wrongApp = true; options.oversized = true
        try await withFixture(options) { cloud in
            await expectError(.invalidData) { _ = try await cloud.fetchConnectIQApp(id: ConnectIQHTTP.appID, deviceID: "101") }
            do { _ = try await cloud.fetchConnectIQHistory(deviceID: "101"); XCTFail("Oversized response accepted") }
            catch { XCTAssertTrue(error is GarminActivityError) }
        }
    }

    func testInstallContextRequiresExactLocalBytesAndNeverCreatesAQueue() async throws {
        var options = ConnectIQHTTP.Options(); options.queued = true
        try await withFixture(options) { cloud in
            let id = try await cloud.fetchConnectIQInstallMessageID(appID: ConnectIQHTTP.appID,
                deviceID: "101", expectedSHA256: GarminPrivateFile.digest(ConnectIQHTTP.package))
            XCTAssertEqual(id, 12345)
            await expectError(.packageChanged) {
                _ = try await cloud.fetchConnectIQInstallMessageID(appID: ConnectIQHTTP.appID,
                    deviceID: "101", expectedSHA256: GarminPrivateFile.digest(Data([0x99])))
            }
            XCTAssertTrue(ConnectIQHTTP.requests.allSatisfy { $0.httpMethod == "GET" })
        }
        try await withFixture { cloud in
            await expectError(.installationContextMissing) {
                _ = try await cloud.fetchConnectIQInstallMessageID(appID: ConnectIQHTTP.appID,
                    deviceID: "101", expectedSHA256: GarminPrivateFile.digest(ConnectIQHTTP.package))
            }
            XCTAssertTrue(ConnectIQHTTP.requests.allSatisfy { $0.httpMethod == "GET" })
        }
    }

    func testNoInstallIsPostedWithoutExplicitQueueConsent() async throws {
        try await withFixture { cloud in
            let app = try ConnectIQApp.parse(ConnectIQHTTP.appObject())
            await expectError(.queueConsentRequired) { _ = try await cloud.downloadConnectIQApp(app: app, deviceID: "101", allowQueueCreation: false) }
            XCTAssertFalse(ConnectIQHTTP.requests.contains { $0.httpMethod == "POST" })
            XCTAssertFalse(ConnectIQHTTP.requests.contains { $0.url!.path.hasPrefix("/packages/") })
        }
    }

    func testExistingQueueDownloadsWithoutCreatingAnotherInstallation() async throws {
        var options = ConnectIQHTTP.Options(); options.queued = true
        try await withFixture(options) { cloud in
            let app = try ConnectIQApp.parse(ConnectIQHTTP.appObject())
            let bytes = try await cloud.downloadConnectIQApp(app: app, deviceID: "101", allowQueueCreation: false)
            XCTAssertEqual(bytes, ConnectIQHTTP.package)
            XCTAssertFalse(ConnectIQHTTP.requests.contains { $0.httpMethod == "POST" })
            XCTAssertEqual(ConnectIQHTTP.requests.last?.value(forHTTPHeaderField: "Accept"), "*/*")
        }
    }

    func testExplicitConsentCreatesOneQueueUsingFreshVersionAndDownloadsBytes() async throws {
        try await withFixture { cloud in
            var stale = ConnectIQHTTP.appObject(); stale["latestInternalVersion"] = 1
            let app = try ConnectIQApp.parse(stale)
            let bytes = try await cloud.downloadConnectIQApp(app: app, deviceID: "101", allowQueueCreation: true)
            XCTAssertEqual(bytes, ConnectIQHTTP.package)
            let posts = ConnectIQHTTP.requests.filter { $0.httpMethod == "POST" }
            XCTAssertEqual(posts.count, 1)
            let post = try XCTUnwrap(posts.first)
            XCTAssertEqual(post.url?.path, "/appstore/api/v2/asm/apps/\(ConnectIQHTTP.appID)/install")
            XCTAssertEqual(query(post)["internalAppVersion"], "7")
            XCTAssertEqual(query(post)["unitId"], "101")
            XCTAssertEqual(post.value(forHTTPHeaderField: "X-Garmin-SW-Part-Number"), ConnectIQHTTP.part)
            XCTAssertFalse(ConnectIQHTTP.requests.contains { $0.httpMethod == "PUT" || $0.httpMethod == "DELETE" })
        }
    }

    func testFreshCompatibilityBlocksQueueCreationEvenWhenCallerClaimsCompatible() async throws {
        var options = ConnectIQHTTP.Options(); options.incompatible = true
        try await withFixture(options) { cloud in
            let app = try ConnectIQApp.parse(ConnectIQHTTP.appObject())
            await expectError(.incompatible) { _ = try await cloud.downloadConnectIQApp(app: app, deviceID: "101", allowQueueCreation: true) }
            XCTAssertFalse(ConnectIQHTTP.requests.contains { $0.httpMethod == "POST" || $0.url!.path.contains("devicemessage") })
        }
    }

    func testUntrustedQueueURLIsRejectedBeforeCredentialsCanBeSent() async throws {
        var options = ConnectIQHTTP.Options(); options.queued = true; options.packageURL = "https://example.org/steal"
        try await withFixture(options) { cloud in
            let app = try ConnectIQApp.parse(ConnectIQHTTP.appObject())
            await expectError(.downloadHostUnsupported) { _ = try await cloud.downloadConnectIQApp(app: app, deviceID: "101", allowQueueCreation: true) }
            XCTAssertFalse(ConnectIQHTTP.requests.contains { $0.url?.host == "example.org" || $0.httpMethod == "POST" })
        }
    }

    func testPackageTextErrorsOversizeAndRedirectResponsesCannotBecomeFiles() async throws {
        for failure in ["html", "json", "oversized", "redirect"] {
            var options = ConnectIQHTTP.Options(); options.queued = true
            if failure == "html" { options.packageBody = Data("<html>failure</html>".utf8) }
            if failure == "json" { options.packageBody = Data(#"{"error":"failure"}"#.utf8) }
            options.oversized = failure == "oversized"; options.redirect = failure == "redirect"
            try await withFixture(options) { cloud in
                let app = try ConnectIQApp.parse(ConnectIQHTTP.appObject())
                do { _ = try await cloud.downloadConnectIQApp(app: app, deviceID: "101", allowQueueCreation: false); XCTFail("Accepted \(failure)") }
                catch { /* Every failure must stop before a file is returned. */ }
                XCTAssertFalse(ConnectIQHTTP.requests.contains { $0.url?.host == "example.org" })
            }
        }
    }

    func testInflightHistoryIsInvalidatedByDeviceRegionOrLogout() async throws {
        for change in ["device", "region", "logout"] {
            var options = ConnectIQHTTP.Options(); options.stallHistory = true
            try await withFixture(options) { cloud in
                let pending = Task { () -> Bool in
                    do { _ = try await cloud.fetchConnectIQHistory(deviceID: "101"); return false }
                    catch { return true }
                }
                for _ in 0..<100 {
                    if ConnectIQHTTP.requests.contains(where: { $0.url!.path.hasSuffix("apps/downloads") }) { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                XCTAssertTrue(ConnectIQHTTP.requests.contains { $0.url!.path.hasSuffix("apps/downloads") })
                if change == "device" { cloud.deviceId = "202" }
                if change == "region" { cloud.switchRegion(.global) }
                if change == "logout" { cloud.logout() }
                ConnectIQHTTP.releaseHistory()
                let rejected = await pending.value
                XCTAssertTrue(rejected, change)
            }
        }
    }

    private func query(_ request: URLRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
    private func expectError(_ expected: ConnectIQError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? ConnectIQError, expected) }
    }
    private func withFixture(_ options: ConnectIQHTTP.Options = .init(), body: (GarminChinaCloud) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let domain = "wristbeam.connectiq-test.\(UUID().uuidString)"
        let auth = root.appendingPathComponent("session.json")
        let token = GarminOAuthToken(accessToken: "synthetic-ciq-access", refreshToken: "synthetic-ciq-refresh", clientID: "SYNTHETIC", expiresAt: Date().addingTimeInterval(3600), refreshExpiresAt: nil, scopes: [])
        try GarminPrivateFile.write(JSONEncoder().encode(token), to: auth)
        ConnectIQHTTP.reset(options)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ConnectIQHTTP.self]
        let session = URLSession(configuration: configuration)
        let cloud = GarminChinaCloud(storageURL: auth, session: session, automaticallyRestore: false, preferences: AppPreferences(domain: domain))
        defer {
            cloud.setNetworkEnabled(false); session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        await cloud.refreshAccount()
        XCTAssertTrue(cloud.isAuthenticated); XCTAssertEqual(cloud.deviceId, "101")
        try await body(cloud)
    }
}
