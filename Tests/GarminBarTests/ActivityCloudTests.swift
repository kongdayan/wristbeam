import Foundation
import XCTest
@testable import GarminBar

private final class ActivityHTTP: URLProtocol {
    private static let lock = NSLock()
    private static var seen: [String] = []
    private static var stall = false
    private static var oversized = false
    private static var failZones = false
    private static var activityIDs: [Int]?
    static func reset(stall: Bool = false, oversized: Bool = false, failZones: Bool = false, ids: [Int]? = nil) {
        lock.lock(); defer { lock.unlock() }
        seen = []; self.activityIDs = ids; self.stall = stall; self.oversized = oversized; self.failZones = failZones
    }
    static var requests: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, path = url.path
        Self.lock.lock(); Self.seen.append(path); let stall = Self.stall, oversized = Self.oversized, failZones = Self.failZones, activityIDs = Self.activityIDs; Self.lock.unlock()
        if stall && path.contains("activitylist-service") { return }
        let body: String
        if path.contains("socialProfile") { body = #"{"garminGUID":"activity-fixture","displayName":"Fixture"}"# }
        else if path.contains("deviceregistration") { body = #"[{"unitId":42,"displayName":"Synthetic watch"}]"# }
        else if path.contains("usersummary-service") {
            body = String(decoding: try! JSONSerialization.data(withJSONObject: ["calendarDate": GarminHealthMetrics.calendarDate(Date()), "totalSteps": 5000, "bodyBatteryMostRecentValue": 50]), as: UTF8.self)
        }
        else if path.contains("activitylist-service") {
            let offset = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "start" }?.value
            if let activityIDs {
                let rows = activityIDs.dropFirst(Int(offset ?? "0") ?? 0).prefix(2).map { id -> [String: Any] in
                    ["activityId": id, "activityName": "Synthetic", "startTimeGMT": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(id) * 60))]
                }
                body = String(decoding: try! JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
            } else if offset == "0" { body = #"[{"activityId":1002,"activityName":"Synthetic run","startTimeLocal":"2026-01-03 10:00:00"},{"activityId":1001,"activityName":"Synthetic walk","startTimeLocal":"2026-01-02 10:00:00"}]"# }
            else if offset == "2" { body = #"[{"activityId":1000,"activityName":"Synthetic swim","startTimeLocal":"2026-01-01 10:00:00"}]"# }
            else { body = "[]" }
        } else if path.hasSuffix("/details") {
            body = #"{"activityId":1001,"metricDescriptors":[{"key":"directHeartRate","metricsIndex":0,"unit":{"key":"bpm","factor":1}}],"activityDetailMetrics":[{"metrics":[100]}]}"#
        } else if path.hasSuffix("/hrTimeInZones") { body = #"[{"zoneNumber":1,"secsInZone":120,"zoneLowBoundary":90}]"# }
        else if path.hasSuffix("/splits") { body = #"{"activityId":1001,"lapDTOs":[{"lapIndex":1,"duration":600,"averageHR":100}]}"# }
        else if path.contains("activity-service") { body = #"{"activityId":1001,"activityName":"Synthetic walk","summaryDTO":{"duration":600}}"# }
        else if path.contains("/export/tcx/") { body = "<TrainingCenterDatabase/>" }
        else { body = "[]" }
        var headers = ["Content-Type": "application/json"]
        if oversized && path.contains("activitylist-service") { headers["Content-Length"] = String(GarminActivities.maximumJSONBytes + 1) }
        // Garmin's file endpoints reject JSON-only content negotiation (HTTP 406).
        let rejectsAccept = path.contains("download-service") && request.value(forHTTPHeaderField: "Accept") != "*/*"
        let statusCode = rejectsAccept ? 406 : failZones && path.hasSuffix("/hrTimeInZones") ? 503 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class ActivityCloudTests: XCTestCase {
    func testOpenAutomaticallyDownloadsOnceAndReusesCompleteCacheOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), domain = "wristbeam.activity-test.\(UUID().uuidString)"
        ActivityHTTP.reset()
        let (cloud, library, session) = try fixture(root, domain: domain)
        defer { cloud.setNetworkEnabled(false); session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: domain) }
        await cloud.refreshAccount(); await library.loadPage(older: false)
        let first = Task { await library.openDetail("1001") }
        let second = Task { await library.openDetail("1001") }
        await first.value; await second.value
        XCTAssertNotNil(library.detail("1001")?.laps)
        XCTAssertEqual(ActivityHTTP.requests.filter { $0 == "/activity-service/activity/1001" }.count, 1)
        let requests = ActivityHTTP.requests.count
        await library.openDetail("1001")
        XCTAssertEqual(ActivityHTTP.requests.count, requests)
        cloud.setNetworkEnabled(false); library.reconcile()
        await library.openDetail("1002")
        XCTAssertEqual(ActivityHTTP.requests.count, requests)
        XCTAssertNil(library.detail("1002"))
        let json = try JSONSerialization.jsonObject(with: library.exportJSON("1001")) as! [String: Any]
        XCTAssertNotNil(json["series"])
    }
    func testLeavingDetailCancelsQueuedDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), domain = "wristbeam.activity-test.\(UUID().uuidString)"
        ActivityHTTP.reset()
        let (cloud, library, session) = try fixture(root, domain: domain)
        defer { cloud.setNetworkEnabled(false); session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: domain) }
        await cloud.refreshAccount(); await library.loadPage(older: false)
        ActivityHTTP.reset(stall: true)
        let refresh = Task { await library.loadPage(older: false) }
        for _ in 0..<100 {
            if library.busy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(library.busy)
        let opening = Task { await library.openDetail("1001") }
        await Task.yield(); opening.cancel(); await opening.value
        XCTAssertFalse(ActivityHTTP.requests.contains { $0.contains("activity-service") })
        cloud.setNetworkEnabled(false); await refresh.value
        XCTAssertNil(library.detail("1001"))
    }
    func testFailedOptionalSectionKeepsOtherDetailSections() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), domain = "wristbeam.activity-test.\(UUID().uuidString)"
        ActivityHTTP.reset(failZones: true)
        let (cloud, library, session) = try fixture(root, domain: domain)
        defer { cloud.setNetworkEnabled(false); session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: domain) }
        await cloud.refreshAccount(); await library.loadPage(older: false); await library.downloadDetail("1001")
        XCTAssertEqual(library.detail("1001")?.summary.statistics["duration"], 600)
        XCTAssertNil(library.detail("1001")?.heartRateZones)
        XCTAssertEqual(library.detail("1001")?.unavailableSections, ["hrTimeInZones"])
        XCTAssertEqual(library.detail("1001")?.laps?.count, 1)
    }
    func testHistoryBoundarySurvivesHeadInsertionAndDeletedAnchor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), domain = "wristbeam.activity-test.\(UUID().uuidString)"
        ActivityHTTP.reset(ids: [1004, 1003, 1002, 1001])
        let (cloud, library, session) = try fixture(root, domain: domain)
        defer { cloud.setNetworkEnabled(false); session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: domain) }
        await cloud.refreshAccount(); await library.loadPage(older: false); await library.loadPage(older: true)
        XCTAssertEqual(library.index.historyAnchorID, "1002")
        ActivityHTTP.reset(ids: [1005, 1004, 1003, 1001])
        await library.loadPage(older: false)
        XCTAssertEqual(library.index.nextOffset, 4)
        await library.loadPage(older: true)
        XCTAssertTrue(library.index.activities.contains { $0.id == "1001" })
        XCTAssertEqual(library.index.historyAnchorID, "1001")
        await library.loadPage(older: true)
        XCTAssertTrue(library.index.reachedEnd)
        await library.loadPage(older: false)
        XCTAssertTrue(library.index.reachedEnd)
    }
    func testCancelOwnedPageRequestPreservesIndexAndPermitsRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), domain = "wristbeam.activity-test.\(UUID().uuidString)"
        ActivityHTTP.reset()
        let (cloud, library, session) = try fixture(root, domain: domain)
        defer { cloud.setNetworkEnabled(false); session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: domain) }
        await cloud.refreshAccount(); await library.loadPage(older: false)
        let saved = library.index
        ActivityHTTP.reset(stall: true)
        library.requestPage(older: false)
        for _ in 0..<100 {
            if library.busy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(library.busy)
        XCTAssertFalse(library.operation.isEmpty)
        library.cancelRequest()
        XCTAssertFalse(library.busy)
        XCTAssertTrue(library.operation.isEmpty)
        XCTAssertEqual(library.index.activities, saved.activities)
        ActivityHTTP.reset()
        await library.loadPage(older: false)
        XCTAssertFalse(library.busy)
        XCTAssertFalse(library.statusIsError)
        XCTAssertEqual(library.index.activities.map(\.id), saved.activities.map(\.id))
    }
    func testHealthRefreshPreservesUnknownMeasurementTimeThroughRegionPresentation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), domain = "wristbeam.activity-test.\(UUID().uuidString)"
        ActivityHTTP.reset()
        let (cloud, _, session) = try fixture(root, domain: domain)
        defer { cloud.setNetworkEnabled(false); session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: domain) }
        await cloud.refreshAccount()
        let result = await cloud.healthMetrics(deviceID: "42")
        let sample = try XCTUnwrap(result.samples.first { $0.kind == .steps })
        XCTAssertEqual(sample.value, 5000)
        XCTAssertEqual(sample.origin, .cloud)
        XCTAssertEqual(sample.timestampIsMeasurement, false)
    }
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
        XCTAssertEqual(library.detail("1001")?.heartRateZones?.count, 1)
        XCTAssertEqual(library.detail("1001")?.laps?.first?.statistics["duration"], 600)
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
