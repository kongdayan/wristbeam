import Foundation
import XCTest
@testable import GarminBar

final class RequestCaptureTests: XCTestCase {
    func testWeatherRequestOnlyRetainsFormatAndForecastHours() throws {
        var log = GFDIRequestLog()
        let payload = Data([1, 0x78, 0x56, 0x34, 0x12, 0x21, 0x43, 0x65, 0x07, 24])
        log.append(GFDIMessage(number: 5014, payload: payload), direction: .watchToMac)
        XCTAssertEqual(log.events.first?.weatherFormat, 1)
        XCTAssertEqual(log.events.first?.forecastHours, 24)
        XCTAssertEqual(log.events.first?.weatherPayloadValid, true)
        let encoded = String(decoding: try log.encoded(), as: UTF8.self)
        XCTAssertFalse(encoded.contains(payload.base64EncodedString()))
        XCTAssertFalse(encoded.contains("305419896"))
        XCTAssertFalse(encoded.contains("latitude"))
        XCTAssertFalse(encoded.contains("longitude"))
    }

    func testUnknownAndAuthenticationPayloadsNeverReachDisk() throws {
        var log = GFDIRequestLog()
        let secret = Data("private-account-location-health-and-token".utf8)
        for number in [UInt16(5199), 5101, 5043, 5035, 5015] {
            log.append(GFDIMessage(number: number, payload: secret), direction: .watchToMac)
        }
        let encoded = String(decoding: try log.encoded(), as: UTF8.self)
        XCTAssertEqual(log.events.count, 5)
        XCTAssertFalse(encoded.contains(String(decoding: secret, as: UTF8.self)))
        XCTAssertFalse(encoded.contains(secret.base64EncodedString()))
        XCTAssertTrue(log.events.allSatisfy { $0.weatherFormat == nil && $0.forecastHours == nil })
    }

    func testMalformedWeatherDoesNotGuessFields() {
        var log = GFDIRequestLog()
        for size in [0, 1, 9, 11, 100] {
            log.append(GFDIMessage(number: 5014, payload: Data(repeating: 42, count: size)), direction: .watchToMac)
        }
        XCTAssertTrue(log.events.allSatisfy { $0.weatherPayloadValid == false && $0.forecastHours == nil })
    }

    func testBulkFileTrafficCannotEvictWeatherAndLogIsBounded() {
        var log = GFDIRequestLog()
        log.append(GFDIMessage(number: 5014), direction: .watchToMac)
        for _ in 0..<1000 { log.append(GFDIMessage(number: 5004, payload: Data(repeating: 123, count: 100)), direction: .watchToMac) }
        XCTAssertEqual(log.events.count, 1)
        XCTAssertEqual(log.omittedRoutineMessages, 1000)
        for _ in 0..<400 { log.append(GFDIMessage(number: 5199), direction: .watchToMac) }
        XCTAssertEqual(log.events.count, GFDIRequestLog.limit)
        XCTAssertEqual(log.totalEvents, 401)
        XCTAssertEqual(log.events.first?.id, 102)
    }

    @MainActor func testCapturePassiveAcrossFragmentedProtocolAndUnsupportedReply() async throws {
        let session = GFDISession(storageDirectory: FileManager.default.temporaryDirectory)
        session.transportMode = .legacy
        var transcript = GFDIRequestLog()
        var outbound = Data()
        session.onDiagnosticMessage = { transcript.append($0, direction: $1) }
        session.onSend = { outbound.append($0) }
        session.connected()
        defer { session.disconnected() }
        let request = GFDIMessage(number: 5014, payload: Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 12]))
        for byte in try request.framed() { session.receive(Data([byte])) }
        XCTAssertEqual(transcript.events.count, 2)
        XCTAssertEqual(transcript.events[0].direction, .watchToMac)
        XCTAssertEqual(transcript.events[1].direction, .macQueued)
        XCTAssertEqual(transcript.events[1].replyTo, 5014)
        XCTAssertEqual(transcript.events[1].status, 2)
        var decoder = GFDIStreamDecoder()
        XCTAssertEqual(try decoder.receive(outbound).map { try $0.get() }, [request.response(status: 2)])
        // An invalid CRC is rejected before the diagnostic callback.
        var packet = try request.packet(); packet[4] ^= 1
        session.receive(Data([0]) + GFDICOBS.encode(packet) + Data([0]))
        XCTAssertEqual(transcript.events.count, 2)
    }

    @MainActor func testRecorderOptInTimeoutRestartAndPrivateFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture.json")
        let capture = WatchRequestCapture(url: url)
        let request = GFDIMessage(number: 5014, payload: Data(repeating: 0, count: 10))
        capture.record(request, direction: .watchToMac)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let start = Date()
        capture.start(at: start)
        capture.record(request, direction: .watchToMac, at: start.addingTimeInterval(10))
        XCTAssertTrue(capture.persist())
        XCTAssertEqual(capture.log.totalEvents, 1)
        let restored = WatchRequestCapture(url: url)
        XCTAssertFalse(restored.isCapturing)
        XCTAssertEqual(restored.log.totalEvents, 1)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(capture.expireIfNeeded(at: start.addingTimeInterval(600)))
        capture.record(request, direction: .watchToMac, at: start.addingTimeInterval(601))
        XCTAssertEqual(capture.log.totalEvents, 1)
        XCTAssertFalse(capture.isCapturing)
        capture.clear()
        XCTAssertEqual(capture.log.totalEvents, 0)
        XCTAssertEqual(WatchRequestCapture(url: url).log.events.count, 0)
    }
}
