import Foundation
import Combine
@preconcurrency import CoreBluetooth

struct GATTEntry: Codable, Identifiable {
    var id: String { service + "/" + characteristic }
    let service: String
    let characteristic: String
    let properties: String
}

enum WatchUUID {
    static func garmin(_ short: String) -> CBUUID { CBUUID(string: "6A4E\(short)-667B-11E3-949A-0800200C9A66") }
    static let heartService = CBUUID(string: "180D")
    static let heartMeasurement = CBUUID(string: "2A37")
    static let realtimeService = garmin("2500")
    static let realtimeHeart = garmin("2501")
    static let realtimeSteps = garmin("2502")
    static let realtimeStress = garmin("2508")
    static let multiLinkService = garmin("2800")
}

@MainActor
final class WatchBluetooth: NSObject, ObservableObject {
    @Published var status = "尚未连接"
    @Published var bluetoothStatus = "前往设备页面，按引导授权并连接"
    @Published var isScanning = false
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var connectedName = "本能 2 太阳能"
    @Published var nearby: [NearbyWatch] = []
    @Published var gatt: [GATTEntry] = []
    @Published var availableMetrics: Set<MetricKind> = []
    @Published var transferStatus = "连接后检测文件同步能力"
    @Published var canSyncFiles = false
    @Published private(set) var protocolReady = false
    @Published private(set) var liveSampleCount = 0
    @Published private(set) var lastLiveSampleAt: Date?
    @Published private(set) var registeredMetrics: Set<MetricKind> = []
    var isTransferringFiles: Bool { session?.isSyncing == true }
    @Published var showAllDevices = false { didSet { publishNearby() } }
    private(set) var archiveRegion: GarminRegion = .china
    @Published var autoReconnect = AppPreferences.shared.object(forKey: "watchAutoReconnect") as? Bool ?? true {
        didSet { AppPreferences.shared.set(autoReconnect, forKey: "watchAutoReconnect"); if !autoReconnect { reconnectTask?.cancel(); recoveryTarget = nil } }
    }
    @Published var connectsOnLaunch = AppPreferences.shared.bool(forKey: "watchConnectOnLaunch") {
        didSet { AppPreferences.shared.set(connectsOnLaunch, forKey: "watchConnectOnLaunch") }
    }
    @Published private(set) var sessionActivated = false
    var onSample: ((MetricSample) -> Void)?
    var onUnavailable: ((MetricKind, String) -> Void)?
    var onLog: ((String) -> Void)?
    var accountGUID: String?
    var onFile: ((URL, GFDIFileMetadata) -> Void)?
    var onDeviceID: ((String) -> Void)?
    var onSyncFinished: ((Bool) -> Void)?
    var onFilesAvailable: (() -> Void)?

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var discovery = WatchDiscoveryStore()
    private var discoveryPublication: Task<Void, Never>?
    private var selected: CBPeripheral?
    private var connectRequested = false
    private var pendingScan = false
    private var reconnectTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var connectTimeout: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var recoveryTarget: UUID?
    private var tx: CBCharacteristic?
    private var rx: CBCharacteristic?
    private var session: GFDISession?
    private var outbound: [Data] = []
    private var waitingForResponse = false
    private var sessionStarted = false
    private var subscribed: Set<String> = []
    private var writeCompletion: ((Error?) -> Void)?
    var permissionState: Int { CBCentralManager.authorization.rawValue }
    var managerState: Int? { central?.state.rawValue }
    var access: BluetoothAccess { BluetoothAccess(rawValue: permissionState) ?? .restricted }
    var hasSavedWatch: Bool { AppPreferences.shared.string(forKey: "watchIdentifier").flatMap(UUID.init(uuidString:)) != nil }
    var savedWatchName: String { AppPreferences.shared.string(forKey: "watchName") ?? "已配对手表" }

    private func initialize() {
        guard central == nil, !PulseRuntime.isPreview else { return }
        sessionActivated = true
        bluetoothStatus = "正在初始化蓝牙；首次使用需确认系统授权提示"
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        // Catch up to an already powered-on manager when restoring a background session.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, let central = self.central, central.state != .unknown else { return }
            self.centralManagerDidUpdateState(central)
        }
    }

    func scan() {
        if !isConnected { beginPairing(); return }
        initialize(); pendingScan = true
        if central?.state == .poweredOn { performScan() }
    }

    func beginPairing() {
        reconnectTask?.cancel(); reconnectTask = nil; connectTimeout?.cancel(); reconnectAttempt = 0
        connectRequested = false; recoveryTarget = nil
        let old = selected; selected = nil
        if let old { central?.cancelPeripheralConnection(old) }
        session?.disconnected(); session = nil; clearConnectionData()
        status = "请在手表进入“手机 → 配对手机”，然后选择发现的 Garmin 手表"
        initialize(); pendingScan = true
        if central?.state == .poweredOn { performScan() }
    }

    func retryProtocol() {
        guard isConnected, let session else { beginPairing(); return }
        protocolReady = false; canSyncFiles = false; registeredMetrics.removeAll()
        session.transportReady()
    }

    func forgetSavedWatch() {
        disconnect(); selected = nil; peripherals.removeAll(); discovery.reset(); nearby.removeAll()
        AppPreferences.shared.removeObject(forKey: "watchIdentifier")
        AppPreferences.shared.removeObject(forKey: "watchName")
        status = "已清除软件保存的手表连接，可重新扫描配对"
        transferStatus = "等候重新建立佳明协议通道"
        onLog?(status)
    }

    private func clearConnectionData() {
        isConnected = false; isConnecting = false; canSyncFiles = false; protocolReady = false
        availableMetrics.removeAll(); registeredMetrics.removeAll(); liveSampleCount = 0; lastLiveSampleAt = nil
        outbound.removeAll(); tx = nil; rx = nil; sessionStarted = false; waitingForResponse = false
    }

    private func performScan() {
        guard let central, central.state == .poweredOn else { return }
        pendingScan = false; discovery.reset(); nearby.removeAll()
        peripherals = peripherals.filter { $0.key == selected?.identifier }; isScanning = true
        bluetoothStatus = "正在扫描附近蓝牙设备"
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        discoveryPublication?.cancel()
        discoveryPublication = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                guard let self, self.isScanning else { return }
                self.publishNearby()
            }
        }
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            self?.stopScan()
            if let self, self.connectRequested, self.autoReconnect, !self.isConnected, !self.isConnecting { self.scheduleReconnect() }
        }
    }

    func stopScan() {
        central?.stopScan(); isScanning = false; pendingScan = false; scanTask?.cancel(); recoveryTarget = nil
        discoveryPublication?.cancel(); publishNearby()
        if central?.state == .poweredOn { bluetoothStatus = "蓝牙已开启" }
    }

    private func publishNearby() {
        let current = discovery.visible(now: Date()).filter { showAllDevices || $0.offersGarmin }
        if nearby != current { nearby = current }
        let keep = Set(current.map(\.id))
        peripherals = peripherals.filter { keep.contains($0.key) || $0.key == selected?.identifier }
    }

    func connect(_ id: UUID) {
        initialize(); stopScan(); reconnectTask?.cancel()
        guard let central, central.state == .poweredOn else { status = "请先开启并授权蓝牙"; return }
        guard let peripheral = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            status = "找不到已保存的手表，请重新扫描"; return
        }
        if let old = selected, old.identifier == id, isConnected || isConnecting { return }
        if let old = selected, old.identifier != id { central.cancelPeripheralConnection(old) }
        connectTimeout?.cancel(); session?.disconnected(); session = nil
        clearConnectionData(); isConnecting = true
        selected = peripheral; peripheral.delegate = self; connectRequested = true
        connectedName = peripheral.name ?? nearby.first(where: { $0.id == id })?.name ?? "Garmin 手表"
        status = "正在连接 \(connectedName)"
        central.connect(peripheral, options: nil)
        connectTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, self.selected?.identifier == id, !self.isConnected else { return }
            // A temporary absence must not permanently stop the user's saved background
            // connection. Each attempt remains bounded; callbacks retry with backoff.
            self.connectRequested = self.autoReconnect && AppPreferences.shared.string(forKey: "watchIdentifier") == id.uuidString
            self.isConnecting = false
            central.cancelPeripheralConnection(peripheral)
            self.status = self.connectRequested ? "暂时找不到已保存的手表，将自动重试" : "连接超时，请打开手表的手机连接或配对模式，再扫描"
            self.onLog?(self.status)
        }
    }

    func reconnectSaved() {
        guard let value = AppPreferences.shared.string(forKey: "watchIdentifier"), let id = UUID(uuidString: value) else {
            onLog?("尚未读取到已保存的手表选择，请扫描连接")
            return
        }
        onLog?("正在恢复已保存的手表连接")
        initialize(); connectRequested = true
        if central?.state == .poweredOn { connect(id) }
    }

    func connectAutomaticallyAtLaunch() {
        guard ConnectionStartupPolicy.canConnect(automatically: connectsOnLaunch, savedWatch: hasSavedWatch,
                                                  access: access, preview: PulseRuntime.isPreview) else { return }
        reconnectSaved()
    }

    func resumeRequestedConnection() {
        guard sessionActivated, connectRequested, autoReconnect, !isConnected, !isConnecting else { return }
        reconnectSaved()
    }

    func disconnect() {
        connectRequested = false; isConnecting = false; connectTimeout?.cancel()
        reconnectTask?.cancel(); reconnectTask = nil
        if let selected { central?.cancelPeripheralConnection(selected) }
        stopScan(); session?.disconnected(); session = nil; clearConnectionData(); status = "已断开连接"
    }

    func requestFileSync() {
        guard canSyncFiles else { transferStatus = "当前连接尚未提供文件同步通道"; return }
        session?.requestSync()
    }

    func requestRecentActivity() {
        guard canSyncFiles else { transferStatus = "当前连接尚未提供文件同步通道"; return }
        session?.requestSync(includeArchivedActivities: true)
    }

    func updateAccountGUID(_ guid: String?) {
        accountGUID = guid
        session?.setAccountGUID(guid)
    }

    func updateCloudRegion(_ region: GarminRegion) {
        guard archiveRegion != region else { return }
        archiveRegion = region
        if isConnected || isConnecting {
            disconnect(); status = "账户区域已切换，请重新连接手表核对归属"
        }
    }

    func diagnosticsURL() -> URL {
        let url = AppPaths.root.appendingPathComponent("Bluetooth-services.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(gatt) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return url
    }

    private func scheduleReconnect() {
        guard autoReconnect, connectRequested, let selected else { return }
        reconnectAttempt += 1
        let seconds = min(30, 2 * reconnectAttempt)
        status = "连接中断，\(seconds) 秒后重连"
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled, let self, self.connectRequested else { return }
            if self.reconnectAttempt <= 2 { self.connect(selected.identifier) }
            else {
                self.recoveryTarget = selected.identifier
                self.status = "正在重新发现已保存的手表；若列表出现新连接，请选择它"
                self.performScan()
            }
        }
    }

    private func setupTransfer(in service: CBService, characteristics: [CBCharacteristic]) {
        guard service.uuid == WatchUUID.multiLinkService, tx == nil else { return }
        for index in 0...4 {
            let readUUID = WatchUUID.garmin(String(format: "%04X", 0x2810 + index))
            let writeUUID = WatchUUID.garmin(String(format: "%04X", 0x2820 + index))
            if let rx = characteristics.first(where: { $0.uuid == readUUID }),
               let tx = characteristics.first(where: { $0.uuid == writeUUID }),
               rx.properties.contains(.notify) || rx.properties.contains(.indicate),
               tx.properties.contains(.write) || tx.properties.contains(.writeWithoutResponse) {
                self.rx = rx; self.tx = tx
                selected?.setNotifyValue(true, for: rx)
                transferStatus = "正在建立 Garmin 文件通道"
                return
            }
        }
        transferStatus = "发现 Garmin 服务，尚无匹配的文件通道"
    }

    private func startSession() {
        guard !sessionStarted, let selected, let tx, let rx, rx.isNotifying else { return }
        sessionStarted = true
        let engine = GFDISession(storageDirectory: archiveRegion.receiveDirectory(root: AppPaths.directory("Received")))
        session = engine
        engine.maximumWriteLength = selected.maximumWriteValueLength(for: tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)
        engine.onSend = { [weak self] data in self?.outbound.append(data); self?.drainWrites() }
        engine.onStatus = { [weak self] text in
            guard let self else { return }
            self.transferStatus = text
            self.protocolReady = self.session?.isReady == true
            self.canSyncFiles = self.session?.canTransferFiles == true
            let services = self.session?.registeredRealtimeServices ?? []
            self.registeredMetrics = Set(MetricKind.allCases.filter { $0.definition.service.map { services.contains($0) } ?? false })
            self.onLog?(text)
        }
        engine.onFile = { [weak self] url, metadata in self?.onFile?(url, metadata) }
        engine.onSyncFinished = { [weak self] success in self?.onSyncFinished?(success) }
        engine.onFilesAvailable = { [weak self] in self?.onFilesAvailable?() }
        engine.onRealtimeData = { [weak self] serviceID, data in
            guard let self else { return }
            do {
                let (kind, value) = try MetricPacketParser.realtime(service: serviceID, data: data)
                self.availableMetrics.insert(kind)
                self.liveSampleCount += 1; self.lastLiveSampleAt = Date()
                self.onSample?(MetricSample(kind: kind, value: value, source: "Garmin 实时\(kind.definition.title)"))
            } catch {
                let kind = MetricKind.allCases.first { $0.definition.service == serviceID }
                if let kind { self.onUnavailable?(kind, "手表暂未提供有效读数") }
            }
        }
        engine.onDeviceInfo = { [weak self] info in
            self?.onDeviceID?(String(info.deviceID))
            self?.canSyncFiles = self?.session?.canTransferFiles == true
        }
        engine.onTransportRedirect = { [weak self] readUUID, writeUUID in
            guard let self, let selected = self.selected else { return }
            let all = selected.services?.flatMap { $0.characteristics ?? [] } ?? []
            guard let newRX = all.first(where: { $0.uuid == CBUUID(nsuuid: readUUID) }),
                  let newTX = all.first(where: { $0.uuid == CBUUID(nsuuid: writeUUID) }) else {
                self.transferStatus = "手表请求另一通道，请断开重连"; return
            }
            self.tx = newTX; self.rx = newRX
            self.canSyncFiles = false; self.protocolReady = false
            self.session?.maximumWriteLength = selected.maximumWriteValueLength(for: newTX.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)
            self.outbound.removeAll(); self.waitingForResponse = false
            selected.setNotifyValue(true, for: newRX)
        }
        canSyncFiles = false
        engine.connected(accountGUID: accountGUID)
        engine.replayPendingFiles()
    }

    private func drainWrites() {
        guard let selected, let tx, !waitingForResponse else { return }
        let withoutResponse = tx.properties.contains(.writeWithoutResponse)
        while !outbound.isEmpty {
            if withoutResponse && !selected.canSendWriteWithoutResponse { return }
            let data = outbound.removeFirst()
            selected.writeValue(data, for: tx, type: withoutResponse ? .withoutResponse : .withResponse)
            if !withoutResponse { waitingForResponse = true; return }
        }
    }

    private func processValue(_ characteristic: CBCharacteristic, data: Data) {
        if characteristic.uuid == CBUUID(string: "2A19"), let value = data.first, value <= 100 {
            availableMetrics.insert(.watchBattery)
            onSample?(MetricSample(kind: .watchBattery, value: Int(value), source: "手表电池服务"))
            return
        }
        if let kind = MetricKind.allCases.first(where: { $0.definition.characteristic.map { CBUUID(nsuuid: GFDISession.uuid(short: $0)) } == characteristic.uuid }),
           let service = kind.definition.service, ![6, 7, 13].contains(service) {
            do {
                let (_, value) = try MetricPacketParser.realtime(service: service, data: data)
                availableMetrics.insert(kind); liveSampleCount += 1; lastLiveSampleAt = Date(); onSample?(MetricSample(kind: kind, value: value, source: "Garmin 实时\(kind.definition.title)"))
            } catch { onUnavailable?(kind, "手表暂未提供有效读数") }
            return
        }
        let kind: MetricKind
        let parse: (Data) throws -> Int
        let source: String
        switch characteristic.uuid {
        case WatchUUID.heartMeasurement: return // The companion now uses Garmin protocols exclusively.
        case WatchUUID.realtimeHeart:
            kind = .heartRate; parse = MetricPacketParser.garminHeartRate; source = "Garmin 实时心率"
        case WatchUUID.realtimeSteps:
            kind = .steps; parse = MetricPacketParser.garminSteps; source = "Garmin 实时步数"
        case WatchUUID.realtimeStress:
            kind = .stress; parse = MetricPacketParser.garminStress; source = "Garmin 实时压力"
        default:
            if characteristic.uuid == rx?.uuid { session?.receive(data) }
            return
        }
        do {
            let value = try parse(data)
            onSample?(MetricSample(kind: kind, value: value, source: source))
        } catch { onUnavailable?(kind, "手表暂未提供有效读数") }
    }
}

// Swift 6 supports isolated conformances through @preconcurrency. Keep the
// delegate implementations on the main actor with the older Swift 5 toolchain
// too; CoreBluetooth delivers them on the configured main queue.
#if compiler(>=6.0)
extension WatchBluetooth: @preconcurrency CBCentralManagerDelegate {}
extension WatchBluetooth: @preconcurrency CBPeripheralDelegate {}
#else
extension WatchBluetooth: CBCentralManagerDelegate {}
extension WatchBluetooth: CBPeripheralDelegate {}
#endif

extension WatchBluetooth {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothStatus = "蓝牙已开启"
            if pendingScan { performScan() }
            else if connectRequested, let string = AppPreferences.shared.string(forKey: "watchIdentifier"), let id = UUID(uuidString: string) { connect(id) }
        case .poweredOff:
            stopScan(); session?.disconnected(); session = nil; clearConnectionData()
            if !autoReconnect { connectRequested = false }
            bluetoothStatus = "蓝牙已关闭"; status = "请开启 Mac 蓝牙"
        case .unauthorized: bluetoothStatus = "蓝牙权限未授权"; status = "请在系统设置中允许 WristBeam 使用蓝牙"
        case .unsupported: bluetoothStatus = "此电脑不支持蓝牙 LE"
        case .resetting: bluetoothStatus = "蓝牙正在重新启动"
        case .unknown: bluetoothStatus = "正在初始化蓝牙"
        @unknown default: bluetoothStatus = "蓝牙状态未知"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "未命名设备"
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let hasHeart = services.contains(WatchUUID.heartService)
        let isGarmin = discovery.knowsGarmin(peripheral.identifier) || services.contains(WatchUUID.multiLinkService) || services.contains(WatchUUID.realtimeService)
            || name.localizedCaseInsensitiveContains("garmin") || name.localizedCaseInsensitiveContains("instinct") || name.contains("本能")
        guard showAllDevices || isGarmin else { return }
        peripherals[peripheral.identifier] = peripheral
        let now = Date(), wasKnown = discovery.contains(peripheral.identifier)
        let watch = NearbyWatch(id: peripheral.identifier, name: name, rssi: RSSI.intValue > 0 ? -127 : RSSI.intValue, lastSeen: now, offersHeartRate: hasHeart, offersGarmin: isGarmin)
        discovery.insert(watch, now: now)
        if !wasKnown && isGarmin { onLog?("发现 \(name)") }
        if isGarmin, recoveryTarget == peripheral.identifier, connectRequested, !isConnecting { connect(peripheral.identifier) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == selected?.identifier else { return }
        connectTimeout?.cancel(); isConnecting = false
        reconnectAttempt = 0; isConnected = true; status = "已连接 \(connectedName)"
        gatt.removeAll(); availableMetrics.removeAll(); registeredMetrics.removeAll(); subscribed.removeAll(); canSyncFiles = false; protocolReady = false; liveSampleCount = 0; lastLiveSampleAt = nil
        tx = nil; rx = nil; sessionStarted = false; waitingForResponse = false; outbound.removeAll()
        peripheral.delegate = self; peripheral.discoverServices(nil)
        onLog?("已连接 \(connectedName)，正在发现可用指标")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == selected?.identifier else { return }
        connectTimeout?.cancel(); isConnecting = false
        isConnected = false; status = "连接失败：\(error?.localizedDescription ?? "未知错误")"
        onLog?(status); scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == selected?.identifier else { return }
        connectTimeout?.cancel(); isConnecting = false
        session?.disconnected(); session = nil; clearConnectionData()
        if connectRequested { scheduleReconnect() } else if !status.hasPrefix("连接超时") { status = "已断开连接" }
        let reason = error.map { "（\(($0 as NSError).domain) \(($0 as NSError).code)：\($0.localizedDescription)）" } ?? ""
        onLog?("手表已断开\(reason)")
    }
}

extension WatchBluetooth {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == selected?.identifier else { return }
        if let error { onLog?("服务发现失败：\(error.localizedDescription)"); return }
        if (peripheral.services ?? []).contains(where: { [WatchUUID.realtimeService, WatchUUID.multiLinkService].contains($0.uuid) }) {
            AppPreferences.shared.set(peripheral.identifier.uuidString, forKey: "watchIdentifier")
            AppPreferences.shared.set(connectedName, forKey: "watchName")
        } else {
            disconnect(); status = "当前连接没有 Garmin 服务。请保持心率广播关闭，进入手表的手机配对界面重新扫描。"
            onLog?(status); return
        }
        for service in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral.identifier == selected?.identifier else { return }
        if let error { onLog?("指标发现失败：\(error.localizedDescription)"); return }
        let characteristics = service.characteristics ?? []
        for characteristic in characteristics {
            var properties: [String] = []
            if characteristic.properties.contains(.read) { properties.append("read") }
            if characteristic.properties.contains(.notify) { properties.append("notify") }
            if characteristic.properties.contains(.indicate) { properties.append("indicate") }
            if characteristic.properties.contains(.write) { properties.append("write") }
            if characteristic.properties.contains(.writeWithoutResponse) { properties.append("writeWithoutResponse") }
            gatt.append(GATTEntry(service: service.uuid.uuidString, characteristic: characteristic.uuid.uuidString, properties: properties.joined(separator: ", ")))
            let metric: MetricKind?
            if characteristic.uuid == WatchUUID.heartMeasurement { metric = nil }
            else if service.uuid == CBUUID(string: "180F"), characteristic.uuid == CBUUID(string: "2A19") { metric = .watchBattery }
            else { metric = MetricKind.allCases.first { $0.definition.characteristic.map { CBUUID(nsuuid: GFDISession.uuid(short: $0)) } == characteristic.uuid } }
            if let metric {
                availableMetrics.insert(metric)
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
                if characteristic.properties.contains(.read) { peripheral.readValue(for: characteristic) }
            }
        }
        setupTransfer(in: service, characteristics: characteristics)
        _ = diagnosticsURL()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == selected?.identifier else { return }
        if let error { onLog?("订阅失败：\(error.localizedDescription)"); return }
        if characteristic.isNotifying { subscribed.insert(characteristic.uuid.uuidString) }
        if characteristic.uuid == rx?.uuid {
            if sessionStarted { session?.transportReady() } else { startSession() }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == selected?.identifier else { return }
        if let error { onLog?("读取失败：\(error.localizedDescription)"); return }
        guard let data = characteristic.value else { return }
        processValue(characteristic, data: data)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == selected?.identifier, characteristic.uuid == tx?.uuid else { return }
        waitingForResponse = false
        if let error { onLog?("发送失败：\(error.localizedDescription)"); session?.disconnected(); canSyncFiles = false; return }
        drainWrites()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { drainWrites() }
}
