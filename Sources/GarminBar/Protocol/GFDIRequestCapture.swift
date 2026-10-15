import Foundation
import Combine

/// A bounded, allowlisted transcript of decoded GFDI messages, not raw BLE traffic.
/// No payload, coordinate, device identity, account, URL or health value is retained.
struct GFDIRequestLog: Codable {
    enum Direction: String, Codable { case watchToMac, macQueued }
    struct Event: Codable, Identifiable {
        let id: Int
        let time: Date
        let direction: Direction
        let number: UInt16
        let payloadBytes: Int
        let replyTo: UInt16?
        let status: UInt8?
        let weatherFormat: UInt8?
        let forecastHours: UInt8?
        let weatherPayloadValid: Bool?
        var name: String { GFDIRequestLog.name(replyTo ?? number) }
    }
    struct RoutineCategory: Codable, Identifiable {
        let direction: Direction
        let number: UInt16
        let replyTo: UInt16?
        var count: Int
        var lastSeen: Date
        var id: String { "\(direction.rawValue):\(number):\(replyTo.map(String.init) ?? "-")" }
        var name: String { GFDIRequestLog.name(replyTo ?? number) }
    }
    private(set) var schemaVersion = 2
    var startedAt: Date?
    var stoppedAt: Date?
    var events: [Event] = []
    var totalEvents = 0
    var omittedRoutineMessages = 0
    private(set) var routineCategories: [RoutineCategory] = []
    private(set) var unclassifiedRoutineMessages = 0
    static let limit = 300
    static let categoryLimit = 128
    static let duration: TimeInterval = 600

    /// Version 1 retained only a total. Do not invent categories for historical traffic.
    var historicalRoutineMessages: Int {
        omittedRoutineMessages - routineCategories.reduce(0) { $0 + $1.count } - unclassifiedRoutineMessages
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, startedAt, stoppedAt, events, totalEvents, omittedRoutineMessages
        case routineCategories, unclassifiedRoutineMessages
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
        stoppedAt = try values.decodeIfPresent(Date.self, forKey: .stoppedAt)
        events = try values.decode([Event].self, forKey: .events)
        totalEvents = try values.decode(Int.self, forKey: .totalEvents)
        omittedRoutineMessages = try values.decode(Int.self, forKey: .omittedRoutineMessages)
        routineCategories = try values.decodeIfPresent([RoutineCategory].self, forKey: .routineCategories) ?? []
        unclassifiedRoutineMessages = try values.decodeIfPresent(Int.self, forKey: .unclassifiedRoutineMessages) ?? 0
        guard (1...2).contains(version), events.count <= Self.limit, totalEvents >= events.count,
              omittedRoutineMessages >= 0, unclassifiedRoutineMessages >= 0,
              unclassifiedRoutineMessages <= omittedRoutineMessages,
              routineCategories.count <= Self.categoryLimit,
              Set(routineCategories.map(\.id)).count == routineCategories.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid diagnostic bounds"))
        }
        var remaining = omittedRoutineMessages - unclassifiedRoutineMessages
        for category in routineCategories {
            guard category.count > 0, category.count <= remaining,
                  Self.routine(category.replyTo ?? category.number),
                  category.replyTo == nil || category.number == 5000 else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid routine category"))
            }
            remaining -= category.count
        }
    }

    static func name(_ number: UInt16) -> String {
        switch number {
        case 5000: return "协议确认"
        case 5001: return "消息查询"
        case 5002: return "文件下载请求"
        case 5003: return "文件上传请求"
        case 5004: return "文件数据块"
        case 5005: return "创建文件"
        case 5006: return "删除文件"
        case 5007: return "文件目录查询"
        case 5008: return "文件标记设置"
        case 5009: return "新文件就绪通知"
        case 5011: return "FIT 定义"
        case 5012: return "FIT 数据"
        case 5014: return "天气请求"
        case 5015: return "天气预警消息"
        case 5022: return "取消文件传输"
        case 5023: return "设备电池状态"
        case 5024: return "设备信息"
        case 5026: return "设备设置"
        case 5027: return "排队下载通知"
        case 5028, 5029: return "GPS 辅助星历"
        case 5030: return "系统事件"
        case 5033...5036: return "智能通知"
        case 5037: return "同步请求"
        case 5039, 5040: return "查找手机"
        case 5041, 5042, 5049: return "音乐控制与状态"
        case 5043: return "Protobuf 请求（内容未解析）"
        case 5044: return "Protobuf 响应（内容未解析）"
        case 5045: return "取消 Protobuf 传输"
        case 5050: return "能力协商"
        case 5052: return "时间请求"
        case 5054: return "压缩文件数据块"
        case 5101...5111: return "应用认证"
        default: return "其他协议消息"
        }
    }

    /// Aggregate high-volume protocol traffic without retaining any payload contents.
    private static func routine(_ number: UInt16) -> Bool {
        [5000, 5001, 5002, 5003, 5004, 5005, 5006, 5007, 5008, 5009,
         5022, 5023, 5024, 5027, 5044, 5045, 5054].contains(number)
    }

    mutating func append(_ message: GFDIMessage, direction: Direction, at time: Date = Date()) {
        var replyTo: UInt16?
        var status: UInt8?
        if message.number == 5000, message.payload.count >= 3 {
            var reader = GFDIReader(message.payload)
            replyTo = try? reader.u16(); status = try? reader.u8()
        }
        guard !Self.routine(replyTo ?? message.number) else {
            omittedRoutineMessages += 1
            if let index = routineCategories.firstIndex(where: {
                $0.direction == direction && $0.number == message.number && $0.replyTo == replyTo
            }) {
                routineCategories[index].count += 1
                routineCategories[index].lastSeen = max(routineCategories[index].lastSeen, time)
            } else if routineCategories.count < Self.categoryLimit {
                routineCategories.append(RoutineCategory(direction: direction, number: message.number,
                                                         replyTo: replyTo, count: 1, lastSeen: time))
            } else { unclassifiedRoutineMessages += 1 }
            return
        }
        let weather = message.number == 5014
        let valid = weather && message.payload.count == 10
        let bytes = valid ? Array(message.payload) : []
        totalEvents += 1
        events.append(Event(id: totalEvents, time: time, direction: direction, number: message.number,
                            payloadBytes: message.payload.count, replyTo: replyTo, status: status,
                            weatherFormat: valid ? bytes[0] : nil, forecastHours: valid ? bytes[9] : nil,
                            weatherPayloadValid: weather ? valid : nil))
        if events.count > Self.limit { events.removeFirst(events.count - Self.limit) }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

@MainActor
final class WatchRequestCapture: ObservableObject {
    @Published private(set) var log = GFDIRequestLog()
    @Published private(set) var isCapturing = false
    @Published private(set) var storageError = false
    let url: URL
    private var timer: Task<Void, Never>?
    private var dirty = false
    private var pendingLog = GFDIRequestLog()

    init(url: URL = AppPaths.root.appendingPathComponent("Diagnostics/watch-requests.json")) {
        self.url = url
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 512_000,
           let data = try? Data(contentsOf: url), let previous = try? decoder.decode(GFDIRequestLog.self, from: data),
           previous.events.count <= GFDIRequestLog.limit {
            log = previous
            // A restarted application never silently resumes capture.
            if log.startedAt != nil && log.stoppedAt == nil { log.stoppedAt = Date() }
        }
        pendingLog = log
    }

    deinit { timer?.cancel() }

    func start(at time: Date = Date()) {
        timer?.cancel()
        pendingLog = GFDIRequestLog(); pendingLog.startedAt = time
        isCapturing = true; dirty = true; persist()
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, self.isCapturing else { return }
                if self.expireIfNeeded(at: Date()) { return }
                self.persist()
            }
        }
    }

    func stop(at time: Date = Date()) {
        guard isCapturing else { return }
        isCapturing = false; timer?.cancel(); timer = nil
        pendingLog.stoppedAt = time; dirty = true; persist()
    }

    @discardableResult
    func expireIfNeeded(at time: Date) -> Bool {
        guard isCapturing, let start = pendingLog.startedAt, time.timeIntervalSince(start) >= GFDIRequestLog.duration else { return false }
        stop(at: time); return true
    }

    func record(_ message: GFDIMessage, direction: GFDIRequestLog.Direction, at time: Date = Date()) {
        guard isCapturing, !expireIfNeeded(at: time) else { return }
        pendingLog.append(message, direction: direction, at: time); dirty = true
    }

    /// Export is a local file reveal; never publish this transcript to cloud or webhooks.
    @discardableResult
    func persist() -> Bool {
        guard dirty else { return !storageError }
        log = pendingLog
        do { try GarminPrivateFile.write(log.encoded(), to: url); dirty = false; storageError = false; return true }
        catch { storageError = true; return false }
    }

    func clear() {
        stop(); pendingLog = GFDIRequestLog(); dirty = true; persist()
    }
}
