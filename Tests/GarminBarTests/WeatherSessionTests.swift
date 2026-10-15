import Foundation
import XCTest
@testable import GarminBar

final class WeatherSessionTests: XCTestCase {
    @MainActor func testDisabledWeatherIsNotAdvertisedAndDoesNotInvokeProvider() throws {
        let fixture = try WeatherSessionFixture()
        defer { fixture.session.weatherProvider = nil; fixture.session.disconnected() }
        let configuration = try XCTUnwrap(fixture.messages.first { $0.number == 5050 })
        XCTAssertFalse(fixture.hasCapability(26, in: configuration))
        XCTAssertFalse(fixture.hasCapability(27, in: configuration))
        var calls = 0
        fixture.session.weatherProvider = { _ in calls += 1; return fixture.snapshot }
        fixture.session.receive(try fixture.weatherRequest.framed())
        let reply = try XCTUnwrap(fixture.messages.last)
        XCTAssertEqual(reply, fixture.weatherRequest.response(status: 2))
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(fixture.session.sendWeather(fixture.snapshot))
        XCTAssertTrue(fixture.weatherMessages.isEmpty)
    }

    @MainActor func testWeatherCapabilitiesFollowExplicitEnableAndDisableDuringConnection() throws {
        let fixture = try WeatherSessionFixture(enabled: true)
        defer { fixture.session.disconnected() }
        let first = try XCTUnwrap(fixture.messages.first { $0.number == 5050 })
        XCTAssertTrue(fixture.hasCapability(26, in: first))
        XCTAssertTrue(fixture.hasCapability(27, in: first))
        fixture.session.configureWeather(enabled: false)
        fixture.session.tick(now: Date())
        let disabled = try XCTUnwrap(fixture.messages.last { $0.number == 5050 })
        XCTAssertFalse(fixture.hasCapability(26, in: disabled))
        XCTAssertFalse(fixture.hasCapability(27, in: disabled))
        fixture.session.receive(try disabled.response().framed())
        fixture.session.configureWeather(enabled: true)
        fixture.session.tick(now: Date())
        let enabled = try XCTUnwrap(fixture.messages.last { $0.number == 5050 })
        XCTAssertTrue(fixture.hasCapability(26, in: enabled))
        XCTAssertTrue(fixture.hasCapability(27, in: enabled))
        for flag in [0, 3, 4, 71] { XCTAssertTrue(fixture.hasCapability(flag, in: enabled)) }
    }

    @MainActor func testIncomingRequestAcknowledgesBeforeFetchAndCoalescesRetransmission() async throws {
        let fixture = try WeatherSessionFixture(enabled: true)
        defer { fixture.session.weatherProvider = nil; fixture.session.disconnected() }
        let definition = expectation(description: "Provider result begins FIT definition")
        var calls = 0
        fixture.session.weatherProvider = { request in
            calls += 1
            XCTAssertEqual(request.forecastHours, 2)
            XCTAssertTrue(fixture.messages.contains(fixture.weatherRequest.response(payload: Data([128, 2, 44, 1]))))
            return fixture.snapshot
        }
        fixture.session.onDiagnosticMessage = { message, direction in
            if direction == .macQueued, message.number == 5011 { definition.fulfill() }
        }
        fixture.session.receive(try fixture.weatherRequest.framed())
        fixture.session.receive(try fixture.weatherRequest.framed())
        XCTAssertTrue(fixture.weatherMessages.isEmpty) // Provider runs asynchronously, ACK is immediate.
        await fulfillment(of: [definition], timeout: 2)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(fixture.weatherMessages.map(\.number), [5011])
        XCTAssertEqual(fixture.messages.filter { $0 == fixture.weatherRequest.response(payload: Data([128, 2, 44, 1])) }.count, 2)
    }

    @MainActor func testMalformedRequestIsRejectedWithoutStartingProvider() throws {
        let fixture = try WeatherSessionFixture(enabled: true)
        defer { fixture.session.weatherProvider = nil; fixture.session.disconnected() }
        var calls = 0
        fixture.session.weatherProvider = { _ in calls += 1; return fixture.snapshot }
        for payload in [Data(), Data(repeating: 0, count: 9), Data([1] + Array(repeating: 0, count: 9))] {
            let request = GFDIMessage(number: 5014, payload: payload, sequence: 31)
            fixture.session.receive(try request.framed())
            XCTAssertEqual(fixture.messages.last, request.response(status: 5))
        }
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(fixture.weatherMessages.isEmpty)
    }

    @MainActor func testEveryDefinitionAndDataRecordWaitsForItsFITStatusAcknowledgement() throws {
        let fixture = try WeatherSessionFixture(enabled: true)
        defer { fixture.session.disconnected() }
        let expected = GFDIWeather.frames(snapshot: fixture.snapshot, forecastHours: 2)
        var outcomes: [Bool] = []
        fixture.session.onWeatherDelivery = { outcomes.append($0) }
        XCTAssertTrue(fixture.session.sendWeather(fixture.snapshot, forecastHours: 2))
        XCTAssertEqual(fixture.weatherMessages, [expected[0]])
        XCTAssertFalse(fixture.session.sendWeather(fixture.snapshot))
        for index in expected.indices {
            XCTAssertEqual(fixture.weatherMessages, Array(expected.prefix(index + 1)))
            XCTAssertTrue(outcomes.isEmpty)
            fixture.session.receive(try expected[index].response(payload: Data([0])).framed())
        }
        XCTAssertEqual(fixture.weatherMessages, expected)
        XCTAssertEqual(outcomes, [true])
        XCTAssertTrue(fixture.session.sendWeather(fixture.snapshot, forecastHours: 0))
    }

    @MainActor func testOuterFailureMissingFITStatusAndFITRejectionAbortWithoutSendingData() throws {
        for reply in [GFDIMessage(number: 5011).response(status: 2),
                      GFDIMessage(number: 5011).response(),
                      GFDIMessage(number: 5011).response(payload: Data([1]))] {
            let fixture = try WeatherSessionFixture(enabled: true)
            defer { fixture.session.disconnected() }
            var outcomes: [Bool] = []
            fixture.session.onWeatherDelivery = { outcomes.append($0) }
            XCTAssertTrue(fixture.session.sendWeather(fixture.snapshot))
            fixture.session.receive(try reply.framed())
            XCTAssertEqual(fixture.weatherMessages.map(\.number), [5011])
            XCTAssertEqual(outcomes, [false])
            XCTAssertTrue(fixture.session.sendWeather(fixture.snapshot)) // Failure releases queue.
        }
    }

    @MainActor func testFITTimeoutRetriesOnceThenReportsFailure() throws {
        let fixture = try WeatherSessionFixture(enabled: true)
        defer { fixture.session.disconnected() }
        var outcomes: [Bool] = []
        fixture.session.onWeatherDelivery = { outcomes.append($0) }
        XCTAssertTrue(fixture.session.sendWeather(fixture.snapshot))
        let now = Date()
        fixture.session.tick(now: now.addingTimeInterval(11))
        XCTAssertEqual(fixture.weatherMessages.map(\.number), [5011, 5011])
        XCTAssertTrue(outcomes.isEmpty)
        fixture.session.tick(now: now.addingTimeInterval(22))
        XCTAssertEqual(fixture.weatherMessages.map(\.number), [5011, 5011])
        XCTAssertEqual(outcomes, [false])
    }

    @MainActor func testDisablingCancelsPendingFITAndIgnoresItsLateAcknowledgement() throws {
        let fixture = try WeatherSessionFixture(enabled: true)
        defer { fixture.session.disconnected() }
        var outcomes: [Bool] = []
        fixture.session.onWeatherDelivery = { outcomes.append($0) }
        XCTAssertTrue(fixture.session.sendWeather(fixture.snapshot))
        let oldDefinition = try XCTUnwrap(fixture.weatherMessages.last)
        fixture.session.configureWeather(enabled: false)
        fixture.session.receive(try oldDefinition.response(payload: Data([0])).framed())
        XCTAssertEqual(fixture.weatherMessages.map(\.number), [5011])
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertFalse(fixture.session.sendWeather(fixture.snapshot))
        fixture.session.configureWeather(enabled: true)
        XCTAssertTrue(fixture.session.sendWeather(fixture.snapshot))
        XCTAssertEqual(fixture.weatherMessages.map(\.number), [5011, 5011])
    }

    @MainActor func testDisconnectedFITDoesNotContinueAfterReconnect() throws {
        let fixture = try WeatherSessionFixture(enabled: true)
        defer { fixture.session.disconnected() }
        XCTAssertTrue(fixture.session.sendWeather(fixture.snapshot))
        fixture.session.disconnected()
        fixture.session.connected()
        try fixture.handshake()
        XCTAssertTrue(fixture.session.isReady)
        XCTAssertTrue(fixture.session.sendWeather(fixture.snapshot))
        XCTAssertEqual(fixture.weatherMessages.map(\.number), [5011, 5011])
    }

    @MainActor func testCancelledPendingFrameDrainsWithoutRetryAndReservesMessageIDUntilDeadline() throws {
        let fixture = try WeatherSessionFixture(enabled: true)
        defer { fixture.session.disconnected() }
        var outcomes: [Bool] = []
        fixture.session.onWeatherDelivery = { outcomes.append($0) }
        XCTAssertTrue(fixture.session.sendWeather(fixture.snapshot))
        fixture.session.configureWeather(enabled: false)
        fixture.session.configureWeather(enabled: true)
        // The old message ID remains reserved until its ACK or deadline; otherwise a late ACK
        // could incorrectly advance an unrelated new definition with the same GFDI message ID.
        XCTAssertFalse(fixture.session.sendWeather(fixture.snapshot))
        fixture.session.tick(now: Date().addingTimeInterval(11))
        XCTAssertEqual(fixture.weatherMessages.map(\.number), [5011])
        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertTrue(fixture.session.sendWeather(fixture.snapshot))
        XCTAssertEqual(fixture.weatherMessages.map(\.number), [5011, 5011])
    }

    @MainActor func testCancelledProviderCannotSendAfterDisableOrReconnect() async throws {
        for disconnect in [false, true] {
            let fixture = try WeatherSessionFixture(enabled: true)
            defer { fixture.session.weatherProvider = nil; fixture.session.disconnected() }
            let started = expectation(description: "Provider started")
            let returned = expectation(description: "Cancellation-insensitive provider returned")
            let unwanted = expectation(description: "Stale provider must not send FIT or delivery result")
            unwanted.isInverted = true
            var continuation: CheckedContinuation<WatchWeatherSnapshot, Error>?
            fixture.session.weatherProvider = { _ in
                let value = try await withCheckedThrowingContinuation { continuation = $0; started.fulfill() }
                returned.fulfill()
                return value
            }
            fixture.session.receive(try fixture.weatherRequest.framed())
            await fulfillment(of: [started], timeout: 2)
            fixture.session.onWeatherDelivery = { _ in unwanted.fulfill() }
            fixture.session.onDiagnosticMessage = { message, direction in
                if direction == .macQueued, [UInt16(5011), 5012].contains(message.number) { unwanted.fulfill() }
            }
            if disconnect {
                fixture.session.disconnected()
                fixture.session.connected()
                try fixture.handshake()
            } else {
                fixture.session.configureWeather(enabled: false)
                fixture.session.configureWeather(enabled: true)
            }
            try XCTUnwrap(continuation).resume(returning: fixture.snapshot)
            await fulfillment(of: [returned, unwanted], timeout: 1)
            XCTAssertTrue(fixture.weatherMessages.isEmpty)
            fixture.session.onDiagnosticMessage = nil
            XCTAssertTrue(fixture.session.sendWeather(fixture.snapshot))
        }
    }
}

@MainActor
private final class WeatherSessionFixture {
    let session: GFDISession
    var messages: [GFDIMessage] = []
    private var decoder = GFDIStreamDecoder()
    let weatherRequest = GFDIMessage(number: 5014, payload: Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 2]), sequence: 7)
    let snapshot: WatchWeatherSnapshot
    var weatherMessages: [GFDIMessage] { messages.filter { $0.number == 5011 || $0.number == 5012 } }

    init(enabled: Bool = false) throws {
        let date = Date(timeIntervalSince1970: 631_066_600)
        snapshot = WatchWeatherSnapshot(location: .init(name: "Fixture City", latitude: 45, longitude: -90), fetchedAt: date,
                                        current: .init(timestamp: date, temperatureC: 20),
                                        hourly: [.init(timestamp: date.addingTimeInterval(3600), temperatureC: 21)],
                                        daily: [.init(timestamp: date, highC: 25, lowC: 15, dayOfWeek: 1)])
        session = GFDISession(storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("WristBeam-weather-test-\(UUID().uuidString)"))
        session.transportMode = .legacy
        session.maximumWriteLength = 23 // Exercise BLE fragmentation, including FIT definitions.
        session.configureWeather(enabled: enabled)
        session.onSend = { [weak self] bytes in
            guard let self else { return }
            for result in self.decoder.receive(bytes) {
                if let message = try? result.get() { self.messages.append(message) }
            }
        }
        session.connected()
        try handshake()
    }

    func handshake() throws {
        var info = GFDIWriter()
        info.u16(113); info.u16(123); info.u32(1234); info.u16(100); info.u16(4096)
        info.string("Fixture"); info.string("Watch"); info.string("Weather")
        session.receive(try GFDIMessage(number: 5024, payload: Data(info.bytes)).framed())
        session.receive(try GFDIMessage(number: 5050, payload: Data([1, 0x18])).framed())
        session.receive(try GFDIMessage(number: 5050).response().framed())
        session.receive(try GFDIMessage(number: 5030).response(payload: Data([0])).framed())
        XCTAssertTrue(session.isReady)
    }

    func hasCapability(_ flag: Int, in message: GFDIMessage) -> Bool {
        let bitmap = Array(message.payload.dropFirst())
        return flag / 8 < bitmap.count && bitmap[flag / 8] & (1 << (flag % 8)) != 0
    }
}
