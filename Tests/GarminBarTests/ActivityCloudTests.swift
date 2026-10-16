import Foundation
import XCTest
@testable import GarminBar

private final class ActivityHTTP: URLProtocol {
    private static let lock = NSLock()
    private static var seen: [String] = []
    private static var stall = false
    private static var oversized = false
    static func reset(stall: Bool = false, oversized: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        seen = []; self.stall = stall; self.oversized = oversized
    }
    static var requests: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, path = url.path
        Self.lock.lock(); Self.seen.append(path); let stall = Self.stall, oversized = Self.oversized; Self.lock.unlock()
        if stall && path.contains("activitylist-service") { return }
        let body: String
        if path.contains("socialProfile") { body = #"{"garminGUID":"activity-fixture","displayName":"Fixture"}"# }
        else if path.contains("deviceregistration") { body = "[]" }
        else if path.contains("activitylist-service") {
            let offset = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "start" }?.value
            if offset == "0" { body = #"[{"activityId":1002,"activityName":"Synthetic run","startTimeLocal":"2026-01-03 10:00:00"},{"activityId":1001,"activityName":"Synthetic walk","startTimeLocal":"2026-01-02 10:00:00"}]"# }
            else if offset == "2" { body = #"[{"activityId":1000,"activityName":"Synthetic swim","startTimeLocal":"2026-01-01 10:00:00"}]"# }
            else { body = "[]" }
        } else if path.hasSuffix("/details") {
            body = #"{"activityId":1001,"metricDescriptors":[{"key":"directHeartRate","metricsIndex":0,"unit":{"key":"bpm","factor":1}}],"activityDetailMetrics":[{"metrics":[100]}]}"#
        } else if path.contains("activity-service") { body = #"{"activityId":1001,"activityName":"Synthetic walk","summaryDTO":{"duration":600}}"# }
        else if path.contains("/export/tcx/") { body = "<TrainingCenterDatabase/>" }
        else { body = "[]" }
        var headers = ["Content-Type": "application/json"]
        if oversized && path.contains("activitylist-service") { headers["Content-Length"] = String(GarminActivities.maximumJSONBytes + 1) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class ActivityCloudTests: XCTestCase {
    private func fixture(_ root: URL, domain: String) throws -> (GarminChinaCloud, ActivityLibrary, URLSession) {
        let auth = root.appendingPathComponent("session.json"), preferences = AppPreferences(domain: domain)
        let token = GarminOAuthToken(accessToken: "fixture-access", refreshToken: "fixture-refresh", clientID: "FIXTURE", expiresAt: Date().addingTimeInterval(3600), refreshExpiresAt: nil, scopes: [])
        try GarminPrivateFile.write(JSONEncoder().encode(token), to: auth)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ActivityHTTP.self]
        let session = URLSession(configuration: config)
        let cloud = GarminChinaCloud(storageURL: auth, session: session, automaticallyRestore: false, preferences: preferences)
        let library = ActivityLibrary(root: root.appendingPathComponent("cache"), preferences: preferences)
        library.attach(cloud)
        return (cloud, library, session)
    }
    func testBrowseDoesNotDownloadAndOfflineMCPKeepsAccountCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), domain = "wristbeam.activity-test.\(UUID().uuidString)"
        ActivityHTTP.reset()
        let (cloud, library, session) = try fixture(root, domain: domain)
        defer { cloud.setNetworkEnabled(false); session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: domain) }
        await cloud.refreshAccount()
        await library.loadPage(older: false)
        XCTAssertEqual(library.index.activities.count, 2); XCTAssertFalse(library.index.reachedEnd)
        XCTAssertFalse(ActivityHTTP.requests.contains { $0.contains("activity-service") || $0.contains("download-service") })
        await library.loadPage(older: true); XCTAssertEqual(library.index.activities.count, 3)
        await library.loadPage(older: true); XCTAssertTrue(library.index.reachedEnd)
        await library.loadPage(older: false); XCTAssertEqual(library.index.activities.count, 3)
        await library.downloadDetail("1001"); XCTAssertNotNil(library.detail("1001"))
        let file = await library.exportFile("1001", format: .tcx); XCTAssertNotNil(file)
        cloud.setNetworkEnabled(false); library.reconcile()
        let requests = ActivityHTTP.requests.count
        await library.loadPage(older: false); await library.downloadDetail("1002")
        let offline = await library.exportFile("1001", format: .tcx)
        XCTAssertEqual(offline, file); XCTAssertEqual(ActivityHTTP.requests.count, requests)
        XCTAssertEqual(library.index.activities.count, 3)
        let cached = try ActivityQueries.query("activity", arguments: ["id": "1001"], index: library.index, detail: { library.detail($0) }, formats: { library.formats($0) })
        XCTAssertEqual(cached["detailCached"] as? Bool, true)
        cloud.switchRegion(.global); library.reconcile(); XCTAssertTrue(library.index.activities.isEmpty)
        cloud.switchRegion(.china); library.reconcile(); XCTAssertEqual(library.index.activities.count, 3)
        cloud.logout(); library.reconcile(); XCTAssertTrue(library.index.activities.isEmpty)
    }
    func testAutomaticRefreshIsOptInAndNeverDownloadsDetails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), domain = "wristbeam.activity-test.\(UUID().uuidString)"
        ActivityHTTP.reset()
        let (cloud, library, session) = try fixture(root, domain: domain)
        defer { cloud.setNetworkEnabled(false); session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: domain) }
        await cloud.refreshAccount()
        let count = ActivityHTTP.requests.count
        library.tick(now: Date().addingTimeInterval(86401))
        XCTAssertEqual(ActivityHTTP.requests.count, count)
        library.refreshMinutes = 30; library.tick(now: Date().addingTimeInterval(1801))
        for _ in 0..<100 {
            if library.index.activities.count == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(library.index.activities.count, 2)
        XCTAssertFalse(ActivityHTTP.requests.contains { $0.contains("activity-service") || $0.contains("download-service") })
    }
    func testPauseCancelsPendingPageWithoutWritingCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), domain = "wristbeam.activity-test.\(UUID().uuidString)"
        ActivityHTTP.reset(stall: true)
        let (cloud, library, session) = try fixture(root, domain: domain)
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: domain) }
        await cloud.refreshAccount()
        let pending = Task { await library.loadPage(older: false) }
        for _ in 0..<100 {
            if ActivityHTTP.requests.contains(where: { $0.contains("activitylist-service") }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(ActivityHTTP.requests.contains { $0.contains("activitylist-service") })
        cloud.setNetworkEnabled(false); await pending.value
        XCTAssertTrue(library.index.activities.isEmpty); XCTAssertFalse(library.busy)
        XCTAssertTrue(library.store?.loadIndex().activities.isEmpty == true)
    }
    func testOversizeResponseCannotReplaceCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), domain = "wristbeam.activity-test.\(UUID().uuidString)"
        ActivityHTTP.reset(oversized: true)
        let (cloud, library, session) = try fixture(root, domain: domain)
        defer { cloud.setNetworkEnabled(false); session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: domain) }
        await cloud.refreshAccount(); await library.loadPage(older: false)
        XCTAssertTrue(library.index.activities.isEmpty); XCTAssertFalse(library.status.isEmpty)
    }
}
