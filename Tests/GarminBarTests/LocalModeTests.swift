import Foundation
import XCTest
@testable import GarminBar

/// No request in these tests can reach Garmin: this protocol handles every URL.
private final class LocalModeHTTP: URLProtocol {
    private static let lock = NSLock()
    private static var seen: [String] = []
    private static var stall = false
    static func reset(stallRequests: Bool = false) { lock.lock(); defer { lock.unlock() }; seen = []; stall = stallRequests }
    static var requests: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.lock.lock(); Self.seen.append("\(request.httpMethod ?? "GET") \(path)"); let hold = Self.stall; Self.lock.unlock()
        if hold { return }
        let json: String
        let code: Int
        if request.httpMethod == "POST" {
            json = #"{"detailedImportResult":{"successes":[{"internalId":123}],"failures":[]}}"#; code = 201
        } else if path.contains("socialProfile") {
            json = #"{"garminGUID":"fixture-owner","displayName":"Fixture"}"#; code = 200
        } else if path.contains("deviceregistration") {
            json = #"[{"deviceId":12345,"displayName":"Fixture Watch"}]"#; code = 200
        } else {
            json = #"{"DataTypes":[{"DataTypeName":"FIT_TYPE_4","UploadLocations":[{"Url":"https://connectapi.garmin.cn/upload-service/upload/.fit"}]}]}"#; code = 200
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LocalModeTests: XCTestCase {
    private func fixture(_ root: URL) throws -> (URL, URLSession, AppPreferences, String) {
        let auth = root.appendingPathComponent("auth/session.json")
        let token = GarminOAuthToken(accessToken: "fixture-access", refreshToken: "fixture-refresh", clientID: "FIXTURE", expiresAt: Date().addingTimeInterval(3600), refreshExpiresAt: nil, scopes: [])
        try GarminPrivateFile.write(JSONEncoder().encode(token), to: auth)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LocalModeHTTP.self]
        let domain = "wristbeam.local-test.\(UUID().uuidString)"
        return (auth, URLSession(configuration: config), AppPreferences(domain: domain), domain)
    }
    @MainActor func testOfflineColdStartRetainsCredentialsAndNeverRequestsCloudEvenWhenForced() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (auth, session, preferences, domain) = try fixture(root)
        defer { session.invalidateAndCancel(); UserDefaults.standard.removePersistentDomain(forName: domain) }
        LocalModeHTTP.reset()
        let before = try Data(contentsOf: auth)
        let cloud = GarminChinaCloud(storageURL: auth, session: session, networkEnabled: false, preferences: preferences)
        let queue = GarminUploadQueue(cloud: cloud, directory: root.appendingPathComponent("UploadQueue")); queue.automaticSyncEnabled = false
        let fit = root.appendingPathComponent("activity.fit"); try CloudTests.fit(subtype: 4, serial: 12345).write(to: fit)
        try queue.enqueue(fileURL: fit, deviceID: "12345")
        await cloud.refreshAccount(); await cloud.refresh(); await queue.syncNow(force: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(LocalModeHTTP.requests.count, 0); XCTAssertEqual(cloud.requestCount, 0)
        XCTAssertFalse(cloud.isAuthenticated); XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.jobs.first?.accountGUID, "")
        XCTAssertEqual(try Data(contentsOf: auth), before)
        cloud.setNetworkEnabled(false)
    }
    @MainActor func testResumeDoesNotUploadUntilExplicitBatchAndChecksDeviceOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (auth, session, preferences, domain) = try fixture(root)
        defer { session.invalidateAndCancel(); UserDefaults.standard.removePersistentDomain(forName: domain) }
        LocalModeHTTP.reset()
        let cloud = GarminChinaCloud(storageURL: auth, session: session, networkEnabled: false, preferences: preferences)
        defer { cloud.setNetworkEnabled(false) }
        let queue = GarminUploadQueue(cloud: cloud, directory: root.appendingPathComponent("UploadQueue")); queue.automaticSyncEnabled = false
        for serial in [UInt32(12345), UInt32(99999)] {
            let fit = root.appendingPathComponent("\(serial).fit"); try CloudTests.fit(subtype: 4, serial: serial).write(to: fit)
            try queue.enqueue(fileURL: fit, deviceID: String(serial))
        }
        XCTAssertTrue(queue.jobs.allSatisfy { $0.awaitingAccount && $0.visible(in: .global) })
        cloud.setNetworkEnabled(true)
        for _ in 0..<200 { if !cloud.devices.isEmpty { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(cloud.isAuthenticated); XCTAssertEqual(cloud.devices.first?.id, "12345")
        XCTAssertFalse(LocalModeHTTP.requests.contains { $0.hasPrefix("POST") })
        XCTAssertEqual(queue.pendingCount, 2)
        await queue.syncNow(force: true)
        XCTAssertEqual(LocalModeHTTP.requests.filter { $0.hasPrefix("POST") }.count, 1)
        XCTAssertEqual(queue.jobs.first { $0.deviceID == "12345" }?.state, .accepted)
        XCTAssertEqual(queue.jobs.first { $0.deviceID == "12345" }?.accountGUID, "fixture-owner")
        XCTAssertEqual(queue.jobs.first { $0.deviceID == "99999" }?.state, .pending)
        cloud.setNetworkEnabled(false)
        let count = LocalModeHTTP.requests.count
        await queue.syncNow(force: true); await cloud.refreshAccount()
        XCTAssertEqual(LocalModeHTTP.requests.count, count)
    }
    @MainActor func testPauseCancelsAnInFlightAccountRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (auth, session, preferences, domain) = try fixture(root)
        defer { session.invalidateAndCancel(); UserDefaults.standard.removePersistentDomain(forName: domain) }
        LocalModeHTTP.reset(stallRequests: true)
        let cloud = GarminChinaCloud(storageURL: auth, session: session, automaticallyRestore: false, preferences: preferences)
        let task = Task { await cloud.refreshAccount() }
        for _ in 0..<200 { if !LocalModeHTTP.requests.isEmpty { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(LocalModeHTTP.requests.count, 1)
        cloud.setNetworkEnabled(false)
        await task.value
        XCTAssertFalse(cloud.isAuthenticated); XCTAssertEqual(cloud.accountGUID, "")
        XCTAssertEqual(LocalModeHTTP.requests.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: auth.path))
    }
    func testNewProfileIsLocalAndExplicitChoiceSurvivesLegacyMigration() {
        let domain = "wristbeam.preferences-test.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let preferences = AppPreferences(domain: domain)
        preferences.prepareSetupDefaults(); XCTAssertFalse(preferences.cloudSyncEnabled)
        preferences.set(true, forKey: "autoSync"); preferences.prepareSetupDefaults()
        XCTAssertFalse(preferences.cloudSyncEnabled)
        preferences.removeObject(forKey: "cloudSyncEnabled")
        preferences.set("12345", forKey: "garmin.cn.selectedDeviceID"); XCTAssertTrue(preferences.cloudSyncEnabled)
        preferences.set(false, forKey: "cloudSyncEnabled"); preferences.set(true, forKey: "autoSync")
        XCTAssertFalse(AppPreferences(domain: domain).cloudSyncEnabled)
    }
    func testExportDeduplicatesFITFiltersPrivateAndCloudFieldsAndPreservesOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = CloudTests.fit(subtype: 4, serial: 12345)
        let fit = root.appendingPathComponent("Received/china/activity.fit")
        try GarminPrivateFile.write(bytes, to: fit)
        try GarminPrivateFile.write(bytes, to: root.appendingPathComponent("UploadQueue/OriginalFIT/duplicate.fit"))
        let auth = root.appendingPathComponent("auth/session.json")
        try GarminPrivateFile.write(Data("PRIVATE_SESSION".utf8), to: auth)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Received/redirect.fit"), withDestinationURL: auth)
        let journal = #"{"kind":"heartRate","timestamp":"2026-10-15T01:00:00Z","value":70,"origin":"watch","source":"PRIVATE_DEVICE"}"# + "\n" + #"{"kind":"heartRate","timestamp":"2026-10-15T01:00:01Z","value":80,"origin":"cloud"}"# + "\n" + #"{"kind":"heartRate","timestamp":"2026-10-15T01:00:02Z","value":true,"origin":"watch"}"# + "\n{incomplete"
        try GarminPrivateFile.write(Data(journal.utf8), to: root.appendingPathComponent("Telemetry/2026-10-15.jsonl"))
        let summary = LocalDataArchive.summary(root: root)
        XCTAssertEqual(summary.fitFiles, 2); XCTAssertEqual(summary.telemetryDays, 1)
        let zip = root.appendingPathComponent("export.zip")
        try LocalDataArchive.export(root: root, to: zip)
        // Replacing an existing user-selected export must also be safe.
        try LocalDataArchive.export(root: root, to: zip)
        let extracted = root.appendingPathComponent("Unpacked")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); process.arguments = ["-x", "-k", zip.path, extracted.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let payload = extracted.appendingPathComponent("WristBeam-Local-Data")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: payload.path)), Set(["FIT", "manifest.json", "watch-readings.csv"]))
        let fits = try FileManager.default.contentsOfDirectory(at: payload.appendingPathComponent("FIT"), includingPropertiesForKeys: nil)
        XCTAssertEqual(fits.count, 1); XCTAssertEqual(try Data(contentsOf: XCTUnwrap(fits.first)), bytes)
        let csv = try String(contentsOf: payload.appendingPathComponent("watch-readings.csv"))
        XCTAssertEqual(csv, "timestamp,metric,value\n2026-10-15T01:00:00Z,heartRate,70.0\n")
        XCTAssertEqual(try Data(contentsOf: fit), bytes); XCTAssertEqual(try String(contentsOf: auth), "PRIVATE_SESSION")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Telemetry/2026-10-15.jsonl")), journal)
    }
}
