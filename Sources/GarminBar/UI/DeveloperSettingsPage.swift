import SwiftUI
import AppKit

struct DeveloperSettingsPage: View {
    @ObservedObject var access: DeveloperAccess
    let kinds: [MetricKind]
    @State private var certificatePassword = ""
    var body: some View {
        VStack(alignment:.leading,spacing:23) {
            VStack(alignment:.leading,spacing:10) {
                HStack {
                    StatusDot(active:access.running)
                    Text(L10n.text(access.status))
                    Spacer()
                    Button(L10n.text("应用接口配置")) { access.apply() }.buttonStyle(.borderedProminent).tint(PulseTheme.mint).disabled(access.isApplying || access.isManagingKey)
                    Button(L10n.text("立即停止全部接口")) { access.stopAll() }
                }
                if access.isApplying {
                    Text(L10n.text("正在启动接口…")).foregroundStyle(PulseTheme.secondary)
                }
                if access.hasUnappliedChanges {
                    Text(L10n.text("配置尚未应用，点击上方按钮后生效。")).foregroundStyle(PulseTheme.secondary)
                }
                if !access.configurationError.isEmpty {
                    Text(L10n.text(access.configurationError)).foregroundStyle(.red).textSelection(.enabled)
                }
            }.font(PulseTheme.font(size:12))
            PreferenceBlock(title:"MCP 与只读 API") {
                PreferenceLine(title:"启用 MCP / HTTP API",note:"允许持有密钥的客户端读取已缓存的健康指标、时间序列和同步状态。不会提供账号凭据、设备标识、原始 FIT 或手表控制能力。") {
                    Toggle("",isOn:$access.configuration.enabled).labelsHidden().toggleStyle(.switch)
                }
                PreferenceLine(title:"监听范围") {
                    Picker("",selection:$access.configuration.host) { Text(L10n.text("仅本机")).tag("127.0.0.1"); Text(L10n.text("局域网（要求 HTTPS）")).tag("0.0.0.0") }.labelsHidden()
                }
                PreferenceLine(title:"端口") { TextField("17890",value:$access.configuration.port,format:.number.grouping(.never)).frame(width:95).textFieldStyle(.roundedBorder) }
                PreferenceLine(title:"使用 HTTPS") { Toggle("",isOn:$access.configuration.https).labelsHidden().toggleStyle(.switch) }
                if access.configuration.host != "127.0.0.1" {
                    PreferenceLine(title:"访问主机名或 IPv4 地址",note:"局域网客户端也能读取健康数据。证书须覆盖访问地址，且客户端必须信任证书。") { TextField("localhost",text:$access.configuration.publicHost).textFieldStyle(.roundedBorder) }
                }
                if access.configuration.https {
                    PreferenceLine(title:"PKCS#12 证书密码") { SecureField("",text:$certificatePassword).textFieldStyle(.roundedBorder) }
                    PreferenceLine(title:access.certificateAvailable ? "已保存 HTTPS 证书" : "请导入含私钥的 .p12 / .pfx 证书") { Button(L10n.text("导入证书…")) { access.importCertificate(password:certificatePassword); certificatePassword = "" } }
                }
                PreferenceLine(title: "启用默认密钥") {
                    Toggle("", isOn: Binding(get: { access.configuration.primaryKeyEnabled != false }, set: { access.configuration.primaryKeyEnabled = $0 })).labelsHidden().toggleStyle(.switch)
                }
                DeveloperKeyControls(access:access, name:"api", title:"访问密钥")
            }
            DeveloperClientsView(access: access)
            PreferenceBlock(title:"客户端接入") {
                VStack(alignment:.leading,spacing:12) {
                    HStack { StatusDot(active:access.running); Text(L10n.text(access.status)); Spacer(); Text(L10n.format("已处理 {0} 次请求",String(access.requestCount))) }.font(PulseTheme.font(size:11))
                    Text(access.baseURL + "/mcp").font(PulseTheme.font(size:12,design:.monospaced)).textSelection(.enabled)
                    DisclosureGroup(L10n.text("客户端配置示例")) {
                        Text(L10n.text("支持手动 Bearer 密钥的 Streamable HTTP 客户端；不提供 OAuth 登录。配置格式因 AI 客户端而异。"))
                            .font(PulseTheme.font(size:11)).foregroundStyle(PulseTheme.secondary).padding(.vertical,8)
                        Text(access.clientExample).font(PulseTheme.font(size:11,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                    }
                    Link(L10n.text("接口文档与 Python SDK ↗"),destination:URL(string:"https://github.com/kongdayan/wristbeam/blob/main/docs/developer/API.md")!)
                }.padding(15)
            }
            PreferenceBlock(title:"Webhook") {
                PreferenceLine(title:"启用数据更新 Webhook",note:"开启后，将所选健康指标与同步状态发送到下方地址。目标服务会获得这些数据，请只填写你信任的接收端。") { Toggle("",isOn:$access.configuration.webhookEnabled).labelsHidden().toggleStyle(.switch) }
                PreferenceLine(title:"接收地址") { TextField("https://your-service.example/hook",text:$access.configuration.webhookURL).textFieldStyle(.roundedBorder) }
                PreferenceLine(title:"合并投递间隔") { Picker("",selection:$access.configuration.webhookInterval) { Text(L10n.text("10 秒")).tag(10); Text(L10n.text("1 分钟")).tag(60); Text(L10n.text("5 分钟")).tag(300) }.labelsHidden() }
                DisclosureGroup(L10n.text("选择发送的指标")) {
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:180))],alignment:.leading) {
                        ForEach(kinds) { kind in
                            Toggle(L10n.text(kind.title),isOn:Binding(get:{access.configuration.webhookMetrics.contains(kind.rawValue)},set:{ selected in
                                if selected { access.configuration.webhookMetrics.insert(kind.rawValue) } else { access.configuration.webhookMetrics.remove(kind.rawValue) }
                            })).toggleStyle(.checkbox)
                        }
                    }.padding(.top,10)
                }.padding(15)
                DeveloperKeyControls(access:access, name:"webhook", title:"签名密钥")
                VStack(alignment:.leading,spacing:6) {
                    Text(L10n.text(access.webhookStatus))
                    Text(L10n.text("HMAC-SHA256 签名；不跟随重定向，失败最多尝试三次。未投递快照不跨退出持久保存。")).foregroundStyle(PulseTheme.secondary)
                }.font(PulseTheme.font(size:11)).padding(15)
            }
            Text(L10n.text("修改后点击应用。关闭应用或 Mac 休眠时，接口暂停。")).font(PulseTheme.font(size:11)).foregroundStyle(PulseTheme.secondary)
        }.buttonStyle(.bordered).controlSize(.regular)
    }
}


private struct DeveloperKeyControls: View {
    @ObservedObject var access: DeveloperAccess
    let name: String
    let title: String
    @State private var importing = false
    @State private var draft = ""
    @State private var importError = ""
    var body: some View {
        VStack(alignment:.leading, spacing:10) {
            HStack {
                Text(L10n.text(title)).font(PulseTheme.font(size:13,weight:.medium))
                Spacer()
                Button(L10n.text(access.revealedKeys[name] == nil ? "显示密钥" : "隐藏密钥")) {
                    if access.revealedKeys[name] == nil { access.manageKey(name,action:.reveal) } else { access.hideKey(name) }
                }
                Button(L10n.text("复制密钥")) { access.copyKey(name) }
                Menu(L10n.text("管理密钥")) {
                    Button(L10n.text("导入密钥…")) { draft = ""; importError = ""; importing = true }
                    Button(L10n.text("导出密钥…")) { access.manageKey(name,action:.export) }
                    Button(L10n.text("重新生成密钥")) { access.rotate(name) }
                    Divider()
                    Button(L10n.text("从旧版钥匙串导入")) { access.manageKey(name,action:.legacy) }
                }.fixedSize()
            }.disabled(access.isApplying || access.isManagingKey)
            if let key = access.revealedKeys[name] {
                Text(key).font(PulseTheme.font(size:12,design:.monospaced)).textSelection(.enabled)
            }
            let status = name == "api" ? access.keyStatus : access.webhookKeyStatus
            if !status.isEmpty { Text(L10n.text(status)).font(PulseTheme.font(size:11)).foregroundStyle(PulseTheme.secondary) }
        }.padding(15)
        .onDisappear { access.hideKey(name) }
        .sheet(isPresented:$importing,onDismiss:{ draft = "" }) {
            VStack(alignment:.leading,spacing:16) {
                Text(L10n.text("导入密钥")).font(.headline)
                HStack {
                    SecureField(L10n.text("粘贴密钥"),text:$draft).textFieldStyle(.roundedBorder)
                    Button(L10n.text("粘贴")) { draft = NSPasteboard.general.string(forType:.string) ?? "" }
                }
                Text(L10n.text("保存后立即替换当前密钥。")).font(.caption).foregroundStyle(.secondary)
                if !importError.isEmpty { Text(L10n.text(importError)).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button(L10n.text("取消")) { importing = false }.keyboardShortcut(.cancelAction)
                    Button(L10n.text("保存")) {
                        do {
                            let value = try DeveloperSecrets.validated(draft)
                            access.manageKey(name,action:.importValue(value)); importing = false; draft = ""
                        } catch { importError = error.localizedDescription }
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width:470)
        }
    }
}
