import Foundation
import XCTest
@testable import GarminBar

final class ExperienceTests: XCTestCase {
    func testColumnsFitNarrowWindowAndLargeTextWithoutOverridingPreference() {
        XCTAssertEqual(MetricLayout.columnCount(width: 560, minimum: 220, preferred: 4), 2)
        XCTAssertEqual(MetricLayout.columnCount(width: 560, minimum: 220 * 1.6, preferred: 4), 1)
        XCTAssertEqual(MetricLayout.columnCount(width: 1200, minimum: 220, preferred: 2), 2)
        XCTAssertEqual(MetricLayout.columnCount(width: 1200, minimum: 220, preferred: 0), 4)
        XCTAssertEqual(MetricLayout.columnCount(width: 100, minimum: 220, preferred: 4), 1)
        XCTAssertEqual(MetricLayout.columnCount(width: .nan, minimum: 220, preferred: 4), 1)
        XCTAssertEqual(MetricLayout.columnCount(width: Double.greatestFiniteMagnitude, minimum: 1, preferred: 0), 4)
    }
    func testInventoryIncludesOnlyRegularManagedDownloadsAndLeavesIndexAndOriginalsAlone() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        for name in ["1001.json", "1001.tcx", "1002.gpx", "1003.zip", "index.json", "original.fit", "credentials.json", "0.json", "1001.extra.zip", ".1004.zip"] {
            try Data("synthetic".utf8).write(to: root.appendingPathComponent(name))
        }
        try manager.createDirectory(at: root.appendingPathComponent("1005.json"), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: root.appendingPathComponent("1006.zip"), withDestinationURL: root.appendingPathComponent("original.fit"))
        let downloads = ActivityDownload.inventory(in: root)
        XCTAssertEqual(Set(downloads.map(\.filename)), ["1001.json", "1001.tcx", "1002.gpx", "1003.zip"])
        XCTAssertEqual(downloads.reduce(0) { $0 + $1.bytes }, 36)
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent("index.json").path))
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent("original.fit").path))
        for name in ["../1001.zip", "1001/other.zip", "1001.JSON", "-1.zip", "1001.zip/", "1001..json"] {
            XCTAssertFalse(ActivityDownload.isManagedFilename(name))
        }
        let redirected = root.appendingPathComponent("redirect")
        try manager.createSymbolicLink(at: redirected, withDestinationURL: root)
        XCTAssertTrue(ActivityDownload.inventory(in: redirected).isEmpty)
        XCTAssertThrowsError(try downloads[0].checkedFile(in: redirected))
        let link = ActivityDownload(filename: "1006.zip", activityID: "1006", fileExtension: "zip", bytes: 0, modifiedAt: nil)
        XCTAssertThrowsError(try link.checkedFile(in: root))
    }
    func testDownloadedCopyCanBeRestoredFromTrashWithoutTouchingOriginalOrIndex() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var trashed: URL?
        defer {
            if let trashed { try? manager.removeItem(at: trashed) }
            try? manager.removeItem(at: root)
        }
        let data = Data("synthetic cache copy".utf8)
        let cached = root.appendingPathComponent("1001.tcx")
        let original = root.appendingPathComponent("original.fit"), index = root.appendingPathComponent("index.json")
        try data.write(to: cached); try data.write(to: original); try data.write(to: index)
        let download = try XCTUnwrap(ActivityDownload.inventory(in: root).first)
        let trash = try download.moveToTrash(in: root); trashed = trash
        XCTAssertFalse(manager.fileExists(atPath: cached.path))
        XCTAssertEqual(try Data(contentsOf: original), data)
        XCTAssertEqual(try Data(contentsOf: index), data)
        try manager.moveItem(at: trash, to: cached); trashed = nil
        XCTAssertEqual(try Data(contentsOf: cached), data)
    }
    func testWorkoutPresentationKeepsLocalWallTimeAndUsesSportSpecificSymbols() {
        let original = L10n.language; defer { L10n.language = original }
        L10n.language = .en
        let workout = GarminActivity(id: "1001", name: "Synthetic", type: "badminton", startTimeLocal: "2026-01-02 10:00:00", statistics: [:], fetchedAt: Date())
        XCTAssertEqual(workout.displayType, "Badminton")
        XCTAssertEqual(workout.displaySymbol, "figure.badminton")
        XCTAssertTrue(workout.displayStartTime.contains("10:00"))
    }
}
