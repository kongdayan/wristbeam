import Combine
import Foundation
import XCTest
@testable import GarminBar

@MainActor private final class ConnectIQLibraryCloud: ConnectIQCloudClient {
    let objectWillChange = ObservableObjectPublisher()
    var networkEnabled = true
    var isAuthenticated = true
    var accountGUID = "synthetic-owner"
    var deviceId = "12345"
    var region = GarminRegion.china
    var loginRevision = UUID()
    var historyContinuation: CheckedContinuation<[ConnectIQDownloadRecord], Error>?
    var downloadContinuation: CheckedContinuation<Data, Error>?
    var downloadRequests = 0
    var installLookupContinuation: CheckedContinuation<UInt64, Error>?
    var duplicateFeatured = false
    var stallSearch = false
    var searchContinuations: [CheckedContinuation<[ConnectIQApp], Error>] = []
    var searchCalls: [(keywords: String, page: Int)] = []
    var searchRows: [ConnectIQApp]?
    var app = ConnectIQApp(id: "00000000-0000-0000-0000-000000000001", name: "Fixture Face", description: "",
                           version: "1.0", internalVersion: 1, isWatchFace: true, compatiblePartNumbers: ["fixture-part"],
                           permissions: [], paymentModel: nil, hasTrialMode: false, iconFileID: nil)
    func fetchConnectIQHistory(deviceID: String, page: Int) async throws -> [ConnectIQDownloadRecord] {
        try await withCheckedThrowingContinuation { historyContinuation = $0 }
    }
    func fetchConnectIQApp(id: String, deviceID: String) async throws -> ConnectIQApp { app }
    func fetchConnectIQFeatured(deviceID: String, page: Int) async throws -> [ConnectIQApp] {
        duplicateFeatured ? [app, app] : [app]
    }
    func searchConnectIQApps(keywords: String, deviceID: String, page: Int) async throws -> [ConnectIQApp] {
        searchCalls.append((keywords, page))
        if stallSearch { return try await withCheckedThrowingContinuation { searchContinuations.append($0) } }
        return searchRows ?? [app]
    }
    func fetchConnectIQInstallMessageID(appID: String, deviceID: String, expectedSHA256: String) async throws -> UInt64 {
        try await withCheckedThrowingContinuation { installLookupContinuation = $0 }
    }
    func downloadConnectIQApp(app: ConnectIQApp, deviceID: String, allowQueueCreation: Bool) async throws -> Data {
        XCTAssertTrue(allowQueueCreation)
        downloadRequests += 1
        // Deliberately ignores cancellation to model an already-submitted server request.
        return try await withCheckedThrowingContinuation { downloadContinuation = $0 }
    }
}

final class ConnectIQLibraryTests: XCTestCase {
    @MainActor func testKeywordSearchDeduplicatesPagesAndResetsForNewQuery() async {
        let cloud = ConnectIQLibraryCloud(), library = ConnectIQLibrary()
        cloud.searchRows = Array(repeating: cloud.app, count: ConnectIQService.pageSize)
        library.attach(cloud); library.lookup("  山水  ")
        await settle { !library.busy }
        XCTAssertEqual(library.searchQuery, "山水")
        XCTAssertEqual(library.searchResults.map(\.id), [cloud.app.id])
        XCTAssertTrue(library.searchHasMore)
        library.search(library.searchQuery, older: true)
        await settle { !library.busy }
        XCTAssertEqual(cloud.searchCalls.map { $0.page }, [0, 1])
        XCTAssertEqual(library.searchResults.count, 1)
        XCTAssertFalse(library.searchHasMore)
        cloud.searchRows = []
        library.search("Digital")
        XCTAssertTrue(library.searchResults.isEmpty)
        await settle { !library.busy }
        XCTAssertEqual(cloud.searchCalls.last?.page, 0)
        XCTAssertEqual(library.searchQuery, "Digital")
        XCTAssertTrue(library.searchResults.isEmpty)
        XCTAssertFalse(library.searchHasMore)
    }

    @MainActor func testNewSearchIgnoresLatePreviousQuery() async {
        let cloud = ConnectIQLibraryCloud(), library = ConnectIQLibrary()
        cloud.stallSearch = true; library.attach(cloud)
        library.search("Old")
        await settle { cloud.searchContinuations.count == 1 }
        library.search("New")
        await settle { cloud.searchContinuations.count == 2 }
        cloud.searchContinuations[0].resume(returning: [cloud.app])
        cloud.searchContinuations[1].resume(returning: [])
        await settle { !library.busy }
        XCTAssertEqual(library.searchQuery, "New")
        XCTAssertTrue(library.searchResults.isEmpty)
        XCTAssertTrue(library.apps.isEmpty)
    }

    @MainActor func testSearchResultsCannotSurviveScopeChangesOrClear() async {
        for change in ["device", "account", "region", "offline", "clear"] {
            let cloud = ConnectIQLibraryCloud(), library = ConnectIQLibrary()
            cloud.stallSearch = true; library.attach(cloud); library.search("Digital")
            await settle { cloud.searchContinuations.count == 1 }
            switch change {
            case "device": cloud.deviceId = "67890"
            case "account": cloud.accountGUID = "another-owner"
            case "region": cloud.region = .global
            case "offline": cloud.networkEnabled = false
            default: library.clearSearch()
            }
            library.reconcile()
            cloud.searchContinuations[0].resume(returning: [cloud.app])
            for _ in 0..<20 { await Task.yield() }
            XCTAssertTrue(library.searchResults.isEmpty, change)
            XCTAssertTrue(library.searchQuery.isEmpty, change)
            XCTAssertFalse(library.busy)
        }
    }

    func testArtworkOnlyUsesPublicGarminMediaEndpoints() {
        let id = "00112233-4455-6677-8899-aabbccddeeff"
        for host in ["services.garmin.cn", "services.garmin.com"] {
            XCTAssertTrue(ConnectIQPackageStore.isArtworkURL(URL(string: "https://\(host)/appstore/api/icons/\(id)")!))
        }
        for text in [
            "http://services.garmin.cn/appstore/api/icons/\(id)",
            "https://example.com/appstore/api/icons/\(id)",
            "https://services.garmin.cn:8443/appstore/api/icons/\(id)",
            "https://user@services.garmin.cn/appstore/api/icons/\(id)",
            "https://services.garmin.cn/private/\(id)",
            "https://services.garmin.cn/appstore/api/icons/not-an-id"
        ] {
            XCTAssertFalse(ConnectIQPackageStore.isArtworkURL(URL(string: text)!))
        }
    }

    @MainActor func testFeaturedDeduplicatesWithinAndAcrossPages() async {
        let cloud = ConnectIQLibraryCloud(), library = ConnectIQLibrary()
        cloud.duplicateFeatured = true
        library.attach(cloud); library.refreshFeatured()
        await settle { !library.busy }
        XCTAssertEqual(library.featured.map(\.id), [cloud.app.id])
        library.refreshFeatured(older: true)
        await settle { !library.busy }
        XCTAssertEqual(library.featured.map(\.id), [cloud.app.id])
        XCTAssertFalse(library.featuredHasMore)
    }

    @MainActor private func settle(until condition: () -> Bool) async {
        for _ in 0..<500 { if condition() { return }; await Task.yield() }
        XCTAssertTrue(condition(), "Controller did not reach expected state")
    }
    @MainActor func testChangedAccountRejectsLateHistoryResponse() async {
        let cloud = ConnectIQLibraryCloud(), library = ConnectIQLibrary()
        library.attach(cloud); library.refreshHistory()
        await settle { cloud.historyContinuation != nil }
        cloud.accountGUID = "different-synthetic-owner"
        library.reconcile()
        cloud.historyContinuation?.resume(returning: [.init(appID: cloud.app.id, internalVersion: 1, version: "1", date: .distantPast)])
        cloud.historyContinuation = nil
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(library.history.isEmpty)
        XCTAssertTrue(library.apps.isEmpty)
        XCTAssertFalse(library.busy)
    }
    @MainActor func testCancellationDoesNotSaveLatePackageAndRetainsQueueWarning() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cloud = ConnectIQLibraryCloud(), library = ConnectIQLibrary(downloadRoot: root)
        let file = try! ConnectIQPackageStore.packageURL(app: cloud.app, root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        library.attach(cloud); library.select(cloud.app.id)
        await settle { library.selected != nil && !library.busy }
        library.download(cloud.app, confirmedScope: library.confirmationScope)
        await settle { cloud.downloadContinuation != nil }
        XCTAssertTrue(library.isDownloading)
        library.cancel()
        XCTAssertEqual(library.status, "下载已取消")
        XCTAssertTrue(library.queueNotice.contains("取消下载不会删除"))
        cloud.downloadContinuation?.resume(returning: Data([1, 2, 3, 4])); cloud.downloadContinuation = nil
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(library.savedURL)
        XCTAssertFalse(library.isDownloading)
    }
    @MainActor func testDeviceChangeRejectsOldDownloadConfirmation() async {
        let cloud = ConnectIQLibraryCloud(), library = ConnectIQLibrary()
        library.attach(cloud); library.select(cloud.app.id)
        await settle { library.selected != nil && !library.busy }
        let scope = library.confirmationScope
        cloud.deviceId = "67890"
        library.download(cloud.app, confirmedScope: scope)
        XCTAssertEqual(cloud.downloadRequests, 0)
        XCTAssertNil(library.selected)
        XCTAssertEqual(library.status, "账户或设备已变化，请重新选择表盘")
    }
    @MainActor func testDownloadFailureKeepsPendingQueueDisclosure() async {
        let cloud = ConnectIQLibraryCloud(), library = ConnectIQLibrary()
        library.attach(cloud); library.select(cloud.app.id)
        await settle { library.selected != nil && !library.busy }
        library.download(cloud.app, confirmedScope: library.confirmationScope)
        await settle { cloud.downloadContinuation != nil }
        cloud.downloadContinuation?.resume(throwing: ConnectIQError.packagePending); cloud.downloadContinuation = nil
        await settle { !library.busy }
        XCTAssertEqual(library.status, ConnectIQError.packagePending.localizedDescription)
        XCTAssertTrue(library.queueNotice.contains("仍可能随同步安装"))
        XCTAssertFalse(library.isDownloading)
    }

    @MainActor func testSuccessfulDownloadWritesPackageAndPublicMetadataInAppFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = ConnectIQLibraryCloud(), library = ConnectIQLibrary(downloadRoot: root)
        library.attach(cloud); library.select(cloud.app.id)
        await settle { library.selected != nil && !library.busy }
        library.download(cloud.app, confirmedScope: library.confirmationScope)
        await settle { cloud.downloadContinuation != nil }
        let bytes = Data([0x12, 0x34, 0x56])
        cloud.downloadContinuation?.resume(returning: bytes); cloud.downloadContinuation = nil
        await settle { !library.busy }
        let file = try XCTUnwrap(library.savedURL)
        XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent, cloud.app.id)
        XCTAssertEqual(file.lastPathComponent, "Fixture-Face.iqpkg")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let metadataURL = file.deletingLastPathComponent().appendingPathComponent("metadata.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        XCTAssertEqual(json["appID"] as? String, cloud.app.id)
        XCTAssertEqual(json["packageSHA256"] as? String, GarminPrivateFile.digest(bytes))
        XCTAssertEqual(json["packageVersionVerified"] as? Bool, false)
        XCTAssertEqual(Set(json.keys), Set(["appID", "name", "storeVersion", "storeInternalVersion", "packageVersionVerified", "packageFilename", "packageSHA256", "downloadedAt", "compatiblePartNumbers", "permissions", "artwork"]))
    }
    @MainActor func testPackageNamesCannotTraverseAndMalformedAppIDIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = fixtureApp(name: "../../a/b\\evil:face")
        let file = try ConnectIQPackageStore.save(Data([1]), app: app, root: root)
        XCTAssertEqual(file.deletingLastPathComponent().deletingLastPathComponent().path, root.path)
        XCTAssertEqual(file.lastPathComponent, "a-b-evil-face.iqpkg")
        XCTAssertThrowsError(try ConnectIQPackageStore.packageURL(app: fixtureApp(id: "../../escape"), root: root))
    }
    @MainActor func testPackageSaveRejectsSymlinkFolderAndPreservesOutsideFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let app = fixtureApp()
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent(app.id), withDestinationURL: outside)
        XCTAssertThrowsError(try ConnectIQPackageStore.save(Data([1]), app: app, root: library))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
    @MainActor func testRepeatedPackageSaveReplacesBothFilesWithoutTemporaryDebris() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = fixtureApp()
        _ = try ConnectIQPackageStore.save(Data([1]), app: app, root: root)
        let bytes = Data([2, 3])
        let url = try ConnectIQPackageStore.save(bytes, app: app, root: root)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(Set(names), Set([url.lastPathComponent, "metadata.json"]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("metadata.json"))) as? [String: Any])
        XCTAssertEqual(json["packageSHA256"] as? String, GarminPrivateFile.digest(bytes))
    }
    @MainActor func testArtworkFilesAndFailuresAreRecordedWithoutLosingPackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = ConnectIQLibraryCloud()
        cloud.app.iconURL = URL(string: "https://services.garmin.cn/appstore/api/icons/00000000-0000-0000-0000-000000000002")!
        cloud.app.screenshotURLs = [URL(string: "https://services.garmin.cn/appstore/api/screenshots/00000000-0000-0000-0000-000000000003")!]
        let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3])
        let library = ConnectIQLibrary(downloadRoot: root, artworkLoader: { url in
            if url.path.contains("/icons/") { return jpeg }
            throw URLError(.notConnectedToInternet)
        })
        library.attach(cloud); library.select(cloud.app.id)
        await settle { library.selected != nil && !library.busy }
        library.download(cloud.app, confirmedScope: library.confirmationScope)
        await settle { cloud.downloadContinuation != nil }
        cloud.downloadContinuation?.resume(returning: Data([1, 2, 3])); cloud.downloadContinuation = nil
        await settle { !library.busy }
        let package = try XCTUnwrap(library.savedURL), directory = package.deletingLastPathComponent()
        XCTAssertEqual(try Data(contentsOf: package), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("icon.jpg")), jpeg)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(ConnectIQPackageMetadata.self, from: Data(contentsOf: directory.appendingPathComponent("metadata.json")))
        XCTAssertEqual(metadata.artwork.map(\.state), ["saved", "failed"])
        XCTAssertEqual(metadata.artwork.first?.filename, "icon.jpg")
        XCTAssertNil(metadata.artwork.last?.filename)
        XCTAssertEqual(library.status, "已下载到 Mac，部分预览图片未能保存")
    }
    @MainActor func testRestartRecognizesDownloadedPackageWithoutCreatingCloudQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = ConnectIQLibraryCloud(), bytes = Data([1, 2, 3])
        let file = try ConnectIQPackageStore.save(bytes, app: cloud.app, root: root)
        let library = ConnectIQLibrary(downloadRoot: root)
        library.attach(cloud); library.select(cloud.app.id)
        await settle { library.selected != nil && !library.busy }
        XCTAssertEqual(library.savedURL, file)
        XCTAssertEqual(library.localPackage?.sha256, GarminPrivateFile.digest(bytes))
        XCTAssertEqual(library.verifiedPackageForInstallation(appID: cloud.app.id)?.data, bytes)
        XCTAssertEqual(cloud.downloadRequests, 0)
        try Data([4, 5, 6]).write(to: file, options: .atomic)
        XCTAssertNil(library.verifiedPackageForInstallation(appID: cloud.app.id))
        XCTAssertNil(library.localPackage)
    }
    @MainActor func testLocalPackageRejectsWrongAppTraversalSymlinksAndOversizeFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = fixtureApp(), bytes = Data([1, 2, 3])
        let file = try ConnectIQPackageStore.save(bytes, app: app, root: root)
        let metadata = file.deletingLastPathComponent().appendingPathComponent("metadata.json")
        let original = try Data(contentsOf: metadata)
        for change in [["appID": "00000000-0000-0000-0000-000000000002"], ["packageFilename": "../outside.iqpkg"], ["packageFilename": "..\\outside.iqpkg"], ["packageSHA256": String(repeating: "0", count: 64)]] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            for (key, value) in change { json[key] = value }
            try JSONSerialization.data(withJSONObject: json).write(to: metadata, options: .atomic)
            XCTAssertThrowsError(try ConnectIQPackageStore.load(appID: app.id, root: root))
        }
        try original.write(to: metadata, options: .atomic)
        let outside = root.appendingPathComponent("outside.iqpkg")
        try bytes.write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertThrowsError(try ConnectIQPackageStore.load(appID: app.id, root: root))
        try FileManager.default.removeItem(at: file)
        try bytes.write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ConnectIQPackageStore.maximumPackageBytes + 1)); try handle.close()
        XCTAssertThrowsError(try ConnectIQPackageStore.load(appID: app.id, root: root))
    }
    @MainActor func testAccountChangeDuringInstallPreparationPreventsInstallation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = ConnectIQLibraryCloud(), library = ConnectIQLibrary(downloadRoot: root)
        _ = try ConnectIQPackageStore.save(Data([1, 2, 3]), app: cloud.app, root: root)
        library.attach(cloud); library.select(cloud.app.id)
        await settle { library.selected != nil && !library.busy }
        let scope = library.confirmationScope
        let preparation = Task { await library.prepareInstallation(cloud.app, confirmedScope: scope) }
        await settle { cloud.installLookupContinuation != nil }
        cloud.accountGUID = "another-synthetic-owner"; library.reconcile()
        cloud.installLookupContinuation?.resume(returning: 123); cloud.installLookupContinuation = nil
        let result = await preparation.value
        XCTAssertNil(result)
        XCTAssertFalse(library.busy)
        XCTAssertEqual(cloud.downloadRequests, 0)
    }
    @MainActor func testInstallPreparationReturnsExactBytesAndExistingQueueContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = ConnectIQLibraryCloud(), library = ConnectIQLibrary(downloadRoot: root), bytes = Data([1, 2, 3])
        _ = try ConnectIQPackageStore.save(bytes, app: cloud.app, root: root)
        library.attach(cloud); library.select(cloud.app.id)
        await settle { library.selected != nil && !library.busy }
        let scope = library.confirmationScope
        let preparation = Task { await library.prepareInstallation(cloud.app, confirmedScope: scope) }
        await settle { cloud.installLookupContinuation != nil }
        cloud.installLookupContinuation?.resume(returning: 123); cloud.installLookupContinuation = nil
        let prepared = await preparation.value
        XCTAssertEqual(prepared?.package.data, bytes)
        XCTAssertEqual(prepared?.sourceMessageID, 123)
        XCTAssertEqual(prepared?.deviceID, cloud.deviceId)
        XCTAssertEqual(prepared?.accountGUID, cloud.accountGUID)
        XCTAssertEqual(cloud.downloadRequests, 0)
    }
    @MainActor func testRuntimeMappingRestoresWithoutOpeningDetailsAndRechecksChecksum() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = fixtureApp(), runtime = "ffeeddcc-bbaa-9988-7766-554433221100"
        func be32(_ value: UInt32) -> Data {
            Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
        }
        func section(_ tag: UInt32, _ bytes: Data) -> Data { be32(tag) + be32(UInt32(bytes.count)) + bytes }
        let entry = Data([0, 1]) + (try GFDIConnectIQSDK.uuidBytes(runtime)) + Data(repeating: 0, count: 20)
        let bytes = be32(0x1d) + be32(20) + be32(32) + (try GFDIConnectIQSDK.uuidBytes(app.id))
            + section(0xd000d000, Data([1, 2, 3])) + section(0x6060c0de, entry)
        let file = try ConnectIQPackageStore.save(bytes, app: app, root: root)
        let library = ConnectIQLibrary(downloadRoot: root)
        library.refreshRuntimeMappings(appIDs: [app.id])
        XCTAssertNil(library.selected)
        XCTAssertEqual(library.runtimeAppIDs[app.id], runtime)
        XCTAssertEqual(library.verifiedRuntimeAppID(appID: app.id), runtime)
        var changed = bytes; changed[changed.count - 1] ^= 1
        try changed.write(to: file, options: .atomic)
        XCTAssertNil(library.verifiedRuntimeAppID(appID: app.id))
        XCTAssertNil(library.runtimeAppIDs[app.id])
    }
    @MainActor func testMissingOrUnsupportedPackageNeverFallsBackToStoreUUID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = fixtureApp(), library = ConnectIQLibrary(downloadRoot: root)
        library.refreshRuntimeMappings(appIDs: [app.id])
        XCTAssertNil(library.runtimeAppIDs[app.id])
        _ = try ConnectIQPackageStore.save(Data([1, 2, 3]), app: app, root: root)
        library.refreshRuntimeMappings(appIDs: [app.id])
        XCTAssertNil(library.runtimeAppIDs[app.id])
        XCTAssertNil(library.verifiedRuntimeAppID(appID: app.id))
    }
    private func fixtureApp(id: String = "00000000-0000-0000-0000-000000000001", name: String = "Fixture Face") -> ConnectIQApp {
        ConnectIQApp(id: id, name: name, description: "", version: "1.0", internalVersion: 1, isWatchFace: true,
                     compatiblePartNumbers: ["fixture-part"], permissions: [], paymentModel: nil, hasTrialMode: false, iconFileID: nil)
    }
}
