import Foundation

enum DeveloperScope: String, CaseIterable, Codable, Identifiable {
    case status, metrics, history, activities, summary
    var id: String { rawValue }
    var title: String {
        switch self {
        case .status: return "连接与同步状态"
        case .metrics: return "当前健康指标"
        case .history: return "历史曲线与 HRV"
        case .activities: return "运动记录"
        case .summary: return "健康摘要"
        }
    }
}

struct DeveloperClientCredential: Codable, Identifiable {
    var id = UUID()
    var name: String
    var key: String
    var scopes: Set<DeveloperScope>
    var createdAt = Date()
    var lastUsedAt: Date?
    var revokedAt: Date?
    var enabled: Bool { revokedAt == nil }
}

final class DeveloperClientStore {
    let url: URL
    private let lock = NSRecursiveLock()
    init(url: URL) { self.url = url }
    func update(_ change: (inout [DeveloperClientCredential]) throws -> Void) throws -> [DeveloperClientCredential] {
        lock.lock(); defer { lock.unlock() }
        var clients = try load()
        try change(&clients)
        try save(clients)
        return clients
    }
    private struct Envelope: Codable { var schemaVersion = 1; var clients: [DeveloperClientCredential] }
    func load() throws -> [DeveloperClientCredential] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= 128 * 1024 else { throw DeveloperError.invalid("Invalid client credentials") }
        let value = try JSONDecoder().decode(Envelope.self, from: data)
        guard value.schemaVersion == 1, value.clients.count <= 32,
              Set(value.clients.map(\.id)).count == value.clients.count else { throw DeveloperError.invalid("Invalid client credentials") }
        for client in value.clients where client.enabled { _ = try DeveloperSecrets.validated(client.key) }
        return value.clients
    }
    func save(_ clients: [DeveloperClientCredential]) throws {
        lock.lock(); defer { lock.unlock() }
        guard clients.count <= 32 else { throw DeveloperError.invalid("最多保存 32 个客户端，请移除已撤销的项目") }
        try GarminPrivateFile.write(JSONEncoder().encode(Envelope(clients: clients)), to: url)
    }
    static func create(name: String, scopes: Set<DeveloperScope>) throws -> DeveloperClientCredential {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 80, !scopes.isEmpty else { throw DeveloperError.invalid("请填写客户端名称并选择权限") }
        return DeveloperClientCredential(name: title, key: try DeveloperSecrets.generate(), scopes: scopes)
    }
}
