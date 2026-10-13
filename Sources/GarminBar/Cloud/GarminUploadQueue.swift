import Foundation
import Combine

struct GarminUploadJob: Identifiable, Codable {
    let id: String
    let fileName: String
    let originalName: String
    let deviceID: String
    let dataType: GarminDataType
    var accountGUID: String
    let createdAt: Date
    var updatedAt: Date
    var state: GarminUploadState
    var detail: String
    var attempts: Int
    var nextAttempt: Date?
    var cloudStatus: GarminUploadStatus?
    var region: GarminRegion? = nil
    var effectiveRegion: GarminRegion { region ?? .china }
    func belongs(to region: GarminRegion, accountGUID: String) -> Bool {
        effectiveRegion == region && (self.accountGUID.isEmpty || self.accountGUID == accountGUID)
    }
}

@MainActor
final class GarminUploadQueue: ObservableObject {
    @Published var automaticSyncEnabled: Bool = AppPreferences.shared.object(forKey: "garmin.cn.automaticSyncEnabled") as? Bool ?? true {
        didSet { AppPreferences.shared.set(automaticSyncEnabled, forKey: "garmin.cn.automaticSyncEnabled") }
    }
    @Published private(set) var jobs: [GarminUploadJob] = []
    @Published private(set) var status = "等待手表 FIT 文件"
    @Published private(set) var pendingCount = 0
    @Published private(set) var isSyncing = false
    @Published private(set) var watchedDirectory: URL?

    private let cloud: GarminChinaCloud
    private let directory: URL
    private let ledgerURL: URL
    private let rawDirectory: URL
    private var heartbeat: Task<Void, Never>?
    private var authObservation: AnyCancellable?
    private var regionObservation: AnyCancellable?
    private var knownWatchFailures: Set<String> = []
    private var ledgerReadable = true
    private var manualResyncRequested = false

    init(cloud: GarminChinaCloud, directory: URL) {
        self.cloud = cloud
        self.directory = directory
        ledgerURL = directory.appendingPathComponent("upload-queue.json")
        rawDirectory = directory.appendingPathComponent("OriginalFIT", isDirectory: true)
        if let bytes = try? Data(contentsOf: ledgerURL) {
            do {
                jobs = try JSONDecoder().decode([GarminUploadJob].self, from: bytes)
                for index in jobs.indices where jobs[index].state == .uploading {
                    jobs[index].state = jobs[index].cloudStatus?.processingURL == nil ? .pending : .processing
                    jobs[index].detail = "程序重新启动，原 FIT 已保留，等待继续同步"
                }
            } catch { ledgerReadable = false; status = "上传队列无法读取，原文件保留；请检查本地存储" }
        }
        updatePendingCount()
        authObservation = cloud.$isAuthenticated.removeDuplicates().sink { [weak self] authenticated in
            if authenticated, self?.automaticSyncEnabled == true { Task { @MainActor [weak self] in await self?.syncNow(force: false) } }
        }
        regionObservation = cloud.$region.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updatePendingCount(); self?.knownWatchFailures.removeAll()
            self?.status = "区域已切换，等待该区域的账户与文件"
        }
        restoreWatchBookmark()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                guard let self else { return }
                self.scanWatchedDirectory()
                await self.syncNow(force: false)
            }
        }
    }

    // The app owns this queue for its process lifetime; stopWatching releases a selected scope.
    deinit { heartbeat?.cancel() }

    /// Copy and persist the original before reporting an enqueue success to the device layer.
    @discardableResult
    func enqueue(fileURL: URL, deviceID: String, dataType: GarminDataType? = nil) throws -> GarminUploadJob {
        guard ledgerReadable else { throw GarminCloudError.invalidResponse("原上传队列无法读取，已阻止覆盖以保留历史") }
        guard UInt64(deviceID) != nil else { throw GarminCloudError.invalidResponse("请先选择账户关联的手表，或填写其数字 Unit ID") }
        let bytes = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let metadata = try GarminFITFileClassifier.inspect(bytes)
        let actual = metadata.dataType
        if let dataType, dataType != actual { throw GarminCloudError.invalidFIT("FIT 实际类型是 \(actual.rawValue)，与下载目录类别不一致") }
        if let serial = metadata.serialNumber, UInt64(serial) != UInt64(deviceID) {
            throw GarminCloudError.invalidFIT("FIT 的设备序列号与所选手表 Unit ID 不一致，未上传")
        }
        var identity = Data("\(deviceID):\(actual.rawValue):".utf8)
        identity.append(bytes)
        let contentID = GarminPrivateFile.digest(identity)
        let name = contentID + ".fit"
        if let previous = jobs.first(where: { $0.fileName == name && $0.belongs(to: cloud.region, accountGUID: cloud.accountGUID) }) { return previous }
        let id = GarminPrivateFile.digest(Data("\(cloud.region.rawValue):\(cloud.accountGUID):\(contentID)".utf8))
        try GarminPrivateFile.write(bytes, to: rawDirectory.appendingPathComponent(name))
        let now = Date()
        let job = GarminUploadJob(id: id, fileName: name, originalName: fileURL.lastPathComponent,
                                  deviceID: deviceID, dataType: actual, accountGUID: cloud.accountGUID,
                                  createdAt: now, updatedAt: now, state: .pending, detail: "原 FIT 已保存，等待上传",
                                  attempts: 0, nextAttempt: nil, cloudStatus: nil, region: cloud.region)
        jobs.insert(job, at: 0)
        do { try persist() }
        catch { jobs.removeAll { $0.id == id }; throw error }
        status = "已加入同步队列：\(actual.label)"
        updatePendingCount()
        if automaticSyncEnabled { Task { [weak self] in await self?.syncNow(force: false) } }
        return job
    }

    @discardableResult
    func importFIT(fileURL: URL, deviceID: String) throws -> GarminUploadJob {
        try enqueue(fileURL: fileURL, deviceID: deviceID)
    }

    func syncNow(force: Bool = true) async {
        guard force || automaticSyncEnabled else { status = "自动上传已暂停，原 FIT 保留在本地"; return }
        guard !isSyncing else { if force { manualResyncRequested = true }; return }
        guard cloud.isAuthenticated else {
            if pendingCount > 0 { status = "\(pendingCount) 份 FIT 已保留，登录\(cloud.region.title)后继续同步" }
            return
        }
        isSyncing = true
        defer {
            isSyncing = false; updatePendingCount()
            if manualResyncRequested {
                manualResyncRequested = false
                Task { [weak self] in await self?.syncNow(force: true) }
            }
        }
        let region = cloud.region, owner = cloud.accountGUID
        let candidates = jobs.filter { $0.effectiveRegion == region && !$0.state.isComplete && (force || $0.nextAttempt == nil || $0.nextAttempt! <= Date()) }.map(\.id)
        for id in candidates {
            guard cloud.isAuthenticated, force || automaticSyncEnabled, !Task.isCancelled,
                  cloud.region == region, cloud.accountGUID == owner,
                  let index = jobs.firstIndex(where: { $0.id == id }) else { break }
            if !jobs[index].accountGUID.isEmpty && jobs[index].accountGUID != cloud.accountGUID {
                jobs[index].detail = "此任务属于另一个佳明账户，原文件保留"
                continue
            }
            guard cloud.devices.contains(where: { $0.id == jobs[index].deviceID }) else {
                jobs[index].detail = "当前账户尚未确认关联此手表，原文件保留"
                continue
            }
            if jobs[index].accountGUID.isEmpty {
                guard cloud.devices.contains(where: { $0.id == jobs[index].deviceID }) else {
                    jobs[index].detail = "尚未确认此手表属于当前账户，等待关联设备列表"
                    continue
                }
                jobs[index].accountGUID = cloud.accountGUID
            }
            if jobs[index].state == .processing && jobs[index].cloudStatus?.processingURL == nil {
                // A 202 without Location cannot be declared successful or blindly re-posted.
                jobs[index].detail = "云端尚未返回可检查的处理地址，保留文件等待人工核对"
                continue
            }
            let previous = jobs[index].cloudStatus
            let fileURL = rawDirectory.appendingPathComponent(jobs[index].fileName)
            let deviceID = jobs[index].deviceID
            let type = jobs[index].dataType
            jobs[index].state = .uploading
            jobs[index].attempts += 1
            jobs[index].updatedAt = Date()
            do { try persist() }
            catch { status = "无法持久保存上传队列，已暂停上传"; return }
            status = "正在同步：\(type.label)"
            let result: GarminUploadStatus
            if let previous, previous.processingURL != nil {
                result = await cloud.checkUploadStatus(previous)
            } else {
                result = await cloud.upload(fileURL: fileURL, deviceID: deviceID, dataType: type)
            }
            guard let updated = jobs.firstIndex(where: { $0.id == id }) else { continue }
            jobs[updated].cloudStatus = result
            jobs[updated].state = result.state
            jobs[updated].detail = result.detail
            jobs[updated].updatedAt = Date()
            let seconds = result.state == .processing ? 30.0 : min(3600, 30 * pow(2, Double(min(jobs[updated].attempts - 1, 7))))
            jobs[updated].nextAttempt = result.state.isComplete ? nil : Date().addingTimeInterval(seconds)
            do { try persist() }
            catch { status = "结果已收到，但上传队列保存失败，原 FIT 保留"; return }
            status = "\(type.label)：\(result.state.label)"
        }
        updatePendingCount()
        if candidates.isEmpty {
            status = jobs.isEmpty ? "尚未接收手表原始文件" : pendingCount == 0 ? "同步队列已处理，原 FIT 保留在本地" : "等待下一次重试，原 FIT 保留在本地"
        }
    }

    func startWatching(directory watched: URL) {
        watchedDirectory?.stopAccessingSecurityScopedResource()
        _ = watched.startAccessingSecurityScopedResource()
        watchedDirectory = watched
        knownWatchFailures.removeAll()
        do {
            let bookmark = try watched.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            try GarminPrivateFile.write(bookmark, to: directory.appendingPathComponent("watched-folder.bookmark"))
        } catch { status = "已监控文件夹；下次启动需要重新选择此文件夹" }
        scanWatchedDirectory()
    }

    func stopWatching() {
        watchedDirectory?.stopAccessingSecurityScopedResource()
        watchedDirectory = nil
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("watched-folder.bookmark"))
        status = "已停止文件夹监控，已排队文件继续保留"
    }

    func retry(jobID: String) {
        guard !isSyncing, let index = jobs.firstIndex(where: { $0.id == jobID }), !jobs[index].state.isComplete else { return }
        jobs[index].state = .pending
        jobs[index].cloudStatus = nil
        jobs[index].nextAttempt = nil
        try? persist()
        Task { [weak self] in await self?.syncNow() }
    }

    private func scanWatchedDirectory() {
        guard let watchedDirectory else { return }
        guard !cloud.deviceId.isEmpty else { status = "请先选择云端关联手表，然后监控 FIT 文件夹"; return }
        guard let enumerator = FileManager.default.enumerator(at: watchedDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var inspected = 0
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "fit", !url.path.hasPrefix(directory.path + "/"),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true, let modified = values.contentModificationDate,
                  Date().timeIntervalSince(modified) >= 3 else { continue }
            let key = "\(url.path):\(modified.timeIntervalSince1970):\(values.fileSize ?? 0)"
            guard !knownWatchFailures.contains(key) else { continue }
            do { try enqueue(fileURL: url, deviceID: cloud.deviceId) }
            catch {
                // No filenames or server output enter logs; users see a bounded local queue status.
                status = (error as? GarminCloudError)?.localizedDescription ?? "读取 FIT 未完成，等待下次文件夹扫描"
            }
            knownWatchFailures.insert(key)
            inspected += 1
            if inspected >= 100 { break }
        }
        if knownWatchFailures.count > 10_000 { knownWatchFailures.removeAll() }
    }

    private func restoreWatchBookmark() {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("watched-folder.bookmark")) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            _ = url.startAccessingSecurityScopedResource()
            watchedDirectory = url
            if stale { status = "监控文件夹授权已变化，请重新选择文件夹" }
        } catch { status = "请重新选择要监控的 FIT 文件夹" }
    }

    private func persist() throws {
        guard ledgerReadable else { throw GarminCloudError.invalidResponse("原上传队列无法读取，已阻止覆盖以保留历史") }
        try GarminPrivateFile.write(JSONEncoder().encode(jobs), to: ledgerURL)
        updatePendingCount()
    }
    var visibleJobs: [GarminUploadJob] { jobs.filter { $0.effectiveRegion == cloud.region } }
    private func updatePendingCount() { pendingCount = visibleJobs.filter { !$0.state.isComplete }.count }
}
