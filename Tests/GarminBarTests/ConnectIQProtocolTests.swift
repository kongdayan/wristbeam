import Foundation
import XCTest
@testable import GarminBar

final class ConnectIQProtocolTests: XCTestCase {
    func testSDKOpenCommandsAndResponsesAreBoundToTheExactUUID() throws {
        let id = "00112233-4455-6677-8899-aabbccddeeff"
        let uuid = Data([0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff])
        XCTAssertEqual(try GFDIConnectIQSDK.command(5, appID: id), Data([0, 5]) + uuid)
        XCTAssertEqual(try GFDIConnectIQSDK.command(6, appID: id), Data([0, 6]) + uuid)
        XCTAssertEqual(try GFDIConnectIQSDK.applicationVersion(Data([0, 5]) + uuid + Data([74, 0]), appID: id), 74)
        XCTAssertEqual(try GFDIConnectIQSDK.applicationVersion(Data([0, 5]) + uuid + Data([255, 255]), appID: id), UInt16.max)
        XCTAssertEqual(try GFDIConnectIQSDK.openStatus(Data([0, 6]) + uuid + Data([0]), appID: id), 0)
        XCTAssertEqual(try GFDIConnectIQSDK.openStatus(Data([0, 6]) + uuid + Data([3]), appID: id), 3)
        XCTAssertThrowsError(try GFDIConnectIQSDK.openStatus(Data([0, 6]) + uuid, appID: id))
        XCTAssertThrowsError(try GFDIConnectIQSDK.openStatus(Data([0, 6]) + uuid + Data([0]), appID: "11112233-4455-6677-8899-aabbccddeeff"))
        XCTAssertThrowsError(try GFDIConnectIQSDK.command(1, appID: id))
        XCTAssertThrowsError(try GFDIConnectIQSDK.command(6, appID: "invalid"))
    }

    func testInstalledWatchFacesUseCIQInventoryAndDoNotInferCurrentSelection() throws {
        XCTAssertEqual(GFDIConnectIQ.installedWatchFacesQuery, Data([0x1a, 4, 0x0a, 2, 8, 3]))
        let inventory = try GFDIConnectIQ.installedWatchFaces(installedInventory(), unitID: 1234)
        XCTAssertEqual(inventory.apps.count, 1)
        XCTAssertEqual(inventory.apps[0].id, "00112233-4455-6677-8899-aabbccddeeff")
        XCTAssertEqual(inventory.apps[0].name, "CIQ Test")
        XCTAssertEqual(inventory.apps[0].version, 74)
        XCTAssertEqual(inventory.availableSlots, 20)
        XCTAssertThrowsError(try GFDIConnectIQ.installedWatchFaces(Data(), unitID: 1234))
        XCTAssertThrowsError(try GFDIConnectIQ.installedWatchFaces(gridComposition(), unitID: 1234))
    }

    func testEmptyRTSDoesNotDiscardWorkingInstalledInventory() async throws {
        try await MainActor.run {
            let fixture = CIQSessionFixture()
            defer { fixture.session.disconnected() }
            try fixture.ready()
            var inventory: GFDIInstalledWatchFaceInventory?
            fixture.session.onInstalledWatchFaces = { inventory = $0 }
            fixture.session.refreshWatchFaces(expectedUnitID: 1234)
            try fixture.respond(installedInventory())
            XCTAssertEqual(inventory?.apps.count, 1)
            try fixture.respond(Data())
            XCTAssertEqual(inventory?.apps.count, 1)
            XCTAssertFalse(fixture.busy)
        }
    }

    func testSelectionUsesRTSGridIndexNotAppLaunchUUID() {
        let option = GFDIWatchFaceOption(unitID: 1234, compositionID: 1, compositionVersion: 1, globalVersion: 1, rowID: 2, index: 3,
                                       title: "Test", imageName: nil, isSelected: false)
        // Smart extension 42 -> settings_change_request 5 -> composition 1 / row 2 /
        // watch_face_grid_value_change 16 { index 3 }.
        XCTAssertEqual(GFDIConnectIQ.selection(option), Data([0xd2, 2, 11, 0x2a, 9, 8, 1, 16, 2, 0x82, 1, 2, 8, 3]))
    }

    func testDeviceGridRequiresCompleteExclusiveSelectionAndCorrectComposition() throws {
        let choices = try GFDIConnectIQ.choices(gridComposition(), unitID: 1234)
        XCTAssertEqual(choices.count, 2)
        XCTAssertTrue(choices.allSatisfy { $0.isSelected == nil })
        let updated = try GFDIConnectIQ.applySettings(gridSettings(selected: 1), compositionID: 36361, choices: choices)
        XCTAssertEqual(updated.map(\.isSelected), [false, true])
        XCTAssertThrowsError(try GFDIConnectIQ.applySettings(gridSettings(selected: 1, composition: 17), compositionID: 36361, choices: choices))
        XCTAssertThrowsError(try GFDIConnectIQ.applySettings(gridSettings(selected: 8), compositionID: 36361, choices: choices))
        XCTAssertThrowsError(try GFDIConnectIQ.applySettings(gridSettings(selected: 1, omitSelection: true), compositionID: 36361, choices: choices))
        XCTAssertThrowsError(try GFDIConnectIQ.applySettings(gridSettings(selected: 1, viewState: 2), compositionID: 36361, choices: choices))
        XCTAssertThrowsError(try GFDIConnectIQ.checkSelectionResponse(service(6, Data())))
        XCTAssertThrowsError(try GFDIConnectIQ.checkSelectionResponse(service(6, integer(1, 1))))
        XCTAssertNoThrow(try GFDIConnectIQ.checkSelectionResponse(service(6, integer(1, 0))))
    }

    func testEmptyResponseIsAcknowledgedAndCannotSupplyASelection() throws {
        var transfer = GFDIConnectIQTransfer(requestID: 5)
        let payload = fragment(id: 5, offset: 0, total: 0, data: Data())
        XCTAssertFalse(try transfer.accept(payload).duplicate)
        XCTAssertTrue(transfer.complete)
        XCTAssertTrue(try transfer.accept(payload).duplicate)
        XCTAssertThrowsError(try GFDIConnectIQ.choices(transfer.data, unitID: 1234))
        XCTAssertThrowsError(try GFDIConnectIQ.checkSelectionResponse(transfer.data))
    }

    func testFragmentIdentityBoundsAndDuplicateConflicts() throws {
        var transfer = GFDIConnectIQTransfer(requestID: 5)
        let first = fragment(id: 5, offset: 0, total: 4, data: Data([1, 2]))
        XCTAssertFalse(try transfer.accept(first).duplicate)
        XCTAssertTrue(try transfer.accept(first).duplicate)
        XCTAssertThrowsError(try transfer.accept(fragment(id: 6, offset: 2, total: 4, data: Data([3, 4]))))
        XCTAssertThrowsError(try transfer.accept(fragment(id: 5, offset: 0, total: 4, data: Data([0, 2]))))
        XCTAssertThrowsError(try transfer.accept(fragment(id: 5, offset: 2, total: 600_000, data: Data([3, 4]))))
        XCTAssertFalse(transfer.complete)
        _ = try transfer.accept(fragment(id: 5, offset: 2, total: 4, data: Data([3, 4])))
        XCTAssertTrue(transfer.complete)
        XCTAssertEqual(transfer.data, Data([1, 2, 3, 4]))
    }

    func testManualSelectionRequiresMatchingDeviceFreshMapAndReadback() async throws {
        try await MainActor.run {
            let fixture = CIQSessionFixture()
            defer { fixture.session.disconnected() }
            try fixture.ready()
            fixture.session.refreshWatchFaces(expectedUnitID: 9876)
            XCTAssertEqual(fixture.requests.count, 0)
            fixture.session.refreshWatchFaces(expectedUnitID: 1234)
            try fixture.respond(installedInventory())
            try fixture.respond(gridComposition())
            try fixture.respond(gridSettings(selected: 0))
            XCTAssertEqual(fixture.choices.count, 2)
            let target = try XCTUnwrap(fixture.choices.last)
            fixture.session.selectWatchFace(target, expectedUnitID: 1234)
            try fixture.respond(gridComposition()) // Selection preflight reads mapping and state.
            try fixture.respond(gridSettings(selected: 0))
            XCTAssertTrue(fixture.busy)
            let change = try XCTUnwrap(fixture.requests.last)
            XCTAssertEqual(Data(change.payload.dropFirst(14)), GFDIConnectIQ.selection(target))
            try fixture.respond(service(6, integer(1, 0)))
            XCTAssertTrue(fixture.busy) // Device write result alone is not success.
            XCTAssertEqual(fixture.choices.last?.isSelected, false)
            try fixture.respond(gridSettings(selected: 1))
            XCTAssertFalse(fixture.busy)
            XCTAssertEqual(fixture.choices.last?.isSelected, true)
            XCTAssertEqual(fixture.status, "手表已确认表盘选择")
            fixture.session.disconnected()
            let count = fixture.requests.count
            fixture.session.selectWatchFace(target, expectedUnitID: 1234)
            XCTAssertEqual(fixture.requests.count, count)
        }
    }

    func testChangedMappingNeverWritesAndTimeoutAllowsRetry() async throws {
        try await MainActor.run {
            let fixture = CIQSessionFixture()
            defer { fixture.session.disconnected() }
            try fixture.ready()
            fixture.session.refreshWatchFaces(expectedUnitID: 1234)
            try fixture.respond(installedInventory())
            try fixture.respond(gridComposition())
            try fixture.respond(gridSettings(selected: 0))
            let target = try XCTUnwrap(fixture.choices.last)
            fixture.session.selectWatchFace(target, expectedUnitID: 1234)
            let count = fixture.requests.count
            try fixture.respond(gridComposition(secondImage: "different"))
            XCTAssertFalse(fixture.busy)
            XCTAssertEqual(fixture.requests.count, count)
            XCTAssertTrue(fixture.choices.isEmpty)
            fixture.session.refreshWatchFaces(expectedUnitID: 1234)
            fixture.session.tick(now: Date().addingTimeInterval(30))
            XCTAssertFalse(fixture.busy)
            fixture.session.refreshWatchFaces(expectedUnitID: 1234)
            XCTAssertTrue(fixture.busy)
        }
    }
}

private func integer(_ field: UInt64, _ value: UInt64) -> Data { GFDIConnectIQ.Proto.integer(field, value) }
private func bytes(_ field: UInt64, _ value: Data) -> Data { GFDIConnectIQ.Proto.bytes(field, value) }
private func service(_ field: UInt64, _ value: Data) -> Data { bytes(42, bytes(field, value)) }
private func gridComposition(secondImage: String = "second") -> Data {
    let item0 = bytes(3, integer(1, 0) + bytes(2, Data("first".utf8)))
    let item1 = bytes(3, integer(1, 1) + bytes(2, Data(secondImage.utf8)))
    let row = integer(1, 7) + integer(2, 25) + bytes(3, bytes(2, Data("Face".utf8))) + bytes(19, item0 + item1)
    return service(2, integer(1, 0) + bytes(2, integer(1, 36361) + integer(2, 1) + integer(3, 1) + bytes(5, row)))
}
private func gridSettings(selected: UInt64, composition: UInt64 = 36361, omitSelection: Bool = false, viewState: UInt64 = 0) -> Data {
    var items = Data()
    for index in UInt64(0)...1 {
        items += bytes(1, integer(1, index) + (omitSelection ? Data() : integer(2, selected == index ? 1 : 0)))
    }
    let row = integer(1, 7) + integer(2, viewState) + bytes(10, items)
    return service(4, integer(1, 0) + bytes(2, integer(1, composition) + integer(2, 1) + integer(3, 1) + bytes(4, row)))
}
private func fragment(id: UInt16, offset: UInt32, total: UInt32, data: Data) -> Data {
    var writer = GFDIWriter(); writer.u16(id); writer.u32(offset); writer.u32(total); writer.u32(UInt32(data.count)); writer.data(data)
    return Data(writer.bytes)
}

@MainActor
private final class CIQSessionFixture {
    let session = GFDISession(storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("WristBeam-ciq-tests"))
    var messages: [GFDIMessage] = []
    var choices: [GFDIWatchFaceOption] = []
    var status = ""
    var busy = false
    private var decoder = GFDIStreamDecoder()
    var requests: [GFDIMessage] { messages.filter { $0.number == 5043 } }
    init() {
        session.transportMode = .legacy; session.maximumWriteLength = 200
        session.onSend = { [weak self] data in
            guard let self else { return }
            for result in self.decoder.receive(data) { if let value = try? result.get() { self.messages.append(value) } }
        }
        session.onWatchFaces = { [weak self] in self?.choices = $0 }
        session.onWatchFaceStatus = { [weak self] text, busy in self?.status = text; self?.busy = busy }
        session.connected()
    }
    func ready() throws {
        var info = GFDIWriter(); info.u16(113); info.u16(123); info.u32(1234); info.u16(100); info.u16(4096)
        info.string("Watch"); info.string("Test"); info.string("Fixture")
        session.receive(try GFDIMessage(number: 5024, payload: Data(info.bytes)).framed())
        session.receive(try GFDIMessage(number: 5050, payload: Data([1, 8])).framed())
        session.receive(try GFDIMessage(number: 5050).response().framed())
    }
    func respond(_ data: Data) throws {
        var reader = GFDIReader(try XCTUnwrap(requests.last).payload)
        let id = try reader.u16()
        session.receive(try GFDIMessage(number: 5044, payload: fragment(id: id, offset: 0, total: UInt32(data.count), data: data)).framed())
    }
}

private func installedInventory() -> Data {
    let uuid = Data([0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff])
    let app = bytes(1, uuid) + integer(2, 3) + bytes(3, Data("CIQ Test".utf8)) + integer(4, 0) + integer(5, 74)
    return bytes(3, bytes(2, integer(1, 1024) + integer(2, 20) + bytes(3, app)))
}

extension ConnectIQProtocolTests {
    func testSettingsNeedPushAndStatusThenSaveReadbackBeforeSuccess() async throws {
        try await MainActor.run {
            let fixture = CIQSessionFixture()
            defer { fixture.session.disconnected() }
            fixture.session.setAccountGUID("00112233445566778899aabbccddeeff")
            try fixture.ready()
            fixture.session.refreshWatchFaces(expectedUnitID: 1234)
            try fixture.respond(installedInventory()); try fixture.respond(Data())
            let id = "00112233-4455-6677-8899-aabbccddeeff"
            let uuid = try GFDIConnectIQSDK.uuidBytes(id)
            let current = try GFDIMonkeyCodec.encode(.dictionary(["x": .int32(1)]))
            let desired = try GFDIMonkeyCodec.encode(.dictionary(["x": .int32(2)]))
            func response(_ saving: Bool) -> Data { bytes(4, bytes(saving ? 4 : 2, bytes(1, uuid) + integer(2, 1))) }
            @MainActor func push(_ data: Data, _ requestID: UInt16) throws {
                let body = bytes(4, bytes(5, bytes(1, uuid) + bytes(2, data)))
                fixture.session.receive(try GFDIMessage(number: 5043, payload: fragment(id: requestID, offset: 0, total: UInt32(body.count), data: body)).framed())
            }
            var result: Result<GFDIConnectIQSettingsSnapshot, Error>?
            fixture.session.startConnectIQSettings(appID: id, settingsData: nil, expectedUnitID: 1234, operationID: UUID()) { result = $0 }
            try fixture.respond(response(false))
            XCTAssertNil(result)
            try push(current, 100)
            XCTAssertEqual(try result?.get().rawData, current)
            XCTAssertEqual(try result?.get().savedAndVerified, false)
            result = nil
            fixture.session.startConnectIQSettings(appID: id, settingsData: desired, expectedUnitID: 1234, operationID: UUID()) { result = $0 }
            try push(current, 101) // Push may precede the Get response.
            XCTAssertNil(result)
            try fixture.respond(response(false)) // Fresh baseline unlocks Save.
            try fixture.respond(response(true)) // Save ACK alone is insufficient.
            XCTAssertNil(result)
            try fixture.respond(response(false)); try push(desired, 102)
            XCTAssertEqual(try result?.get().savedAndVerified, true)
            XCTAssertEqual(try result?.get().rawData, desired)
        }
    }

    func testSettingsAccountChangeCompletesPendingOperationExactlyOnce() async throws {
        try await MainActor.run {
            let fixture = CIQSessionFixture()
            fixture.session.setAccountGUID("00112233445566778899aabbccddeeff")
            try fixture.ready()
            fixture.session.refreshWatchFaces(expectedUnitID: 1234)
            try fixture.respond(installedInventory()); try fixture.respond(Data())
            var calls = 0
            fixture.session.startConnectIQSettings(appID: "00112233-4455-6677-8899-aabbccddeeff", settingsData: nil,
                expectedUnitID: 1234, operationID: UUID()) { result in
                calls += 1
                if case .success = result { XCTFail("Changed account cannot complete settings") }
            }
            fixture.session.setAccountGUID("11112233445566778899aabbccddeeff")
            fixture.session.disconnected()
            XCTAssertEqual(calls, 1)
            XCTAssertFalse(fixture.session.connectIQSettingsBusy)
        }
    }
}
