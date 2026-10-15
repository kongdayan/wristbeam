import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    let bluetooth = WatchBluetooth()
    let cloud = GarminChinaCloud(automaticallyRestore: !PulseRuntime.isPreview, networkEnabled: !PulseRuntime.isPreview && AppPreferences.shared.cloudSyncEnabled)
    let widgetPublisher = PulseWidgetPublisher()
    let updater = PulseUpdater()
    let developer = DeveloperAccess()
    lazy var uploads = GarminUploadQueue(cloud: cloud, directory: AppPaths.directory("UploadQueue"))
    @Published var metrics: [MetricKind: MetricSample] = [:]
    @Published var history: [MetricKind: [MetricSample]] = [:]
    @Published var seriesDays: [String: [MetricKind: MetricDaySeries]] = [:]
    @Published var seriesStatus = "等待读取全天趋势"
    @Published var loadingSeriesDays: Set<String> = []
    @Published var seriesNotes: [String: [MetricKind: String]] = [:]
    @Published var hrvReport: GarminHRVReport?
    @Published var hrvStatusMessage = ""
    @Published var hrvLoading = false
    private var hrvRequestID = UUID()
    private var hrvMessageDay: String?
    private var hrvStore: GarminHRVStore?
    @Published var detailMetric: MetricKind? = nil
    @Published var detailDay = Date()
    @Published var metricNotes: [MetricKind: String] = [:]
    @Published var events: [ActivityLog] = []
    @Published var now = Date()
    @Published var page = AppPage.overview
    @Published var showLogin = false
    @Published var language = PulseLanguage(rawValue: AppPreferences.shared.string(forKey: "language") ?? "system") ?? .system {
        didSet { L10n.language = language; AppPreferences.shared.set(language.rawValue, forKey: "language"); onAppearanceChange?() }
    }
    @Published var watchUnitID = "" { didSet { uploads.localDeviceID = watchUnitID } }
    @Published var fontScale = AppPreferences.shared.object(forKey: "fontScale") as? Double ?? 1.15 {
        didSet { PulseTheme.textScale = fontScale; AppPreferences.shared.set(fontScale, forKey: "fontScale"); onAppearanceChange?(); onFloatingLayoutChange?() }
    }
    @Published var appearance = PulseAppearance(rawValue: AppPreferences.shared.string(forKey: "appearance") ?? "system") ?? .system {
        didSet { AppPreferences.shared.set(appearance.rawValue, forKey: "appearance"); onAppearanceChange?() }
    }
    @Published var cardSize = PulseCardSize(rawValue: AppPreferences.shared.string(forKey: "cardSize") ?? "regular") ?? .regular {
        didSet { AppPreferences.shared.set(cardSize.rawValue, forKey: "cardSize") }
    }
    @Published var dashboardColumns = AppPreferences.shared.object(forKey: "dashboardColumns") as? Int ?? 0 {
        didSet { AppPreferences.shared.set(dashboardColumns, forKey: "dashboardColumns") }
    }
    @Published var dashboardMetrics = MetricLayout.selected("dashboardMetrics", fallback: MetricSelection.load("floatingMetrics", includeSolar: true)) {
        didSet { MetricSelection.save(dashboardMetrics, key: "dashboardMetrics") }
    }
    @Published var dashboardOrder = AppPreferences.shared.object(forKey: "dashboardOrder") as? [String] ?? [] {
        didSet { AppPreferences.shared.set(dashboardOrder, forKey: "dashboardOrder") }
    }
    @Published var floatingDetailed = AppPreferences.shared.object(forKey: "floatingDetailed") as? Bool ?? true {
        didSet { AppPreferences.shared.set(floatingDetailed, forKey: "floatingDetailed"); onFloatingLayoutChange?() }
    }
    @Published var floatingSize = PulsePanelSize(rawValue: AppPreferences.shared.string(forKey: "floatingSize") ?? "medium") ?? .medium {
        didSet { AppPreferences.shared.set(floatingSize.rawValue, forKey: "floatingSize"); onFloatingLayoutChange?() }
    }
    @Published var widgetMetrics = MetricLayout.selected("widgetMetrics", fallback: [.heartRate, .bodyBattery, .stress, .steps]) {
        didSet { MetricSelection.save(widgetMetrics, key: "widgetMetrics"); writeWidgetSnapshot(force: true) }
    }
    @Published var selectionDestination = MetricDestination.dashboard
    @Published var autoRefreshMetrics = AppPreferences.shared.object(forKey: "autoRefreshMetrics") as? Bool ?? true {
        didSet { AppPreferences.shared.set(autoRefreshMetrics, forKey: "autoRefreshMetrics") }
    }
    @Published var metricRefreshInterval = AppPreferences.shared.object(forKey: "metricRefreshInterval") as? Int ?? 5 {
        didSet { AppPreferences.shared.set(metricRefreshInterval, forKey: "metricRefreshInterval") }
    }
    @Published var floatingEnabled = AppPreferences.shared.object(forKey: "floatingEnabled") as? Bool ?? false {
        didSet { AppPreferences.shared.set(floatingEnabled, forKey: "floatingEnabled"); onFloatingChange?(floatingEnabled) }
    }
    @Published var floatingMetrics = MetricSelection.load("floatingMetrics", includeSolar: true) {
        didSet { MetricSelection.save(floatingMetrics, key: "floatingMetrics"); onFloatingLayoutChange?() }
    }
    @Published var menuMetrics = MetricSelection.load("menuMetrics", includeSolar: false) {
        didSet { MetricSelection.save(menuMetrics, key: "menuMetrics") }
    }
    @Published var sunlightThreshold = AppPreferences.shared.object(forKey: "sunlightThreshold") as? Double ?? 20 {
        didSet { AppPreferences.shared.set(sunlightThreshold, forKey: "sunlightThreshold"); Task { await refreshHealthMetrics(force: true) } }
    }
    @Published var healthStatus = "等待读取已同步健康指标"
    @Published private(set) var isRefreshingHealth = false
    @Published var cloudSyncEnabled = AppPreferences.shared.cloudSyncEnabled {
        didSet {
            AppPreferences.shared.set(cloudSyncEnabled, forKey: "cloudSyncEnabled")
            if !cloudSyncEnabled { autoUpload = false; showLogin = false }
            cloud.setNetworkEnabled(cloudSyncEnabled && !preview)
            uploads.automaticSyncEnabled = cloudSyncEnabled && autoUpload && !preview
        }
    }
    @Published var autoUpload = AppPreferences.shared.object(forKey: "autoUpload") as? Bool ?? AppPreferences.shared.bool(forKey: "autoSync") {
        didSet {
            AppPreferences.shared.set(autoUpload, forKey: "autoUpload")
            uploads.automaticSyncEnabled = cloudSyncEnabled && autoUpload && !preview
            if cloudSyncEnabled && autoUpload && !preview { Task { await uploads.syncNow(force: false) } }
        }
    }
    @Published var localDataSummary = LocalDataSummary()
    @Published var localExportStatus = ""
    @Published var isExportingLocalData = false
    @Published var autoSync = AppPreferences.shared.object(forKey: "autoSync") as? Bool ?? false {
        didSet { AppPreferences.shared.set(autoSync, forKey: "autoSync") }
    }
    @Published var syncInterval = AppPreferences.shared.object(forKey: "syncInterval") as? Int ?? 15 { didSet { AppPreferences.shared.set(syncInterval, forKey: "syncInterval") } }
    @Published var preview = PulseRuntime.isPreview
    @Published var previewSetup = PulseRuntime.previewsOnboarding
    var onOpenSettings: ((AppPage) -> Void)?
    var onFloatingChange: ((Bool) -> Void)?
    var onFloatingLayoutChange: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    var onShowMenu: (() -> Void)?
    var onQuit: (() -> Void)?
    private let journal = TelemetryJournal()
    private var subscriptions: Set<AnyCancellable> = []
    private var lastAutoSync = Date.distantPast
    private var manualFileSync = false
    private var fileSyncRequested = false
    private var recentSyncRequested = false
    private var lastStatusWrite = Date.distantPast
    private var lastWidgetBuild = Date.distantPast
    private var lastHealthRefresh = Date.distantPast
    private var lastSeriesRefresh: [String: Date] = [:]
    private var seriesStore: MetricSeriesStore?
    private var seriesOwner = ""
    var lastControlRequest = ""

    init() {
        L10n.language = language
        PulseTheme.textScale = fontScale
        bluetooth.onSample = { [weak self] in self?.receive($0) }
        bluetooth.onUnavailable = { [weak self] kind, text in
            guard let self, self.metrics[kind]?.origin == .watch || self.metrics[kind] == nil else { return }
            self.metricNotes[kind] = text
        }
        bluetooth.onLog = { [weak self] in self?.log($0) }
        bluetooth.onFilesAvailable = { [weak self] in
            guard let self, self.autoSync, !self.preview else { return }
            self.lastAutoSync = Date()
            self.bluetooth.requestFileSync()
        }
        bluetooth.onDeviceID = { [weak self] value in
            self?.watchUnitID = value
            Task { await self?.refreshHealthMetrics(force: true) }
        }
        bluetooth.onSyncFinished = { [weak self] success in
            guard let self else { return }
            self.manualFileSync = false
            if !self.preview && success && self.cloudSyncEnabled && self.autoUpload {
                Task { await self.uploads.syncNow(force: false) }
            }
        }
        bluetooth.onFile = { [weak self] url, metadata in
            guard let self else { return }
            guard self.bluetooth.archiveRegion == self.cloud.region else { self.log("账户区域已变化，原文件保留，等候同一区域恢复"); return }
            let id = metadata.deviceID > 0 ? String(metadata.deviceID) : (!self.watchUnitID.isEmpty ? self.watchUnitID : self.cloud.deviceId)
            let type = GarminDataType(fitSubtype: UInt8(clamping: metadata.subtype))
            do {
                try self.uploads.enqueue(fileURL: url, deviceID: id, dataType: type)
                self.log("已接收\(type.label)原始文件，已暂存在本机")
                self.refreshLocalDataSummary()
            }
            catch { self.log("文件入队失败：\(error.localizedDescription)") }
            if self.cloudSyncEnabled && self.autoUpload && !self.preview { Task { await self.uploads.syncNow(force: false) } }
        }
        uploads.automaticSyncEnabled = cloudSyncEnabled && autoUpload && !preview
        bluetooth.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        cloud.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        uploads.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        updater.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        uploads.$isSyncing.removeDuplicates().sink { [weak self] syncing in
            if !syncing { Task { await self?.refreshHealthMetrics(force: true); await self?.refreshSeries(day: Date(), force: true) } }
        }.store(in: &subscriptions)
        bluetooth.$canSyncFiles.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] ready in
            guard let self, ready, !self.preview else { return }
            if self.recentSyncRequested {
                self.recentSyncRequested = false; self.fileSyncRequested = false; self.manualFileSync = true
                self.bluetooth.requestRecentActivity()
                return
            }
            if self.fileSyncRequested {
                self.fileSyncRequested = false; self.manualFileSync = true
                self.bluetooth.requestFileSync()
                return
            }
            guard self.autoSync else { return }
            self.lastAutoSync = Date()
            self.bluetooth.requestFileSync()
        }.store(in: &subscriptions)
        bluetooth.$isConnected.removeDuplicates().sink { [weak self] connected in
            if !connected { self?.manualFileSync = false }
        }.store(in: &subscriptions)
        cloud.$region.sink { [weak self] region in self?.bluetooth.updateCloudRegion(region) }.store(in: &subscriptions)
        cloud.$accountGUID.sink { [weak self] guid in
            guard let self else { return }
            self.bluetooth.updateAccountGUID(self.cloudSyncEnabled && !guid.isEmpty ? guid : nil)
            let owner = guid.isEmpty ? "" : "\(self.cloud.region.rawValue):\(guid)"
            if self.seriesOwner != owner {
                self.developer.accountChanged()
                self.hrvReport = nil; self.hrvRequestID = UUID(); self.hrvLoading = false; self.hrvStatusMessage = ""; self.hrvMessageDay = nil; self.hrvStore = owner.isEmpty ? nil : GarminHRVStore(owner: owner)
                self.seriesOwner = owner; self.seriesDays = [:]; self.seriesNotes = [:]; self.lastSeriesRefresh = [:]; self.lastHealthRefresh = .distantPast
                self.metrics = self.metrics.filter { $0.value.origin == .watch }; self.metricNotes = [:]
                self.seriesStore = guid.isEmpty ? nil : MetricSeriesStore(accountGUID: owner)
                self.restoreSeries(day: Date())
                if !guid.isEmpty, let cached = self.hrvStore?.load() { self.applyHRV(cached) }
            }
        }.store(in: &subscriptions)
        cloud.$deviceId.sink { [weak self] id in
            if self?.watchUnitID.isEmpty == true { self?.watchUnitID = id }
            Task { await self?.refreshHealthMetrics(force: true) }
        }.store(in: &subscriptions)
        cloud.$devices.sink { [weak self] _ in
            Task { await self?.refreshHealthMetrics(force: true) }
        }.store(in: &subscriptions)
        cloud.$isAuthenticated.sink { [weak self] authenticated in
            guard let self else { return }
            if authenticated {
                self.showLogin = false
                self.log("\(self.cloud.region.title)账户已连接")
                if !self.preview { self.bluetooth.resumeRequestedConnection() }
                if self.cloudSyncEnabled && self.autoUpload && !self.preview { Task { await self.uploads.syncNow(force: false) } }
            }
        }.store(in: &subscriptions)
        developer.attach(self)
        Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] date in
            guard let self else { return }; self.now = date
            self.developer.tick()
            if date.timeIntervalSince(self.lastStatusWrite) >= 5 { self.writeRuntimeState() }
            if self.autoRefreshMetrics && date.timeIntervalSince(self.lastHealthRefresh) >= Double(max(1, self.metricRefreshInterval)) * 60 { Task { await self.refreshHealthMetrics() } }
            if self.autoSync && !self.preview && date.timeIntervalSince(self.lastAutoSync) >= Double(max(1, self.syncInterval)) * 60 {
                self.lastAutoSync = date
                if self.bluetooth.canSyncFiles { self.bluetooth.requestFileSync() }
                if self.cloudSyncEnabled && self.autoUpload && self.cloud.isAuthenticated { Task { await self.uploads.syncNow(force: false) } }
            }
        }.store(in: &subscriptions)
        if !preview { restoreSeries(day: Date()); refreshLocalDataSummary() }
        log("WristBeam 已启动")
    }

    var visibleMetrics: [MetricKind] {
        MetricKind.allCases.filter { floatingMetrics.contains($0) && availableMetricKinds.contains($0) }
    }
    var availableMetricKinds: Set<MetricKind> { MetricLayout.available(readings: Set(metrics.keys), registered: bluetooth.registeredMetrics, discovered: bluetooth.availableMetrics) }
    var dashboardVisibleMetrics: [MetricKind] { MetricLayout.ordered(selection: dashboardMetrics.intersection(availableMetricKinds), order: dashboardOrder) }
    var preferredColorScheme: ColorScheme? { appearance == .system ? nil : appearance == .light ? .light : .dark }
    var menuVisibleMetrics: [MetricKind] { MetricKind.allCases.filter { menuMetrics.contains($0) && availableMetricKinds.contains($0) } }
    var floatingColumns: Int { min(floatingSize.columns, max(1, visibleMetrics.count)) }
    var floatingWidth: CGFloat { min(520, floatingSize.width) * min(1.3, fontScale) }
    var floatingHeight: CGFloat { floatingDetailed ? 470 + 140 * (fontScale - 1) : 280 + 100 * (fontScale - 1) }
    func selectedMetrics(for destination: MetricDestination) -> Set<MetricKind> {
        switch destination { case .dashboard: return dashboardMetrics; case .floating: return floatingMetrics; case .menu: return menuMetrics }
    }
    func setMetrics(_ metrics: Set<MetricKind>, for destination: MetricDestination) {
        switch destination { case .dashboard: dashboardMetrics = metrics; case .floating: floatingMetrics = metrics; case .menu: menuMetrics = metrics }
    }
    func select(_ metrics: [MetricKind], enabled: Bool, destination: MetricDestination) {
        var selected = selectedMetrics(for: destination)
        if enabled { selected.formUnion(metrics) } else { selected.subtract(metrics) }
        setMetrics(selected, for: destination)
    }
    func refreshMetricsNow() { Task { await refreshHealthMetrics(force: true) } }
    func widgetSnapshot() -> PulseWidgetSnapshot {
        let day = Calendar.current.startOfDay(for: now)
        let readings = MetricKind.allCases.filter { !$0.isDeviceStatus && widgetMetrics.contains($0) }.map { kind -> PulseWidgetReading in
            let sample = metrics[kind], series = series(for: kind)
            let canonical = kind.timelineKind ?? kind
            let fixedRange = ["solarIntensity", "bodyBattery", "stress", "spo2", "trainingReadiness"].contains(canonical.rawValue)
            let lower = fixedRange || canonical.seriesStyle == .bars ? 0 : max(0, (series?.minimum ?? 0) - 5)
            let upper = fixedRange ? 100 : max(lower + 1, (series?.maximum ?? 1) * 1.1 + 5)
            let segments = (series?.segments ?? []).map { segment in segment.map { PulseWidgetPoint(seconds: max(0, $0.timestamp.timeIntervalSince(day)), value: $0.value!, endSeconds: $0.end.map { $0.timeIntervalSince(day) }) } }
            return PulseWidgetReading(id: kind.rawValue, title: kind.title, symbol: kind.symbol, value: display(kind), unit: kind.unit,
                source: sample?.source ?? "等待同步", updatedAt: sample?.timestamp, stale: isStale(kind), category: kind.category.rawValue,
                segments: segments, lowerBound: lower, upperBound: upper, style: canonical.seriesStyle == .bars ? "bars" : canonical.seriesStyle == .area ? "area" : "line")
        }
        return PulseWidgetSnapshot(generatedAt: now, day: day, regionTitle: cloud.region.title, watchConnected: bluetooth.isConnected, readings: readings, appearance: appearance.rawValue)
    }
    func writeWidgetSnapshot(force: Bool = false) {
        guard !preview, force || Date().timeIntervalSince(lastWidgetBuild) >= 30 else { return }
        lastWidgetBuild = Date(); widgetPublisher.publish(widgetSnapshot(), force: force)
    }
    var menuAccessibilityText: String {
        let readings = menuVisibleMetrics.prefix(5).map { kind in
            "\(kind.title): \(display(kind)) \(kind.unit)"
        }.joined(separator: "; ")
        return readings.isEmpty ? "WristBeam" : "WristBeam · " + readings
    }
    func display(_ kind: MetricKind) -> String {
        guard let sample = metrics[kind], metricNotes[kind] == nil, !isStale(kind) else { return "—" }
        if kind == .hrvStatus { return GarminHRVStatus(rawValue: Int(sample.value))?.title ?? "—" }
        return sample.formatted
    }
    func isStale(_ kind: MetricKind) -> Bool {
        guard let sample = metrics[kind] else { return true }
        if preview || kind.isOvernightHRV { return false }
        if sample.origin == .watch { return !bluetooth.isConnected || now.timeIntervalSince(sample.timestamp) > kind.definition.freshness }
        if !Calendar.current.isDate(sample.timestamp, inSameDayAs: now) { return true }
        return kind == .solarIntensity && now.timeIntervalSince(sample.timestamp) > kind.definition.freshness
    }
    func detail(_ kind: MetricKind) -> String {
        if preview { return "演示数据" }
        if kind.isOvernightHRV, let sample = metrics[kind] {
            return L10n.format("夜间记录日期：{0}；最近同步：{1}", GarminHealthMetrics.calendarDate(sample.timestamp), hrvReport?.refreshedAt.formatted(.dateTime.month().day().hour().minute().locale(L10n.locale)) ?? "—")
        }
        if let note = metricNotes[kind] { return note }
        if let sample = metrics[kind] {
            let time = sample.timestamp.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale))
            return isStale(kind) ? "上次 \(sample.formatted) · \(time) · 已过期" : "\(sample.source) · \(time)"
        }
        if kind.group != .live || kind.definition.dailyKey != nil { return "等待今日同步记录或手表读数" }
        if !bluetooth.isConnected { return "等待连接手表" }
        return bluetooth.availableMetrics.contains(kind) ? "已订阅 · 等待读数" : "当前服务未开放此指标"
    }
    func receive(_ sample: MetricSample) {
        if sample.origin != .watch, let current = metrics[sample.kind], current.origin == .watch, !isStale(sample.kind) { return }
        metrics[sample.kind] = sample; metricNotes.removeValue(forKey: sample.kind)
        guard !sample.kind.isDeviceStatus else { return }
        var points = history[sample.kind] ?? []; points.append(sample)
        if points.count > 60 { points.removeFirst(points.count - 60) }
        history[sample.kind] = points
        if sample.origin == .watch, sample.kind.acceptsLiveTimeline {
            let incoming = MetricDaySeries(kind: sample.kind, day: Calendar.current.startOfDay(for: sample.timestamp),
                points: [MetricSeriesPoint(timestamp: sample.timestamp, value: sample.value, origin: .watch)],
                source: "Mac 接收的手表读数 · 每分钟最近一次", refreshedAt: Date())
            mergeSeries([sample.kind: incoming], day: sample.timestamp)
        }
        if !preview { journal.append(sample) }
    }
    func log(_ text: String) {
        events.insert(ActivityLog(message: text), at: 0)
        if events.count > 150 { events.removeLast(events.count - 150) }
    }
    func refreshHealthMetrics(force: Bool = false) async {
        guard !preview, cloud.isAuthenticated, !isRefreshingHealth, force || now.timeIntervalSince(lastHealthRefresh) >= 60 else { return }
        let device = watchUnitID.isEmpty ? cloud.deviceId : watchUnitID
        guard !device.isEmpty, cloud.devices.contains(where: { $0.id == device }) else { return }
        isRefreshingHealth = true; lastHealthRefresh = Date()
        let owner = seriesOwner
        defer {
            isRefreshingHealth = false
            if owner != seriesOwner { Task { await refreshHealthMetrics(force: true) } }
        }
        let snapshot = await cloud.healthMetrics(deviceID: device, sunlightThreshold: sunlightThreshold)
        guard owner == seriesOwner, cloud.isAuthenticated else { return }
        if let report = snapshot.hrv { applyHRV(report) }
        for sample in snapshot.samples where !sample.kind.isOvernightHRV { receive(sample) }
        for (kind, note) in snapshot.notes where metrics[kind] == nil || isStale(kind) { metricNotes[kind] = note }
        healthStatus = snapshot.detail
        if let series = snapshot.solarSeries { mergeSeries([.solarIntensity: series], day: series.day) }
        await refreshSeries(day: Date(), force: force)
    }

    private func applyHRV(_ incoming: GarminHRVReport) {
        var report = incoming
        // Preserve previously loaded nights for the same account and current window.
        for (key, points) in hrvReport?.nights ?? [:] where report.nights[key] == nil && report.summaries.contains(where: { GarminHealthMetrics.calendarDate($0.day) == key }) { report.nights[key] = points }
        hrvReport = report
        hrvStatusMessage = report.nightWarning ?? ""
        hrvMessageDay = report.latest.map { GarminHealthMetrics.calendarDate($0.day) }
        for kind in [MetricKind.hrvNight, .hrvWeekly, .hrvStatus, .hrvHigh] { metrics.removeValue(forKey: kind); metricNotes.removeValue(forKey: kind) }
        for sample in report.samples { receive(sample) }
        hrvStore?.save(report)
        if report.latest != nil, !AppPreferences.shared.bool(forKey: "overnightHRVIntroduced") {
            dashboardMetrics.formUnion([.hrvNight, .hrvWeekly, .hrvStatus])
            floatingMetrics.formUnion([.hrvNight, .hrvWeekly, .hrvStatus])
            AppPreferences.shared.set(true, forKey: "overnightHRVIntroduced")
        }
    }
    func hrvMessage(for day: Date) -> String {
        hrvMessageDay == GarminHealthMetrics.calendarDate(day) ? hrvStatusMessage : ""
    }
    func loadHRVNight(_ day: Date) async {
        guard !preview, cloud.isAuthenticated else { return }
        let owner = seriesOwner, key = GarminHealthMetrics.calendarDate(day), requestID = UUID()
        hrvRequestID = requestID; hrvLoading = true; hrvStatusMessage = ""; hrvMessageDay = key
        defer { if hrvRequestID == requestID { hrvLoading = false } }
        do {
            let (summary, points) = try await cloud.overnightHRVNight(day: day)
            guard owner == seriesOwner, hrvRequestID == requestID, !Task.isCancelled else { return }
            var report = hrvReport ?? GarminHRVReport(summaries: [], nights: [:], refreshedAt: Date())
            if let summary {
                report.summaries.removeAll { $0.day == summary.day }
                report.summaries.append(summary); report.summaries.sort { $0.day < $1.day }
            }
            report.nights[key] = points; report.nightWarning = nil
            applyHRV(report)
            hrvMessageDay = key
            hrvStatusMessage = points.contains(where: { $0.value != nil }) ? "" : "该夜间尚无 HRV 记录"
        } catch {
            if owner == seriesOwner, hrvRequestID == requestID, !Task.isCancelled {
                hrvStatusMessage = "夜间 HRV 暂时无法读取，请稍后重试。"
            }
        }
    }

    func developerCachedSeries(kind: MetricKind, day: Date) -> MetricDaySeries? {
        guard !kind.isDeviceStatus else { return nil }
        return series(for: kind, day: day) ?? seriesStore?.load(day: day)[kind.timelineKind ?? kind]
    }
    func series(for kind: MetricKind, day: Date? = nil) -> MetricDaySeries? {
        if kind.isOvernightHRV { return hrvReport?.trend(kind) }
        guard let canonical = kind.timelineKind else { return nil }
        return seriesDays[GarminHealthMetrics.calendarDate(day ?? now)]?[canonical]
    }
    func mergeSeries(_ incoming: [MetricKind: MetricDaySeries], day: Date) {
        let key = GarminHealthMetrics.calendarDate(day)
        var collection = seriesDays[key] ?? [:]
        for (kind, series) in incoming where !kind.isDeviceStatus { collection[kind] = collection[kind].map { $0.merging(series) } ?? series }
        seriesDays[key] = collection
        // Bound memory without deleting stored history. Requested dates reload.
        if seriesDays.count > 10, let oldest = seriesDays.keys.sorted().first, oldest != key { seriesDays.removeValue(forKey: oldest) }
    }
    func restoreSeries(day: Date) {
        let store = seriesStore
        var cached = store?.load(day: day) ?? [:]
        if cached.isEmpty, cloud.region == .china, !cloud.accountGUID.isEmpty {
            cached = MetricSeriesStore(accountGUID: cloud.accountGUID).load(day: day)
            if !cached.isEmpty { store?.save(cached, day: day) }
        }
        mergeSeries(cached, day: day)
        Task { @MainActor [weak self] in
            let local = await Task.detached(priority: .utility) { MetricSeriesStore.localReadings(day: day) }.value
            guard let self, self.seriesStore === store else { return }
            self.mergeSeries(local, day: day)
        }
    }
    func refreshSeries(day: Date, force: Bool = false) async {
        let key = GarminHealthMetrics.calendarDate(day)
        if !preview, seriesDays[key] == nil { restoreSeries(day: day) }
        guard !preview, cloudSyncEnabled, cloud.isAuthenticated, !loadingSeriesDays.contains(key),
              force || Date().timeIntervalSince(lastSeriesRefresh[key] ?? .distantPast) >= Double(max(1, metricRefreshInterval)) * 60 else { return }
        let device = watchUnitID.isEmpty ? cloud.deviceId : watchUnitID
        guard !device.isEmpty, cloud.devices.contains(where: { $0.id == device }) else { return }
        if seriesDays[key] == nil { restoreSeries(day: day) }
        let owner = seriesOwner
        loadingSeriesDays.insert(key); lastSeriesRefresh[key] = Date()
        defer { loadingSeriesDays.remove(key) }
        let snapshot = await cloud.dailySeries(deviceID: device, day: day)
        guard seriesOwner == owner else { return }
        mergeSeries(snapshot.series, day: day)
        seriesNotes[key] = snapshot.notes
        seriesStatus = snapshot.detail
        if let collection = seriesDays[key] { seriesStore?.save(collection, day: day) }
        if Calendar.current.isDateInToday(day) {
            for series in snapshot.series.values where series.kind.definition.dailyKey == nil {
                if let latest = series.latest, let value = latest.value, !["floors", "pushes"].contains(series.kind.rawValue) {
                    receive(MetricSample(kind: series.kind, value: value, source: "\(cloud.region.title) · 最近同步读数", timestamp: latest.timestamp, origin: .cloud))
                }
            }
        }
    }
    func openMetric(_ kind: MetricKind, day: Date? = nil) {
        if kind.isDeviceStatus { openSettings(.watch); return }
        detailDay = day ?? Date(); openSettings(.overview); detailMetric = kind
        Task { await refreshSeries(day: detailDay) }
    }
    func writeRuntimeState() {
        lastStatusWrite = Date()
        let state: [String: Any] = [
            "reportedAt": lastStatusWrite.timeIntervalSince1970,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unbundled",
            "watchConnected": bluetooth.isConnected,
            "watchConnecting": bluetooth.isConnecting,
            "bluetoothStatus": bluetooth.bluetoothStatus,
            "bluetoothPermission": bluetooth.permissionState,
            "bluetoothManagerState": bluetooth.managerState ?? -1,
            "bluetoothSessionActivated": bluetooth.sessionActivated,
            "connectsOnLaunch": bluetooth.connectsOnLaunch,
            "automaticFileSync": autoSync,
            "watchConnectionStatus": bluetooth.status,
            "fileChannelReady": bluetooth.canSyncFiles,
            "protocolReady": bluetooth.protocolReady,
            "liveSampleCount": bluetooth.liveSampleCount,
            "lastLiveSampleAt": bluetooth.lastLiveSampleAt?.timeIntervalSince1970 ?? 0,
            "registeredMetrics": bluetooth.registeredMetrics.map(\.rawValue).sorted(),
            "nearbyWatches": bluetooth.nearby.filter(\.offersGarmin).map { ["name": $0.name, "id": $0.id.uuidString, "rssi": $0.rssi] as [String: Any] },
            "watchFileStatus": bluetooth.transferStatus,
            "cloudSyncEnabled": cloudSyncEnabled,
            "automaticCloudUpload": autoUpload,
            "cloudRequestCount": cloud.requestCount,
            "cloudAuthenticated": cloud.isAuthenticated,
            "cloudRegion": cloud.region.rawValue,
            "uploadQueueStatus": uploads.status,
            "pendingFileCount": uploads.pendingCount,
            "metrics": Dictionary(uniqueKeysWithValues: MetricKind.allCases.map { ($0.rawValue, display($0)) }),
            "metricSources": Dictionary(uniqueKeysWithValues: metrics.map { ($0.key.rawValue, $0.value.source) }),
            "healthStatus": healthStatus,
            "seriesStatus": seriesStatus,
            "seriesCounts": Dictionary(uniqueKeysWithValues: (seriesDays[GarminHealthMetrics.calendarDate(Date())] ?? [:]).map { ($0.key.rawValue, $0.value.values.count) }),
            "detailMetric": detailMetric?.rawValue ?? "",
            "detailDate": GarminHealthMetrics.calendarDate(detailDay),
            "chartPlotBuilds": ChartRenderDiagnostics.plotBuilds,
            "chartCursorEvents": ChartRenderDiagnostics.cursorEvents,
            "floatingMetrics": visibleMetrics.map(\.rawValue),
            "dashboardMetrics": dashboardVisibleMetrics.map(\.rawValue),
            "widgetMetrics": widgetMetrics.map(\.rawValue).sorted(),
            "widgetStatus": widgetPublisher.status,
            "fontScale": fontScale,
            "appearance": appearance.rawValue,
            "menuMetrics": menuVisibleMetrics.map(\.rawValue),
            "uploadJobs": uploads.jobs.map { ["type": $0.dataType.rawValue, "state": $0.state.rawValue,
                "httpStatus": $0.cloudStatus?.httpStatus ?? 0, "detail": $0.detail] as [String: Any] },
            "lastControlRequest": lastControlRequest,
            "windows": NSApp.windows.map { ["title": $0.title, "number": $0.windowNumber, "visible": $0.isVisible, "minimized": $0.isMiniaturized] as [String: Any] },
            "recentEvents": events.prefix(12).map(\.message)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? GarminPrivateFile.write(data, to: PulseLocalControl.statusURL)
        }
    }
    func openSettings(_ page: AppPage = .overview) { detailMetric = nil; self.page = page; onOpenSettings?(page) }
    func syncNow() {
        guard !preview else { return }
        if bluetooth.canSyncFiles {
            manualFileSync = true; bluetooth.requestFileSync()
        } else {
            if bluetooth.sessionActivated {
                fileSyncRequested = true; bluetooth.reconnectSaved()
            } else { openSettings(.watch) }
        }
    }
    func syncRecentActivity() {
        guard !preview else { return }
        if bluetooth.canSyncFiles {
            manualFileSync = true; bluetooth.requestRecentActivity()
        } else {
            if bluetooth.sessionActivated {
                recentSyncRequested = true; bluetooth.reconnectSaved()
            } else { openSettings(.watch) }
        }
    }
    func importFIT() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "fit") ?? .data]; panel.allowsMultipleSelection = true
        panel.prompt = L10n.text("暂存原始文件")
        panel.message = L10n.text("原始 FIT 会先保存在本机。开启云同步并登录后，可以选择补传。")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                try uploads.importFIT(fileURL: url, deviceID: watchUnitID.isEmpty ? cloud.deviceId : watchUnitID)
                log("已导入 \(url.lastPathComponent)")
            } catch { log("导入失败：\(error.localizedDescription)") }
        }
        refreshLocalDataSummary()
        if cloudSyncEnabled && autoUpload && !preview { Task { await uploads.syncNow(force: false) } }
    }
    func watchFITFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = L10n.text("选择并监测此文件夹")
        panel.message = L10n.text("将所选文件夹中的新增 FIT 暂存到本机；云上传由独立开关控制。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        uploads.startWatching(directory: url)
        log(uploads.watchedDirectory == url ? "已启用 FIT 文件夹自动同步" : uploads.status)
    }
    func refreshLocalDataSummary() {
        guard !preview else { return }
        let root = AppPaths.root
        Task {
            let summary = await Task.detached(priority: .utility) { LocalDataArchive.summary(root: root) }.value
            self.localDataSummary = summary
        }
    }
    func uploadStoredFiles() {
        guard cloudSyncEnabled, cloud.isAuthenticated, !preview else { openSettings(.account); return }
        Task { await uploads.syncNow(force: true) }
    }
    func exportLocalData() {
        guard !preview, !isExportingLocalData else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "WristBeam-Local-Data.zip"
        panel.prompt = L10n.text("导出暂存数据")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isExportingLocalData = true; localExportStatus = "正在导出暂存数据"
        let root = AppPaths.root
        Task {
            defer { isExportingLocalData = false }
            do {
                try await Task.detached(priority: .utility) { try LocalDataArchive.export(root: root, to: destination) }.value
                localExportStatus = "暂存数据已导出"
            } catch { localExportStatus = "导出未完成，原始数据保留" }
        }
    }
    func enablePreview() {
        preview = true; cloud.setNetworkEnabled(false); uploads.automaticSyncEnabled = false
        log("已进入演示预览；蓝牙与上传暂停")
        if previewSetup { floatingEnabled = false; return }
        for index in 0..<30 {
            receive(MetricSample(kind: .heartRate, value: 66 + (index % 5), source: "演示", timestamp: Date().addingTimeInterval(Double(index - 30))))
        }
        receive(MetricSample(kind: .heartRate, value: 68, source: "演示"))
        receive(MetricSample(kind: .stress, value: 24, source: "演示"))
        receive(MetricSample(kind: .steps, value: 6842, source: "演示"))
        for (id, value) in [("hrv", 880.0), ("watchBattery", 76.0), ("bodyBattery", 68.0), ("respiration", 15.2), ("spo2", 98), ("floors", 8), ("solarIntensity", 12.8), ("sunlightMinutes", 48), ("daily.restingHeartRate", 52), ("daily.sleepingSeconds", 7.5), ("calories", 1840)] {
            receive(MetricSample(kind: MetricKind(rawValue: id)!, value: value, source: "演示", origin: .cloud))
        }
        dashboardMetrics = [.heartRate, .bodyBattery, .stress, .steps, .solarIntensity, .sunlightMinutes, MetricKind(rawValue: "daily.restingHeartRate")!, MetricKind(rawValue: "respiration")!, MetricKind(rawValue: "spo2")!]
        dashboardMetrics.formUnion([.hrvNight, .hrvWeekly, .hrvStatus, MetricKind(rawValue: "hrv")!])
        dashboardColumns = 3; cardSize = .regular; fontScale = 1.15
        let day = Calendar.current.startOfDay(for: Date()), minute = min(1439, Int(Date().timeIntervalSince(day) / 60))
        for kind in [MetricKind.heartRate, .bodyBattery, .stress, .solarIntensity, MetricKind(rawValue: "respiration")!, MetricKind(rawValue: "spo2")!] {
            let points = stride(from: 0, through: minute, by: 1).map { offset -> MetricSeriesPoint in
                let time = Double(offset) / 60
                let value: Double
                if kind == .heartRate { value = 62 + 6 * sin(time * 2) + (time > 8 && time < 9 ? 35 : 0) }
                else if kind == .bodyBattery { value = time < 7 ? 45 + time * 5 : max(20, 80 - (time - 7) * 3) }
                else if kind == .stress { value = max(0, 18 + 14 * sin(time * 1.6) + (time > 8 && time < 9 ? 25 : 0)) }
                else if kind.rawValue == "respiration" { value = 15 + sin(time * 2) }
                else if kind.rawValue == "spo2" { value = 97 + sin(time / 2) }
                else { value = time < 6 || time > 18 ? 0 : max(0, 52 * sin((time - 6) / 12 * .pi) + 8 * sin(time * 6)) }
                return MetricSeriesPoint(timestamp: day.addingTimeInterval(Double(offset) * 60), value: value, origin: .cloud)
            }
            mergeSeries([kind: MetricDaySeries(kind: kind, day: day, points: points, source: "演示数据", refreshedAt: Date())], day: day)
        }
        let stepPoints: [MetricSeriesPoint] = stride(from: 0, through: max(0, minute - 15), by: 15).map { offset -> MetricSeriesPoint in
            let start = day.addingTimeInterval(Double(offset) * 60)
            let end = start.addingTimeInterval(900)
            let increment: Double = offset < 360 ? 0 : max(0.0, 110.0 + 100.0 * sin(Double(offset) / 90.0))
            return MetricSeriesPoint(timestamp: start, value: increment, end: end, origin: .cloud)
        }
        mergeSeries([.steps: MetricDaySeries(kind: .steps, day: day, points: stepPoints, source: "演示数据", refreshedAt: Date())], day: day)
        let hrvDays = (0..<28).map { offset -> GarminHRVSummary in
            let date = Calendar.current.date(byAdding: .day, value: offset - 27, to: day)!
            return GarminHRVSummary(day: date, night: 48 + 9 * sin(Double(offset) * 0.7), weekly: 48 + 3 * sin(Double(offset) * 0.2), high: 75, baselineLow: 40, baselineHigh:  60, status: .balanced)
        }
        let hrvPoints = (0..<84).map { index in MetricSeriesPoint(timestamp: day.addingTimeInterval(Double(index) * 300), value: 48 + 15 * sin(Double(index) * 0.3), origin: .cloud) }
        applyHRV(GarminHRVReport(summaries: hrvDays, nights: [GarminHealthMetrics.calendarDate(day): hrvPoints], refreshedAt: Date()))
        healthStatus = "演示预览 · 所有数值均为模拟数据"
    }
}

enum AppPage: String, CaseIterable, Identifiable {
    static var navigationPages: [Self] { [.overview, .watch, .sync, .settings] }
    static var settingsPages: [Self] { [.settings, .appearance, .metricSelection, .refresh, .developer, .updates, .about] }
    var navigationPage: Self { self == .account ? .watch : Self.settingsPages.contains(self) ? .settings : self }
    case overview, watch, account, sync, settings, appearance, metricSelection, refresh, developer, updates, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return L10n.text("健康看板")
        case .watch: return L10n.text("设备")
        case .account: return L10n.text("设备账号")
        case .sync: return L10n.text("同步记录")
        case .settings: return L10n.text("设置")
        case .appearance: return L10n.text("显示设置")
        case .updates: return L10n.text("软件更新")
        case .metricSelection: return L10n.text("指标选择")
        case .refresh: return L10n.text("网络与刷新")
        case .developer: return L10n.text("开发者集成")
        case .about: return L10n.text("关于")
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .watch: return "applewatch"
        case .account: return "person.crop.circle"
        case .sync: return "arrow.triangle.2.circlepath"
        case .settings: return "gearshape"
        case .appearance: return "menubar.rectangle"
        case .updates: return "arrow.down.circle"
        case .metricSelection: return "checklist"
        case .refresh: return "arrow.clockwise"
        case .developer: return "curlybraces"
        case .about: return "info.circle"
        }
    }
}
