import Foundation
import Combine

@MainActor final class ActivityLibrary: ObservableObject {
    @Published private(set) var index = GarminActivityIndex()
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var cacheRevision = 0
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
    private(set) var store: GarminActivityStore?
    var online: Bool { cloud?.networkEnabled == true && cloud?.isAuthenticated == true && cloud?.accountGUID.isEmpty == false }

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
        scope = next; generation = UUID(); busy = false; status = ""; lastPageIDs = []
        store = next.isEmpty ? nil : GarminActivityStore(directory: root.appendingPathComponent(next, isDirectory: true))
        index = store?.loadIndex() ?? .init(); cacheRevision += 1
    }
    func tick(now: Date = Date()) {
        reconcile()
        guard refreshMinutes > 0, online, !busy, now.timeIntervalSince(lastAttempt) >= Double(refreshMinutes) * 60 else { return }
        lastAttempt = now
        Task { await loadPage(older: false) }
    }
    private func current(_ token: UUID) -> Bool { reconcile(); return generation == token && online }
    private func failure(_ error: Error, token: UUID) {
        guard generation == token, !(error is CancellationError) else { return }
        status = error is GarminActivityError ? error.localizedDescription : L10n.text("暂时无法读取运动记录，请稍后重试")
    }
    func loadPage(older: Bool) async {
        reconcile()
        guard let cloud, let store, online, !busy, !older || !index.reachedEnd else { return }
        let token = generation
        busy = true; status = ""; lastAttempt = Date()
        defer { if token == generation { busy = false } }
        do {
            let offset = older ? index.nextOffset : 0
            let rows = try await cloud.fetchActivityPage(offset: offset)
            guard current(token) else { return }
            let ids = rows.map(\.id)
            if older && !ids.isEmpty && ids == lastPageIDs { throw GarminActivityError.repeatedPage }
            var next = index
            var byID = Dictionary(next.activities.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            for row in rows { byID[row.id] = row }
            next.activities = byID.values.sorted {
                let a = $0.startTimeGMT ?? $0.startTimeLocal ?? "", b = $1.startTimeGMT ?? $1.startTimeLocal ?? ""
                return a == b ? (Int64($0.id) ?? 0) > (Int64($1.id) ?? 0) : a > b
            }
            next.nextOffset = offset + rows.count
            // Only an empty page proves the cursor is exhausted; servers can return short pages.
            next.reachedEnd = rows.isEmpty
            if !older { next.refreshedAt = Date() }
            do { try store.saveIndex(next) } catch { throw GarminActivityError.storage }
            index = next; lastPageIDs = ids; cacheRevision += 1
        } catch { failure(error, token: token) }
    }
    func detail(_ id: String) -> GarminActivityDetail? { store?.detail(id) }
    func formats(_ id: String) -> [String] {
        guard let store else { return [] }
        return GarminActivityFormat.allCases.filter {
            guard let file = try? store.file(id, extension: $0.fileExtension) else { return false }
            return FileManager.default.fileExists(atPath: file.path)
        }.map(\.rawValue)
    }
    func downloadDetail(_ id: String) async {
        reconcile()
        guard let cloud, let store, online, !busy, index.activities.contains(where: { $0.id == id }) else { return }
        let token = generation
        busy = true; status = ""
        defer { if token == generation { busy = false } }
        do {
            let detail = try await cloud.fetchActivityDetail(id: id)
            guard current(token) else { return }
            do { try store.save(detail) } catch { throw GarminActivityError.storage }
            cacheRevision += 1
        } catch { failure(error, token: token) }
    }
    /// Cache a requested server export. Local-only mode may read an existing copy;
    /// it can never start a download. The UI chooses the user's destination separately.
    func exportFile(_ id: String, format: GarminActivityFormat) async -> URL? {
        reconcile()
        guard let store, !busy, index.activities.contains(where: { $0.id == id }),
              let file = try? store.file(id, extension: format.fileExtension) else { return nil }
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let cloud, online else { status = L10n.text("尚未下载这条运动的数据"); return nil }
        let token = generation
        busy = true; status = ""
        defer { if token == generation { busy = false } }
        do {
            let data = try await cloud.fetchActivityFile(id: id, format: format)
            guard current(token) else { return nil }
            do { try GarminPrivateFile.write(data, to: file) } catch { throw GarminActivityError.storage }
            cacheRevision += 1
            return file
        } catch { failure(error, token: token); return nil }
    }
    func exportJSON(_ id: String) throws -> Data {
        reconcile()
        guard let summary = index.activities.first(where: { $0.id == id }) else { throw GarminActivityError.notCached }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        if let detail = detail(id) { return try encoder.encode(detail) }
        return try encoder.encode(summary)
    }
}
