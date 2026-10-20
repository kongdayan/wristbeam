import Foundation
import Combine

@MainActor protocol ConnectIQCloudClient: AnyObject {
    var objectWillChange: ObservableObjectPublisher { get }
    var networkEnabled: Bool { get }
    var isAuthenticated: Bool { get }
    var accountGUID: String { get }
    var deviceId: String { get }
    var region: GarminRegion { get }
    var loginRevision: UUID { get }
    func fetchConnectIQHistory(deviceID: String, page: Int) async throws -> [ConnectIQDownloadRecord]
    func fetchConnectIQApp(id: String, deviceID: String) async throws -> ConnectIQApp
    func fetchConnectIQFeatured(deviceID: String, page: Int) async throws -> [ConnectIQApp]
    func downloadConnectIQApp(app: ConnectIQApp, deviceID: String, allowQueueCreation: Bool) async throws -> Data
    func fetchConnectIQInstallMessageID(appID: String, deviceID: String, expectedSHA256: String) async throws -> UInt64
}
extension GarminChinaCloud: ConnectIQCloudClient {}

/// A local package and its public store snapshot; no account or device fields are persisted.
struct ConnectIQPackageMetadata: Codable {
    let appID: String
    let name: String
    let storeVersion: String
    let storeInternalVersion: Int
    let packageVersionVerified: Bool
    let packageFilename: String
    let packageSHA256: String
    let downloadedAt: Date
    let compatiblePartNumbers: [String]
    let permissions: [String]
    var artwork: [ConnectIQSavedArtwork]
}

struct ConnectIQSavedArtwork: Codable {
    let key: String
    var filename: String?
    var state: String
}

struct ConnectIQLocalPackage {
    let appID: String
    let url: URL
    let sha256: String
    let byteCount: Int
}
struct ConnectIQVerifiedPackage {
    let file: ConnectIQLocalPackage
    let data: Data
}

struct ConnectIQInstallationPackage {
    let package: ConnectIQVerifiedPackage
    let sourceMessageID: UInt64
    let accountGUID: String
    let deviceID: String
}

private final class ConnectIQArtworkRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Artwork is public, but redirects must stay on Garmin's media endpoints.
        completionHandler(request.url.map(ConnectIQPackageStore.isArtworkURL) == true ? request : nil)
    }
}

enum ConnectIQPackageStore {
    static let maximumPackageBytes = 32 * 1024 * 1024
    static func load(appID: String, root: URL) throws -> ConnectIQVerifiedPackage {
        guard let uuid = UUID(uuidString: appID) else { throw ConnectIQError.invalidAppID }
        let id = uuid.uuidString.lowercased()
        let directory = root.appendingPathComponent(id, isDirectory: true)
        let metadataURL = directory.appendingPathComponent("metadata.json")
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              directory.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let metadataData = try boundedFile(metadataURL, maximumBytes: 1024 * 1024)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(ConnectIQPackageMetadata.self, from: metadataData)
        guard UUID(uuidString: metadata.appID) == uuid,
              !metadata.packageFilename.isEmpty, !metadata.packageFilename.contains("/"), !metadata.packageFilename.contains("\\"),
              metadata.packageFilename.hasSuffix(".iqpkg"),
              metadata.packageSHA256.count == 64, metadata.packageSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let url = directory.appendingPathComponent(metadata.packageFilename)
        guard url.standardizedFileURL.deletingLastPathComponent().path == directory.standardizedFileURL.path else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let data = try boundedFile(url, maximumBytes: maximumPackageBytes)
        guard GarminPrivateFile.digest(data) == metadata.packageSHA256 else { throw CocoaError(.fileReadCorruptFile) }
        return ConnectIQVerifiedPackage(file: ConnectIQLocalPackage(appID: id, url: url, sha256: metadata.packageSHA256, byteCount: data.count), data: data)
    }
    private static func boundedFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size > 0, size <= maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while data.count <= maximumBytes {
            let chunk = try file.read(upToCount: min(256 * 1024, maximumBytes + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard !data.isEmpty, data.count <= maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
    static func artworkSources(_ app: ConnectIQApp) -> [(key: String, url: URL)] {
        var sources: [(key: String, url: URL)] = []
        if let icon = app.iconURL { sources.append(("icon", icon)) }
        sources += app.screenshotURLs.enumerated().map { ("screenshot-\($0.offset + 1)", $0.element) }
        return sources
    }
    static func isArtworkURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              ["services.garmin.cn", "services.garmin.com"].contains(url.host?.lowercased() ?? ""),
              url.path.hasPrefix("/appstore/api/icons/") || url.path.hasPrefix("/appstore/api/screenshots/") else {
            return false
        }
        return UUID(uuidString: url.lastPathComponent) != nil
    }
    static func loadArtwork(_ url: URL) async throws -> Data {
        guard isArtworkURL(url) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: ConnectIQArtworkRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let maximumBytes = 16 * 1024 * 1024
        let (bytes, response) = try await session.bytes(from: url)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.expectedContentLength <= Int64(maximumBytes) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw CocoaError(.fileReadTooLarge) }
            if data.count % 65536 == 0 { try Task.checkCancellation() }
            data.append(byte)
        }
        guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
    static func saveArtwork(_ data: Data?, key: String, packageURL: URL) throws {
        let directory = packageURL.deletingLastPathComponent()
        let metadataURL = directory.appendingPathComponent("metadata.json")
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              (try? metadataURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw CocoaError(.fileWriteInvalidFileName) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var metadata = try decoder.decode(ConnectIQPackageMetadata.self, from: Data(contentsOf: metadataURL))
        guard let index = metadata.artwork.firstIndex(where: { $0.key == key }),
              key == "icon" || (key.hasPrefix("screenshot-") && Int(key.dropFirst(11)) != nil) else { throw CocoaError(.fileWriteInvalidFileName) }
        if let data {
            let suffix: String
            if data.starts(with: [0xff, 0xd8, 0xff]) { suffix = "jpg" }
            else if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { suffix = "png" }
            else if data.starts(with: Array("GIF8".utf8)) { suffix = "gif" }
            else if data.count >= 12 && data.prefix(4) == Data("RIFF".utf8) && data.subdata(in: 8..<12) == Data("WEBP".utf8) { suffix = "webp" }
            else { throw CocoaError(.fileReadCorruptFile) }
            guard data.count <= 16 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let filename = key + "." + suffix
            let url = directory.appendingPathComponent(filename)
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw CocoaError(.fileWriteInvalidFileName) }
            try data.write(to: url, options: .atomic)
            metadata.artwork[index].filename = filename; metadata.artwork[index].state = "saved"
        } else { metadata.artwork[index].state = "failed" }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
    }
    static var defaultRoot: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WristBeam", isDirectory: true)
            .appendingPathComponent("ConnectIQ", isDirectory: true)
    }
    static func packageURL(app: ConnectIQApp, root: URL) throws -> URL {
        guard let id = UUID(uuidString: app.id) else { throw ConnectIQError.invalidAppID }
        let name = app.name.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        // At most 48 Unicode scalars keeps even multibyte names below filesystem limits.
        let filename = (name.isEmpty ? "ConnectIQ" : String(String.UnicodeScalarView(name.unicodeScalars.prefix(48)))) + ".iqpkg"
        return root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true).appendingPathComponent(filename)
    }
    static func save(_ data: Data, app: ConnectIQApp, root: URL) throws -> URL {
        let manager = FileManager.default
        let package = try packageURL(app: app, root: root)
        let directory = package.deletingLastPathComponent()
        // A pre-existing app folder must not redirect downloaded data outside this library.
        let metadataURL = directory.appendingPathComponent("metadata.json")
        for url in [directory, package, metadataURL] {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw CocoaError(.fileWriteInvalidFileName) }
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CocoaError(.fileWriteInvalidFileName) }
        } else { try manager.createDirectory(at: directory, withIntermediateDirectories: false) }
        guard directory.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path == resolvedRoot.path else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let metadata = ConnectIQPackageMetadata(appID: app.id.lowercased(), name: app.name,
            storeVersion: app.version, storeInternalVersion: app.internalVersion, packageVersionVerified: false,
            packageFilename: package.lastPathComponent, packageSHA256: GarminPrivateFile.digest(data), downloadedAt: Date(),
            compatiblePartNumbers: app.compatiblePartNumbers, permissions: app.permissions,
            artwork: artworkSources(app).map { ConnectIQSavedArtwork(key: $0.key, filename: nil, state: "pending") })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let snapshot = try encoder.encode(metadata)
        try data.write(to: package, options: .atomic)
        try snapshot.write(to: metadataURL, options: .atomic)
        return package
    }
}

/// Cloud download history is deliberately separate from the watch's live face list.
@MainActor final class ConnectIQLibrary: ObservableObject {
    @Published private(set) var history: [ConnectIQDownloadRecord] = []
    @Published private(set) var featured: [ConnectIQApp] = []
    @Published private(set) var apps: [String: ConnectIQApp] = [:]
    @Published private(set) var selected: ConnectIQApp?
    @Published private(set) var busy = false
    @Published private(set) var isDownloading = false
    @Published private(set) var queueNotice = ""
    @Published private(set) var status = ""
    @Published private(set) var savedURL: URL?
    @Published private(set) var localPackage: ConnectIQLocalPackage?
    @Published private(set) var runtimeAppIDs: [String: String] = [:]
    @Published private(set) var historyHasMore = false
    @Published private(set) var featuredHasMore = false
    private weak var cloud: (any ConnectIQCloudClient)?
    private var subscription: AnyCancellable?
    private var task: Task<Void, Never>?
    private var installPreparation: Task<ConnectIQInstallationPackage, Error>?
    private var scope = ""
    private var generation = UUID()
    private var historyPage = 0
    private var featuredPage = 0
    let downloadRoot: URL
    private let artworkLoader: (URL) async throws -> Data

    init(downloadRoot: URL = ConnectIQPackageStore.defaultRoot,
         artworkLoader: @escaping (URL) async throws -> Data = ConnectIQPackageStore.loadArtwork) {
        self.downloadRoot = downloadRoot; self.artworkLoader = artworkLoader
    }

    var online: Bool {
        guard let cloud else { return false }
        return cloud.networkEnabled && cloud.isAuthenticated && !cloud.accountGUID.isEmpty && !cloud.deviceId.isEmpty
    }
    func attach(_ cloud: any ConnectIQCloudClient) {
        self.cloud = cloud
        subscription = cloud.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        reconcile()
    }
    private var currentScope: String {
        guard let cloud, online else { return "" }
        return "\(cloud.region.rawValue):\(cloud.accountGUID):\(cloud.loginRevision):\(cloud.deviceId)"
    }
    func reconcile() {
        let next = currentScope
        guard next != scope else { return }
        let cancelledDownload = isDownloading
        task?.cancel(); task = nil; installPreparation?.cancel(); installPreparation = nil; scope = next; generation = UUID()
        history = []; featured = []; apps = [:]; selected = nil
        busy = false; isDownloading = false
        status = cancelledDownload ? "下载已取消" : ""; savedURL = nil; localPackage = nil
        historyPage = 0; featuredPage = 0; historyHasMore = false; featuredHasMore = false
    }
    private func current(_ token: UUID) -> Bool {
        reconcile()
        return generation == token && online && !Task.isCancelled
    }
    func cancel() {
        if isDownloading { status = "下载已取消" }
        task?.cancel(); task = nil; installPreparation?.cancel(); installPreparation = nil; generation = UUID(); busy = false; isDownloading = false
    }
    private func run(downloading: Bool = false, _ operation: @escaping @MainActor (any ConnectIQCloudClient, String, UUID) async throws -> Void) {
        reconcile()
        guard let cloud, online else { status = "请先登录并选择手表"; return }
        cancel()
        let token = generation, deviceID = cloud.deviceId
        busy = true; isDownloading = downloading; status = ""
        if downloading { queueNotice = "佳明安装任务可能已创建，之后仍可能随同步安装；取消下载不会删除这些任务。" }
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.busy = false; self.isDownloading = false; self.task = nil } }
            do { try await operation(cloud, deviceID, token) }
            catch {
                guard self.current(token), !(error is CancellationError) else { return }
                // Network descriptions may contain signed URLs or device identifiers.
                self.status = error is ConnectIQError ? error.localizedDescription : "Connect IQ 请求未完成，请稍后重试"
            }
        }
    }
    func refreshHistory(older: Bool = false) {
        reconcile()
        let page = older ? historyPage + 1 : 0
        run { [weak self] cloud, deviceID, token in
            guard let self else { return }
            let rows = try await cloud.fetchConnectIQHistory(deviceID: deviceID, page: page)
            guard self.current(token) else { return }
            let previous = older ? self.history : []
            self.history = previous + rows.filter { row in
                !previous.contains { $0.appID == row.appID && $0.internalVersion == row.internalVersion && $0.date == row.date }
            }
            self.historyPage = page; self.historyHasMore = !rows.isEmpty && self.history.count > previous.count
            if self.history.isEmpty { self.status = "没有云端下载记录" }
            for row in rows where self.apps[row.appID] == nil {
                guard self.current(token) else { return }
                // A removed store listing must not hide the remaining history.
                if let app = try? await cloud.fetchConnectIQApp(id: row.appID, deviceID: deviceID) {
                    guard self.current(token) else { return }
                    self.apps[app.id] = app
                }
            }
        }
    }
    func refreshFeatured(older: Bool = false) {
        reconcile()
        let page = older ? featuredPage + 1 : 0
        run { [weak self] cloud, deviceID, token in
            guard let self else { return }
            let rows = try await cloud.fetchConnectIQFeatured(deviceID: deviceID, page: page)
            guard self.current(token) else { return }
            let previous = older ? self.featured : []
            var seen = Set(previous.map(\.id))
            let additions = rows.filter { seen.insert($0.id).inserted }
            self.featured = previous + additions; self.featuredPage = page
            self.featuredHasMore = !additions.isEmpty
            for app in rows { self.apps[app.id] = app }
            if self.featured.isEmpty { self.status = "暂无推荐表盘" }
        }
    }
    static func appID(from input: String) -> String? { ConnectIQService.appID(from: input) }
    func lookup(_ input: String) {
        guard let id = Self.appID(from: input) else { status = "请输入表盘 ID 或佳明商店链接"; return }
        select(id)
    }
    func select(_ id: String) {
        reconcile()
        selected = apps[id]
        savedURL = nil; localPackage = nil
        run { [weak self] cloud, deviceID, token in
            guard let self else { return }
            let app = try await cloud.fetchConnectIQApp(id: id, deviceID: deviceID)
            guard self.current(token) else { return }
            self.apps[app.id] = app; self.selected = app
            self.restoreLocalPackage(appID: app.id)
        }
    }
    func restoreLocalPackage(appID: String) {
        savedURL = nil; localPackage = nil
        guard selected?.id == appID else { return }
        runtimeAppIDs[appID] = nil
        let metadata = downloadRoot.appendingPathComponent(appID).appendingPathComponent("metadata.json")
        guard FileManager.default.fileExists(atPath: metadata.path) else { return }
        do {
            let package = try ConnectIQPackageStore.load(appID: appID, root: downloadRoot)
            localPackage = package.file; savedURL = package.file.url
            cacheRuntimeID(package)
            status = "已找到本地表盘文件"
        } catch { status = "本地表盘文件校验失败，请重新下载" }
    }
    private func cacheRuntimeID(_ package: ConnectIQVerifiedPackage) {
        runtimeAppIDs[package.file.appID] = try? GFDIConnectIQPackageIdentity.parse(package.data, expectedStoreAppID: package.file.appID).runtimeAppID
    }
    func refreshRuntimeMappings(appIDs: [String]) {
        for appID in Set(appIDs) {
            if let package = try? ConnectIQPackageStore.load(appID: appID, root: downloadRoot) { cacheRuntimeID(package) }
            else { runtimeAppIDs[appID] = nil }
        }
    }
    /// Revalidate disk contents for each SDK action; cached IDs only control presentation.
    func verifiedRuntimeAppID(appID: String) -> String? {
        do {
            let package = try ConnectIQPackageStore.load(appID: appID, root: downloadRoot)
            let identity = try GFDIConnectIQPackageIdentity.parse(package.data, expectedStoreAppID: appID)
            runtimeAppIDs[appID] = identity.runtimeAppID
            return identity.runtimeAppID
        } catch {
            runtimeAppIDs[appID] = nil
            status = "需要已校验的本地表盘包，请先下载到 Mac"
            return nil
        }
    }
    func verifiedPackageForInstallation(appID: String) -> ConnectIQVerifiedPackage? {
        reconcile()
        guard selected?.id == appID, !busy else { return nil }
        do {
            let package = try ConnectIQPackageStore.load(appID: appID, root: downloadRoot)
            localPackage = package.file; savedURL = package.file.url
            return package
        } catch {
            localPackage = nil; savedURL = nil; runtimeAppIDs[appID] = nil
            status = "本地表盘文件校验失败，请重新下载"
            return nil
        }
    }
    /// Match the existing cloud task to these exact bytes; this path never creates a queue entry.
    func prepareInstallation(_ app: ConnectIQApp, confirmedScope: String) async -> ConnectIQInstallationPackage? {
        reconcile()
        guard let cloud, online, !busy, !confirmedScope.isEmpty, confirmedScope == currentScope,
              selected?.id == app.id else { status = "账户或设备已变化，请重新选择表盘"; return nil }
        guard let local = verifiedPackageForInstallation(appID: app.id) else { return nil }
        cancel()
        let token = generation, deviceID = cloud.deviceId, account = cloud.accountGUID
        busy = true; status = "正在核对本地包与手表安装任务"
        let preparation = Task {
            let messageID = try await cloud.fetchConnectIQInstallMessageID(appID: app.id, deviceID: deviceID, expectedSHA256: local.file.sha256)
            try Task.checkCancellation()
            return ConnectIQInstallationPackage(package: local, sourceMessageID: messageID, accountGUID: account, deviceID: deviceID)
        }
        installPreparation = preparation
        defer { if generation == token { busy = false; installPreparation = nil } }
        do {
            let prepared = try await preparation.value
            guard current(token), currentScope == confirmedScope, selected?.id == app.id else { return nil }
            status = "安装文件已校验"
            return prepared
        } catch {
            guard current(token), !(error is CancellationError) else { return nil }
            status = error is ConnectIQError ? error.localizedDescription : "无法核对安装任务，请稍后重试"
            return nil
        }
    }
    /// Call only after the user has accepted the queue side effect in the save UI.
    func download(_ app: ConnectIQApp, confirmedScope: String) {
        reconcile()
        guard !confirmedScope.isEmpty, confirmedScope == currentScope, selected?.id == app.id else {
            status = "账户或设备已变化，请重新选择表盘"; return
        }
        savedURL = nil; localPackage = nil
        run(downloading: true) { [weak self] cloud, deviceID, token in
            guard let self else { return }
            let data = try await cloud.downloadConnectIQApp(app: app, deviceID: deviceID, allowQueueCreation: true)
            guard self.current(token) else { return }
            let package: URL
            do {
                package = try ConnectIQPackageStore.save(data, app: app, root: self.downloadRoot)
                self.savedURL = package
                self.localPackage = ConnectIQLocalPackage(appID: app.id, url: package, sha256: GarminPrivateFile.digest(data), byteCount: data.count)
                self.refreshRuntimeMappings(appIDs: [app.id])
            } catch { self.status = "下载完成，但无法保存文件，请检查保存位置"; return }
            let sources = ConnectIQPackageStore.artworkSources(app)
            if !sources.isEmpty { self.status = "表盘已保存，正在下载预览图片" }
            var artworkFailures = false
            for source in sources {
                guard self.current(token) else { return }
                do {
                    let image = try await self.artworkLoader(source.url)
                    guard self.current(token) else { return }
                    try ConnectIQPackageStore.saveArtwork(image, key: source.key, packageURL: package)
                } catch {
                    guard self.current(token) else { return }
                    artworkFailures = true
                    try? ConnectIQPackageStore.saveArtwork(nil, key: source.key, packageURL: package)
                }
            }
            self.status = artworkFailures ? "已下载到 Mac，部分预览图片未能保存" : "已下载到 Mac"
        }
    }
    var confirmationScope: String { currentScope }
}
