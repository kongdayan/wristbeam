import Foundation
import XCTest
@testable import GarminBar

final class ReliabilityTests: XCTestCase {
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
