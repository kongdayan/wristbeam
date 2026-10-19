import AppKit
import Security

/// Isolated CI probe: unique credentials, a named pasteboard and synthetic loopback data.
/// Does not initialize AppModel, open user caches, or change normal preferences.
enum DeveloperSelfTest {
    @MainActor static func run() async throws {
        let service = "cn.wristbeam.selftest." + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(service)
        let store = DeveloperSecrets(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = try await Task.detached { try store.key("api") }.value
        let restored = try await Task.detached { try DeveloperSecrets(directory: directory).load("api") }.value
        guard token.count == 64, restored == token else { throw DeveloperError.invalid("Packaged key persistence failed") }
        let exported = directory.appendingPathComponent("exported.txt")
        try DeveloperSecrets.export(token, to:exported)
        let imported = try DeveloperSecrets.validated(String(contentsOf:exported,encoding:.utf8))
        try store.save(imported,name:"webhook")
        let mode = try FileManager.default.attributesOfItem(atPath:exported.path)[.posixPermissions] as? NSNumber
        guard try store.load("webhook") == token, mode?.intValue == 0o600 else { throw DeveloperError.invalid("Packaged key export/import failed") }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(service))
        defer { pasteboard.clearContents(); pasteboard.releaseGlobally() }
        guard pasteboard.setString(token, forType: .string), pasteboard.string(forType: .string) == token else {
            throw DeveloperError.invalid("Packaged clipboard verification failed")
        }
        let server = DeveloperServer()
        let port = UInt16.random(in: 49152...64000)
        let origin = "http://127.0.0.1:\(port)"
        var requireAPIKey = true
        server.handle = { request, complete in Task { @MainActor in
            complete(DeveloperProtocol.route(request, token: token, allowedHosts: ["127.0.0.1:\(port)"], origin: origin, requireAPIKey: requireAPIKey) { _,_ in ["synthetic":true] })
        } }
        defer { server.stop() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var completed = false
            server.onState = { ready in Task { @MainActor in
                guard ready, !completed else { return }; completed = true; continuation.resume()
            } }
            server.onFailure = { message in Task { @MainActor in
                guard !completed else { return }; completed = true; continuation.resume(throwing: DeveloperError.invalid(message))
            } }
            do { try server.start(host: "127.0.0.1", port: port, identity: nil) }
            catch { completed = true; continuation.resume(throwing: error) }
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: origin + "/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0","id":1,"method":"initialize","params":["protocolVersion":"2025-06-18"]])
        let (_, denied) = try await session.data(for: request)
        guard (denied as? HTTPURLResponse)?.statusCode == 401 else { throw DeveloperError.invalid("Packaged authentication gate failed") }
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String:Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              (json?["result"] as? [String:Any])?["protocolVersion"] as? String == "2025-06-18" else {
            throw DeveloperError.invalid("Packaged MCP handshake failed")
        }
        requireAPIKey = false
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        let (_, anonymous) = try await session.data(for: request)
        guard (anonymous as? HTTPURLResponse)?.statusCode == 200 else { throw DeveloperError.invalid("Packaged keyless handshake failed") }
        request.setValue("Bearer invalid-fixture", forHTTPHeaderField: "Authorization")
        let (_, invalid) = try await session.data(for: request)
        guard (invalid as? HTTPURLResponse)?.statusCode == 401 else { throw DeveloperError.invalid("Packaged invalid credential rejection failed") }
        requireAPIKey = true
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        let (_, restoredGate) = try await session.data(for: request)
        guard (restoredGate as? HTTPURLResponse)?.statusCode == 401 else { throw DeveloperError.invalid("Packaged authentication restore failed") }
    }
}
