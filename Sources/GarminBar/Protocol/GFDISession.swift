import Foundation

// Protocol evidence (independent Swift implementation; no third-party implementation copied):
// supplied APK nj2/m, nj2/g, nj2/l, oj2/d/h: multilink UUIDs/register/status/handle routing;
// gr2/a: device info and configuration; dr2/c/i: old file request/block wire fields;
// GDICore/GDICoreExtension generated descriptors: account identity query protobuf fields.
// Characteristic pairs and companion client 2 corroborated by primary community sources:
// https://github.com/wh1le/garmin-bridge/blob/main/src/protocol/transport.py
// https://codeberg.org/Freeyourgadget/Gadgetbridge/src/branch/master/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/garmin/communicator/v2/CommunicatorV2.java
// APK ff2/c: realtime registers on services 6, 7 and 13; notifications carry their raw parser data.
// Optional [handle, 1] start fallback is a community compatibility path, not required by APK:
// https://github.com/gwerneckp/garmin-ble/blob/main/garmin_ble/watch.py
// Community code licenses were consulted as references to wire observations, not ported.

struct GFDIDeviceInfo: Equatable {
    let protocolVersion: Int
    let productNumber: Int
    let unitID: UInt32
    let softwareVersion: Int
    let maximumPacketSize: Int
    let friendlyName: String
    let deviceName: String
    let modelName: String
    var configurationFlags = Set<Int>()
    var deviceID: UInt32 { unitID }
    var needsNativeMLR: Bool { configurationFlags.contains(90) }
}

enum GFDITransportMode { case multiLink, legacy }

/// Owns Garmin framing and multiplexing, while the caller owns CoreBluetooth and its write queue.
/// All callbacks run on the main actor. `onSend` is an ordered, MTU-sized GATT write.
/// Call `connected` only after notifications are enabled; forward their raw bytes to `receive`.
/// Connection does not clear other clients' handles, pair/reset the watch or change its account.
@MainActor
final class GFDISession {
    var onSend: ((Data) -> Void)?
    var onDiagnosticMessage: ((GFDIMessage, GFDIRequestLog.Direction) -> Void)?
    var onStatus: ((String) -> Void)?
    var onFile: ((URL, GFDIFileMetadata) -> Void)?
    var onDeviceInfo: ((GFDIDeviceInfo) -> Void)?
    var onRealtimeData: ((UInt16, Data) -> Void)?
    var onBatteryReading: ((GFDIBattery.Reading) -> Void)?
    var weatherProvider: ((GFDIWeatherRequest) async throws -> WatchWeatherSnapshot)?
    var onWeatherDelivery: ((Bool) -> Void)?
    private(set) var weatherEnabled = false
    private var weatherConfigurationDirty = false
    private var weatherTask: Task<Void, Never>?
    private var weatherGeneration = UUID()
    private var weatherFrames: [GFDIMessage] = []
    /// ALREADY_IN_USE supplies a new Garmin RX short UUID. Enable its notifications and call
    /// `transportReady` when the redirected characteristic pair is ready.
    var onTransportRedirect: ((UUID, UUID) -> Void)?
    var onSyncFinished: ((Bool) -> Void)?
    var onFilesAvailable: (() -> Void)?

    var transportMode: GFDITransportMode = .multiLink
    var maximumWriteLength = 20
    private(set) var deviceInfo: GFDIDeviceInfo?
    private(set) var isReady = false
    private(set) var isSyncing = false
    private(set) var cloudIdentityMatches: Bool?
    var canTransferFiles: Bool {
        isReady && !authenticationUnsupported && deviceInfo?.needsNativeMLR != true && cloudIdentityMatches != false
            && (deviceInfo?.configurationFlags.contains(4) != true || handshakeCompleted)
            && (deviceInfo?.configurationFlags.contains(95) != true || accountGUID == nil || cloudIdentityMatches == true)
    }
    var registeredRealtimeServices: Set<UInt16> { Set(handles.values.filter { Self.realtimeServices.contains($0) }) }
    let storageDirectory: URL

    static let serviceUUID = UUID(uuidString: "6A4E2800-667B-11E3-949A-0800200C9A66")!
    static let realtimeServices: [UInt16] = MetricKind.allCases.compactMap { $0.definition.service }
    static func uuid(short: UInt16) -> UUID { UUID(uuidString: String(format: "6A4E%04X-667B-11E3-949A-0800200C9A66", short))! }

    // The supplied APK's client_config.xml uses 1 for Connect Mobile. Published Gadgetbridge
    // and garmin-bridge captures use 2 for an independent companion client; random IDs are
    // not assumed to be accepted by firmware. Never CLOSE_ALL the phone's client 1.
    private let clientID: UInt64 = 2
    private var connectedToTransport = false
    private var accountGUID: String?
    private var decoder = GFDIStreamDecoder()
    private var handles: [UInt8: UInt16] = [:]
    private var pendingRegistrations: [UInt16: Date] = [:]
    private var registrationAttempts: [UInt16: Int] = [:]
    private var realtimeStartDeadlines: [UInt16: Date] = [:]
    private var realtimeHasData = Set<UInt16>()
    private var handshakeDeadline: Date?
    private var handshakeCompletionPending = false
    private var handshakeCompleted = false
    private var watchdog: Task<Void, Never>?
    private var pending: [UInt16: Request] = [:]
    private var fileQueue: [GFDIDirectoryEntry] = []
    private var transfer: Transfer?
    private var queuedSync = false
    private var authenticationUnsupported = false
    private var identityDeadline: Date?
    private var identityQueryID: UInt16 = 0
    private var protobufQueryID: UInt16 = 0
    private var batteryQueryID: UInt16?
    private var batteryTransfer: GFDIBatteryTransfer?
    private var batteryDeadline: Date?
    private var batteryUsesLegacy = false
    private var nextBatteryRefresh = Date.distantPast
    private var batteryNotification: GFDIBatteryTransfer?
    private var batteryNotificationDeadline: Date?
    private var identityBuffer = Data()
    private var identityExpectedSize = 0
    private var redirects = 0
    private var downloadedThisSession = Set<String>()
    private var includeArchivedActivities = false
    private var filesSavedThisSync = 0

    private struct Request {
        let message: GFDIMessage
        var deadline: Date
        var retries: Int
        let completion: (Result<Data, Error>) -> Void
    }
    private struct Transfer {
        let index: Int
        let entry: GFDIDirectoryEntry?
        var receiver: GFDIFileReceiver
        var data: Data
        var deadline: Date
    }
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(storageDirectory: URL) {
        self.storageDirectory = storageDirectory
    }

    deinit { watchdog?.cancel() }

    func connected(accountGUID: String? = nil) {
        disconnected(report: false)
        self.accountGUID = accountGUID
        connectedToTransport = true
        authenticationUnsupported = false
        cloudIdentityMatches = nil
        redirects = 0
        downloadedThisSession.removeAll()
        startWatchdog()
        if transportMode == .multiLink {
            status("正在注册手表蓝牙通道")
            register(service: 4) // Registration service, without CLOSE_ALL.
        } else {
            handshakeDeadline = Date().addingTimeInterval(20)
            status("蓝牙通道已连接，等待手表设备信息")
        }
    }

    func disconnected() { disconnected(report: true) }

    private func disconnected(report: Bool) {
        cancelWeather()
        connectedToTransport = false
        isReady = false
        isSyncing = false
        decoder = GFDIStreamDecoder()
        handles.removeAll()
        pendingRegistrations.removeAll()
        registrationAttempts.removeAll()
        realtimeStartDeadlines.removeAll()
        realtimeHasData.removeAll()
        handshakeDeadline = nil
        handshakeCompletionPending = false
        handshakeCompleted = false
        identityDeadline = nil
        identityBuffer.removeAll()
        resetBatteryRequests()
        transfer = nil
        fileQueue.removeAll()
        queuedSync = false
        let abandoned = Array(pending.values)
        pending.removeAll()
        watchdog?.cancel()
        watchdog = nil
        for request in abandoned { request.completion(.failure(Failure(message: "手表蓝牙连接已断开"))) }
        if report { status("手表蓝牙连接已断开，本地待上传文件已保留") }
    }

    func transportReady() {
        guard connectedToTransport else { return }
        cancelWeather()
        // A characteristic redirect invalidates the previous packet stream and pending request
        // correlation. Restart read tasks at zero; their original watch files remain untouched.
        isReady = false
        isSyncing = false
        transfer = nil
        fileQueue.removeAll()
        pending.removeAll()
        identityDeadline = nil
        resetBatteryRequests()
        handshakeDeadline = nil
        handshakeCompletionPending = false
        handshakeCompleted = false
        pendingRegistrations.removeAll()
        registrationAttempts.removeAll()
        realtimeStartDeadlines.removeAll(); realtimeHasData.removeAll()
        handles.removeAll()
        decoder = GFDIStreamDecoder()
        register(service: 4)
    }

    func setAccountGUID(_ guid: String?) {
        accountGUID = guid
        cloudIdentityMatches = nil
        identityDeadline = nil
        if isReady { checkIdentityThenSync() }
    }

    func replayPendingFiles() {
        do { for (url, metadata) in try GFDIFileArchive.pendingFiles(root: storageDirectory) { onFile?(url, metadata) } }
        catch { status("无法读取本地上传队列：\(error.localizedDescription)") }
    }

    func requestSync(includeArchivedActivities: Bool = false) {
        guard connectedToTransport else { status("请先连接手表；已保存的文件可继续上传"); return }
        guard !isSyncing else { return }
        guard !authenticationUnsupported else { status("手表要求 Garmin 应用层加密，当前版本无法传输文件"); return }
        guard deviceInfo?.needsNativeMLR != true else { status("手表启用 CoreTransfer / MLR（能力 90）；本版本仅支持旧文件协议，实时订阅可继续"); return }
        self.includeArchivedActivities = includeArchivedActivities
        queuedSync = true
        guard isReady else { status("正在等待手表完成协议握手"); return }
        checkIdentityThenSync()
    }

    func receive(_ data: Data) {
        guard connectedToTransport, !data.isEmpty else { return }
        if transportMode == .multiLink {
            let bytes = Array(data)
            if bytes[0] == 0 { receiveControl(data); return }
            guard let service = handles[bytes[0]] else { return }
            let payload = Data(bytes.dropFirst())
            if Self.realtimeServices.contains(service) {
                realtimeHasData.insert(service)
                onRealtimeData?(service, payload)
                return
            }
            guard service == 1 else { return }
            receiveGFDI(payload)
        } else {
            receiveGFDI(data)
        }
    }

    private func register(service: UInt16) {
        guard connectedToTransport, !handles.values.contains(service), pendingRegistrations[service] == nil else { return }
        var writer = GFDIWriter()
        writer.u8(0)
        writer.u8(0)
        writer.u64(clientID)
        writer.u16(service)
        writer.u8(0) // Request the non-reliable path. Native MLR is not implemented.
        pendingRegistrations[service] = Date().addingTimeInterval(30)
        registrationAttempts[service, default: 0] += 1
        onSend?(Data(writer.bytes))
    }

    private func registerApplicationServices() {
        register(service: 1)
        for realtime in Self.realtimeServices { register(service: realtime) }
    }

    private func receiveControl(_ data: Data) {
        do {
            var reader = GFDIReader(data)
            guard try reader.u8() == 0 else { return }
            let command = try reader.u8()
            let respondingClient = try reader.u64()
            let service = try reader.u16()
            guard respondingClient == clientID else { return }
            if command == 1 {
                let result = try reader.u8()
                guard pendingRegistrations[service] != nil else { return }
                if result == 2 {
                    // Authentication can finish after this response. Re-register a bounded
                    // number of times rather than leaving a connected but silent session.
                    pendingRegistrations[service] = Date().addingTimeInterval(10)
                    status("手表等待蓝牙认证，请在系统或手表上确认配对提示")
                    return
                }
                pendingRegistrations.removeValue(forKey: service)
                if result == 3 {
                    let short = try reader.u16()
                    guard redirects < 4 else { status("蓝牙通道正在被占用，请暂时断开手机的佳明连接再重试"); return }
                    redirects += 1
                    let tx: UInt16 = (short & 0xfff0) == 0x2810 ? short + 0x10 : short
                    guard onTransportRedirect != nil else { status("需要切换手表蓝牙通道，当前连接器未提供通道切换"); return }
                    status("正在切换可用手表蓝牙通道")
                    onTransportRedirect?(Self.uuid(short: short), Self.uuid(short: tx))
                    return
                }
                guard result == 0 else {
                    let description = result == 1 ? "不支持" : result == 4 ? "拒绝" : "返回错误 \(result)"
                    status("手表蓝牙服务 \(service) \(description)")
                    // Some legacy community implementations register GFDI directly. A missing
                    // optional REGISTRATION service must not suppress all realtime subscriptions.
                    if service == 4, result == 1 { registerApplicationServices() }
                    return
                }
                let handle = try reader.u8()
                guard handle != 0 else { throw GFDIProtocolError.invalidLength }
                let flags = reader.remaining > 0 ? try reader.u8() : 0
                if flags & 1 != 0 { status("手表服务 \(service) 要求 native MLR，本版本尚未支持"); return }
                handles[handle] = service
                if service == 4 {
                    registerApplicationServices()
                } else if service == 1 {
                    handshakeDeadline = Date().addingTimeInterval(20)
                    status("文件通道已连接，等待手表设备信息")
                } else if Self.realtimeServices.contains(service) {
                    // APK starts streaming on registration. Some older community captures need
                    // [handle, 1]; only send that fallback if registration yields no data.
                    realtimeStartDeadlines[service] = Date().addingTimeInterval(2)
                    status("实时服务 \(service) 已订阅")
                }
            } else if command == 3 || command == 4 {
                let handle = try reader.u8()
                if handles[handle] == 1 { cancelWeather(); isReady = false; abortSync("手表关闭了文件同步通道") }
                handles.removeValue(forKey: handle)
            }
        } catch { status("手表蓝牙控制响应无效：\(error.localizedDescription)") }
    }

    private func receiveGFDI(_ data: Data) {
        for result in decoder.receive(data) {
            switch result {
            case .success(let message): receiveMessage(message)
            case .failure(let error): status("丢弃损坏的手表消息：\(error.localizedDescription)")
            }
        }
    }

    private func send(_ message: GFDIMessage) {
        guard connectedToTransport else { return }
        do {
            let frame = try message.framed()
            let handle = handles.first(where: { $0.value == 1 })?.key
            guard transportMode != .multiLink || handle != nil else { return }
            onDiagnosticMessage?(message, .macQueued)
            let prefix = transportMode == .multiLink ? Data([handle!]) : Data()
            let size = max(1, maximumWriteLength - prefix.count)
            for start in stride(from: 0, to: frame.count, by: size) {
                onSend?(prefix + frame.subdata(in: start..<min(frame.count, start + size)))
            }
        } catch { status("无法编码手表请求：\(error.localizedDescription)") }
    }

    private func request(_ number: UInt16, payload: Data = Data(), completion: @escaping (Result<Data, Error>) -> Void) {
        guard pending[number] == nil else { completion(.failure(Failure(message: "同步请求正在处理中"))); return }
        let message = GFDIMessage(number: number, payload: payload)
        pending[number] = Request(message: message, deadline: Date().addingTimeInterval(10), retries: 1, completion: completion)
        send(message)
    }

    private func receiveMessage(_ message: GFDIMessage) {
        onDiagnosticMessage?(message, .watchToMac)
        do {
            switch message.number {
            case 5000:
                var reader = GFDIReader(message.payload)
                let number = try reader.u16()
                let result = try reader.u8()
                let responsePayload = try reader.data(reader.remaining)
                if number == 5043, receiveBatteryAcknowledgement(status: result, payload: responsePayload) { return }
                guard let request = pending.removeValue(forKey: number) else { return }
                if result == 0 { request.completion(.success(responsePayload)) }
                else { request.completion(.failure(Failure(message: "手表拒绝请求 \(number)（状态 \(result)）"))) }
            case 5024: try receiveDeviceInfo(message)
            case 5050: try receiveConfiguration(message)
            case 5009:
                guard message.payload.count >= 16 else { throw GFDIProtocolError.truncated }
                send(message.response()) // File-ready notification, APK br2/i.
                status("手表通知有新的已保存文件")
                onFilesAvailable?()
            case 5027:
                guard let count = message.payload.first, message.payload.count >= Int(count) + 1 else { throw GFDIProtocolError.truncated }
                send(message.response(payload: Data([0]))) // Queued download bitmap; no settings/firmware are sent.
                onFilesAvailable?()
            case 5037:
                guard message.payload.count >= 2, message.payload.count >= Int(message.payload[1]) + 2 else { throw GFDIProtocolError.truncated }
                send(message.response()) // Device-initiated sync, independent of HR broadcasting.
                status("手表请求检查原始文件")
                onFilesAvailable?()
            case 5052: try receiveTimeRequest(message)
            case 5014: receiveWeatherRequest(message)
            case 5004: receiveFileBlock(message)
            case 5054:
                // Read requests disable compression. Reject compressed data without inflating or
                // acknowledging bytes that were not verified and persisted.
                send(message.response(payload: Data([100, 0, 0, 0, 0])))
                abortSync("手表返回压缩文件块；当前版本只支持标准文件块，请重试")
            case 5022:
                send(message.response())
                abortSync("手表取消了本次文件传输，原始文件仍保留在手表")
            case 5023:
                let reading = try GFDIBattery.legacy(message.payload)
                send(message.response())
                if let reading {
                    if batteryUsesLegacy { batteryDeadline = nil }
                    onBatteryReading?(reading)
                }
            case 5043: receiveBatteryNotification(message)
            case 5044:
                var reader = GFDIReader(message.payload)
                if try reader.u16() == batteryQueryID { receiveBatteryResponse(message) }
                else { try receiveIdentityResponse(message) }
            case 5045:
                var reader = GFDIReader(message.payload)
                if try reader.u16() == batteryQueryID {
                    send(message.response(payload: message.payload)); batteryFallback()
                } else { send(message.response(status: 2)) }
            case 5101:
                authenticationUnsupported = true
                // No common algorithm / no saved application key. Do not start key generation,
                // alter an existing phone bond, or imply that an encrypted session is established.
                send(message.response(payload: Data([1, 0, 0, 0, 0, 0])))
                abortSync("手表要求 Garmin 应用层认证；本版本尚未实现密钥配对，实时订阅可继续尝试")
            case 5102...5111:
                authenticationUnsupported = true
                send(message.response(status: 2))
                abortSync("手表应用层加密尚未支持；没有修改手机已有配对")
            default: send(message.response(status: 2))
            }
        } catch {
            if message.number != 5000 { send(message.response(status: 5)) }
            status("无法解析手表消息 \(message.number)：\(error.localizedDescription)")
        }
    }

    private func receiveDeviceInfo(_ message: GFDIMessage) throws {
        var reader = GFDIReader(message.payload)
        let version = Int(try reader.u16())
        let product = Int(try reader.u16())
        let unit = try reader.u32()
        let software = Int(try reader.u16())
        let maxPacket = Int(try reader.u16())
        let friendly = try reader.string()
        let name = try reader.string()
        let model = try reader.string()
        guard unit != 0, maxPacket >= 6 else { throw GFDIProtocolError.invalidLength }
        deviceInfo = GFDIDeviceInfo(protocolVersion: version, productNumber: product, unitID: unit, softwareVersion: software, maximumPacketSize: maxPacket, friendlyName: friendly, deviceName: name, modelName: model)
        onDeviceInfo?(deviceInfo!)
        var host = GFDIWriter()
        host.u16(113) // APK's default legacy protocol; compact received headers are still accepted.
        host.u16(0xffff)
        host.u32(0xffff_ffff)
        host.u16(1)
        host.u16(0xffff)
        host.string("GarminBar")
        host.string("Apple")
        host.string("Mac")
        host.u8(1)
        send(message.response(payload: Data(host.bytes)))
        handshakeDeadline = Date().addingTimeInterval(20)
        status("已识别 \(name) \(model)，设备 \(unit)，等待能力协商")
    }

    private func receiveConfiguration(_ message: GFDIMessage) throws {
        var reader = GFDIReader(message.payload)
        let count = Int(try reader.u8())
        let bitmap = try reader.data(count)
        var flags = Set<Int>()
        for (index, byte) in bitmap.enumerated() {
            for bit in 0..<8 where byte & (1 << bit) != 0 { flags.insert(index * 8 + bit) }
        }
        guard var info = deviceInfo else { throw GFDIProtocolError.truncated }
        info.configurationFlags = flags
        deviceInfo = info
        onDeviceInfo?(info)
        send(message.response())
        // APK SupportedCapability / cj0/f: bit 0 is CONNECT_MOBILE_FIT_LINK,
        // 3 is SYNC, 4 DEVICE_INITIATES_SYNC and 71 CURRENT_TIME_REQUEST_SUPPORT.
        // The fitness link is needed along with generic synchronization support.
        weatherConfigurationDirty = false
        request(5050, payload: hostConfiguration()) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.isReady = true
                self.handshakeDeadline = nil
                if info.needsNativeMLR { self.status("手表启用 CoreTransfer / MLR（能力 90）；旧文件同步不可用，实时订阅保持连接") }
                else { self.status("手表能力协商完成，正在准备文件同步") }
                self.checkIdentityThenSync()
            case .failure(let error): self.status("手表能力协商未完成：\(error.localizedDescription)")
            }
        }
    }

    private func hostConfiguration() -> Data {
        var flags: Set<Int> = [0, 3, 4, 71]
        if deviceInfo?.configurationFlags.contains(95) == true { flags.insert(95) }
        if weatherEnabled { flags.formUnion([26, 27]) }
        let count = (flags.max() ?? 0) / 8 + 1
        var bitmap = Array(repeating: UInt8(0), count: count)
        for flag in flags { bitmap[flag / 8] |= 1 << (flag % 8) }
        return Data([UInt8(count)] + bitmap)
    }

    func configureWeather(enabled: Bool) {
        guard weatherEnabled != enabled else { return }
        weatherEnabled = enabled
        weatherConfigurationDirty = true
        if !enabled { cancelWeather() }
    }

    /// Cancelled requests are removed without invoking stale completions on a new connection.
    private func cancelWeather() {
        weatherGeneration = UUID()
        weatherTask?.cancel(); weatherTask = nil
        weatherFrames.removeAll()
        // Keep in-flight ACK correlation until it settles; its generation invalidates the callback.
        for number: UInt16 in [5011, 5012] {
            if var request = pending[number] { request.retries = 0; pending[number] = request }
        }
    }

    private func receiveWeatherRequest(_ message: GFDIMessage) {
        guard weatherEnabled, isReady, let provider = weatherProvider else { send(message.response(status: 2)); return }
        guard let query = try? GFDIWeatherRequest(payload: message.payload) else { send(message.response(status: 5)); return }
        send(message.response(payload: query.acknowledgementPayload))
        // Retransmitted requests share the ongoing refresh instead of starting parallel transfers.
        guard weatherTask == nil, weatherFrames.isEmpty, pending[5011] == nil, pending[5012] == nil else { return }
        let generation = weatherGeneration
        weatherTask = Task { [weak self] in
            do {
                let snapshot = try await provider(query)
                guard let self, !Task.isCancelled, self.weatherGeneration == generation, self.weatherEnabled else { return }
                self.weatherTask = nil
                _ = self.sendWeather(snapshot, forecastHours: query.forecastHours)
            } catch {
                guard let self, self.weatherGeneration == generation else { return }
                self.weatherTask = nil; self.onWeatherDelivery?(false)
            }
        }
    }

    @discardableResult
    func sendWeather(_ snapshot: WatchWeatherSnapshot, forecastHours: Int = 24) -> Bool {
        guard connectedToTransport, isReady, weatherEnabled, weatherTask == nil, weatherFrames.isEmpty,
              pending[5011] == nil, pending[5012] == nil else { return false }
        weatherFrames = GFDIWeather.frames(snapshot: snapshot, forecastHours: forecastHours)
        guard !weatherFrames.isEmpty else { return false }
        sendNextWeatherFrame(generation: weatherGeneration)
        return true
    }

    private func sendNextWeatherFrame(generation: UUID) {
        guard weatherEnabled, isReady, generation == weatherGeneration else { return }
        guard !weatherFrames.isEmpty else { onWeatherDelivery?(true); return }
        let frame = weatherFrames.removeFirst()
        request(frame.number, payload: frame.payload) { [weak self] result in
            guard let self, self.weatherGeneration == generation, self.weatherEnabled else { return }
            // FITHandler requires a successful FIT status byte in addition to the GFDI ACK.
            if case let .success(payload) = result, payload.first == 0 {
                self.sendNextWeatherFrame(generation: generation)
            } else {
                self.weatherFrames.removeAll(); self.onWeatherDelivery?(false)
            }
        }
    }

    private func receiveTimeRequest(_ message: GFDIMessage) throws {
        var reader = GFDIReader(message.payload)
        let reference = try reader.u32()
        let now = Date()
        var response = GFDIWriter()
        response.u32(reference)
        response.u32(UInt32(clamping: Int(now.timeIntervalSince1970 - 631_065_600)))
        response.u32(UInt32(bitPattern: Int32(TimeZone.current.secondsFromGMT(for: now))))
        response.u32(0)
        response.u32(0)
        send(message.response(payload: Data(response.bytes)))
    }

    private func checkIdentityThenSync() {
        guard isReady else { return }
        if deviceInfo?.configurationFlags.contains(95) == true, let accountGUID {
            guard let bytes = GFDICoreIdentity.guidBytes(accountGUID) else { status("账户 GUID 格式无效，请重新登录佳明账户"); return }
            guard cloudIdentityMatches != false else { abortSync("手表账户 GUID 与登录账户不匹配，已停止文件同步"); return }
            if cloudIdentityMatches == nil {
                guard identityDeadline == nil else { return }
                identityQueryID = allocateProtobufQueryID()
                identityBuffer.removeAll()
                identityExpectedSize = 0
                let protobuf = GFDICoreIdentity.query(guid: bytes)
                var payload = GFDIWriter()
                payload.u16(identityQueryID)
                payload.u32(0)
                payload.u32(UInt32(protobuf.count))
                payload.u32(UInt32(protobuf.count))
                payload.data(protobuf)
                identityDeadline = Date().addingTimeInterval(20)
                request(5043, payload: Data(payload.bytes)) { [weak self] result in
                    if case .failure(let error) = result {
                        self?.identityDeadline = nil
                        self?.status("手表账户检查未完成：\(error.localizedDescription)")
                    }
                }
                status("正在检查手表与佳明账户的归属")
                return
            }
        }
        // No feature-capabilities support means identity must be checked against the cloud's
        // associated-device list before uploading; no GUID is ever set on the watch.
        // APK DeviceManager.completeHandshake / br2/l: the configuration exchange alone
        // does not finish a device-initiated-sync handshake. Event 5030 carries [8, 0].
        if deviceInfo?.configurationFlags.contains(4) == true, !handshakeCompleted {
            guard !handshakeCompletionPending, !authenticationUnsupported else { return }
            handshakeCompletionPending = true
            status("正在完成手表同步握手")
            request(5030, payload: Data([8, 0])) { [weak self] result in
                guard let self else { return }
                self.handshakeCompletionPending = false
                switch result {
                case .success:
                    self.handshakeCompleted = true
                    self.status("手表同步握手已完成")
                    self.checkIdentityThenSync()
                case .failure(let error): self.abortSync("手表同步握手未完成：\(error.localizedDescription)")
                }
            }
            return
        }
        guard queuedSync, !isSyncing else { return }
        guard deviceInfo?.needsNativeMLR != true, !authenticationUnsupported else { queuedSync = false; return }
        queuedSync = false
        isSyncing = true
        filesSavedThisSync = 0
        status(includeArchivedActivities ? "正在读取手表全部文件目录，查找最近一次运动" : "正在读取手表待上传文件目录")
        request(5007, payload: Data([includeArchivedActivities ? 0 : 3])) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let payload):
                guard payload.first == 0 else { self.abortSync("手表不支持待上传文件筛选，保留所有手表文件"); return }
                self.readFile(index: 0, entry: nil)
            case .failure(let error): self.abortSync("无法读取待上传文件目录：\(error.localizedDescription)")
            }
        }
    }

    private func receiveIdentityResponse(_ message: GFDIMessage) throws {
        var reader = GFDIReader(message.payload)
        let requestID = try reader.u16()
        let offset = Int(try reader.u32())
        let total = Int(try reader.u32())
        let size = Int(try reader.u32())
        guard requestID == identityQueryID, identityDeadline != nil else { send(message.response(status: 2)); return }
        guard total <= 32_768, size <= reader.remaining else { throw GFDIProtocolError.oversized }
        let bytes = try reader.data(size)
        var reply = GFDIWriter()
        reply.u16(requestID)
        reply.u32(UInt32(offset))
        reply.u8(0)
        if offset < identityBuffer.count {
            guard offset + size <= identityBuffer.count, identityBuffer.subdata(in: offset..<(offset + size)) == bytes else { throw GFDIProtocolError.invalidCRC }
            reply.u8(101)
            send(message.response(payload: Data(reply.bytes)))
            return
        }
        guard offset == identityBuffer.count, offset + size <= total,
              identityExpectedSize == 0 || identityExpectedSize == total else { throw GFDIProtocolError.invalidLength }
        identityExpectedSize = total
        identityBuffer += bytes
        reply.u8(0)
        send(message.response(payload: Data(reply.bytes)))
        guard identityBuffer.count == total else { identityDeadline = Date().addingTimeInterval(20); return }
        identityDeadline = nil
        guard let result = try GFDICoreIdentity.guidStatus(identityBuffer) else { abortSync("手表没有返回账户归属，文件同步未启动"); return }
        guard result <= 2 else { abortSync("手表返回未知账户校验状态 \(result)，文件同步未启动"); return }
        cloudIdentityMatches = result == 1
        if result == 1 { status("手表与佳明账户匹配"); checkIdentityThenSync() }
        else if result == 0 { abortSync("手表未关联账户；本版本不会覆盖 GUID，请先通过官方应用完成首次账户配对") }
        else { abortSync("手表账户 GUID 与登录账户不匹配，已停止文件同步") }
    }

    private func readFile(index: Int, entry: GFDIDirectoryEntry?, notReadyRetries: Int = 1) {
        guard isSyncing else { return }
        var payload = GFDIWriter()
        payload.u16(UInt16(index))
        payload.u32(0) // Always restart at zero; no unverified cross-session resume.
        payload.u8(1)
        payload.u16(0)
        payload.u32(0)
        payload.u8(0) // Disable compressed transfer.
        request(5002, payload: Data(payload.bytes)) { [weak self] result in
            guard let self, self.isSyncing else { return }
            switch result {
            case .success(let data):
                do {
                    var reader = GFDIReader(data)
                    let status = try reader.u8()
                    if status == 3, notReadyRetries > 0 {
                        Task { [weak self] in
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            guard let self, self.isSyncing else { return }
                            self.readFile(index: index, entry: entry, notReadyRetries: notReadyRetries - 1)
                        }
                        return
                    }
                    guard status == 0 else { throw Failure(message: "文件 \(index) 读取被拒绝（状态 \(status)）") }
                    let size = Int(try reader.u32())
                    guard size <= 64 * 1024 * 1024, index != 0 || size <= 1024 * 1024 else { throw GFDIProtocolError.oversized }
                    guard entry == nil || entry?.size == size else { throw Failure(message: "手表文件在下载前发生变化，请重新同步") }
                    self.transfer = Transfer(index: index, entry: entry, receiver: GFDIFileReceiver(finalSize: size), data: Data(), deadline: Date().addingTimeInterval(30))
                    if size == 0 { try self.finishTransfer(); return }
                    self.status(index == 0 ? "正在下载手表目录（\(size) 字节）" : "正在下载文件 \(index)（\(size) 字节）")
                } catch { self.abortSync("无法开始文件下载：\(error.localizedDescription)") }
            case .failure(let error): self.abortSync("文件下载请求失败：\(error.localizedDescription)")
            }
        }
    }

    private func receiveFileBlock(_ message: GFDIMessage) {
        guard var current = transfer else { send(message.response(payload: Data([2, 0, 0, 0, 0]))); return }
        let result = current.receiver.accept(message.payload)
        if result.status == 0 {
            current.data += result.bytesToAppend
            current.deadline = Date().addingTimeInterval(30)
            transfer = current
        }
        if result.isComplete, result.status == 0 {
            do {
                // Last block is acknowledged only after originals and queue metadata are durable.
                let completed = try persistTransfer(current)
                transfer = nil
                send(message.response(payload: result.responsePayload))
                completeTransfer(current, completed: completed)
            } catch {
                var response = GFDIWriter(); response.u8(2); response.u32(result.nextOffset)
                send(message.response(payload: Data(response.bytes)))
                abortSync("文件保存失败，已停止同步：\(error.localizedDescription)")
            }
        } else {
            send(message.response(payload: result.responsePayload))
            if result.status == 2 || result.status == 3 { abortSync("文件块校验失败，已停止本次下载；手表文件未归档") }
        }
    }

    private func persistTransfer(_ current: Transfer) throws -> (URL, GFDIFileMetadata)? {
        guard current.data.count == current.receiver.finalSize else { throw GFDIProtocolError.invalidLength }
        guard let entry = current.entry else {
            // Keep one bounded, CRC-checked directory snapshot locally to diagnose firmware
            // formats without logging raw BLE traffic, identity requests or authentication.
            let diagnostic = storageDirectory.appendingPathComponent("last-directory.bin")
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try current.data.write(to: diagnostic, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: diagnostic.path)
            _ = try GFDIDirectoryEntry.parseDirectory(current.data)
            return nil
        }
        guard let device = deviceInfo?.unitID else { throw GFDIProtocolError.truncated }
        return try GFDIFileArchive.persist(current.data, entry: entry, deviceID: device, root: storageDirectory)
    }

    private func finishTransfer() throws {
        guard let current = transfer else { return }
        let completed = try persistTransfer(current)
        transfer = nil
        completeTransfer(current, completed: completed)
    }

    private func completeTransfer(_ current: Transfer, completed: (URL, GFDIFileMetadata)?) {
        if current.index == 0 {
            do {
                let entries = try GFDIDirectoryEntry.parseDirectory(current.data)
                // Only read FIT originals. No GarminDevice XML, firmware, settings or write access.
                fileQueue = entries.filter { $0.dataType == 128 && $0.isReadable && $0.size > 0 && $0.size <= 64 * 1024 * 1024 }
                if includeArchivedActivities {
                    fileQueue = Array(fileQueue.filter { $0.subtype == 4 }.sorted { $0.timestamp > $1.timestamp }.prefix(1))
                }
                status(includeArchivedActivities ? "全部目录中找到 \(fileQueue.count) 份最近运动 FIT" : "发现 \(fileQueue.count) 份待上传 FIT 文件")
                nextFile()
            } catch { abortSync("文件目录无效：\(error.localizedDescription)") }
        } else if let (url, metadata) = completed {
            downloadedThisSession.insert(directoryIdentity(current.entry!))
            filesSavedThisSync += 1
            onFile?(url, metadata)
            nextFile()
        }
    }

    private func directoryIdentity(_ entry: GFDIDirectoryEntry) -> String { "\(entry.index)-\(entry.dataType)-\(entry.identifier)-\(entry.size)-\(entry.timestamp)" }

    private func nextFile() {
        while !fileQueue.isEmpty {
            let entry = fileQueue.removeFirst()
            if downloadedThisSession.contains(directoryIdentity(entry)) { continue }
            readFile(index: entry.index, entry: entry)
            return
        }
        isSyncing = false
        let empty = includeArchivedActivities ? "检查完成，手表目录中没有可读取的运动文件" : "检查完成，本次没有新增文件"
        status(filesSavedThisSync == 0 ? empty : "已在 Mac 保存 \(filesSavedThisSync) 份原始 FIT")
        onSyncFinished?(true)
    }

    private func abortSync(_ message: String) {
        isSyncing = false
        queuedSync = false
        transfer = nil
        fileQueue.removeAll()
        let cancelled = [UInt16(5002), UInt16(5007)]
        for number in cancelled { pending.removeValue(forKey: number) }
        status(message)
        onSyncFinished?(false)
    }

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self else { return }
                self.tick(now: Date())
            }
        }
    }

    // Exposed internally for deterministic timeout tests; no actual sleeps are needed by tests.
    func tick(now: Date) {
        guard connectedToTransport else { return }
        if weatherConfigurationDirty, isReady, pending[5050] == nil {
            weatherConfigurationDirty = false
            request(5050, payload: hostConfiguration()) { [weak self] result in
                if case .failure = result { self?.onWeatherDelivery?(false) }
            }
        }
        for service in pendingRegistrations.keys.sorted() where pendingRegistrations[service]! < now {
            pendingRegistrations.removeValue(forKey: service)
            if (registrationAttempts[service] ?? 0) < 4 {
                status("重新注册佳明服务 \(service)，等待系统配对完成")
                register(service: service)
            } else { status("手表蓝牙服务 \(service) 注册超时，请检查配对或手机占用情况") }
        }
        for service in realtimeStartDeadlines.keys.sorted() where realtimeStartDeadlines[service]! < now {
            realtimeStartDeadlines.removeValue(forKey: service)
            if !realtimeHasData.contains(service), let handle = handles.first(where: { $0.value == service })?.key { onSend?(Data([handle, 1])) }
        }
        let timedOut = pending.filter { $0.value.deadline < now }.map(\.key)
        for number in timedOut {
            guard var request = pending.removeValue(forKey: number) else { continue }
            if request.retries > 0 {
                request.retries -= 1
                request.deadline = now.addingTimeInterval(10)
                pending[number] = request
                send(request.message)
            } else {
                request.completion(.failure(Failure(message: "手表请求 \(number) 超时")))
            }
        }
        if let deadline = transfer?.deadline, deadline < now { abortSync("手表文件传输超时，已保留手表原始记录，可重新同步") }
        if let deadline = identityDeadline, deadline < now { identityDeadline = nil; abortSync("手表账户归属检查超时，文件同步未启动") }
        if let deadline = handshakeDeadline, deadline < now { handshakeDeadline = nil; status("等待手表协议握手超时；实时服务如可用仍保持订阅") }
        if let deadline = batteryNotificationDeadline, deadline < now {
            batteryNotification = nil; batteryNotificationDeadline = nil
        }
        if let deadline = batteryDeadline, deadline < now { batteryFallback(now: now) }
        refreshBatteryIfNeeded(now: now)
    }

    private func allocateProtobufQueryID() -> UInt16 {
        repeat { protobufQueryID &+= 1 } while protobufQueryID == 0 || protobufQueryID == identityQueryID || protobufQueryID == batteryQueryID
        return protobufQueryID
    }

    private func resetBatteryRequests() {
        batteryQueryID = nil; batteryTransfer = nil; batteryDeadline = nil
        batteryUsesLegacy = false; nextBatteryRefresh = .distantPast
        batteryNotification = nil; batteryNotificationDeadline = nil
    }

    /// Battery refresh is optional and never participates in file-sync success/failure.
    /// Delay until the initial identity/handshake is settled and the file channel is idle.
    private func refreshBatteryIfNeeded(now: Date) {
        guard isReady, !authenticationUnsupported, !isSyncing, !queuedSync,
              identityDeadline == nil, !handshakeCompletionPending,
              deviceInfo?.configurationFlags.contains(4) != true || handshakeCompleted,
              batteryDeadline == nil, now >= nextBatteryRefresh else { return }
        nextBatteryRefresh = now.addingTimeInterval(300)
        batteryDeadline = now.addingTimeInterval(20)
        if batteryUsesLegacy {
            // APK GenericSendMessageManager.requestMessage: 5001 + requested message u16.
            var payload = GFDIWriter(); payload.u16(5023)
            send(GFDIMessage(number: 5001, payload: Data(payload.bytes)))
        } else {
            let id = allocateProtobufQueryID()
            batteryQueryID = id; batteryTransfer = GFDIBatteryTransfer(requestID: id)
            // ACKs are correlated by protobuf request ID, separately from identity queries.
            send(GFDIMessage(number: 5043, payload: GFDIBatteryTransfer.request(id: id)))
        }
    }

    private func batteryFallback(now: Date = Date()) {
        guard batteryDeadline != nil else { return }
        batteryDeadline = nil; batteryTransfer = nil
        if !batteryUsesLegacy {
            batteryUsesLegacy = true
            nextBatteryRefresh = now
            refreshBatteryIfNeeded(now: now)
        }
    }

    private func receiveBatteryAcknowledgement(status: UInt8, payload: Data) -> Bool {
        guard let id = batteryQueryID else { return false }
        var reader = GFDIReader(payload)
        guard let received = try? reader.u16(), received == id else { return false }
        guard batteryDeadline != nil, !batteryUsesLegacy else { return true }
        guard status == 0, let offset = try? reader.u32(), offset == 0,
              let accepted = try? reader.u8(), let error = try? reader.u8(), accepted == 0, [0, 101].contains(error) else {
            batteryFallback(); return true
        }
        return true
    }

    private func receiveBatteryResponse(_ message: GFDIMessage) {
        guard var transfer = batteryTransfer, batteryDeadline != nil else { send(message.response(status: 2)); return }
        do {
            let fragment = try transfer.accept(message.payload)
            batteryTransfer = transfer
            let reading = transfer.complete ? try GFDIBattery.response(transfer.data) : nil
            send(message.response(payload: fragment.ack))
            guard transfer.complete, !fragment.duplicate else { return }
            guard let reading else { batteryFallback(); return }
            batteryDeadline = nil; batteryTransfer = nil
            onBatteryReading?(reading)
        } catch {
            send(message.response(status: 5))
            batteryFallback()
        }
    }

    private func receiveBatteryNotification(_ message: GFDIMessage) {
        do {
            var reader = GFDIReader(message.payload)
            let id = try reader.u16()
            if batteryNotification?.complete == true, batteryNotification?.requestID != id { batteryNotification = nil }
            if batteryNotification == nil { batteryNotification = GFDIBatteryTransfer(requestID: id) }
            guard var transfer = batteryNotification, transfer.requestID == id else { send(message.response(status: 2)); return }
            let fragment = try transfer.accept(message.payload)
            batteryNotification = transfer; batteryNotificationDeadline = Date().addingTimeInterval(20)
            if transfer.complete {
                guard try GFDIBattery.isChangeNotification(transfer.data) else {
                    batteryNotification = nil; batteryNotificationDeadline = nil
                    send(message.response(status: 2)); return
                }
                // Retain the completed receiver briefly so duplicate fragments are ACKed.
                if !fragment.duplicate { nextBatteryRefresh = Date() }
            }
            send(message.response(payload: fragment.ack))
        } catch {
            batteryNotification = nil; batteryNotificationDeadline = nil
            send(message.response(status: 5))
        }
    }

    private func status(_ message: String) { onStatus?(message) }
}
