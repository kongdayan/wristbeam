import AppKit
import Combine
import CryptoKit
import Security

@MainActor final class DeveloperAccess: ObservableObject {
    @Published var configuration: DeveloperConfiguration
    @Published private(set) var running = false
    @Published private(set) var status = "接口已关闭"
    @Published private(set) var requestCount = 0
    @Published private(set) var webhookStatus = "Webhook 已关闭"
    @Published private(set) var certificateAvailable = false
    @Published private(set) var keyStatus = ""
    @Published private(set) var revealedKeys: [String: String] = [:]
    @Published private(set) var webhookKeyStatus = ""
    @Published private(set) var configurationError = ""
    @Published var isManagingKey = false
    @Published private(set) var isApplying = false
    @Published var clients: [DeveloperClientCredential] = []
    @Published var clientStatus = ""
    let clientStore = DeveloperClientStore(url: AppPaths.directory("Developer").appendingPathComponent("Credentials/clients.json"))
    private var operationGeneration = UUID()
    private let secrets = DeveloperSecrets()
    private let server = DeveloperServer()
    private weak var model: AppModel?
    private var token = ""
    private var webhookToken = ""
    private var active = DeveloperConfiguration()
    private var lastRequestWindow = Date.distantPast
    private var requestsInWindow = 0
    private var webhookTask: Task<Void,Never>?
    private var lastWebhook = Date.distantPast
    private var lastPayloadHash = ""
    var generation = UUID()
    private let redirectPolicy = WebhookNoRedirect()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
        return URLSession(configuration:config,delegate:redirectPolicy,delegateQueue:nil)
    }()
    private var certificateURL: URL { AppPaths.directory("Developer").appendingPathComponent("identity.p12") }
    init() {
        configuration = AppPreferences.shared.data(forKey:"developerConfiguration").flatMap { try? JSONDecoder().decode(DeveloperConfiguration.self,from:$0) } ?? DeveloperConfiguration()
        certificateAvailable = FileManager.default.fileExists(atPath:certificateURL.path)
    }
    func attach(_ model: AppModel) {
        self.model = model
        server.onState = { [weak self] ready in Task { @MainActor in
            guard let self else { return }; self.running = ready
            self.status = ready ? "接口正在监听" : self.active.enabled ? "接口启动失败或已停止，请检查端口与证书" : "接口已关闭"
        } }
        server.onFailure = { [weak self] message in Task { @MainActor in
            self?.configurationError = message
        } }
        server.handle = { [weak self, weak model] request, completion in Task { @MainActor in
            guard let self, let model, self.active.enabled else { completion(.json(["error":"Server disabled"],status:403)); return }
            let now = Date()
            if now.timeIntervalSince(self.lastRequestWindow) >= 60 { self.lastRequestWindow = now; self.requestsInWindow = 0 }
            self.requestsInWindow += 1
            guard self.requestsInWindow <= 240 else { completion(.json(["error":"Rate limit: 240 requests/minute"],status:429)); return }
            self.requestCount += 1
            let host = self.active.host == "127.0.0.1" ? "127.0.0.1" : self.active.publicHost
            let allowed: Set<String> = ["\(host):\(self.active.port)","localhost:\(self.active.port)","127.0.0.1:\(self.active.port)"]
            let incoming = request.headers["authorization"] ?? ""
            let client = self.clients.first { $0.enabled && DeveloperProtocol.equalSecret(incoming, "Bearer " + $0.key) }
            let requireAPIKey = self.active.requiresAPIKey
            let primary = self.active.primaryKeyEnabled != false
            let token = client?.key ?? (primary ? self.token : "")
            let scopes = client.map { Set($0.scopes.map(\.rawValue)) }
            let snapshot = model.developerSnapshot(), scope = self.generation
            let origin = self.baseURL(config: self.active)
            let response = await Task.detached(priority: .utility) {
                DeveloperProtocol.route(request, token: token, allowedHosts: allowed, origin: origin, scopes: scopes, requireAPIKey: requireAPIKey) { route, args in
                    try snapshot.query(route, arguments: args)
                }
            }.value
            guard self.generation == scope, self.active.enabled else { completion(.json(["error": "Data scope changed; retry the request"], status: 409)); return }
            if let client, response.status == 200 { self.recordClientAccess(client.id) }
            completion(response)
        } }
        if configuration.enabled || configuration.webhookEnabled { apply() }
        else {
            let file = clientStore
            Task {
                do { clients = try await Task.detached(priority: .utility) { try file.load() }.value }
                catch { clientStatus = "无法读取客户端密钥" }
            }
        }
    }
    var hasUnappliedChanges: Bool { configuration != active }
    var baseURL: String { baseURL(config:configuration) }
    private func baseURL(config: DeveloperConfiguration) -> String { "\(config.https ? "https" : "http")://\(config.host == "127.0.0.1" ? "127.0.0.1" : config.publicHost):\(config.port)" }
    var authenticationStatus: String { active.requiresAPIKey ? "访问需要密钥" : "无密钥访问已开启" }
    var clientExample: String { configuration.clientExample(baseURL: baseURL) }
    func apply() {
        guard model?.preview != true else { status = "演示模式不启动接口或 Webhook"; return }
        guard !isApplying, !isManagingKey else { return }
        configurationError = ""
        let config = configuration
        do {
            guard (1024...65535).contains(config.port), ["127.0.0.1","0.0.0.0"].contains(config.host), (10...3600).contains(config.webhookInterval) else { throw DeveloperError.invalid("监听端口或间隔无效") }
            guard !config.publicHost.isEmpty, config.publicHost.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { throw DeveloperError.invalid("访问主机名无效") }
            guard config.host == "127.0.0.1" || config.https else { throw DeveloperError.invalid("局域网监听必须启用 HTTPS") }
            if config.webhookEnabled {
                guard DeveloperProtocol.webhookURL(config.webhookURL) != nil, !config.webhookMetrics.isEmpty else { throw DeveloperError.invalid("请选择 Webhook 指标及有效的 HTTPS 地址") }
            }
        } catch { configurationError = error.localizedDescription; return }
        isApplying = true
        let operation = UUID(); operationGeneration = operation
        let store = secrets, clientsFile = clientStore
        Task { [self] in
            defer { isApplying = false }
            do {
                // Read private local files away from the UI thread.
                let values = try await Task.detached(priority: .userInitiated) {
                    let api = config.enabled ? try store.key("api") : ""
                    let webhook = config.webhookEnabled ? try store.key("webhook") : ""
                    let password = config.enabled && config.https ? try store.load("certificatePassword") ?? "" : ""
                    let clients = try clientsFile.load()
                    return (api, password, webhook, clients)
                }.value
                guard operationGeneration == operation else { return }
                let identity = config.enabled && config.https ? try DeveloperServer.identity(data:Data(contentsOf:certificateURL),password:values.1) : nil
                token = values.0; webhookToken = values.2; clients = values.3
                generation = UUID(); webhookTask?.cancel(); webhookTask = nil; lastPayloadHash = ""; lastWebhook = .distantPast
                active = config; running = false; server.stop()
                if config.enabled { status = "正在启动接口…"; try server.start(host:config.host,port:UInt16(config.port),identity:identity) }
                else { status = "接口已关闭" }
                AppPreferences.shared.set(try JSONEncoder().encode(config),forKey:"developerConfiguration")
                webhookStatus = config.webhookEnabled ? "等待下一次数据更新" : "Webhook 已关闭"
            } catch {
                guard operationGeneration == operation else { return }
                configurationError = error.localizedDescription
            }
        }
    }
    func accountChanged() {
        generation = UUID(); webhookTask?.cancel(); webhookTask = nil; lastPayloadHash = ""; lastWebhook = Date()
    }
    func resumeAfterWake() {
        if active.enabled && !running && !isApplying && !hasUnappliedChanges { apply() }
    }
    func stopAll() {
        operationGeneration = UUID(); configurationError = ""; accountChanged(); configuration.enabled = false; configuration.webhookEnabled = false
        active.enabled = false; active.webhookEnabled = false; server.stop(); running = false
        status = "接口已关闭"; webhookStatus = "Webhook 已关闭"
        if let data = try? JSONEncoder().encode(configuration) { AppPreferences.shared.set(data,forKey:"developerConfiguration") }
    }
    private func setKeyStatus(_ message: String, name: String) {
        if name == "api" { keyStatus = message } else { webhookKeyStatus = message }
    }
    enum KeyAction { case copy, reveal, rotate, importValue(String), legacy, export }
    func hideKeys() { revealedKeys.removeAll() }
    func hideKey(_ name: String) { revealedKeys.removeValue(forKey: name) }
    func rotate(_ name: String) { manageKey(name, action: .rotate) }
    func copyKey(_ name: String) { manageKey(name, action: .copy) }
    func manageKey(_ name: String, action: KeyAction) {
        guard ["api", "webhook"].contains(name), !isManagingKey, !isApplying else { return }
        isManagingKey = true
        setKeyStatus("", name: name)
        let store = secrets
        Task { [self] in
            defer { isManagingKey = false }
            do {
                let key = try await Task.detached(priority: .userInitiated) {
                    switch action {
                    case .rotate:
                        let value = try DeveloperSecrets.generate(); try store.save(value, name:name); return value
                    case .importValue(let text):
                        let value = try DeveloperSecrets.validated(text); try store.save(value, name:name); return value
                    case .legacy:
                        let value = try DeveloperSecrets.legacyKey(name); try store.save(value, name:name); return value
                    default: return try store.key(name)
                    }
                }.value
                if name == "api" { token = key } else { webhookToken = key }
                switch action {
                case .rotate, .importValue, .legacy:
                    accountChanged()
                    revealedKeys.removeValue(forKey: name)
                    setKeyStatus("密钥已保存并生效",name:name)
                case .reveal: revealedKeys[name] = key
                case .copy:
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.setString(key,forType:.string), NSPasteboard.general.string(forType:.string) == key else {
                        throw DeveloperError.invalid("无法写入剪贴板，请重试")
                    }
                    setKeyStatus("密钥已复制",name:name)
                case .export:
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "wristbeam-\(name)-key.txt"
                    panel.canCreateDirectories = true
                    let response = await withCheckedContinuation { continuation in
                        if let window = NSApp.keyWindow {
                            panel.beginSheetModal(for:window) { continuation.resume(returning:$0) }
                        } else { panel.begin { continuation.resume(returning:$0) } }
                    }
                    guard response == .OK, let url = panel.url else { return }
                    try await Task.detached(priority:.userInitiated) { try DeveloperSecrets.export(key, to:url) }.value
                    setKeyStatus("密钥已导出",name:name)
                }
            } catch { setKeyStatus(error.localizedDescription,name:name) }
        }
    }
    func importCertificate(password: String) {
        guard !isApplying, !isManagingKey else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = []; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf:url); guard data.count <= 1048576 else { throw DeveloperError.invalid("证书文件过大") }
            _ = try DeveloperServer.identity(data:data,password:password)
            try secrets.save(password,name:"certificatePassword"); try GarminPrivateFile.write(data,to:certificateURL)
            certificateAvailable = true; status = "证书已导入，应用配置后生效"
        } catch { status = "证书导入失败，请检查 PKCS#12 文件和密码" }
    }
    func tick() {
        guard active.webhookEnabled, model?.preview == false, webhookTask == nil, Date().timeIntervalSince(lastWebhook) >= Double(active.webhookInterval), let model else { return }
        do {
            let all = try model.developerQuery("metrics",arguments:[:]) as? [String:Any] ?? [:]
            let rows = (all["metrics"] as? [[String:Any]] ?? []).filter { active.webhookMetrics.contains($0["id"] as? String ?? "") }
            guard !rows.isEmpty else { return }
            let payload: [String:Any] = ["metrics":rows,"sync":try model.developerQuery("status",arguments:[:])]
            let compare = try DeveloperWebhook.changeFingerprint(payload)
            let hash = SHA256.hash(data:compare).map{String(format:"%02x",$0)}.joined()
            guard hash != lastPayloadHash, let url = DeveloperProtocol.webhookURL(active.webhookURL), !webhookToken.isEmpty else { return }
            let secret = webhookToken
            let event: [String:Any] = ["schemaVersion":1,"id":UUID().uuidString,"type":"health.snapshot","createdAt":ISO8601DateFormatter().string(from:Date()),"data":payload]
            let bytes = try JSONSerialization.data(withJSONObject:event,options:[.sortedKeys])
            let scope = generation; lastWebhook = Date()
            webhookTask = Task { [weak self] in
                guard let self else { return }
                defer { if self.generation == scope { self.webhookTask = nil } }
                let delivered = await DeveloperWebhook.deliver(url:url,body:bytes,secret:secret,session:self.session)
                guard self.generation == scope, !Task.isCancelled else { return }
                if delivered { self.lastPayloadHash = hash; self.webhookStatus = "最近投递成功" }
                else { self.webhookStatus = "投递未成功，已保留重试" }
            }
        } catch { webhookStatus = "尚无可投递的数据" }
    }
}
