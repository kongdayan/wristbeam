import AppKit
import Combine
import CoreLocation

enum WatchWeatherSource: String, CaseIterable { case openMeteo, garmin }

/// Location is requested only by an explicit action. Weather never bypasses the cloud switch.
@MainActor
final class WatchWeatherController: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var enabled = AppPreferences.shared.bool(forKey: "watchWeatherEnabled") {
        didSet { AppPreferences.shared.set(enabled, forKey: "watchWeatherEnabled"); reconcile() }
    }
    @Published var source = WatchWeatherSource(rawValue: AppPreferences.shared.string(forKey: "watchWeatherSource") ?? "openMeteo") ?? .openMeteo {
        didSet { AppPreferences.shared.set(source.rawValue, forKey: "watchWeatherSource"); invalidate(); reconcile() }
    }
    private let openMeteo = OpenMeteoWeatherClient()
    @Published var cityQuery = ""
    @Published private(set) var location: WatchWeatherSnapshot.Location?
    @Published private(set) var candidates: [WatchWeatherSnapshot.Location] = []
    @Published private(set) var locationBusy = false
    @Published private(set) var refreshing = false
    @Published private(set) var status = "天气同步已关闭"
    @Published private(set) var locationStatus = ""
    @Published private(set) var lastFetched: Date?
    @Published private(set) var lastDelivered: Date?
    @Published private(set) var missingSections: [String] = []
    private weak var cloud: GarminChinaCloud?
    private weak var bluetooth: WatchBluetooth?
    private var subscriptions: Set<AnyCancellable> = []
    private var manager: CLLocationManager?
    private let geocoder = CLGeocoder()
    private var locationTask: Task<Void, Never>?
    private var locationTimeout: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var fetchTask: Task<WatchWeatherSnapshot, Error>?
    private var generation = UUID()
    private var lastAttempt = Date.distantPast
    private var snapshot: WatchWeatherSnapshot?
    private var identity = ""

    override init() {
        super.init()
        if let bytes = AppPreferences.shared.data(forKey: "watchWeatherLocation"),
           let saved = try? JSONDecoder().decode(WatchWeatherSnapshot.Location.self, from: bytes),
           CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: saved.latitude, longitude: saved.longitude)) {
            location = saved; cityQuery = saved.name
        }
    }

    func attach(cloud: GarminChinaCloud, bluetooth: WatchBluetooth) {
        self.cloud = cloud; self.bluetooth = bluetooth
        bluetooth.weatherProvider = { [weak self] query in
            guard let self else { throw CancellationError() }
            return try await self.fetch(forecastHours: query.forecastHours)
        }
        bluetooth.onWeatherDelivery = { [weak self] success in
            guard let self else { return }
            if success { self.lastDelivered = Date(); self.status = "天气已发送至手表" }
            else if self.available { self.status = "天气未能发送，请重试" }
        }
        Publishers.CombineLatest4(cloud.$networkEnabled, cloud.$isAuthenticated, cloud.$region, cloud.$accountGUID)
            .receive(on: RunLoop.main).sink { [weak self] _, _, _, _ in self?.reconcile() }.store(in: &subscriptions)
        bluetooth.$protocolReady.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] ready in
            if ready { self?.refreshIfDue() }
        }.store(in: &subscriptions)
        Timer.publish(every: 60, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.refreshIfDue() }.store(in: &subscriptions)
        reconcile()
    }

    var available: Bool { enabled && location != nil && (source == .openMeteo || (cloud?.networkEnabled == true && cloud?.isAuthenticated == true)) && !PulseRuntime.isPreview }

    private func invalidate() {
        generation = UUID(); fetchTask?.cancel(); fetchTask = nil; openMeteo.cancel()
        refreshTask?.cancel(); refreshTask = nil; refreshing = false
        snapshot = nil; lastFetched = nil; lastDelivered = nil; missingSections = []
        lastAttempt = .distantPast
        bluetooth?.configureWeather(enabled: false)
    }

    private func reconcile() {
        let current = "\(cloud?.region.rawValue ?? ""):\(cloud?.accountGUID ?? "")"
        if identity != current || !available { invalidate(); identity = current }
        bluetooth?.configureWeather(enabled: available)
        if !enabled { status = "天气同步已关闭" }
        else if source == .garmin && cloud?.networkEnabled != true { status = "仅本地模式下天气同步已暂停" }
        else if source == .garmin && cloud?.isAuthenticated != true { status = "请先连接设备云账号" }
        else if location == nil { status = "请选择天气城市" }
        else if bluetooth?.protocolReady != true { status = "等待手表连接" }
        else { refreshIfDue() }
    }

    func select(_ value: WatchWeatherSnapshot.Location) {
        invalidate(); location = value; cityQuery = value.name; candidates = []
        AppPreferences.shared.set(try? JSONEncoder().encode(value), forKey: "watchWeatherLocation")
        locationStatus = ""; reconcile()
    }

    func searchCity() {
        let query = cityQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !PulseRuntime.isPreview else { return }
        cancelLocation(); locationBusy = true; locationStatus = "正在查找城市"
        locationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let matches = try await self.geocoder.geocodeAddressString(String(query.prefix(160)))
                guard !Task.isCancelled else { return }
                self.candidates = matches.prefix(8).compactMap(Self.city)
                self.locationStatus = self.candidates.isEmpty ? "没有找到城市，请补充地区名称" : "请选择匹配的城市"
            } catch { if !Task.isCancelled { self.locationStatus = "城市查询失败，请稍后重试" } }
            if !Task.isCancelled { self.locationBusy = false }
        }
    }

    private static func city(_ placemark: CLPlacemark) -> WatchWeatherSnapshot.Location? {
        guard let coordinate = placemark.location?.coordinate, CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        var names: [String] = []
        for value in [placemark.locality ?? placemark.name, placemark.administrativeArea, placemark.country].compactMap({ $0 }) where !names.contains(value) { names.append(value) }
        return .init(name: names.joined(separator: " · "), latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    private func cancelLocation() {
        locationTask?.cancel(); locationTimeout?.cancel(); geocoder.cancelGeocode(); manager?.stopUpdatingLocation()
        locationBusy = false
    }

    func locate() {
        guard !PulseRuntime.isPreview else { return }
        cancelLocation(); candidates = []; locationBusy = true; locationStatus = "正在获取当前位置"
        if manager == nil { manager = CLLocationManager(); manager?.delegate = self; manager?.desiredAccuracy = kCLLocationAccuracyKilometer }
        guard let manager else { return }
        switch manager.authorizationStatus {
        case .denied, .restricted: locationBusy = false; locationStatus = "请在系统设置中允许定位，或手动选择城市"
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: manager.requestLocation()
        }
        locationTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self, self.locationBusy else { return }
            self.manager?.stopUpdatingLocation(); self.locationBusy = false; self.locationStatus = "定位超时，请重试或手动选择城市"
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard locationBusy else { return }
        switch manager.authorizationStatus {
        case .notDetermined: break
        case .denied, .restricted: locationTimeout?.cancel(); locationBusy = false; locationStatus = "请在系统设置中允许定位，或手动选择城市"
        default: manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard locationBusy, let found = locations.last, found.horizontalAccuracy >= 0,
              abs(found.timestamp.timeIntervalSinceNow) < 300 else { return }
        locationTimeout?.cancel(); manager.stopUpdatingLocation()
        locationTask = Task { [weak self] in
            guard let self else { return }
            let marks = try? await self.geocoder.reverseGeocodeLocation(found)
            guard !Task.isCancelled else { return }
            let value = marks?.first.flatMap(Self.city) ?? .init(name: L10n.text("当前位置"), latitude: found.coordinate.latitude, longitude: found.coordinate.longitude)
            self.locationBusy = false; self.select(value)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard locationBusy else { return }
        cancelLocation(); locationStatus = "无法获取位置，请重试或手动选择城市"
    }

    private func fetch(forecastHours: Int = 24) async throws -> WatchWeatherSnapshot {
        guard available, let cloud, let location else { throw CancellationError() }
        if let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) < 900 { return snapshot }
        if let fetchTask { return try await fetchTask.value }
        let id = generation
        let selectedSource = source
        let task = Task {
            if selectedSource == .openMeteo { return try await openMeteo.fetch(latitude: location.latitude, longitude: location.longitude, city: location.name) }
            return try await cloud.fetchWeather(latitude: location.latitude, longitude: location.longitude, city: location.name, forecastHours: max(24, forecastHours))
        }
        fetchTask = task
        do {
            let result = try await task.value
            guard available, generation == id, !Task.isCancelled else { throw CancellationError() }
            fetchTask = nil; snapshot = result; lastFetched = result.fetchedAt
            missingSections = result.unavailableSections
            return result
        } catch {
            if generation == id { fetchTask = nil; status = (error as? GarminWeatherError)?.localizedDescription ?? "天气更新失败，请稍后重试" }
            throw error
        }
    }

    private func refreshIfDue() {
        guard available, bluetooth?.protocolReady == true, Date().timeIntervalSince(lastAttempt) >= 900 else { return }
        refresh()
    }

    func refresh() {
        guard available, !refreshing else { return }
        lastAttempt = Date(); refreshing = true; status = "正在更新天气"
        let id = generation
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.fetch()
                guard self.generation == id, !Task.isCancelled else { return }
                self.status = self.bluetooth?.sendWeather(result) == true ? "正在发送天气至手表" : "天气已获取，等待手表连接"
            } catch { /* fetch publishes a safe, localized error */ }
            if self.generation == id { self.refreshing = false; self.refreshTask = nil }
        }
    }
}
