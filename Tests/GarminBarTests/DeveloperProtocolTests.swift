import XCTest
import Security
@testable import GarminBar

@MainActor final class DeveloperProtocolTests: XCTestCase {
    func testAuthenticationDefaultsAndPreferenceMigration() throws {
        XCTAssertTrue(DeveloperConfiguration().requiresAPIKey)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DeveloperConfiguration())) as? [String: Any])
        object.removeValue(forKey: "requireAPIKey")
        func decode() throws -> DeveloperConfiguration {
            try JSONDecoder().decode(DeveloperConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertTrue(try decode().requiresAPIKey)
        object["requireAPIKey"] = NSNull()
        XCTAssertTrue(try decode().requiresAPIKey)
        object["requireAPIKey"] = false
        let anonymous = try decode()
        XCTAssertFalse(try JSONDecoder().decode(DeveloperConfiguration.self, from: JSONEncoder().encode(anonymous)).requiresAPIKey)
        object["requireAPIKey"] = true
        XCTAssertTrue(try decode().requiresAPIKey)
        object["requireAPIKey"] = "false"
        XCTAssertThrowsError(try decode())
    }
    func testClientExamplesMatchAuthenticationMode() throws {
        for required in [true, false] {
            var configuration = DeveloperConfiguration()
            configuration.requireAPIKey = required
            let data = Data(configuration.clientExample(baseURL: "http://127.0.0.1:17890").utf8)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let servers = try XCTUnwrap(object["mcpServers"] as? [String: [String: Any]])
            let server = try XCTUnwrap(servers["wristbeam"])
            XCTAssertEqual(server["url"] as? String, "http://127.0.0.1:17890/mcp")
            XCTAssertEqual(server["headers"] != nil, required)
        }
    }
    func testKeylessAccessRequiresExplicitOptOutAndCanBeDisabledAgain() throws {
        var queries = 0
        let headers = ["host": "127.0.0.1:17890"]
        let anonymous = DeveloperRequest(method: "GET", target: "/api/v1/metrics", headers: headers, body: Data())
        for (required, expected) in [(true, 401), (false, 200), (true, 401)] {
            let response = DeveloperProtocol.route(anonymous, token: "", allowedHosts: ["127.0.0.1:17890"], origin: "http://127.0.0.1:17890", requireAPIKey: required) { _, _ in
                queries += 1; return ["synthetic": true]
            }
            XCTAssertEqual(response.status, expected)
        }
        XCTAssertEqual(queries, 1)
        // The primary-key toggle does not determine whether missing credentials are accepted.
        let defaultResponse = DeveloperProtocol.route(anonymous, token: "", allowedHosts: ["127.0.0.1:17890"], origin: "http://127.0.0.1:17890") { _, _ in
            XCTFail("Default mode queried private data"); return [:]
        }
        XCTAssertEqual(defaultResponse.status, 401)
    }
    func testKeylessModePreservesHostOriginCredentialsAndScopes() throws {
        func call(headers: [String: String], scopes: Set<String>? = nil, expected: Int) {
            var values = ["host": "127.0.0.1:17890"]
            values.merge(headers) { _, new in new }
            let request = DeveloperRequest(method: "GET", target: "/api/v1/metrics", headers: values, body: Data())
            let response = DeveloperProtocol.route(request, token: "fixture", allowedHosts: ["127.0.0.1:17890"], origin: "http://127.0.0.1:17890", scopes: scopes, requireAPIKey: false) { _, _ in
                XCTAssertEqual(expected, 200); return ["synthetic": true]
            }
            XCTAssertEqual(response.status, expected)
        }
        call(headers: [:], expected: 200)
        call(headers: ["host": "evil.example"], expected: 403)
        call(headers: ["origin": "https://evil.example"], expected: 403)
        for credential in ["", "Bearer wrong", "Basic fixture"] {
            call(headers: ["authorization": credential], expected: 401)
        }
        call(headers: ["authorization": "Bearer fixture"], scopes: ["status"], expected: 403)
        call(headers: ["authorization": "Bearer fixture"], scopes: ["metrics"], expected: 200)
    }
    func testKeychainFailuresAreNotMissingKeys() throws {
        XCTAssertNil(try DeveloperSecrets.decoded(status: errSecItemNotFound, data: nil))
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled, errSecMissingEntitlement] {
            XCTAssertThrowsError(try DeveloperSecrets.decoded(status: status, data: nil)) { error in
                XCTAssertEqual((error as? DeveloperKeychainError)?.status, status)
            }
        }
        XCTAssertThrowsError(try DeveloperSecrets.decoded(status: errSecSuccess, data: nil))
        XCTAssertEqual(try DeveloperSecrets.decoded(status: errSecSuccess, data: Data("fixture".utf8)), "fixture")
    }
    func testLocalCredentialsPersistAndRotateIndependently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = DeveloperSecrets(directory:directory)
        XCTAssertNil(try store.load("api"))
        let key = try store.key("api")
        XCTAssertEqual(key.count,64)
        XCTAssertEqual(try DeveloperSecrets(directory:directory).key("api"),key)
        let webhook = try store.key("webhook")
        XCTAssertNotEqual(webhook,key)
        let replacement = try DeveloperSecrets.generate()
        try store.save(replacement,name:"api")
        XCTAssertEqual(try store.load("api"),replacement)
        XCTAssertEqual(try store.load("webhook"),webhook)
        let fileMode = try FileManager.default.attributesOfItem(atPath:directory.appendingPathComponent("api.key").path)[.posixPermissions] as? NSNumber
        let directoryMode = try FileManager.default.attributesOfItem(atPath:directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(fileMode?.intValue,0o600)
        XCTAssertEqual(directoryMode?.intValue,0o700)
    }
    func testKeyExportImportRoundtripPreservesDestinationFolderPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o755])
        defer { try? FileManager.default.removeItem(at:directory) }
        let key = try DeveloperSecrets.generate()
        let file = directory.appendingPathComponent("export.txt")
        try DeveloperSecrets.export(key,to:file)
        let imported = try DeveloperSecrets.validated(String(contentsOf:file,encoding:.utf8))
        XCTAssertEqual(imported,key)
        let folderMode = try FileManager.default.attributesOfItem(atPath:directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(folderMode?.intValue,0o755)
        XCTAssertEqual(fileMode?.intValue,0o600)
        let store = DeveloperSecrets(directory:directory.appendingPathComponent("credentials"))
        try store.save(imported,name:"api")
        XCTAssertEqual(try store.load("api"),key)
    }
    func testInvalidImportsAndCorruptFilesNeverReplaceExistingKeys() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = DeveloperSecrets(directory:directory)
        let key = try store.key("api")
        for invalid in ["", "short", String(repeating:"a",count:513), key + "\r\nInjected: header", "Bearer " + key] {
            XCTAssertThrowsError(try store.save(invalid,name:"api"))
            XCTAssertEqual(try store.load("api"),key)
        }
        XCTAssertThrowsError(try store.save(key,name:"../escape"))
        try Data([0xff]).write(to:directory.appendingPathComponent("api.key"))
        XCTAssertThrowsError(try store.key("api"))
        XCTAssertEqual(try Data(contentsOf:directory.appendingPathComponent("api.key")),Data([0xff]))
    }
    func testImportedKeyImmediatelyChangesAuthentication() throws {
        let payload: [String:Any] = ["jsonrpc":"2.0","id":1,"method":"tools/list"]
        let old = try DeveloperSecrets.generate(), new = try DeveloperSecrets.generate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = DeveloperSecrets(directory:directory)
        try store.save(old,name:"api"); try store.save(new,name:"api")
        let active = try store.key("api")
        for (key,status) in [(old,401),(new,200)] {
            let response = DeveloperProtocol.route(try request(payload,token:"Bearer " + key),token:active,allowedHosts:["127.0.0.1:17890"],origin:"http://127.0.0.1:17890") { _,_ in ["synthetic":true] }
            XCTAssertEqual(response.status,status)
        }
    }
    private func request(_ object: Any, token: String = "Bearer fixture", origin: String? = nil, host: String = "127.0.0.1:17890") throws -> DeveloperRequest {
        var headers = ["host":host,"authorization":token,"content-type":"application/json","accept":"application/json, text/event-stream"]
        headers["origin"] = origin
        return DeveloperRequest(method:"POST",target:"/mcp",headers:headers,body:try JSONSerialization.data(withJSONObject:object))
    }
    private func route(_ request: DeveloperRequest) -> DeveloperResponse {
        DeveloperProtocol.route(request,token:"fixture",allowedHosts:["127.0.0.1:17890"],origin:"http://127.0.0.1:17890") { _,_ in ["synthetic":true] }
    }
    func testRejectsUnauthorizedOriginsAndHostsBeforeDataQueries() throws {
        let payload: [String:Any] = ["jsonrpc":"2.0","id":1,"method":"tools/list"]
        XCTAssertEqual(route(try request(payload,token:"wrong")).status,401)
        XCTAssertEqual(route(try request(payload,origin:"https://untrusted.example")).status,403)
        XCTAssertEqual(route(try request(payload,host:"evil.example:17890")).status,403)
        XCTAssertEqual(route(try request(payload)).status,200)
    }
    func testInitializeAndReadOnlyTools() throws {
        let response = route(try request(["jsonrpc":"2.0","id":1,"method":"initialize","params":["protocolVersion":"2025-06-18"]]))
        let object = try JSONSerialization.jsonObject(with:response.data) as! [String:Any]
        let result = object["result"] as! [String:Any]
        XCTAssertEqual(result["protocolVersion"] as? String,"2025-06-18")
        XCTAssertEqual(DeveloperProtocol.tools.count,9)
        for item in DeveloperProtocol.tools { XCTAssertEqual((item["annotations"] as? [String:Bool])?["readOnlyHint"],true) }
        XCTAssertFalse(DeveloperProtocol.tools.contains { ($0["name"] as? String ?? "").contains("upload") })
    }
    func testNotificationsReturnEmpty202AndUnknownToolFails() throws {
        let response = route(try request(["jsonrpc":"2.0","method":"notifications/initialized"]))
        XCTAssertEqual(response.status,202); XCTAssertEqual(response.data.count,0)
        let bad = route(try request(["jsonrpc":"2.0","id":2,"method":"tools/call","params":["name":"delete_watch"]]))
        XCTAssertTrue(String(decoding:bad.data,as:UTF8.self).contains("-32602"))
    }
    func testScopedMCPDiscoveryAndDirectCallsEnforceTheSameBoundary() throws {
        var queries = 0
        func scoped(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
            let response = DeveloperProtocol.route(try request(["jsonrpc": "2.0", "id": 1, "method": method, "params": params]),
                token: "fixture", allowedHosts: ["127.0.0.1:17890"], origin: "http://127.0.0.1:17890", scopes: ["summary"]) { _, _ in
                    queries += 1; return ["synthetic": true]
                }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: response.data) as? [String: Any])
        }
        let tools = try XCTUnwrap(scoped("tools/list")["result"] as? [String: Any])
        XCTAssertEqual((tools["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["wristbeam_summary"])
        let resources = try XCTUnwrap(scoped("resources/list")["result"] as? [String: Any])
        XCTAssertEqual((resources["resources"] as? [[String: Any]])?.count, 0)
        XCTAssertNotNil(try scoped("resources/read", ["uri": "wristbeam://metrics"])["error"])
        XCTAssertNotNil(try scoped("tools/call", ["name": "wristbeam_series"])["error"])
        XCTAssertEqual(queries, 0)
        XCTAssertNotNil(try scoped("tools/call", ["name": "wristbeam_summary"])["result"])
        XCTAssertEqual(queries, 1)
    }
    func testIncrementalHTTPAndRequestSmugglingRejection() throws {
        let head = "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n"
        XCTAssertNil(try DeveloperRequest.parse(Data((head + "{").utf8)))
        XCTAssertEqual(try DeveloperRequest.parse(Data((head + "{}").utf8))?.body,Data("{}".utf8))
        XCTAssertThrowsError(try DeveloperRequest.parse(Data((head + "{}extra").utf8)))
        XCTAssertThrowsError(try DeveloperRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 0\r\ncontent-length: 8\r\n\r\n".utf8)))
        XCTAssertThrowsError(try DeveloperRequest.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)))
        XCTAssertThrowsError(try DeveloperRequest.parse(Data(repeating:65,count:65537)))
    }
    func testWebhookOnlyUsesExplicitSecureDestinations() {
        XCTAssertNotNil(DeveloperProtocol.webhookURL("https://receiver.example/hook"))
        XCTAssertNotNil(DeveloperProtocol.webhookURL("http://127.0.0.1:9000/hook"))
        XCTAssertNil(DeveloperProtocol.webhookURL("http://receiver.example/hook"))
        XCTAssertNil(DeveloperProtocol.webhookURL("https://user:password@receiver.example/hook"))
        XCTAssertNil(DeveloperProtocol.webhookURL("file:///private/data"))
    }
    func testSignaturesBindTimestampAndRawBody() {
        let body = Data("{\"synthetic\":true}".utf8)
        let first = DeveloperProtocol.webhookSignature(secret:"fixture",timestamp:"123",body:body)
        XCTAssertEqual(first,DeveloperProtocol.webhookSignature(secret:"fixture",timestamp:"123",body:body))
        XCTAssertNotEqual(first,DeveloperProtocol.webhookSignature(secret:"fixture",timestamp:"124",body:body))
        XCTAssertNotEqual(first,DeveloperProtocol.webhookSignature(secret:"fixture",timestamp:"123",body:Data("{}".utf8)))
        XCTAssertFalse(DeveloperProtocol.equalSecret("fixture","other"))
    }
    func testWebhookDeduplicatesAgeButPreservesFreshnessTransitions() throws {
        func payload(age: Double, stale: Bool = false, value: Double = 60) -> [String: Any] {
            ["metrics": [["id": "heartRate", "value": value, "ageSeconds": age, "stale": stale]], "sync": ["watchConnected": true]]
        }
        let initial = try DeveloperWebhook.changeFingerprint(payload(age: 1))
        XCTAssertEqual(initial, try DeveloperWebhook.changeFingerprint(payload(age: 20)))
        XCTAssertNotEqual(initial, try DeveloperWebhook.changeFingerprint(payload(age: 200, stale: true)))
        XCTAssertNotEqual(initial, try DeveloperWebhook.changeFingerprint(payload(age: 1, value: 70)))
    }
}
