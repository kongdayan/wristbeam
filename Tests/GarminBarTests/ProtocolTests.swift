import Foundation
import XCTest
@testable import GarminBar

final class ProtocolCodecTests: XCTestCase {
    func testKnownCRCAndIncrementalCRC() {
        let bytes = Data("123456789".utf8)
        XCTAssertEqual(GFDICRC.calculate(bytes), 0xbb3d)
        XCTAssertEqual(GFDICRC.calculate(bytes.suffix(5), initial: GFDICRC.calculate(bytes.prefix(4))), 0xbb3d)
    }

    func testCOBSBoundariesAndEmbeddedZeros() throws {
        let vectors = [Data(), Data([0]), Data([0, 0]), Data([1, 0, 2, 0]), Data(repeating: 42, count: 254), Data(repeating: 42, count: 255), Data(repeating: 42, count: 508), Data((0...255).map(UInt8.init))]
        for vector in vectors {
            let encoded = GFDICOBS.encode(vector)
            XCTAssertFalse(encoded.contains(0))
            XCTAssertEqual(try GFDICOBS.decode(encoded), vector)
        }
        XCTAssertThrowsError(try GFDICOBS.decode(Data([3, 1])))
        XCTAssertThrowsError(try GFDICOBS.decode(Data([0])))
        XCTAssertThrowsError(try GFDICOBS.decode(Data([2, 0])))
    }

    func testCompactFrameResponseMirrorsSequenceAndRejectsCorruption() throws {
        let message = GFDIMessage(number: 5004, payload: Data([0, 1, 0, 9]), sequence: 7)
        let packet = try message.packet()
        XCTAssertEqual(try GFDIMessage.decode(packet), message)
        let response = message.response(payload: Data([0, 4, 0, 0, 0]))
        XCTAssertEqual(response.sequence, 7)
        XCTAssertEqual(try GFDIMessage.decode(response.packet()), response)
        var corrupt = packet
        corrupt[4] ^= 1
        XCTAssertThrowsError(try GFDIMessage.decode(corrupt)) { XCTAssertEqual($0 as? GFDIProtocolError, .invalidCRC) }
        XCTAssertThrowsError(try GFDIMessage.decode(Data([0, 0, 0, 0, 0, 0]))) { XCTAssertEqual($0 as? GFDIProtocolError, .invalidLength) }
    }

    func testFragmentedAndCoalescedStreamResynchronizes() throws {
        let messages = [GFDIMessage(number: 5024, payload: Data([0, 1, 0])), GFDIMessage(number: 5050, payload: Data([2, 0, 4]))]
        var stream = GFDIStreamDecoder()
        var decoded: [GFDIMessage] = []
        let bytes = Data([9, 8, 7]) + (try messages[0].framed()) + (try messages[1].framed())
        for byte in bytes {
            for result in stream.receive(Data([byte])) { decoded.append(try result.get()) }
        }
        XCTAssertEqual(decoded, messages)
        var coalesced = GFDIStreamDecoder()
        XCTAssertEqual(try coalesced.receive(bytes).map { try $0.get() }, messages)
        var corrupt = try messages[0].packet(); corrupt[4] ^= 1
        let damaged = Data([0]) + GFDICOBS.encode(corrupt) + Data([0]) + (try messages[1].framed())
        var recovered = GFDIStreamDecoder()
        let results = recovered.receive(damaged)
        XCTAssertEqual(results.count, 2)
        XCTAssertThrowsError(try results[0].get())
        XCTAssertEqual(try results[1].get(), messages[1])
    }
}

final class ProtocolFilesTests: XCTestCase {
    func testDirectoryUsesSixteenByteRecordsAndKeepsFITSubtype() throws {
        let data = fixtureDirectory(size: 123)
        let entries = try GFDIDirectoryEntry.parseDirectory(data)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].index, 42)
        XCTAssertEqual(entries[0].dataType, 128)
        XCTAssertEqual(entries[0].subtype, 4)
        XCTAssertEqual(entries[0].identifier, [4, 0, 0])
        XCTAssertEqual(entries[0].size, 123)
        XCTAssertTrue(entries[0].isReadable)
        XCTAssertThrowsError(try GFDIDirectoryEntry.parseDirectory(data + Data([1])))
        XCTAssertThrowsError(try GFDIDirectoryEntry.parseDirectory(data + data.suffix(16)))
    }

    func testDirectoryIgnoresReservedIndexAndEmptySlots() throws {
        let data = fixtureDirectory(size: 123)
        XCTAssertEqual(try GFDIDirectoryEntry.parseDirectory(data + Data(repeating: 0, count: 16)).count, 1)
        XCTAssertTrue(try GFDIDirectoryEntry.parseDirectory(Data(repeating: 0, count: 32)).isEmpty)
    }

    func testDuplicateOffsetAndBadCRCNeverAdvanceState() {
        var receiver = GFDIFileReceiver(finalSize: 6)
        let first = Data([1, 2, 3])
        let crc1 = GFDICRC.calculate(first)
        let result1 = receiver.accept(fixtureBlock(data: first, offset: 0, crc: crc1))
        XCTAssertEqual(result1.status, 0)
        XCTAssertEqual(result1.nextOffset, 3)
        let duplicate = receiver.accept(fixtureBlock(data: first, offset: 0, crc: crc1))
        XCTAssertEqual(duplicate.status, 0)
        XCTAssertTrue(duplicate.bytesToAppend.isEmpty)
        XCTAssertEqual(receiver.receivedSize, 3)
        let offsetError = receiver.accept(fixtureBlock(data: Data([4]), offset: 9, crc: 0))
        XCTAssertEqual(offsetError.status, 4)
        XCTAssertEqual(receiver.receivedSize, 3)
        let second = Data([4, 5, 6])
        let crc2 = GFDICRC.calculate(second, initial: crc1)
        XCTAssertEqual(receiver.accept(fixtureBlock(data: second, offset: 3, crc: crc2 ^ 1)).status, 3)
        XCTAssertEqual(receiver.crc, crc1)
        XCTAssertEqual(receiver.receivedSize, 3)
        let result2 = receiver.accept(fixtureBlock(data: second, offset: 3, crc: crc2))
        XCTAssertEqual(result2.status, 0)
        XCTAssertTrue(result2.isComplete)
        XCTAssertEqual(receiver.receivedSize, 6)
        XCTAssertEqual(receiver.crc, crc2)
    }

    func testOversizedOrEmptyBlockAbortsWithoutAcceptingData() {
        var receiver = GFDIFileReceiver(finalSize: 2)
        XCTAssertEqual(receiver.accept(fixtureBlock(data: Data([1, 2, 3]), offset: 0, crc: 0)).status, 2)
        XCTAssertEqual(receiver.accept(fixtureBlock(data: Data(), offset: 0, crc: 0)).status, 2)
        XCTAssertEqual(receiver.receivedSize, 0)
    }

    func testImmutablePersistenceAndRestartQueue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GarminBar-protocol-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let content = Data([1, 2, 3, 4])
        let entry = try XCTUnwrap(GFDIDirectoryEntry.parseDirectory(fixtureDirectory(size: content.count)).first)
        let first = try GFDIFileArchive.persist(content, entry: entry, deviceID: 1234, root: directory)
        let second = try GFDIFileArchive.persist(content, entry: entry, deviceID: 1234, root: directory)
        XCTAssertEqual(first.0, second.0)
        XCTAssertEqual(first.1, second.1)
        XCTAssertEqual(try Data(contentsOf: first.0), content)
        let restored = try GFDIFileArchive.pendingFiles(root: directory)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].1, first.1)
        try Data([9]).write(to: first.0)
        XCTAssertTrue(try GFDIFileArchive.pendingFiles(root: directory).isEmpty)
    }
}

final class ProtocolIdentityTests: XCTestCase {
    func testGUIDQueryDoesNotConstructOverwriteAndReadsNestedReply() throws {
        let bytes = try XCTUnwrap(GFDICoreIdentity.guidBytes("00112233-4455-6677-8899-aabbccddeeff"))
        XCTAssertEqual(bytes, Data("00112233-4455-6677-8899-aabbccddeeff".utf8))
        XCTAssertNil(GFDICoreIdentity.guidBytes("not-an-account-id"))
        let query = GFDICoreIdentity.query(guid: bytes)
        XCTAssertEqual(query[0], 13 << 3 | 2)
        XCTAssertEqual(query[2], 8 << 3 | 2) // feature query, never overwrite field 10.
        for status in UInt64(0)...2 {
            let response = GFDICoreIdentity.bytesField(13, GFDICoreIdentity.bytesField(9, GFDICoreIdentity.integerField(1, status)))
            XCTAssertEqual(try GFDICoreIdentity.guidStatus(response), status)
        }
        XCTAssertThrowsError(try GFDICoreIdentity.guidStatus(Data([0x6a, 0xff])))
    }

    func testGUIDUsesOfficialTextBytesInsteadOfBinaryUUID() throws {
        let guid = "00112233445566778899aabbccddeeff"
        let bytes = try XCTUnwrap(GFDICoreIdentity.guidBytes(guid))
        XCTAssertEqual(bytes.count, 32)
        // Golden protobuf bytes: Smart.core_service=13, feature_request=8,
        // garmin_guid=1 carrying exactly 32 ASCII bytes, version=1 and client name.
        let expected = Data([0x6a, 0x31, 0x42, 0x2f, 0x0a, 0x20]) + Data(guid.utf8)
            + Data([0x10, 0x01, 0x1a, 0x09]) + Data("GarminBar".utf8)
        XCTAssertEqual(GFDICoreIdentity.query(guid: bytes), expected)
        XCTAssertNil(GFDICoreIdentity.guidBytes("00112233--4455-6677-8899-aabbccddeeff"))
    }
}

final class ProtocolSessionTests: XCTestCase {
    func testDeviceSyncNotificationsAreAcknowledgedBeforeCheckingFiles() async throws {
        try await MainActor.run {
            let session = GFDISession(storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("GarminBar-notify-test-\(UUID().uuidString)"))
            defer { session.disconnected() }
            session.transportMode = .legacy
            session.maximumWriteLength = 200
            var decoder = GFDIStreamDecoder()
            var messages: [GFDIMessage] = []
            var checks = 0
            session.onSend = { for result in decoder.receive($0) { if let value = try? result.get() { messages.append(value) } } }
            session.onFilesAvailable = { checks += 1; XCTAssertEqual(messages.last?.number, 5000); XCTAssertEqual(messages.last?.payload[2], 0) }
            session.connected()
            try feedHandshake(session)
            session.receive(try GFDIMessage(number: 5009, payload: Data(fixtureDirectory(size: 100).dropFirst(16))).framed())
            session.receive(try GFDIMessage(number: 5027, payload: Data([1,0])).framed())
            session.receive(try GFDIMessage(number: 5037, payload: Data([1,0])).framed())
            XCTAssertEqual(checks, 3)
            session.receive(try GFDIMessage(number: 5009, payload: Data([0])).framed())
            session.receive(try GFDIMessage(number: 5027, payload: Data([5,0])).framed())
            session.receive(try GFDIMessage(number: 5037, payload: Data([1,5])).framed())
            XCTAssertEqual(checks, 3)
            XCTAssertEqual(messages.last?.payload[2], 5)
            XCTAssertFalse(messages.contains { [5005, 5008, 5026].contains(Int($0.number)) })
        }
    }

    func testDirectoryWaitsForHandshakeCompleteEventAcknowledgement() async throws {
        try await MainActor.run {
            let session = GFDISession(storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("GarminBar-handshake-test-\(UUID().uuidString)"))
            defer { session.disconnected() }
            session.transportMode = .legacy
            session.maximumWriteLength = 200
            var decoder = GFDIStreamDecoder()
            var messages: [GFDIMessage] = []
            session.onSend = { for result in decoder.receive($0) { if let value = try? result.get() { messages.append(value) } } }
            session.connected()
            try feedHandshake(session, complete: false)
            XCTAssertTrue(session.isReady)
            XCTAssertFalse(session.canTransferFiles)
            let event = try XCTUnwrap(messages.first { $0.number == 5030 })
            XCTAssertEqual(event.payload, Data([8, 0]))
            session.requestSync()
            XCTAssertFalse(messages.contains { $0.number == 5007 || $0.number == 5002 })
            session.receive(try event.response(payload: Data([0])).framed())
            XCTAssertTrue(session.canTransferFiles)
            XCTAssertEqual(messages.last?.number, 5007)
            XCTAssertEqual(messages.filter { $0.number == 5030 }.count, 1)
        }
    }

    func testFitnessHandshakeAdvertisesFitLinkWithoutUnsupportedCapabilities() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GarminBar-capabilities-test-\(UUID().uuidString)")
            let session = GFDISession(storageDirectory: directory)
            defer { session.disconnected() }
            session.transportMode = .legacy
            session.maximumWriteLength = 200
            var messages: [GFDIMessage] = []
            var decoder = GFDIStreamDecoder()
            session.onSend = { for result in decoder.receive($0) { if let value = try? result.get() { messages.append(value) } } }
            session.connected()
            try feedHandshake(session, flags: [0, 3, 4, 90, 95])
            let configuration = try XCTUnwrap(messages.first { $0.number == 5050 })
            let bitmap = Array(configuration.payload.dropFirst())
            XCTAssertEqual(configuration.payload.first, UInt8(bitmap.count))
            func enabled(_ flag: Int) -> Bool { flag / 8 < bitmap.count && bitmap[flag / 8] & (1 << (flag % 8)) != 0 }
            for flag in [0, 3, 4, 71, 95] { XCTAssertTrue(enabled(flag)) }
            for flag in [1, 2, 29, 90] { XCTAssertFalse(enabled(flag)) }
            // A firmware requiring SYNC_2 still cannot use the legacy file path.
            session.requestSync()
            XCTAssertFalse(messages.contains { $0.number == 5007 || $0.number == 5002 })
        }
    }

    func testRealEmptyDirectoryCompletesWithoutDownloadingIndexZero() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GarminBar-empty-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let session = GFDISession(storageDirectory: directory)
            defer { session.disconnected() }
            session.transportMode = .legacy
            session.maximumWriteLength = 200
            var messages: [GFDIMessage] = []
            var decoder = GFDIStreamDecoder()
            var files = 0
            var finished: Bool?
            var status = ""
            session.onSend = { for result in decoder.receive($0) { if let value = try? result.get() { messages.append(value) } } }
            session.onFile = { _, _ in files += 1 }
            session.onSyncFinished = { finished = $0 }
            session.onStatus = { status = $0 }
            session.connected()
            try feedHandshake(session)
            session.requestSync()
            session.receive(try GFDIMessage(number: 5007).response(payload: Data([0])).framed())
            var empty = Data(repeating: 0, count: 32)
            empty[2] = 1 // Observed Instinct 2 Solar empty directory header.
            session.receive(try readReply(size: empty.count).framed())
            session.receive(try GFDIMessage(number: 5004, payload: fixtureBlock(data: empty, offset: 0, crc: GFDICRC.calculate(empty))).framed())
            XCTAssertEqual(files, 0)
            XCTAssertEqual(finished, true)
            XCTAssertTrue(status.contains("本次没有新增文件"))
            XCTAssertEqual(messages.filter { $0.number == 5002 }.count, 1)
        }
    }

    func testHistoryDownloadSelectsOnlyLatestActivityAndKeepsNormalPendingFilter() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GarminBar-history-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let session = GFDISession(storageDirectory: directory)
            defer { session.disconnected() }
            session.transportMode = .legacy
            session.maximumWriteLength = 200
            var messages: [GFDIMessage] = []
            var decoder = GFDIStreamDecoder()
            var files = 0
            session.onSend = { for result in decoder.receive($0) { if let value = try? result.get() { messages.append(value) } } }
            session.onFile = { _, _ in files += 1 }
            session.connected()
            try feedHandshake(session)
            session.requestSync(includeArchivedActivities: true)
            XCTAssertEqual(messages.last?.payload, Data([0]))
            session.receive(try GFDIMessage(number: 5007).response(payload: Data([0])).framed())
            let fit = fixtureFIT()
            var listing = GFDIWriter()
            listing.data(Data(repeating: 0, count: 16))
            for (index, subtype, timestamp) in [(42, 4, 10), (43, 4, 20), (44, 32, 30)] {
                listing.u16(UInt16(index)); listing.u8(128); listing.data(Data([UInt8(subtype), 0, 0])); listing.u8(0); listing.u8(128)
                listing.u32(UInt32(fit.count)); listing.u32(UInt32(timestamp))
            }
            let data = Data(listing.bytes)
            session.receive(try readReply(size: data.count).framed())
            session.receive(try GFDIMessage(number: 5004, payload: fixtureBlock(data: data, offset: 0, crc: GFDICRC.calculate(data))).framed())
            XCTAssertEqual(messages.last?.number, 5002)
            XCTAssertEqual(messages.last?.payload.prefix(2), Data([43, 0]))
            session.receive(try readReply(size: fit.count).framed())
            session.receive(try GFDIMessage(number: 5004, payload: fixtureBlock(data: fit, offset: 0, crc: GFDICRC.calculate(fit))).framed())
            XCTAssertEqual(files, 1)
            XCTAssertFalse(session.isSyncing)
            XCTAssertFalse(messages.contains { $0.number == 5008 })
            session.requestSync()
            XCTAssertEqual(messages.last?.number, 5007)
            XCTAssertEqual(messages.last?.payload, Data([3]))
        }
    }

    func testMultiLinkRegistrationAndRealtimeRoutingWithoutLogin() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GarminBar-ml-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let session = GFDISession(storageDirectory: directory)
            defer { session.disconnected() }
            var writes: [Data] = []
            var realtime: [(UInt16, Data)] = []
            session.onSend = { writes.append($0) }
            session.onRealtimeData = { realtime.append(($0, $1)) }
            session.connected()
            let register = try XCTUnwrap(writes.first)
            XCTAssertEqual(register.count, 13)
            XCTAssertEqual(register[1], 0)
            XCTAssertEqual(register[2], 2)
            XCTAssertEqual(register.subdata(in: 3..<10), Data(repeating: 0, count: 7))
            XCTAssertEqual(register[10], 4)
            var registrationReply = register
            registrationReply[1] = 1
            registrationReply[12] = 0
            registrationReply += Data([2, 0, 0])
            session.receive(registrationReply)
            let requested = writes.filter { $0.count == 13 && $0[1] == 0 }.map { Int($0[10]) | Int($0[11]) << 8 }
            XCTAssertEqual(Set(requested), Set([4, 1, 6, 7, 13, 20, 8, 9, 10, 12, 19, 21, 25, 26, 29]))
            XCTAssertFalse(writes.contains { $0.count >= 2 && $0[0] == 0 && $0[1] == 5 })
            var heartReply = try XCTUnwrap(writes.first { $0.count == 13 && $0[10] == 6 })
            heartReply[1] = 1
            heartReply[12] = 0
            heartReply += Data([10, 0])
            session.receive(heartReply)
            session.receive(Data([10, 70]))
            XCTAssertEqual(realtime.count, 1)
            XCTAssertEqual(realtime[0].0, 6)
            XCTAssertEqual(realtime[0].1, Data([70]))
        }
    }

    @MainActor func testRegistrationResumesAfterSystemPairingAndRetriesAreBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GarminBar-pairing-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = GFDISession(storageDirectory: directory)
        defer { session.disconnected() }
        var writes: [Data] = []
        session.onSend = { writes.append($0) }
        session.connected()
        let first = try XCTUnwrap(writes.first)
        var waiting = first; waiting[1] = 1; waiting[12] = 2
        session.receive(waiting)
        session.tick(now: Date().addingTimeInterval(11))
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.last, first)
        var accepted = first; accepted[1] = 1; accepted[12] = 0; accepted += Data([2, 0])
        session.receive(accepted)
        XCTAssertTrue(writes.contains { $0.count == 13 && $0[10] == 6 })
        XCTAssertFalse(session.canTransferFiles)
        session.disconnected(); writes.removeAll(); session.connected()
        for _ in 0..<8 { session.tick(now: Date().addingTimeInterval(1000)) }
        XCTAssertEqual(writes.count, 4)
        XCTAssertFalse(writes.contains { $0.count >= 2 && $0[0] == 0 && $0[1] == 5 })
    }

    func testLegacyDirectoryAndFileDownloadPersistsBeforeFinalAcknowledgement() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GarminBar-read-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let session = GFDISession(storageDirectory: directory)
            defer { session.disconnected() }
            session.transportMode = .legacy
            session.maximumWriteLength = 200
            var decoder = GFDIStreamDecoder()
            var sent: [GFDIMessage] = []
            var files: [(URL, GFDIFileMetadata)] = []
            var finalACKWasDurable = false
            session.onSend = { data in
                for result in decoder.receive(data) {
                    if let message = try? result.get() {
                        sent.append(message)
                        if message.number == 5000, message.payload.starts(with: [0x8c, 0x13, 0]), message.payload.last == 0,
                           (try? GFDIFileArchive.pendingFiles(root: directory).count) == 1 { finalACKWasDurable = true }
                    }
                }
            }
            session.onFile = { files.append(($0, $1)) }
            session.connected()
            try feedHandshake(session)
            XCTAssertTrue(session.isReady)
            session.requestSync()
            XCTAssertEqual(sent.last?.number, 5007)
            session.receive(try GFDIMessage(number: 5007).response(payload: Data([0])).framed())
            XCTAssertEqual(sent.last?.number, 5002)
            XCTAssertEqual(sent.last?.payload.prefix(2), Data([0, 0]))
            XCTAssertEqual(sent.last?.payload.count, 14)
            XCTAssertEqual(sent.last?.payload.last, 0) // compression off
            let fit = fixtureFIT()
            let directoryData = fixtureDirectory(size: fit.count)
            session.receive(try readReply(size: directoryData.count).framed())
            session.receive(try GFDIMessage(number: 5004, payload: fixtureBlock(data: directoryData, offset: 0, crc: GFDICRC.calculate(directoryData))).framed())
            XCTAssertEqual(sent.last?.number, 5002)
            XCTAssertEqual(sent.last?.payload.prefix(2), Data([42, 0]))
            session.receive(try readReply(size: fit.count).framed())
            session.receive(try GFDIMessage(number: 5004, payload: fixtureBlock(data: fit, offset: 0, crc: GFDICRC.calculate(fit))).framed())
            XCTAssertEqual(files.count, 1)
            XCTAssertEqual(try Data(contentsOf: files[0].0), fit)
            XCTAssertEqual(files[0].1.deviceID, 1234)
            XCTAssertEqual(files[0].1.subtype, 4)
            XCTAssertFalse(session.isSyncing)
            XCTAssertTrue(finalACKWasDurable)
            XCTAssertFalse(sent.contains { [5005, 5008, 5026].contains(Int($0.number)) })
        }
    }

    func testMissingRegistrationServiceDoesNotSuppressRealtimeRequests() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GarminBar-reg-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let session = GFDISession(storageDirectory: directory)
            defer { session.disconnected() }
            var writes: [Data] = []
            session.onSend = { writes.append($0) }
            session.connected()
            var invalidService = try XCTUnwrap(writes.first)
            invalidService[1] = 1
            invalidService[12] = 1
            session.receive(invalidService)
            let services = writes.filter { $0.count == 13 && $0[1] == 0 }.map { Int($0[10]) }
            XCTAssertEqual(Set(services), Set([4, 1, 6, 7, 13, 20, 8, 9, 10, 12, 19, 21, 25, 26, 29]))
        }
    }

    func testCapabilityNinetyDoesNotSendLegacyDownload() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GarminBar-mlr-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let session = GFDISession(storageDirectory: directory)
            defer { session.disconnected() }
            session.transportMode = .legacy
            session.maximumWriteLength = 200
            var decoder = GFDIStreamDecoder()
            var sent: [GFDIMessage] = []
            session.onSend = { for result in decoder.receive($0) { if let message = try? result.get() { sent.append(message) } } }
            session.connected()
            try feedHandshake(session, flags: [3, 4, 90])
            session.requestSync()
            XCTAssertEqual(session.deviceInfo?.needsNativeMLR, true)
            XCTAssertFalse(sent.contains { $0.number == 5007 || $0.number == 5002 })
        }
    }

    func testGUIDMismatchNeverDownloadsOrOverwrites() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GarminBar-guid-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let session = GFDISession(storageDirectory: directory)
            defer { session.disconnected() }
            session.transportMode = .legacy
            session.maximumWriteLength = 200
            var decoder = GFDIStreamDecoder()
            var sent: [GFDIMessage] = []
            session.onSend = { for result in decoder.receive($0) { if let message = try? result.get() { sent.append(message) } } }
            session.connected(accountGUID: "00112233445566778899aabbccddeeff")
            try feedHandshake(session, flags: [3, 4, 95])
            session.requestSync()
            let query = try XCTUnwrap(sent.first { $0.number == 5043 })
            var queryReader = GFDIReader(query.payload)
            let id = try queryReader.u16()
            let response = GFDICoreIdentity.bytesField(13, GFDICoreIdentity.bytesField(9, GFDICoreIdentity.integerField(1, 2)))
            var payload = GFDIWriter()
            payload.u16(id); payload.u32(0); payload.u32(UInt32(response.count)); payload.u32(UInt32(response.count)); payload.data(response)
            session.receive(try GFDIMessage(number: 5044, payload: Data(payload.bytes)).framed())
            XCTAssertEqual(session.cloudIdentityMatches, false)
            XCTAssertFalse(sent.contains { $0.number == 5007 || $0.number == 5002 })
        }
    }

    func testLostDirectoryResponseRetriesOnceThenStopsCleanly() async throws {
        try await MainActor.run {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GarminBar-timeout-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let session = GFDISession(storageDirectory: directory)
            defer { session.disconnected() }
            session.transportMode = .legacy
            session.maximumWriteLength = 200
            var decoder = GFDIStreamDecoder()
            var sent: [GFDIMessage] = []
            session.onSend = { for result in decoder.receive($0) { if let message = try? result.get() { sent.append(message) } } }
            session.connected()
            try feedHandshake(session)
            session.requestSync()
            XCTAssertTrue(session.isSyncing)
            let now = Date()
            session.tick(now: now.addingTimeInterval(11))
            XCTAssertEqual(sent.filter { $0.number == 5007 }.count, 2)
            session.tick(now: now.addingTimeInterval(22))
            XCTAssertFalse(session.isSyncing)
            XCTAssertFalse(sent.contains { $0.number == 5002 })
        }
    }
}

private func fixtureDirectory(size: Int) -> Data {
    var writer = GFDIWriter()
    writer.data(Data(repeating: 0, count: 16))
    writer.u16(42); writer.u8(128); writer.data(Data([4, 0, 0])); writer.u8(0); writer.u8(128)
    writer.u32(UInt32(size)); writer.u32(1)
    return Data(writer.bytes)
}

private func fixtureBlock(data: Data, offset: UInt32, crc: UInt16) -> Data {
    var writer = GFDIWriter(); writer.u8(0); writer.u16(crc); writer.u32(offset); writer.data(data); return Data(writer.bytes)
}

private func fixtureFIT() -> Data {
    var data = Data([12, 0x10, 0, 0, 0, 0, 0, 0, 0x2e, 0x46, 0x49, 0x54])
    let crc = GFDICRC.calculate(data)
    data += Data([UInt8(truncatingIfNeeded: crc), UInt8(truncatingIfNeeded: crc >> 8)])
    return data
}

private func readReply(size: Int) -> GFDIMessage {
    var writer = GFDIWriter(); writer.u8(0); writer.u32(UInt32(size)); return GFDIMessage(number: 5002).response(payload: Data(writer.bytes))
}

@MainActor
private func feedHandshake(_ session: GFDISession, flags: Set<Int> = [3, 4], complete: Bool = true) throws {
    var info = GFDIWriter()
    info.u16(113); info.u16(123); info.u32(1234); info.u16(100); info.u16(4096)
    info.string("Instinct 2"); info.string("Instinct"); info.string("2 Solar")
    session.receive(try GFDIMessage(number: 5024, payload: Data(info.bytes)).framed())
    let count = (flags.max() ?? 0) / 8 + 1
    var bitmap = Array(repeating: UInt8(0), count: count)
    for flag in flags { bitmap[flag / 8] |= 1 << (flag % 8) }
    session.receive(try GFDIMessage(number: 5050, payload: Data([UInt8(count)] + bitmap)).framed())
    session.receive(try GFDIMessage(number: 5050).response().framed())
    if complete { session.receive(try GFDIMessage(number: 5030).response(payload: Data([0])).framed()) }
}
