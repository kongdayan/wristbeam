import Foundation
import XCTest
@testable import GarminBar

final class BatteryProtocolTests: XCTestCase {
    func testDescriptorBasedBatteryProtobufAndMissingValues() throws {
        XCTAssertEqual(GFDIBattery.query, Data([0x42, 0x02, 0x12, 0x00]))
        // Synthetic APK descriptor fixture: Smart 8 -> response 3 -> OK 1,
        // percent 2, charging status 3, estimated remaining hours 4.
        let fixture = Data([0x42, 10, 0x1a, 8, 8, 1, 16, 63, 24, 4, 32, 95])
        XCTAssertEqual(try GFDIBattery.response(fixture), .init(percent: 63, charging: true, estimatedHoursRemaining: 95))
        XCTAssertNil(try GFDIBattery.response(Data([0x42, 4, 0x1a, 2, 8, 1])))
        XCTAssertNil(try GFDIBattery.response(Data([0x42, 6, 0x1a, 4, 8, 2, 16, 63])))
        XCTAssertNil(try GFDIBattery.response(Data([0x42, 6, 0x1a, 4, 8, 1, 16, 101])))
        XCTAssertEqual(try GFDIBattery.response(Data([0x42, 6, 0x1a, 4, 8, 1, 16, 0]))?.percent, 0)
        XCTAssertTrue(try GFDIBattery.isChangeNotification(Data([0x42, 2, 0x0a, 0])))
        XCTAssertFalse(try GFDIBattery.isChangeNotification(fixture))
        XCTAssertThrowsError(try GFDIBattery.response(Data([0x42, 20, 0x1a])))
        XCTAssertThrowsError(try GFDIBattery.response(Data([0x42, 2, 0, 1])))
    }

    func testLegacyBatteryAcceptsPercentWithoutInventingCharging() throws {
        XCTAssertEqual(try GFDIBattery.legacy(Data([0x20, 0, 63, 255, 255, 255])), .init(percent: 63, charging: nil, estimatedHoursRemaining: nil))
        XCTAssertNil(try GFDIBattery.legacy(Data([0x20, 0, 255, 255, 255, 255])))
        XCTAssertThrowsError(try GFDIBattery.legacy(Data([0x20, 0, 63])))
    }

    func testBatteryFragmentsRejectMixingTruncationAndConflictingDuplicates() throws {
        var transfer = GFDIBatteryTransfer(requestID: 9)
        let first = batteryFragment(id: 9, offset: 0, total: 4, data: Data([0x42, 2]))
        XCTAssertFalse(try transfer.accept(first).duplicate)
        XCTAssertTrue(try transfer.accept(first).duplicate)
        XCTAssertThrowsError(try transfer.accept(batteryFragment(id: 10, offset: 2, total: 4, data: Data([0x0a, 0]))))
        XCTAssertThrowsError(try transfer.accept(batteryFragment(id: 9, offset: 3, total: 4, data: Data([0]))))
        XCTAssertThrowsError(try transfer.accept(batteryFragment(id: 9, offset: 0, total: 4, data: Data([0x42, 3]))))
        XCTAssertThrowsError(try transfer.accept(batteryFragment(id: 9, offset: 2, total: 5, data: Data([0x0a, 0]))))
        XCTAssertThrowsError(try transfer.accept(batteryFragment(id: 9, offset: 2, total: 5000, data: Data([0x0a, 0]))))
        XCTAssertFalse(transfer.complete)
        _ = try transfer.accept(batteryFragment(id: 9, offset: 2, total: 4, data: Data([0x0a, 0])))
        XCTAssertTrue(transfer.complete)
        XCTAssertEqual(transfer.data, Data([0x42, 2, 0x0a, 0]))
    }

    func testBatteryResponseDoesNotConsumeIdentityReplyAndRefreshIsBounded() async throws {
        try await MainActor.run {
            let fixture = BatterySessionFixture()
            defer { fixture.session.disconnected() }
            try fixture.ready()
            let now = Date()
            fixture.session.tick(now: now)
            let request = try XCTUnwrap(fixture.messages.last { $0.number == 5043 })
            var reader = GFDIReader(request.payload)
            let id = try reader.u16()
            fixture.session.receive(try GFDIMessage(number: 5044, payload: batteryFragment(id: id + 1, offset: 0, total: 8, data: Data([0x42, 6, 0x1a, 4, 8, 1, 16, 63]))).framed())
            XCTAssertTrue(fixture.readings.isEmpty)
            fixture.session.receive(try GFDIMessage(number: 5044, payload: batteryFragment(id: id, offset: 0, total: 8, data: Data([0x42, 6, 0x1a, 4, 8, 1, 16, 63]))).framed())
            XCTAssertEqual(fixture.readings.map(\.percent), [63])
            XCTAssertTrue(fixture.session.isReady)
            XCTAssertTrue(fixture.session.canTransferFiles)
            fixture.session.tick(now: now.addingTimeInterval(299))
            XCTAssertEqual(fixture.messages.filter { $0.number == 5043 }.count, 1)
            fixture.session.tick(now: now.addingTimeInterval(301))
            XCTAssertEqual(fixture.messages.filter { $0.number == 5043 }.count, 2)
        }
    }

    func testUnsupportedBatteryFallsBackWithoutAbortingSync() async throws {
        try await MainActor.run {
            let fixture = BatterySessionFixture()
            defer { fixture.session.disconnected() }
            try fixture.ready()
            fixture.session.tick(now: Date())
            let request = try XCTUnwrap(fixture.messages.last { $0.number == 5043 })
            fixture.session.receive(try request.response(status: 2, payload: Data(request.payload.prefix(2))).framed())
            let legacy = try XCTUnwrap(fixture.messages.last { $0.number == 5001 })
            XCTAssertEqual(legacy.payload, Data([0x9f, 0x13]))
            fixture.session.receive(try GFDIMessage(number: 5023, payload: Data([0x20, 0, 63, 255, 255, 255])).framed())
            XCTAssertEqual(fixture.readings.map(\.percent), [63])
            fixture.session.requestSync()
            XCTAssertTrue(fixture.messages.contains { $0.number == 5007 })
            XCTAssertTrue(fixture.session.isSyncing)
        }
    }

    func testBatteryAndIdentityResponsesUseIndependentRequestIDs() async throws {
        try await MainActor.run {
            let fixture = BatterySessionFixture()
            defer { fixture.session.disconnected() }
            try fixture.ready(flags: [3, 95])
            fixture.session.tick(now: Date())
            let battery = try XCTUnwrap(fixture.messages.last { $0.number == 5043 })
            var batteryReader = GFDIReader(battery.payload)
            let batteryID = try batteryReader.u16()
            fixture.session.setAccountGUID("00112233445566778899aabbccddeeff")
            let identity = try XCTUnwrap(fixture.messages.last { $0.number == 5043 })
            var identityReader = GFDIReader(identity.payload)
            let identityID = try identityReader.u16()
            XCTAssertNotEqual(batteryID, identityID)
            var ack = GFDIWriter(); ack.u16(batteryID); ack.u32(0); ack.u8(0); ack.u8(0)
            fixture.session.receive(try battery.response(payload: Data(ack.bytes)).framed())
            fixture.session.receive(try identity.response().framed())
            fixture.session.receive(try GFDIMessage(number: 5044, payload: batteryFragment(id: batteryID, offset: 0, total: 8, data: Data([0x42, 6, 0x1a, 4, 8, 1, 16, 63]))).framed())
            XCTAssertNil(fixture.session.cloudIdentityMatches)
            fixture.session.receive(try GFDIMessage(number: 5044, payload: batteryFragment(id: identityID, offset: 0, total: 6, data: Data([0x6a, 4, 0x4a, 2, 8, 1]))).framed())
            XCTAssertEqual(fixture.session.cloudIdentityMatches, true)
            XCTAssertEqual(fixture.readings.map(\.percent), [63])
            XCTAssertTrue(fixture.session.canTransferFiles)
        }
    }

    func testBatteryTimeoutDoesNotReportFileSyncFailureOrLoop() async throws {
        try await MainActor.run {
            let fixture = BatterySessionFixture()
            defer { fixture.session.disconnected() }
            try fixture.ready()
            var failures = 0
            fixture.session.onSyncFinished = { if !$0 { failures += 1 } }
            let now = Date()
            fixture.session.tick(now: now)
            fixture.session.tick(now: now.addingTimeInterval(21))
            XCTAssertEqual(fixture.messages.filter { $0.number == 5001 }.count, 1)
            fixture.session.tick(now: now.addingTimeInterval(42))
            fixture.session.tick(now: now.addingTimeInterval(100))
            XCTAssertEqual(fixture.messages.filter { $0.number == 5001 }.count, 1)
            XCTAssertTrue(fixture.session.canTransferFiles)
            XCTAssertEqual(failures, 0)
        }
    }

    func testBatteryNotificationsAndFileTransferScheduling() async throws {
        try await MainActor.run {
            let fixture = BatterySessionFixture()
            defer { fixture.session.disconnected() }
            try fixture.ready()
            fixture.session.requestSync()
            fixture.session.tick(now: Date())
            XCTAssertFalse(fixture.messages.contains { $0.number == 5043 })
            let notification = GFDIMessage(number: 5043, payload: batteryFragment(id: 500, offset: 0, total: 4, data: Data([0x42, 2, 0x0a, 0])))
            fixture.session.receive(try notification.framed())
            XCTAssertEqual(fixture.messages.last?.number, 5000)
            XCTAssertEqual(fixture.messages.last?.payload[2], 0)
            fixture.session.receive(try notification.framed())
            XCTAssertEqual(fixture.messages.last?.payload.last, 101)
            XCTAssertTrue(fixture.session.isSyncing)
        }
    }
}

private func batteryFragment(id: UInt16, offset: UInt32, total: UInt32, data: Data) -> Data {
    var writer = GFDIWriter()
    writer.u16(id); writer.u32(offset); writer.u32(total); writer.u32(UInt32(data.count)); writer.data(data)
    return Data(writer.bytes)
}

@MainActor
private final class BatterySessionFixture {
    let session = GFDISession(storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("WristBeam-battery-tests"))
    var messages: [GFDIMessage] = []
    var readings: [GFDIBattery.Reading] = []
    private var decoder = GFDIStreamDecoder()

    init() {
        session.transportMode = .legacy; session.maximumWriteLength = 200
        session.onSend = { [weak self] in
            guard let self else { return }
            for result in self.decoder.receive($0) { if let value = try? result.get() { self.messages.append(value) } }
        }
        session.onBatteryReading = { [weak self] in self?.readings.append($0) }
        session.connected()
    }

    func ready(flags: Set<Int> = [3]) throws {
        var info = GFDIWriter()
        info.u16(113); info.u16(123); info.u32(1234); info.u16(100); info.u16(4096)
        info.string("Watch"); info.string("Test"); info.string("Fixture")
        session.receive(try GFDIMessage(number: 5024, payload: Data(info.bytes)).framed())
        let count = (flags.max() ?? 0) / 8 + 1
        var bitmap = Array(repeating: UInt8(0), count: count)
        for flag in flags { bitmap[flag / 8] |= 1 << (flag % 8) }
        session.receive(try GFDIMessage(number: 5050, payload: Data([UInt8(count)] + bitmap)).framed())
        session.receive(try GFDIMessage(number: 5050).response().framed())
    }
}
