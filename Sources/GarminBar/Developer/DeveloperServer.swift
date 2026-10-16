import Foundation
import Network
import Security

final class DeveloperServer {
    private let queue = DispatchQueue(label:"cn.wristbeam.developer.http",qos:.utility)
    private var listener: NWListener?
    private var clients: [UUID:NWConnection] = [:]
    private var generation = UUID()
    var onState: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var handle: ((DeveloperRequest, @escaping (DeveloperResponse) -> Void) -> Void)?
    func start(host: String, port: UInt16, identity: SecIdentity?) throws {
        let parameters: NWParameters
        if let identity {
            let tls = NWProtocolTLS.Options()
            guard let local = sec_identity_create(identity) else { throw DeveloperError.invalid("Invalid TLS identity") }
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions,local)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions,.TLSv12)
            parameters = NWParameters(tls:tls,tcp:NWProtocolTCP.Options())
        } else { parameters = NWParameters.tcp }
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host:NWEndpoint.Host(host),port:NWEndpoint.Port(rawValue:port)!)
        let next = try NWListener(using:parameters)
        queue.async { [self] in
            stopOnQueue(); let active = UUID(); generation = active; listener = next
            next.stateUpdateHandler = { [weak self] state in
                guard let self, self.generation == active else { return }
                switch state {
                case .ready: self.onState?(true)
                case .failed(let error), .waiting(let error):
                    self.stopOnQueue(); self.onState?(false); self.onFailure?(error.localizedDescription)
                default: break
                }
            }
            next.newConnectionHandler = { [weak self] client in self?.accept(client) }
            next.start(queue:queue)
        }
    }
    func stop() { queue.async { [self] in stopOnQueue(); onState?(false) } }
    private func stopOnQueue() {
        generation = UUID(); listener?.cancel(); listener = nil
        for connection in clients.values { connection.cancel() }; clients.removeAll()
    }
    private func accept(_ connection: NWConnection) {
        guard clients.count < 32 else { connection.cancel(); return }
        let id = UUID(); clients[id] = connection; connection.start(queue:queue)
        queue.asyncAfter(deadline:.now()+10) { [weak self] in self?.finish(id) }
        read(connection,id:id,buffer:Data())
    }
    private func finish(_ id: UUID) { clients.removeValue(forKey:id)?.cancel() }
    private func read(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:8192) { [weak self] bytes,_,complete,error in
            guard let self, self.clients[id] != nil else { return }
            var data = buffer; if let bytes { data.append(bytes) }
            do {
                if let request = try DeveloperRequest.parse(data) {
                    self.handle?(request) { [weak self] response in
                        guard let self else { return }
                        self.queue.async {
                            guard self.clients[id] != nil else { return }
                            connection.send(content:response.wire,completion:.contentProcessed { [weak self] _ in self?.finish(id) })
                        }
                    }
                } else if complete || error != nil { self.finish(id) }
                else { self.read(connection,id:id,buffer:data) }
            } catch {
                connection.send(content:DeveloperResponse.json(["error":"Malformed HTTP request"],status:400).wire,completion:.contentProcessed { [weak self] _ in self?.finish(id) })
            }
        }
    }
    static func identity(data: Data, password: String) throws -> SecIdentity {
        var values: CFArray?
        let status = SecPKCS12Import(data as CFData,[kSecImportExportPassphrase as String:password] as CFDictionary,&values)
        guard status == errSecSuccess, let items = values as? [[String:Any]], let value = items.first?[kSecImportItemIdentity as String] else { throw DeveloperError.invalid("Certificate or password is invalid") }
        return value as! SecIdentity
    }
}

final class WebhookNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Best-effort coalesced delivery. The caller owns cancellation and account scope.
enum DeveloperWebhook {
    // Age changes with the clock; timestamps, values and freshness transitions
    // still trigger delivery. The actual event keeps the complete metadata.
    static func changeFingerprint(_ payload: [String: Any]) throws -> Data {
        var stable = payload
        if let rows = stable["metrics"] as? [[String: Any]] {
            stable["metrics"] = rows.map { row -> [String: Any] in
                var row = row; row.removeValue(forKey: "ageSeconds"); return row
            }
        }
        return try JSONSerialization.data(withJSONObject: stable, options: [.sortedKeys])
    }
    static func deliver(url: URL, body: Data, secret: String, session: URLSession) async -> Bool {
        for attempt in 0..<3 {
            guard !Task.isCancelled else { return false }
            if attempt > 0 { do { try await Task.sleep(nanoseconds:UInt64(attempt * 2) * 1_000_000_000) } catch { return false } }
            guard !Task.isCancelled else { return false }
            let stamp = String(Int(Date().timeIntervalSince1970))
            var request = URLRequest(url:url); request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.setValue(stamp,forHTTPHeaderField:"X-WristBeam-Timestamp")
            request.setValue("sha256=" + DeveloperProtocol.webhookSignature(secret:secret,timestamp:stamp,body:body),forHTTPHeaderField:"X-WristBeam-Signature")
            do {
                let (_,response) = try await session.data(for:request)
                guard !Task.isCancelled else { return false }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) { return true }
                if code >= 300 && code < 500 && code != 429 { return false }
            } catch { if Task.isCancelled { return false } }
        }
        return false
    }
}
