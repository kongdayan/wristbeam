import XCTest
@testable import GarminBar

final class RegionTests: XCTestCase {
    func testGlobalLoginTicketAndRoutesNeverTrustChinaHosts() throws {
        let login = GarminChinaURLPolicy.loginURL(mode: .mobile, clientID: "GCM_ANDROID_LIGHT", region: .global)
        XCTAssertEqual(login.host, "sso.garmin.com")
        let service = GarminChinaURLPolicy.serviceURL(mode: .mobile, region: .global)
        let callback = URL(string: service.absoluteString + "?ticket=ST-test-global")!
        XCTAssertEqual(GarminChinaURLPolicy.serviceTicket(from: callback, expectedService: service), "ST-test-global")
        XCTAssertNil(GarminChinaURLPolicy.serviceTicket(from: callback, expectedService: GarminChinaURLPolicy.mobileService))
        XCTAssertNil(GarminChinaURLPolicy.serviceTicket(from: URL(string: GarminChinaURLPolicy.mobileService.absoluteString + "?ticket=ST-test-cn")!, expectedService: service))
        XCTAssertFalse(GarminChinaURLPolicy.isTrusted(URL(string: "https://connectapi.garmin.cn/upload")!, region: .global))
        XCTAssertFalse(GarminChinaURLPolicy.isTrusted(URL(string: "https://connectapi.garmin.com.evil.example/upload")!, region: .global))
        XCTAssertEqual(try GarminChinaURLPolicy.uploadConfigurationURL(deviceID: "12345", region: .global).host, "omt.garmin.com")
        for endpoint in GarminSeriesEndpoint.allCases { XCTAssertEqual(endpoint.url(day: Date(), profile: "test", region: .global).host, "connectapi.garmin.com") }
        let config = Data(#"{"DataTypes":[{"DataTypeName":"FIT_TYPE_4","UploadLocations":[{"Url":"https://connectapi.garmin.com/upload"}]}]}"#.utf8)
        XCTAssertEqual(try GarminUploadConfiguration.parse(config, region: .global).endpoint(for: .activity).host, "connectapi.garmin.com")
        XCTAssertThrowsError(try GarminUploadConfiguration.parse(config, region: .china))
    }
    @MainActor func testSwitchPreservesChinaSessionAndIsolatesQueueWithIdenticalFIT() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RegionTests-\(UUID().uuidString)")
        let domain = "RegionTests.\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: domain) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = GarminOAuthToken(accessToken: "test-only-access", refreshToken: "test-only-refresh", clientID: "TEST", expiresAt: Date().addingTimeInterval(3600), refreshExpiresAt: nil, scopes: [])
        let sessionURL = root.appendingPathComponent("china-session.json")
        let saved = try JSONEncoder().encode(session)
        try GarminPrivateFile.write(saved, to: sessionURL)
        let preferences = AppPreferences(domain: domain)
        preferences.set("12345", forKey: "garmin.cn.selectedDeviceID")
        preferences.set("54321", forKey: "garmin.com.selectedDeviceID")
        let cloud = GarminChinaCloud(storageURL: sessionURL, automaticallyRestore: false, preferences: preferences)
        let queue = GarminUploadQueue(cloud: cloud, directory: root.appendingPathComponent("Queue"))
        let file = root.appendingPathComponent("record.fit")
        try CloudTests.fit(subtype: 32, serial: 12345).write(to: file)
        let china = try queue.enqueue(fileURL: file, deviceID: "12345")
        cloud.switchRegion(.global)
        XCTAssertEqual(cloud.deviceId, "54321")
        XCTAssertFalse(cloud.isAuthenticated)
        XCTAssertEqual(queue.visibleJobs.count, 0)
        let global = try queue.enqueue(fileURL: file, deviceID: "12345")
        XCTAssertFalse(china.id == global.id)
        XCTAssertEqual(global.effectiveRegion, .global)
        XCTAssertFalse(china.belongs(to: .global, accountGUID: china.accountGUID))
        XCTAssertEqual(try Data(contentsOf: sessionURL), saved)
        cloud.switchRegion(.china)
        XCTAssertEqual(cloud.deviceId, "12345")
        XCTAssertEqual(queue.visibleJobs.map(\.id), [china.id])
        XCTAssertEqual(try queue.enqueue(fileURL: file, deviceID: "12345").id, china.id)
        XCTAssertEqual(try Data(contentsOf: sessionURL), saved)
    }
    func testLegacyQueueJobDefaultsToChinaAndKeepsAccountOwnership() throws {
        let job = GarminUploadJob(id: "legacy", fileName: "legacy.fit", originalName: "original.fit", deviceID: "12345", dataType: .monitoring, accountGUID: "owner", createdAt: Date(), updatedAt: Date(), state: .accepted, detail: "accepted", attempts: 1, nextAttempt: nil, cloudStatus: nil)
        let legacy = try JSONEncoder().encode(job)
        let restored = try JSONDecoder().decode(GarminUploadJob.self, from: legacy)
        XCTAssertEqual(restored.effectiveRegion, .china)
        XCTAssertTrue(restored.belongs(to: .china, accountGUID: "owner"))
        XCTAssertFalse(restored.belongs(to: .china, accountGUID: "other-owner"))
        XCTAssertFalse(restored.belongs(to: .global, accountGUID: "owner"))
    }
    func testLegacyReceivedChinaFilesAreNotReplayedIntoGlobalRegion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RegionArchive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = CloudTests.fit(subtype: 32, serial: 12345)
        let entry = GFDIDirectoryEntry(index: 9, dataType: 128, identifier: [32, 0, 0], flags: 0x80, size: bytes.count, timestamp: 10)
        _ = try GFDIFileArchive.persist(bytes, entry: entry, deviceID: 12345, root: GarminRegion.china.receiveDirectory(root: root))
        XCTAssertEqual(try GFDIFileArchive.pendingFiles(root: GarminRegion.china.receiveDirectory(root: root)).count, 1)
        XCTAssertEqual(try GFDIFileArchive.pendingFiles(root: GarminRegion.global.receiveDirectory(root: root)).count, 0)
        _ = try GFDIFileArchive.persist(bytes, entry: entry, deviceID: 12345, root: GarminRegion.global.receiveDirectory(root: root))
        XCTAssertEqual(try GFDIFileArchive.pendingFiles(root: GarminRegion.global.receiveDirectory(root: root)).count, 1)
        XCTAssertEqual(try GFDIFileArchive.pendingFiles(root: GarminRegion.china.receiveDirectory(root: root)).count, 1)
    }
}
