import XCTest
@testable import GarminBar

final class DashboardSharingTests: XCTestCase {
    private func metric(_ kind: MetricKind) -> SharedMetric {
        SharedMetric(kind: kind, value: "42", updatedAt: Date(), unavailable: false,
                     series: MetricDaySeries(kind: kind, day: Date(), points: [], source: "private", refreshedAt: Date()))
    }
    func testSelectionKeepsDashboardOrderAndExcludesOtherMetrics() {
        let metrics = [metric(.steps), metric(.heartRate), metric(.stress), metric(.steps)]
        XCTAssertEqual(DashboardSharing.selected(metrics, ids: [.heartRate, .steps], valueOnly: false).map(\.kind), [.steps, .heartRate])
        XCTAssertTrue(DashboardSharing.selected(metrics, ids: [], valueOnly: false).isEmpty)
        XCTAssertTrue(DashboardSharing.selected(metrics, ids: [.solarIntensity], valueOnly: false).isEmpty)
    }
    func testValueOnlySharesOneValueWithoutItsDayHistory() {
        let selected = DashboardSharing.selected([metric(.steps), metric(.stress)], ids: [.steps, .stress], valueOnly: true)
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.kind, .steps)
        XCTAssertNil(selected.first?.series)
    }
    func testExportStripsSourceAndPointAnnotationsButKeepsGaps() {
        let date = Date()
        let series = MetricDaySeries(kind: .heartRate, day: date, points: [
            MetricSeriesPoint(timestamp: date, value: 60, label: "private label"),
            MetricSeriesPoint(timestamp: date.addingTimeInterval(60), value: nil, unavailable: "private diagnostic")
        ], source: "private device identifier", refreshedAt: date)
        let sanitized = DashboardSharing.sanitizedSeries(series)
        XCTAssertEqual(sanitized?.source, "")
        XCTAssertNil(sanitized?.points.first?.label)
        XCTAssertNil(sanitized?.points.last?.unavailable)
        XCTAssertNil(sanitized?.points.last?.value)
        XCTAssertEqual(sanitized?.points.first?.value, 60)
        XCTAssertEqual(sanitized?.points.count, 2)
        XCTAssertNil(DashboardSharing.sanitizedSeries(nil))
    }
    func testEssentialsNeverInventUnsupportedCapabilities() {
        XCTAssertEqual(DashboardSharing.basicMetrics.intersection([.heartRate, .steps, .watchBattery]), [.heartRate, .steps])
        XCTAssertEqual(DashboardSharing.selected([metric(.watchBattery), metric(.steps)], ids: [.watchBattery, .steps], valueOnly: false).map(\.kind), [.steps])
    }
}
