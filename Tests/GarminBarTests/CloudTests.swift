import XCTest
@testable import GarminBar

final class CloudTests: XCTestCase {
    func testChinaURLsAndTicketScope() throws {
        let login = GarminChinaURLPolicy.loginURL(mode: .mobile, clientID: "GCM_ANDROID_LIGHT")
        XCTAssertEqual(login.host, "sso.garmin.cn")
        let items = URLComponents(url: login, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "service" }?.value, GarminChinaURLPolicy.mobileService.absoluteString)
        let callback = URL(string: "https://mobile.integration.garmin.cn/gcm/android?ticket=ST-test%2Bticket")!
        XCTAssertEqual(GarminChinaURLPolicy.serviceTicket(from: callback, expectedService: GarminChinaURLPolicy.mobileService), "ST-test+ticket")
        for value in ["https://mobile.integration.garmin.com/gcm/android?ticket=ST-test",
                      "https://mobile.integration.garmin.cn.attacker.example/gcm/android?ticket=ST-test",
                      "https://mobile.integration.garmin.cn/gcm/android/extra?ticket=ST-test",
                      "https://mobile.integration.garmin.cn/gcm/android?ticket=ST-one&ticket=ST-two",
                      "http://mobile.integration.garmin.cn/gcm/android?ticket=ST-test"] {
            XCTAssertNil(GarminChinaURLPolicy.serviceTicket(from: URL(string: value)!, expectedService: GarminChinaURLPolicy.mobileService))
        }
        XCTAssertFalse(GarminChinaURLPolicy.isTrusted(URL(string: "https://garmin.cn@attacker.example/upload")!))
        XCTAssertFalse(GarminChinaURLPolicy.isTrusted(URL(string: "https://user:secret@connectapi.garmin.cn/upload")!))
        XCTAssertEqual(try GarminChinaURLPolicy.uploadConfigurationURL(deviceID: "1234567").absoluteString,
                       "https://omt.garmin.cn/UploadConfigurationService/UnitUploadSettings/1234567?clientId=ConnectMobile")
    }

    func testOfficialThickClientBridgeHasTheSameServiceScope() {
        let event: [String: Any] = ["eventType": "USER_AUTHENTICATED", "data": ["serviceTicket": "ST-test-bridge", "serviceUrl": GarminChinaURLPolicy.mobileService.absoluteString]]
        let callback = GarminChinaURLPolicy.callbackURL(fromSSOEvent: event, expectedService: GarminChinaURLPolicy.mobileService)
        XCTAssertEqual(callback.flatMap { GarminChinaURLPolicy.serviceTicket(from: $0, expectedService: GarminChinaURLPolicy.mobileService) }, "ST-test-bridge")
        XCTAssertNil(GarminChinaURLPolicy.callbackURL(fromSSOEvent: event, expectedService: GarminChinaURLPolicy.portalService))
        XCTAssertNil(GarminChinaURLPolicy.callbackURL(fromSSOEvent: ["eventType": "USER_AUTHENTICATED", "data": ["serviceTicket": "ST-test", "serviceUrl": "https://attacker.example/upload"]], expectedService: GarminChinaURLPolicy.mobileService))
        XCTAssertNil(GarminChinaURLPolicy.callbackURL(fromSSOEvent: ["eventType": "COMMUNICATION", "data": event["data"]!], expectedService: GarminChinaURLPolicy.mobileService))
    }

    func testTokenExpiryRotationAndMFA() throws {
        let now = Date(timeIntervalSince1970: 100)
        let body = Data(#"{"access_token":"test-access","refresh_token":"test-refresh","token_type":"Bearer","expires_in":3600,"refresh_token_expires_in":86400,"scope":"DI_CONNECT_READ DI_CONNECT_WRITE"}"#.utf8)
        let token = try GarminOAuthToken.parse(body, clientID: "TEST_CLIENT", now: now)
        XCTAssertEqual(token.expiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(token.refreshExpiresAt, now.addingTimeInterval(86400))
        XCTAssertEqual(token.scopes, ["DI_CONNECT_READ", "DI_CONNECT_WRITE"])
        let renewed = try GarminOAuthToken.parse(Data(#"{"access_token":"test-renewed","refresh_token":"test-rotated","expires_in":"7200"}"#.utf8), clientID: "TEST_CLIENT", now: now, previous: token)
        XCTAssertEqual(renewed.refreshToken, "test-rotated")
        XCTAssertEqual(renewed.refreshExpiresAt, token.refreshExpiresAt)
        XCTAssertThrowsError(try GarminOAuthToken.parse(Data(#"{"mfa_token":"test-mfa","mfa_required":true}"#.utf8), clientID: "TEST_CLIENT"))
        XCTAssertThrowsError(try GarminOAuthToken.parse(Data(#"{"access_token":"test","refresh_token":"test","expires_in":true}"#.utf8), clientID: "TEST_CLIENT"))
        XCTAssertThrowsError(try GarminOAuthToken.parse(Data(#"{"access_token":"test","refresh_token":"test","expires_in":-1}"#.utf8), clientID: "TEST_CLIENT"))
        // The APK also returns an MFA session marker with a completed DI token; this is not itself an MFA challenge.
        XCTAssertNoThrow(try GarminOAuthToken.parse(Data(#"{"access_token":"test","refresh_token":"test","expires_in":3600,"mfa_token":"test-session-marker"}"#.utf8), clientID: "TEST_CLIENT"))
    }

    func testDistinctFITTypeRoutesAndHostChecks() throws {
        let data = Data(#"{"DataTypes":[{"DataTypeName":"FIT_TYPE_4","UploadLocations":[{"Url":"https://connectapi.garmin.cn/upload-service/upload/.fit"}]},{"DataTypeName":"FIT_TYPE_32","UploadLocations":[{"Url":"https://connectapi.garmin.cn/wellness/upload"}]},{"DataTypeName":"FIT_TYPE_49","UploadLocations":[{"Url":"https://connectapi.garmin.cn/sleep/upload"}]}]}"#.utf8)
        let config = try GarminUploadConfiguration.parse(data)
        XCTAssertEqual(try config.endpoint(for: .activity).path, "/upload-service/upload/.fit")
        XCTAssertEqual(try config.endpoint(for: .monitoring).path, "/wellness/upload")
        XCTAssertEqual(try config.endpoint(for: .sleep).path, "/sleep/upload")
        XCTAssertThrowsError(try config.endpoint(for: .biometric))
        XCTAssertThrowsError(try GarminUploadConfiguration.parse(Data(#"{"DataTypes":[{"DataTypeName":"FIT_TYPE_4","UploadLocations":[{"Url":"https://connectapi.garmin.com/upload"}]}]}"#.utf8)))
    }

    func testAcceptedDuplicateAndProcessingAreDifferent() {
        let location = URL(string: "https://connectapi.garmin.cn/upload/status/123")!
        let pending = GarminUploadResponse.classify(code: 202, data: Data(), location: location, fileName: "file.fit")
        XCTAssertEqual(pending.state, .processing)
        XCTAssertFalse(pending.state.isComplete)
        XCTAssertEqual(pending.processingURL, location)
        XCTAssertEqual(GarminUploadResponse.classify(code: 409, data: Data(), location: nil, fileName: "file.fit").state, .duplicate)
        let rejected = Data(#"{"detailedImportResult":{"successes":[],"failures":[{"messages":[{"code":408,"content":"timeout"}]}]}}"#.utf8)
        XCTAssertEqual(GarminUploadResponse.classify(code: 201, data: rejected, location: nil, fileName: "file.fit").state, .failed)
        let duplicate = Data(#"{"detailedImportResult":{"failures":[{"messages":[{"code":409}]}]}}"#.utf8)
        XCTAssertEqual(GarminUploadResponse.classify(code: 201, data: duplicate, location: nil, fileName: "file.fit").state, .duplicate)
        let accepted = Data(#"{"detailedImportResult":{"successes":[{"internalId":123}],"failures":[]}}"#.utf8)
        XCTAssertEqual(GarminUploadResponse.classify(code: 201, data: accepted, location: nil, fileName: "file.fit").activityID, "123")
    }

    func testFITClassifierUsesBinaryTypeAndCRC() throws {
        for big in [false, true] {
            let bytes = Self.fit(subtype: 32, serial: 12345, bigEndian: big)
            let metadata = try GarminFITFileClassifier.inspect(bytes)
            XCTAssertEqual(metadata.dataType, .monitoring)
            XCTAssertEqual(metadata.serialNumber, 12345)
        }
        var corrupted = Self.fit(subtype: 49, serial: 12345)
        corrupted[corrupted.count - 3] ^= 0x01
        XCTAssertThrowsError(try GarminFITFileClassifier.inspect(corrupted))
        XCTAssertThrowsError(try GarminFITFileClassifier.inspect(Self.fit(subtype: 4, serial: 12345).dropLast()))
    }

    @MainActor
    func testQueuePersistsOriginalAndRejectsWrongDeviceOrType() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GarminCloudTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("activity-looking-name.fit")
        let bytes = Self.fit(subtype: 32, serial: 12345)
        try bytes.write(to: source)
        let cloud = GarminChinaCloud(storageURL: root.appendingPathComponent("no-session.json"), automaticallyRestore: false)
        let queueRoot = root.appendingPathComponent("Queue")
        let queue = GarminUploadQueue(cloud: cloud, directory: queueRoot)
        let job = try queue.enqueue(fileURL: source, deviceID: "12345")
        XCTAssertEqual(job.dataType, .monitoring)
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(try queue.enqueue(fileURL: source, deviceID: "12345").id, job.id)
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertThrowsError(try queue.enqueue(fileURL: source, deviceID: "12345", dataType: .activity))
        XCTAssertThrowsError(try queue.enqueue(fileURL: source, deviceID: "55555"))
        let stored = queueRoot.appendingPathComponent("OriginalFIT/\(job.fileName)")
        XCTAssertEqual(try Data(contentsOf: stored), bytes)
        let permissions = try FileManager.default.attributesOfItem(atPath: stored.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let restored = GarminUploadQueue(cloud: cloud, directory: queueRoot)
        XCTAssertEqual(restored.jobs.first?.id, job.id)
        XCTAssertEqual(restored.pendingCount, 1)
    }

    static func fit(subtype: UInt8, serial: UInt32, bigEndian: Bool = false) -> Data {
        let serialBytes: [UInt8] = (0..<4).map { UInt8(truncatingIfNeeded: serial >> ($0 * 8)) }
        var records: [UInt8] = [0x40, 0, bigEndian ? 1 : 0, 0, 0, 2, 0, 1, 0, 3, 4, 0x8c,
                               0, subtype]
        records += bigEndian ? Array(serialBytes.reversed()) : serialBytes
        let size = UInt32(records.count)
        var bytes: [UInt8] = [14, 0x20, 0, 0] + (0..<4).map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) } + [0x2e, 0x46, 0x49, 0x54]
        let headerCRC = GarminFITFileClassifier.crc16(bytes)
        bytes += [UInt8(truncatingIfNeeded: headerCRC), UInt8(truncatingIfNeeded: headerCRC >> 8)]
        bytes += records
        let crc = GarminFITFileClassifier.crc16(bytes)
        bytes += [UInt8(truncatingIfNeeded: crc), UInt8(truncatingIfNeeded: crc >> 8)]
        return Data(bytes)
    }
}
