import AppKit

@MainActor extension DeveloperAccess {
    func createClient(name: String, scopes: Set<DeveloperScope>) {
        changeClients { values in values.append(try DeveloperClientStore.create(name: name, scopes: scopes)) }
    }
    func revokeClient(_ id: UUID) {
        changeClients { values in
            guard let index = values.firstIndex(where: { $0.id == id }) else { return }
            values[index].revokedAt = Date(); values[index].key = ""
        }
    }
    func removeRevokedClient(_ id: UUID) {
        changeClients { values in values.removeAll { $0.id == id && !$0.enabled } }
    }
    private func changeClients(_ operation: @escaping (inout [DeveloperClientCredential]) throws -> Void) {
        guard !isManagingKey, !isApplying else { return }
        isManagingKey = true
        let store = clientStore
        Task {
            defer { isManagingKey = false }
            do {
                let values = try await Task.detached(priority: .utility) { try store.update(operation) }.value
                clients = values; accountChanged(); clientStatus = "客户端权限已保存"
            } catch { clientStatus = error.localizedDescription }
        }
    }
    func recordClientAccess(_ id: UUID) {
        guard let index = clients.firstIndex(where: { $0.id == id }),
              Date().timeIntervalSince(clients[index].lastUsedAt ?? .distantPast) >= 60 else { return }
        let date = Date(), store = clientStore
        clients[index].lastUsedAt = date
        Task {
            do {
                _ = try await Task.detached(priority: .utility) {
                    try store.update { values in
                        if let index = values.firstIndex(where: { $0.id == id && $0.enabled }) { values[index].lastUsedAt = date }
                    }
                }.value
            } catch { clientStatus = "无法保存客户端访问记录" }
        }
    }
    func copyClientKey(_ id: UUID) {
        guard let client = clients.first(where: { $0.id == id && $0.enabled }) else { return }
        NSPasteboard.general.clearContents()
        clientStatus = NSPasteboard.general.setString(client.key, forType: .string) && NSPasteboard.general.string(forType: .string) == client.key ? "密钥已复制" : "无法写入剪贴板，请重试"
    }
    func exportClientKey(_ id: UUID) {
        guard let client = clients.first(where: { $0.id == id && $0.enabled }), !isManagingKey else { return }
        isManagingKey = true
        Task {
            defer { isManagingKey = false }
            let panel = NSSavePanel(); panel.nameFieldStringValue = "wristbeam-client-key.txt"
            let response = await withCheckedContinuation { continuation in
                if let window = NSApp.keyWindow { panel.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
                else { panel.begin { continuation.resume(returning: $0) } }
            }
            guard response == .OK, let url = panel.url else { return }
            do {
                try await Task.detached(priority: .utility) { try DeveloperSecrets.export(client.key, to: url) }.value
                clientStatus = "密钥已导出"
            } catch { clientStatus = error.localizedDescription }
        }
    }
}
