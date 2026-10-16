import Foundation
import XCTest
@testable import GarminBar

final class ReliabilityTests: XCTestCase {
    func testHistoricalIndexInvalidatesAndMeasuresWarmQueries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let day = GarminHRV.date("2026-01-02")!, now = day.addingTimeInterval(86400 * 2)
        let file = root.appendingPathComponent("2026-01-02.jsonl"), encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var bytes = Data()
        for offset in 0..<10_000 {
            bytes += try encoder.encode(MetricSample(kind: .heartRate, value: 70 + offset % 20,
                source: "fixture", timestamp: day.addingTimeInterval(Double(offset)), origin: .watch)) + Data([10])
        }
        try GarminPrivateFile.write(bytes, to: file)
        let reader = HealthHistoryReader(telemetry: root), start = Date()
        let cold = reader.read(day: day, now: now), coldSeconds = Date().timeIntervalSince(start)
        let warmStart = Date(), warm = reader.read(day: day, now: now)
        let warmSeconds = Date().timeIntervalSince(warmStart)
        XCTAssertFalse(cold.usedIndex); XCTAssertTrue(warm.usedIndex)
        XCTAssertEqual(cold.series[.heartRate]?.points, warm.series[.heartRate]?.points)
        bytes += try encoder.encode(MetricSample(kind: .heartRate, value: 100, source: "fixture", timestamp: day.addingTimeInterval(20_000))) + Data([10])
        try GarminPrivateFile.write(bytes, to: file)
        let changed = reader.read(day: day, now: now)
        XCTAssertFalse(changed.usedIndex); XCTAssertEqual(changed.series[.heartRate]?.latest?.value, 100)
        print("BENCH synthetic history: 10000 samples, coldSeconds=\(coldSeconds), warmSeconds=\(warmSeconds)")
    }
    func testSummaryDatesMissingDataAndCoverageAreExplicit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = GarminHRV.date("2026-01-10")!
        let snapshot = DeveloperQuerySnapshot(metrics: [:], freshness: [:], history: [:], reader: HealthHistoryReader(telemetry: root),
            activityIndex: .init(), statusValue: [:], observedAt: date, metadata: [:])
        let summary = try snapshot.healthSummary(["startDate": "2026-01-01", "endDate": "2026-01-02"])
        let days = summary["days"] as! [[String: Any]]
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual((days[0]["missingMetrics"] as? [String])?.count, 4)
        let rows = days[0]["metrics"] as! [[String: Any]]
        XCTAssertTrue(rows[0]["sampleMean"] is NSNull)
        XCTAssertEqual(rows[0]["observedMinuteCount"] as? Int, 0)
        XCTAssertThrowsError(try snapshot.healthSummary(["startDate": "2025-01-01", "endDate": "2026-01-01"]))
        XCTAssertThrowsError(try snapshot.healthSummary(["startDate": "2026-01-01", "endDate": "2027-01-01"]))
    }

    func testNamedCredentialsPersistAndRevokeIndependently() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeveloperClientStore(url: root.appendingPathComponent("clients.json"))
        let first = try DeveloperClientStore.create(name: "Coach", scopes: [.summary]), second = try DeveloperClientStore.create(name: "Dashboard", scopes: [.metrics])
        _ = try store.update { $0 = [first, second] }
        _ = try store.update { $0[0].revokedAt = Date(); $0[0].key = "" }
        let restored = try store.load()
        XCTAssertFalse(restored[0].enabled); XCTAssertEqual(restored[1].key, second.key)
        XCTAssertTrue(DeveloperProtocol.permits("summary", scopes: ["summary"]))
        XCTAssertFalse(DeveloperProtocol.permits("metrics", scopes: ["summary"]))
        let request = DeveloperRequest(method: "GET", target: "/api/v1/metrics", headers: ["host": "localhost", "authorization": "Bearer " + second.key], body: Data())
        var queried = false
        let response = DeveloperProtocol.route(request, token: second.key, allowedHosts: ["localhost"], origin: "http://localhost", scopes: ["status"]) { _, _ in queried = true; return [:] }
        XCTAssertEqual(response.status, 403); XCTAssertFalse(queried)
    }

    func testConnectionStagesAndWakeRespectManualDisconnect() {
        XCTAssertFalse(ConnectionStartupPolicy.canResume(activated: true, requested: false, automatic: true, connected: false, connecting: false))
        XCTAssertTrue(ConnectionStartupPolicy.canResume(activated: true, requested: true, automatic: true, connected: false, connecting: false))
        XCTAssertFalse(ConnectionStartupPolicy.canResume(activated: true, requested: true, automatic: false, connected: false, connecting: false))
        let now = Date()
        func stage(_ ready: Bool, _ last: Date?) -> WatchConnectionStage {
            WatchConnectionStage.resolve(access: .allowed, powered: true, scanning: false, discovered: true,
                connecting: false, connected: true, protocolReady: ready, lastSample: last, now: now)
        }
        XCTAssertEqual(stage(false, nil), .negotiating)
        XCTAssertEqual(stage(true, nil), .ready)
        XCTAssertEqual(stage(true, now), .receiving)
        XCTAssertEqual(stage(true, now.addingTimeInterval(-100)), .ready)
    }

    func testPixelSamplingKeepsPeaksGapsAndOriginalCursorValues() {
        let day = GarminHRV.date("2026-01-01")!
        var points = (0..<86_400).map { MetricSeriesPoint(timestamp: day.addingTimeInterval(Double($0)), value: Double($0 % 60)) }
        points[12345].value = 199
        points[40000].value = nil
        let source = MetricDaySeries(kind: .heartRate, day: day, points: points, source: "fixture", refreshedAt: day)
        let start = Date()
        let rendered = source.sampled(width: 300, domain: day...day.addingTimeInterval(86400))
        let renderingSeconds = Date().timeIntervalSince(start)
        let cursorStart = Date()
        for index in 0..<1000 { _ = source.reading(at: day.addingTimeInterval(Double(index * 80))) }
        print("BENCH synthetic chart: source=86400, rendered=\(rendered.points.count), samplingSeconds=\(renderingSeconds), cursor1000Seconds=\(Date().timeIntervalSince(cursorStart))")
        XCTAssertTrue(rendered.points.count < 4000)
        XCTAssertEqual(rendered.maximum, 199)
        XCTAssertEqual(rendered.minimum, 0)
        XCTAssertEqual(rendered.segments.count, source.segments.count)
        XCTAssertEqual(source.reading(at: day.addingTimeInterval(12345))?.value, 199)
        XCTAssertEqual(source.points.count, 86400)
    }
    func testOfflineColdQueryUsesJournalWithoutOpeningDashboard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let day = GarminHRV.date("2026-01-02")!, date = day.addingTimeInterval(3600)
        let sample = MetricSample(kind: .heartRate, value: 71, source: "Synthetic", timestamp: date, origin: .watch)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let file = root.appendingPathComponent("2026-01-02.jsonl")
        try GarminPrivateFile.write(encoder.encode(sample) + Data([10]), to: file)
        let reader = HealthHistoryReader(telemetry: root)
        let snapshot = DeveloperQuerySnapshot(metrics: [:], freshness: [:], history: [:], reader: reader,
            activityIndex: .init(), statusValue: [:], observedAt: day.addingTimeInterval(7200), metadata: [:])
        let response = try snapshot.query("series", arguments: ["metric": "heartRate", "date": "2026-01-02"]) as! [String: Any]
        XCTAssertEqual(response["total"] as? Int, 1)
        XCTAssertEqual((response["points"] as? [[String: Any]])?.first?["value"] as? Double, 71)
        var exported: [Double] = []
        try HealthHistoryReader.samples(file: file) { exported.append($0.value) }
        XCTAssertEqual(exported, [71])
        XCTAssertEqual(reader.read(day: day).series[.heartRate]?.latest?.value, 71)
    }

    func testMissingCorruptAndPartialHistoryAreDistinct() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let day = GarminHRV.date("2026-01-02")!, reader = HealthHistoryReader(telemetry: root)
        XCTAssertTrue(reader.read(day: day).issues.isEmpty)
        try GarminPrivateFile.write(Data("{incomplete".utf8), to: root.appendingPathComponent("2026-01-02.jsonl"))
        XCTAssertEqual(reader.read(day: day).issues, ["invalidTelemetryRecord"])
        let store = MetricSeriesStore(accountGUID: "fixture", root: root.appendingPathComponent("charts"))
        try store.saveChecked([:], day: day)
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("charts"), includingPropertiesForKeys: nil)!
        let chart = (files.allObjects as! [URL]).first { $0.pathExtension == "json" }!
        try Data("bad".utf8).write(to: chart)
        XCTAssertThrowsError(try store.loadChecked(day: day))
        XCTAssertTrue(HealthHistoryReader(telemetry: root, charts: store).read(day: day).issues.contains("chartReadFailed"))
    }

    func testVersionedChartStoreReadsLegacyWithoutRemovingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let day = GarminHRV.date("2026-01-02")!, store = MetricSeriesStore(accountGUID: "fixture", root: root)
        let value = MetricDaySeries(kind: .heartRate, day: day, points: [.init(timestamp: day, value: 70)], source: "fixture", refreshedAt: day)
        try store.saveChecked([.heartRate: value], day: day)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        let file = (files.allObjects as! [URL]).first { $0.pathExtension == "json" }!
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([value]).write(to: file)
        XCTAssertEqual(try store.loadChecked(day: day)[.heartRate]?.latest?.value, 70)
        try store.saveChecked([.heartRate: value], day: day)
        let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual(envelope["schemaVersion"] as? Int, 1)
    }

    func testOldCloudHeartRateAndOldNightCannotClaimCurrentState() {
        let now = GarminHRV.date("2026-01-10")!.addingTimeInterval(43200)
        let old = MetricSample(kind: .heartRate, value: 70, source: "fixture", timestamp: now.addingTimeInterval(-3600), origin: .cloud)
        let freshSync = MetricFreshness.evaluate(old, now: now, connected: true, syncedAt: now)
        XCTAssertTrue(freshSync.stale); XCTAssertFalse(freshSync.suitableForCurrentState)
        XCTAssertEqual(freshSync.ageSeconds, 3600)
        let night = MetricSample(kind: .hrvNight, value: 55, source: "fixture", timestamp: now.addingTimeInterval(-86400 * 3), origin: .cloud)
        XCTAssertTrue(MetricFreshness.evaluate(night, now: now, connected: true).stale)
        let recentNight = MetricSample(kind: .hrvNight, value: 55, source: "fixture", timestamp: now.addingTimeInterval(-86400), origin: .cloud)
        let timing = MetricFreshness.evaluate(recentNight, now: now, connected: true)
        XCTAssertFalse(timing.stale); XCTAssertFalse(timing.suitableForCurrentState)
    }

    func testRecentRefreshPreservesHistoryAndAccountsForInsertedHead() {
        func row(_ id: Int) -> GarminActivity { .init(id: String(id), name: "fixture", type: "run", statistics: [:], fetchedAt: Date()) }
        var index = GarminActivityIndex()
        index.mergePage([row(10), row(9)], offset: 0, older: false)
        index.mergePage([row(8), row(7)], offset: 2, older: true)
        index.mergePage([], offset: 4, older: true)
        index.mergePage([row(11), row(10)], offset: 0, older: false)
        XCTAssertEqual(index.nextOffset, 5); XCTAssertTrue(index.reachedEnd)
        XCTAssertEqual(index.historyAnchorID, "7")
        index.mergePage([row(20), row(19)], offset: 0, older: false)
        XCTAssertEqual(index.needsHistoryRebase, true); XCTAssertFalse(index.reachedEnd)
    }

    func testActivityListingDoesNotDecodeDetails() throws {
        let index = GarminActivityIndex(activities: [.init(id: "10", name: "fixture", type: "run", statistics: [:], fetchedAt: Date())])
        var decodes = 0
        let result = try ActivityQueries.query("activities", arguments: [:], index: index,
            detail: { _ in decodes += 1; return nil }, formats: { _ in [] }, hasDetail: { _ in true })
        XCTAssertEqual(decodes, 0)
        XCTAssertEqual((result["activities"] as? [[String: Any]])?.first?["detailCached"] as? Bool, true)
    }

    func testJournalReportsFailureAndRecoversBufferedSample() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("blocked directory".utf8).write(to: root)
        let failed = expectation(description: "storage failure"), saved = expectation(description: "buffer recovered")
        let journal = TelemetryJournal(directory: root)
        journal.onEvent = { event in
            switch event { case .failed: failed.fulfill(); case .saved: saved.fulfill() }
        }
        journal.append(.init(kind: .heartRate, value: 72, source: "fixture", origin: .watch))
        await fulfillment(of: [failed], timeout: 2)
        try FileManager.default.removeItem(at: root)
        journal.retry()
        await fulfillment(of: [saved], timeout: 5)
        XCTAssertEqual(HealthHistoryReader(telemetry: root).read(day: Date()).series[.heartRate]?.latest?.value, 72)
    }
}
