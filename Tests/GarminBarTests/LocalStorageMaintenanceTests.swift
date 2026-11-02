import Foundation
import XCTest
@testable import GarminBar

final class LocalStorageMaintenanceTests: XCTestCase {
    private let owner = "fixture-account"
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        return url
    }
    private func job(root:URL,state:GarminUploadState = .accepted,code:Int = 201,account:String = "fixture-account") throws -> GarminUploadJob {
        let bytes = Data("synthetic FIT bytes; no real device data".utf8)
        var identity = Data("1234:\(GarminDataType.activity.rawValue):".utf8); identity.append(bytes)
        let name = GarminPrivateFile.digest(identity)+".fit"
        try GarminPrivateFile.write(bytes,to:root.appendingPathComponent("UploadQueue/OriginalFIT/"+name))
        return GarminUploadJob(id:UUID().uuidString,fileName:name,originalName:"fixture.fit",deviceID:"1234",dataType:.activity,
            accountGUID:account,createdAt:Date(),updatedAt:Date(),state:state,detail:"fixture",attempts:1,nextAttempt:nil,
            cloudStatus:.init(fileName:name,state:state,detail:"fixture",httpStatus:code),region:.china)
    }
    private func ledger(_ jobs:[GarminUploadJob],root:URL) throws {
        try GarminPrivateFile.write(JSONEncoder().encode(jobs),to:root.appendingPathComponent("UploadQueue/upload-queue.json"))
    }
    func testOnlyFinalMatchingCloudReceiptsQualify() throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at:r) }
        XCTAssertTrue(LocalStorageMaintenance.confirmed(try job(root:r)))
        XCTAssertTrue(LocalStorageMaintenance.confirmed(try job(root:r,state:.duplicate,code:409)))
        for (state,code) in [(GarminUploadState.processing,202),(.empty,204),(.failed,500),(.accepted,202),(.pending,201)] {
            XCTAssertFalse(LocalStorageMaintenance.confirmed(try job(root:r,state:state,code:code)))
        }
        var mismatch = try job(root:r); mismatch.cloudStatus?.state = .processing
        XCTAssertFalse(LocalStorageMaintenance.confirmed(mismatch))
        mismatch.cloudStatus = .init(fileName:"different.fit",state:.accepted,detail:"fixture",httpStatus:201)
        XCTAssertFalse(LocalStorageMaintenance.confirmed(mismatch))
    }
    func testPendingAndOtherAccountReferencesProtectSharedCopies() throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at:r) }
        let a = try job(root:r), b = try job(root:r,state:.pending,code:0)
        try ledger([a,b],root:r)
        XCTAssertTrue(try LocalStorageMaintenance.inspect(root:r,region:.china,account:owner).fitFiles.isEmpty)
        let other = try job(root:r,account:"other-account")
        try ledger([a,other],root:r)
        XCTAssertTrue(try LocalStorageMaintenance.inspect(root:r,region:.china,account:owner).fitFiles.isEmpty)
        try ledger([a],root:r)
        XCTAssertTrue(try LocalStorageMaintenance.inspect(root:r,region:.global,account:owner).fitFiles.isEmpty)
        XCTAssertTrue(try LocalStorageMaintenance.inspect(root:r,region:.china,account:"").fitFiles.isEmpty)
    }
    func testConfirmedCopiesMoveTogetherAndLedgerIsKept() throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at:r) }
        let a = try job(root:r); try ledger([a],root:r)
        let original = r.appendingPathComponent("UploadQueue/OriginalFIT/"+a.fileName)
        let received = r.appendingPathComponent("Received/1234/fixture.fit")
        try GarminPrivateFile.write(Data(contentsOf:original),to:received)
        let receipt = r.appendingPathComponent("Received/1234/fixture.json")
        try GarminPrivateFile.write(Data("immutable receipt".utf8),to:receipt)
        let plan = try LocalStorageMaintenance.inspect(root:r,region:.china,account:owner)
        XCTAssertEqual(plan.fitFiles.count,2)
        let before = try Data(contentsOf:r.appendingPathComponent("UploadQueue/upload-queue.json"))
        let trash = r.appendingPathComponent("test-trash")
        let result = try LocalStorageMaintenance.execute(plan,removeFIT:true,compactLogs:false) { try FileManager.default.moveItem(at:$0,to:trash) }
        XCTAssertEqual(result.originals,2)
        XCTAssertFalse(FileManager.default.fileExists(atPath:original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:received.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:receipt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:trash.appendingPathComponent("Originals/Received/1234/fixture.fit").path))
        XCTAssertEqual(try Data(contentsOf:r.appendingPathComponent("UploadQueue/upload-queue.json")),before)
    }
    func testChangedLedgerOrFileAbortsBeforeMovingAnything() throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at:r) }
        let a = try job(root:r); try ledger([a],root:r)
        let plan = try LocalStorageMaintenance.inspect(root:r,region:.china,account:owner)
        try ledger([a,a],root:r)
        XCTAssertThrowsError(try LocalStorageMaintenance.execute(plan,removeFIT:true,compactLogs:false) { _ in XCTFail("Unexpected trash") })
        try ledger([a],root:r)
        let file = r.appendingPathComponent("UploadQueue/OriginalFIT/"+a.fileName)
        try Data("changed".utf8).write(to:file)
        XCTAssertThrowsError(try LocalStorageMaintenance.execute(plan,removeFIT:true,compactLogs:false) { _ in XCTFail("Unexpected trash") })
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
    }
    func testTrashFailureRollsBackAllOriginals() throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at:r) }
        let a = try job(root:r); try ledger([a],root:r)
        let plan = try LocalStorageMaintenance.inspect(root:r,region:.china,account:owner)
        let file = plan.fitFiles[0].url, before = try Data(contentsOf:file)
        XCTAssertThrowsError(try LocalStorageMaintenance.execute(plan,removeFIT:true,compactLogs:false) { _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertEqual(try Data(contentsOf:file),before)
    }
    func testCompactionPreservesWatchHistoryAndOriginalBackup() throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at:r) }
        let day = GarminHRV.date("2020-01-02")!, file = r.appendingPathComponent("Telemetry/2020-01-02.jsonl")
        let text = """
        {"kind":"heartRate","value":70,"timestamp":"2020-01-02T01:00:00Z","origin":"watch"}
        {"kind":"heartRate","value":70,"timestamp":"2020-01-02T01:00:01Z","origin":"watch"}
        {"kind":"heartRate","value":70,"timestamp":"2020-01-02T01:00:01Z","origin":"watch","id":"another-id"}
        {"kind":"bodyBattery","value":60,"timestamp":"2020-01-02T01:00:00Z","origin":"cloud"}
        {"kind":"bodyBattery","value":60,"timestamp":"2020-01-02T01:01:00Z","origin":"cloud"}
        {"kind":"sunlightMinutes","value":2,"timestamp":"2020-01-02T01:00:00Z","origin":"estimated"}
        preserve this unknown line
        """ + "\n"
        try GarminPrivateFile.write(Data(text.utf8),to:file)
        let before = HealthHistoryReader(telemetry:r.appendingPathComponent("Telemetry")).read(day:day).series[.heartRate]?.points
        let plan = try LocalStorageMaintenance.inspect(root:r,region:.china,account:owner)
        XCTAssertEqual(plan.journals.count,1); XCTAssertEqual(plan.journals[0].discarded,4)
        let trash = r.appendingPathComponent("test-trash")
        _ = try LocalStorageMaintenance.execute(plan,removeFIT:false,compactLogs:true) { try FileManager.default.moveItem(at:$0,to:trash) }
        let after = HealthHistoryReader(telemetry:r.appendingPathComponent("Telemetry")).read(day:day).series[.heartRate]?.points
        XCTAssertEqual(after,before)
        let result = try String(contentsOf:file)
        XCTAssertTrue(result.contains("01:00:00Z")); XCTAssertTrue(result.contains("01:00:01Z"))
        XCTAssertTrue(result.contains("preserve this unknown line")); XCTAssertFalse(result.contains("cloud"))
        XCTAssertEqual(try String(contentsOf:trash.appendingPathComponent("Originals/Telemetry/2020-01-02.jsonl")),text)
    }
    func testTodayAndSymlinkedFilesAreProtected() throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at:r) }
        let now = Date(), file = r.appendingPathComponent("Telemetry/"+GarminHealthMetrics.calendarDate(now)+".jsonl")
        try GarminPrivateFile.write(Data("{\"kind\":\"heartRate\",\"value\":70,\"timestamp\":\"2020-01-02T01:00:00Z\",\"origin\":\"cloud\"}\n".utf8),to:file)
        XCTAssertTrue(try LocalStorageMaintenance.inspect(root:r,region:.china,account:owner,now:now).journals.isEmpty)
        let a = try job(root:r);try ledger([a],root:r)
        let raw = r.appendingPathComponent("UploadQueue/OriginalFIT/"+a.fileName)
        let external = r.appendingPathComponent("external.fit");try FileManager.default.moveItem(at:raw,to:external)
        try FileManager.default.createSymbolicLink(at:raw,withDestinationURL:external)
        XCTAssertTrue(try LocalStorageMaintenance.inspect(root:r,region:.china,account:owner).fitFiles.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath:external.path))
    }
    func testJournalOnlyPersistsCompactWatchRows() async throws {
        let r = try root();defer { try? FileManager.default.removeItem(at:r) }
        let saved = expectation(description:"watch row saved")
        let journal = TelemetryJournal(directory:r)
        journal.onEvent = { if case .saved = $0 { saved.fulfill() } }
        journal.append(.init(kind:.heartRate,value:72,source:"poll",origin:.cloud))
        journal.append(.init(kind:.heartRate,value:72,source:"estimate",origin:.estimated))
        journal.append(.init(kind:.watchBattery,value:80,source:"watch",origin:.watch))
        journal.append(.init(kind:.heartRate,value:72,source:"watch",origin:.watch))
        await fulfillment(of:[saved],timeout:2)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at:r,includingPropertiesForKeys:nil).first)
        let lines = try String(contentsOf:file).split(separator:"\n")
        XCTAssertEqual(lines.count,1)
        let object = try JSONSerialization.jsonObject(with:Data(lines[0].utf8)) as! [String:Any]
        XCTAssertNil(object["id"]);XCTAssertNil(object["source"])
        XCTAssertEqual(object["origin"] as? String,"watch")
        var rows = 0;try HealthHistoryReader.samples(file:file) { _ in rows += 1 };XCTAssertEqual(rows,1)
    }
    func testClockChangeCannotCompactTheActiveJournal() throws {
        let r = try root();defer { try? FileManager.default.removeItem(at:r) }
        let now = Date(), file = r.appendingPathComponent("Telemetry/"+GarminHealthMetrics.calendarDate(now)+".jsonl")
        let bytes = Data("{\"kind\":\"heartRate\",\"value\":70,\"timestamp\":\"2020-01-02T01:00:00Z\",\"origin\":\"cloud\"}\n".utf8)
        try GarminPrivateFile.write(bytes,to:file)
        let plan = try LocalStorageMaintenance.inspect(root:r,region:.china,account:owner,now:now.addingTimeInterval(172800))
        XCTAssertEqual(plan.journals.count,1)
        XCTAssertThrowsError(try LocalStorageMaintenance.execute(plan,removeFIT:false,compactLogs:true) { _ in XCTFail("Active journal moved") })
        XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
    func testClearIncludesTodayAndCachesButPreservesFITAndReceipts() throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at:r) }
        let a = try job(root:r); try ledger([a],root:r)
        let ledgerURL = r.appendingPathComponent("UploadQueue/upload-queue.json"), before = try Data(contentsOf:ledgerURL)
        for path in ["Telemetry/"+GarminHealthMetrics.calendarDate(Date())+".jsonl", "Telemetry/Index/old.json", "Charts/account/day.json"] {
            try GarminPrivateFile.write(Data("fixture".utf8),to:r.appendingPathComponent(path))
        }
        let trash = r.appendingPathComponent("fixture-trash")
        let bytes = try LocalStorageMaintenance.clearReadingHistory(root:r) { try FileManager.default.moveItem(at:$0,to:trash) }
        XCTAssertEqual(bytes,21)
        for name in ["Telemetry","Charts"] {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(at:r.appendingPathComponent(name),includingPropertiesForKeys:nil).isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath:trash.appendingPathComponent(name).path))
        }
        XCTAssertEqual(try Data(contentsOf:ledgerURL),before)
        XCTAssertTrue(FileManager.default.fileExists(atPath:r.appendingPathComponent("UploadQueue/OriginalFIT/"+a.fileName).path))
    }
    func testClearRollbackRestoresBothFoldersAndRejectsSymlinks() throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at:r) }
        for path in ["Telemetry/today.jsonl","Charts/account/day.json"] { try GarminPrivateFile.write(Data("fixture".utf8),to:r.appendingPathComponent(path)) }
        XCTAssertThrowsError(try LocalStorageMaintenance.clearReadingHistory(root:r) { _ in throw CocoaError(.fileWriteUnknown) })
        for path in ["Telemetry/today.jsonl","Charts/account/day.json"] { XCTAssertEqual(try String(contentsOf:r.appendingPathComponent(path)),"fixture") }
        let link = r.appendingPathComponent("Telemetry/external")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:r.appendingPathComponent("Charts"))
        XCTAssertThrowsError(try LocalStorageMaintenance.clearReadingHistory(root:r) { _ in XCTFail("Unsafe folder moved") })
    }
    func testExclusiveClearContinuesRecordingAndStaleChartSavesCannotRestoreHistory() async throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at:r) }
        let now = Date(), folder = r.appendingPathComponent("Telemetry"), journal = TelemetryJournal(directory:folder)
        let charts = MetricSeriesStore(directory:r.appendingPathComponent("Charts/account"))
        let oldGeneration = MetricSeriesStore.currentGeneration
        journal.append(.init(kind:.heartRate,value:70,source:"fixture",timestamp:now,origin:.watch))
        let trash = r.appendingPathComponent("fixture-trash")
        let bytes = try await journal.withExclusiveMutation {
            // This append queues behind the exclusive clear while it is running.
            journal.append(.init(kind:.heartRate,value:71,source:"fixture",timestamp:now,origin:.watch))
            return try MetricSeriesStore.clearingHistory { try LocalStorageMaintenance.clearReadingHistory(root:r) { try FileManager.default.moveItem(at:$0,to:trash) } }
        }
        XCTAssertTrue(bytes > 0)
        try charts.saveChecked([:],day:now,revision:1,generation:oldGeneration)
        XCTAssertFalse(FileManager.default.fileExists(atPath:r.appendingPathComponent("Charts/account/"+GarminHealthMetrics.calendarDate(now)+".json").path))
        let staleIndex = folder.appendingPathComponent("Index/old.json")
        try MetricSeriesStore.writeHistoryIndex(Data("old index".utf8),to:staleIndex,generation:oldGeneration)
        XCTAssertFalse(FileManager.default.fileExists(atPath:staleIndex.path))
        // Same timestamp is accepted after clearing; old throttling state resets.
        let count = try await journal.withExclusiveMutation { () -> Int in
            var values:[Double] = []
            try HealthHistoryReader.samples(file:folder.appendingPathComponent(GarminHealthMetrics.calendarDate(now)+".jsonl")) { values.append($0.value) }
            XCTAssertEqual(values,[71]); return values.count
        }
        XCTAssertEqual(count,1)
        try charts.saveChecked([:],day:now,revision:2,generation:MetricSeriesStore.currentGeneration)
        XCTAssertTrue(FileManager.default.fileExists(atPath:r.appendingPathComponent("Charts/account/"+GarminHealthMetrics.calendarDate(now)+".json").path))
    }
    func testClearDoesNotRunWhenPendingJournalCannotBeSaved() async throws {
        let r = try root(); defer { try? FileManager.default.removeItem(at:r) }
        let journal = TelemetryJournal(directory:r,writer:{ _,_ in throw CocoaError(.fileWriteUnknown) })
        journal.append(.init(kind:.heartRate,value:70,source:"fixture",origin:.watch))
        do { try await journal.withExclusiveMutation { XCTFail("Pending data discarded") }; XCTFail("Expected save failure") }
        catch { }
    }
}
