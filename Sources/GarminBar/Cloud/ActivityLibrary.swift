import Foundation
import Combine
import AppKit

@MainActor final class ActivityLibrary: ObservableObject {
    @Published private(set) var index = GarminActivityIndex()
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var statusIsError = false
    @Published private(set) var cacheRevision = 0
    @Published private(set) var operation = ""
    @Published private(set) var downloads: [ActivityDownload] = []
    @Published private(set) var scanningDownloads = false
    @Published private(set) var managingDownloads = false
    private var request: Task<Void, Never>?
    private var requestID = UUID()
    private var inventoryGeneration = UUID()
    @Published var refreshMinutes: Int {
        didSet { preferences.set(refreshMinutes, forKey: "activities.refreshMinutes"); lastAttempt = Date() }
    }
    private let preferences: AppPreferences
    private let root: URL
    private weak var cloud: GarminChinaCloud?
    private var subscription: AnyCancellable?
    private var scope = ""
    private var generation = UUID()
    private var lastAttempt = Date()
    private var lastPageIDs: [String] = []
    private var detailCache: [String: GarminActivityDetail] = [:]
    private(set) var store: GarminActivityStore?
    @Published private(set) var online = false

    init(root: URL = AppPaths.directory("CloudActivities"), preferences: AppPreferences = .shared) {
        self.root = root; self.preferences = preferences
        let saved = preferences.object(forKey: "activities.refreshMinutes") as? Int ?? 0
        refreshMinutes = [0, 15, 30, 60, 180, 360, 1440].contains(saved) ? saved : 0
    }
    func attach(_ cloud: GarminChinaCloud) {
        self.cloud = cloud
        subscription = cloud.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        reconcile()
    }
    /// Retain the selected account's cache in local-only mode, but never display a
    /// previous account while a different login/region is being authenticated.
    func reconcile() {
        guard let cloud else { return }
        let connected = cloud.networkEnabled && cloud.isAuthenticated && !cloud.accountGUID.isEmpty
        if online != connected { online = connected }
        let key = "activities.scope." + cloud.region.rawValue
        var next = ""
        if online {
            next = GarminPrivateFile.digest(Data("\(cloud.region.rawValue):\(cloud.accountGUID)".utf8))
            if preferences.string(forKey: key) != next { preferences.set(next, forKey: key) }
        } else if !cloud.networkEnabled && !preferences.bool(forKey: "\(cloud.region.preferencePrefix).signedOut") {
            let saved = preferences.string(forKey: key) ?? ""
            if saved.count == 64 && saved.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) { next = saved }
        }
        guard next != scope else { return }
        request?.cancel(); request = nil
        scope = next; generation = UUID(); busy = false; operation = ""; status = ""; statusIsError = false; lastPageIDs = []; detailCache = [:]
        downloads = []; inventoryGeneration = UUID(); scanningDownloads = false; managingDownloads = false
        store = next.isEmpty ? nil : GarminActivityStore(directory: root.appendingPathComponent(next, isDirectory: true))
        index = store?.loadIndex() ?? .init(); cacheRevision += 1
    }
    func tick(now: Date = Date()) {
        reconcile()
        guard refreshMinutes > 0, online, !busy, now.timeIntervalSince(lastAttempt) >= Double(refreshMinutes) * 60 else { return }
        lastAttempt = now
        requestPage(older: false)
    }
    private func current(_ token: UUID) -> Bool { reconcile(); return generation == token && online && !Task.isCancelled }
    private func failure(_ error: Error, token: UUID) {
        guard generation == token, !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        statusIsError = true
        status = error is GarminActivityError ? error.localizedDescription : L10n.text("暂时无法读取运动记录，请稍后重试")
    }
    func loadPage(older: Bool) async {
        reconcile()
        guard let cloud, let store, online, !busy, !managingDownloads, !older || !index.reachedEnd else { return }
        let token = generation
        busy = true; operation = older ? "正在加载更早的运动…" : "正在刷新运动摘要…"; status = ""; statusIsError = false; lastAttempt = Date()
        defer { if token == generation { busy = false; operation = "" } }
        do {
            let page = try await fetchPage(older: older, cloud: cloud, token: token)
            let offset = page.offset, rows = page.rows
            guard current(token) else { return }
            let ids = rows.map(\.id)
            if older && !ids.isEmpty && ids == lastPageIDs { throw GarminActivityError.repeatedPage }
            var next = index
            next.mergePage(rows, offset: offset, older: older)
            do { try store.saveIndex(next) } catch { throw GarminActivityError.storage }
            index = next; lastPageIDs = ids; cacheRevision += 1
        } catch { failure(error, token: token) }
    }
    /// Validate the history boundary on every continuation. Insertion/deletion can
    /// move offset-based pages; the last observed ID (or time if deleted) anchors us.
    private func fetchPage(older: Bool, cloud: GarminChinaCloud, token: UUID) async throws -> (offset: Int, rows: [GarminActivity]) {
        guard older else { return (0, try await cloud.fetchActivityPage(offset: 0)) }
        guard let anchor = index.historyAnchorID else {
            return (index.nextOffset, try await cloud.fetchActivityPage(offset: index.nextOffset))
        }
        var offset = index.needsHistoryRebase == true ? 0 : max(0, index.nextOffset - 1)
        var restarted = offset == 0
        var previous: [String] = []
        while offset <= 1_000_000 {
            let rows = try await cloud.fetchActivityPage(offset: offset)
            guard current(token), !Task.isCancelled else { throw CancellationError() }
            if let position = rows.firstIndex(where: { $0.id == anchor }) {
                let start = position + 1
                if start < rows.count { return (offset + start, Array(rows.dropFirst(start))) }
                let next = offset + rows.count
                return (next, try await cloud.fetchActivityPage(offset: next))
            }
            if !restarted { offset = 0; restarted = true; continue }
            // A removed boundary record must not strand the history cursor.
            if let time = index.historyAnchorTime, let position = rows.firstIndex(where: {
                let value = $0.startTimeGMT ?? $0.startTimeLocal ?? ""
                return !value.isEmpty && value < time
            }) { return (offset + position, Array(rows.dropFirst(position))) }
            if rows.isEmpty { return (offset, []) }
            let ids = rows.map(\.id)
            guard ids != previous else { throw GarminActivityError.repeatedPage }
            previous = ids; offset += rows.count
        }
        throw GarminActivityError.repeatedPage
    }
    func detail(_ id: String) -> GarminActivityDetail? {
        if let cached = detailCache[id] { return cached }
        guard let cached = store?.detail(id) else { return nil }
        if detailCache.count >= 20 { detailCache.removeAll() }
        detailCache[id] = cached
        return cached
    }
    func cachedDetail(_ id: String) async -> GarminActivityDetail? {
        reconcile()
        if let cached = detailCache[id] { return cached }
        guard let store else { return nil }
        let token = generation
        let cached = await Task.detached(priority: .utility) { store.detail(id) }.value
        guard generation == token, !Task.isCancelled else { return nil }
        if let cached {
            if detailCache.count >= 20 { detailCache.removeAll() }
            detailCache[id] = cached
        }
        return cached
    }
    func hasDetail(_ id: String) -> Bool {
        guard let file = try? store?.file(id, extension: "json") else { return false }
        return FileManager.default.fileExists(atPath: file.path)
    }
    func formats(_ id: String) -> [String] {
        guard let store else { return [] }
        return GarminActivityFormat.allCases.filter {
            guard let file = try? store.file(id, extension: $0.fileExtension) else { return false }
            return FileManager.default.fileExists(atPath: file.path)
        }.map(\.rawValue)
    }
    func downloadDetail(_ id: String) async {
        reconcile()
        guard let cloud, let store, online, !busy, !managingDownloads, index.activities.contains(where: { $0.id == id }) else { return }
        let token = generation
        busy = true; operation = "正在加载运动数据…"; status = ""; statusIsError = false
        defer { if token == generation { busy = false; operation = "" } }
        do {
            let detail = try await cloud.fetchActivityDetail(id: id)
            guard current(token) else { return }
            do { try store.save(detail) } catch { throw GarminActivityError.storage }
            if detailCache.count >= 20 { detailCache.removeAll() }
            detailCache[id] = detail
            cacheRevision += 1
        } catch { failure(error, token: token) }
    }
    /// Opening a record is the demand signal. Reuse complete cached details and
    /// wait for an existing library request instead of silently dropping selection.
    func openDetail(_ id: String) async {
        reconcile()
        let token = generation
        while busy {
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            guard current(token), !Task.isCancelled else { return }
        }
        guard current(token), !Task.isCancelled else { return }
        status = ""; statusIsError = false
        if let cached = detail(id), cached.heartRateZones != nil, cached.laps != nil,
           cached.unavailableSections?.isEmpty != false { return }
        await downloadDetail(id)
    }
    /// Cache a requested server export. Local-only mode may read an existing copy;
    /// it can never start a download. The UI chooses the user's destination separately.
    func exportFile(_ id: String, format: GarminActivityFormat) async -> URL? {
        reconcile()
        guard let store, !busy, !managingDownloads, index.activities.contains(where: { $0.id == id }),
              let file = try? store.file(id, extension: format.fileExtension) else { return nil }
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let cloud, online else { statusIsError = true; status = L10n.text("尚未下载这条运动的数据"); return nil }
        let token = generation
        busy = true; operation = "正在准备导出文件…"; status = ""; statusIsError = false
        defer { if token == generation { busy = false; operation = "" } }
        do {
            let data = try await cloud.fetchActivityFile(id: id, format: format)
            guard current(token) else { return nil }
            do { try GarminPrivateFile.write(data, to: file) } catch { throw GarminActivityError.storage }
            cacheRevision += 1
            return file
        } catch { failure(error, token: token); return nil }
    }
    /// Own UI-started requests so Cancel really cancels URLSession's async work.
    func requestPage(older: Bool) {
        guard !busy, !managingDownloads, request == nil else { return }
        let id = UUID(); requestID = id
        request = Task {
            defer { if requestID == id { request = nil } }
            await loadPage(older: older)
        }
    }
    func cancelRequest() {
        request?.cancel(); request = nil; requestID = UUID()
        generation = UUID(); busy = false; operation = ""; status = ""
    }
    func revealDownload(_ download: ActivityDownload) {
        guard downloads.contains(download), let store,
              let file = try? store.file(download.activityID, extension: download.fileExtension) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
    var downloadBytes: Int64 { downloads.reduce(0) { $0 + $1.bytes } }
    func refreshDownloads() async {
        reconcile()
        guard let store else { downloads = []; return }
        let account = scope, inventory = UUID()
        inventoryGeneration = inventory; scanningDownloads = true
        defer { if inventory == inventoryGeneration { scanningDownloads = false } }
        let result = await Task.detached(priority: .utility) { ActivityDownload.inventory(in: store.directory) }.value
        guard account == scope, inventory == inventoryGeneration, !Task.isCancelled else { return }
        downloads = result; scanningDownloads = false
    }
    /// The download manager only touches validated per-activity cache files.
    /// It never removes the index, received FIT files, account data or preferences.
    func moveDownloadToTrash(_ download: ActivityDownload) async {
        reconcile()
        guard let store, !busy, !managingDownloads,
              downloads.contains(download), ActivityDownload.isManagedFilename(download.filename) else { return }
        let directory = store.directory, account = scope
        managingDownloads = true; status = ""; statusIsError = false
        let succeeded = await Task.detached(priority: .utility) {
            do {
                let url = directory.appendingPathComponent(download.filename)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return false }
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                return true
            } catch { return false }
        }.value
        guard account == scope else { return }
        managingDownloads = false
        if succeeded {
            detailCache.removeValue(forKey: download.activityID); cacheRevision += 1
            status = "已移到废纸篓，可在 Finder 中恢复"
            await refreshDownloads()
        } else { statusIsError = true; status = "无法移到废纸篓，请在 Finder 中重试" }
    }
    func exportJSON(_ id: String) throws -> Data {
        reconcile()
        guard let summary = index.activities.first(where: { $0.id == id }) else { throw GarminActivityError.notCached }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        if let detail = detail(id) { return try encoder.encode(detail) }
        return try encoder.encode(summary)
    }
}
