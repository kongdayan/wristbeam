import SwiftUI

struct DeveloperClientsView: View {
    @ObservedObject var access: DeveloperAccess
    @State private var name = ""
    @State private var scopes: Set<DeveloperScope> = [.status, .summary]
    @State private var revealed: UUID?
    var body: some View {
        PreferenceBlock(title: "客户端与权限") {
            VStack(alignment: .leading, spacing: 12) {
                TextField(L10n.text("客户端名称"), text: $name).textFieldStyle(.roundedBorder)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading) {
                    ForEach(DeveloperScope.allCases) { scope in
                        Toggle(L10n.text(scope.title), isOn: Binding(get: { scopes.contains(scope) }, set: {
                            if $0 { scopes.insert(scope) } else { scopes.remove(scope) }
                        })).toggleStyle(.checkbox)
                    }
                }
                Button(L10n.text("创建客户端密钥")) { access.createClient(name: name, scopes: scopes) }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || scopes.isEmpty || access.isManagingKey || access.isApplying)
                ForEach(access.clients) { client in
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(client.name).fontWeight(.semibold)
                            Text(client.scopes.sorted { $0.rawValue < $1.rawValue }.map { L10n.text($0.title) }.joined(separator: " · "))
                                .font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
                            if let used = client.lastUsedAt {
                                Text(L10n.text("最近访问") + " · " + used.formatted(.dateTime.month().day().hour().minute().locale(L10n.locale)))
                                    .font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
                            }
                        }
                        Spacer()
                        if client.enabled {
                            Menu(L10n.text("管理密钥")) {
                                Button(L10n.text(revealed == client.id ? "隐藏密钥" : "显示密钥")) { revealed = revealed == client.id ? nil : client.id }
                                Button(L10n.text("复制密钥")) { access.copyClientKey(client.id) }
                                Button(L10n.text("导出密钥…")) { access.exportClientKey(client.id) }
                                Divider()
                                Button(L10n.text("撤销访问"), role: .destructive) { revealed = nil; access.revokeClient(client.id) }
                            }.disabled(access.isManagingKey || access.isApplying)
                        } else {
                            Text(L10n.text("已撤销"))
                            Button(L10n.text("移除")) { access.removeRevokedClient(client.id) }.disabled(access.isManagingKey)
                        }
                    }
                    if revealed == client.id && client.enabled { Text(client.key).font(PulseTheme.font(size: 11, design: .monospaced)).textSelection(.enabled) }
                }
                if !access.clientStatus.isEmpty { Text(L10n.text(access.clientStatus)).font(PulseTheme.font(size: 11)) }
            }
        }.onDisappear { revealed = nil }
    }
}
