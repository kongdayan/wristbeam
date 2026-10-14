import AppKit
import Combine
import CryptoKit

struct DeveloperConfiguration: Codable {
    var enabled = false
    var host = "127.0.0.1"
    var port = 17890
    var https = false
    var publicHost = "localhost"
    var webhookEnabled = false
    var webhookURL = ""
    var webhookInterval = 60
    var webhookMetrics: Set<String> = []
}

@MainActor final class DeveloperAccess: ObservableObject {
    @Published var configuration: DeveloperConfiguration
    @Published private(set) var running = false
    @Published private(set) var status = "接口已关闭"
    @Published private(set) var requestCount = 0
    @Published private(set) var webhookStatus = "Webhook 已关闭"
    @Published private(set) var certificateAvailable = false
    private let secrets = DeveloperSecrets()
    private let server = DeveloperServer()
    private weak var model: AppModel?
    private var token = ""
    private var active = DeveloperConfiguration()
    private var lastRequestWindow = Date.distantPast
    private var requestsInWindow = 0
    private var webhookTask: Task<Void,Never>?
    private var lastWebhook = Date.distantPast
    private var lastPayloadHash = ""
    private var generation = UUID()
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
        server.handle = { [weak self, weak model] request, completion in Task { @MainActor in
            guard let self, let model, self.active.enabled else { completion(.json(["error":"Server disabled"],status:403)); return }
            let now = Date()
            if now.timeIntervalSince(self.lastRequestWindow) >= 60 { self.lastRequestWindow = now; self.requestsInWindow = 0 }
            self.requestsInWindow += 1
            guard self.requestsInWindow <= 240 else { completion(.json(["error":"Rate limit: 240 requests/minute"],status:429)); return }
            self.requestCount += 1
            let host = self.active.host == "127.0.0.1" ? "127.0.0.1" : self.active.publicHost
            let allowed: Set<String> = ["\(host):\(self.active.port)","localhost:\(self.active.port)","127.0.0.1:\(self.active.port)"]
            completion(DeveloperProtocol.route(request,token:self.token,allowedHosts:allowed,origin:self.baseURL(config:self.active)) { route,args in try model.developerQuery(route,arguments:args) })
        } }
        if configuration.enabled || configuration.webhookEnabled { apply() }
    }
    var baseURL: String { baseURL(config:configuration) }
    private func baseURL(config: DeveloperConfiguration) -> String { "\(config.https ? "https" : "http")://\(config.host == "127.0.0.1" ? "127.0.0.1" : config.publicHost):\(config.port)" }
    var clientExample: String { "{\n  \"mcpServers\": {\n    \"wristbeam\": {\n      \"type\": \"http\",\n      \"url\": \"\(baseURL)/mcp\",\n      \"headers\": {\"Authorization\": \"Bearer <WRISTBEAM_API_KEY>\"}\n    }\n  }\n}" }
    func apply() {
        guard model?.preview != true else { status = "演示模式不启动接口或 Webhook"; return }
        do {
            let config = configuration
            guard (1024...65535).contains(config.port), ["127.0.0.1","0.0.0.0"].contains(config.host), (10...3600).contains(config.webhookInterval) else { throw DeveloperError.invalid("监听端口或间隔无效") }
            guard !config.publicHost.isEmpty, config.publicHost.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { throw DeveloperError.invalid("访问主机名无效") }
            guard config.host == "127.0.0.1" || config.https else { throw DeveloperError.invalid("局域网监听必须启用 HTTPS") }
            if config.webhookEnabled {
                guard DeveloperProtocol.webhookURL(config.webhookURL) != nil, !config.webhookMetrics.isEmpty else { throw DeveloperError.invalid("请选择 Webhook 指标及有效的 HTTPS 地址") }
                if secrets.load("webhook") == nil { try secrets.save(DeveloperSecrets.generate(),name:"webhook") }
            }
            let identity = config.enabled && config.https ? try DeveloperServer.identity(data:Data(contentsOf:certificateURL),password:secrets.load("certificatePassword") ?? "") : nil
            if config.enabled {
                if secrets.load("api") == nil { try secrets.save(DeveloperSecrets.generate(),name:"api") }
                guard let stored = secrets.load("api"), !stored.isEmpty else { throw DeveloperError.invalid("无法读取访问密钥") }; token = stored
            }
            generation = UUID(); webhookTask?.cancel(); webhookTask = nil; lastPayloadHash = ""; lastWebhook = .distantPast
            active = config; running = false; server.stop()
            if config.enabled { status = "正在启动接口…"; try server.start(host:config.host,port:UInt16(config.port),identity:identity) }
            else { status = "接口已关闭" }
            AppPreferences.shared.set(try JSONEncoder().encode(config),forKey:"developerConfiguration")
            webhookStatus = config.webhookEnabled ? "等待下一次数据更新" : "Webhook 已关闭"
        } catch { status = error.localizedDescription }
    }
    func accountChanged() {
        generation = UUID(); webhookTask?.cancel(); webhookTask = nil; lastPayloadHash = ""; lastWebhook = Date()
    }
    func stopAll() {
        accountChanged(); configuration.enabled = false; configuration.webhookEnabled = false
        active.enabled = false; active.webhookEnabled = false; server.stop(); running = false
        status = "接口已关闭"; webhookStatus = "Webhook 已关闭"
        if let data = try? JSONEncoder().encode(configuration) { AppPreferences.shared.set(data,forKey:"developerConfiguration") }
    }
    func rotate(_ name: String) {
        do {
            try secrets.save(DeveloperSecrets.generate(),name:name)
            if name == "api" { token = secrets.load("api") ?? "" }
            if name == "webhook" { generation = UUID(); webhookTask?.cancel(); webhookTask = nil; lastPayloadHash = "" }
            status = "密钥已轮换，旧密钥立即失效"
        } catch { status = "密钥保存失败" }
    }
    func copyKey(_ name: String) {
        guard let key = secrets.load(name) else { status = "请先生成密钥"; return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key,forType:.string)
        status = "密钥已复制，请只交给可信客户端"
    }
    func importCertificate(password: String) {
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
            let compare = try JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys])
            let hash = SHA256.hash(data:compare).map{String(format:"%02x",$0)}.joined()
            guard hash != lastPayloadHash, let url = DeveloperProtocol.webhookURL(active.webhookURL), let secret = secrets.load("webhook") else { return }
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
