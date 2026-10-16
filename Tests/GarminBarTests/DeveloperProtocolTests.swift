import XCTest
@testable import GarminBar

@MainActor final class DeveloperProtocolTests: XCTestCase {
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
        XCTAssertEqual(DeveloperProtocol.tools.count,8)
        for item in DeveloperProtocol.tools { XCTAssertEqual((item["annotations"] as? [String:Bool])?["readOnlyHint"],true) }
        XCTAssertFalse(DeveloperProtocol.tools.contains { ($0["name"] as? String ?? "").contains("upload") })
    }
    func testNotificationsReturnEmpty202AndUnknownToolFails() throws {
        let response = route(try request(["jsonrpc":"2.0","method":"notifications/initialized"]))
        XCTAssertEqual(response.status,202); XCTAssertEqual(response.data.count,0)
        let bad = route(try request(["jsonrpc":"2.0","id":2,"method":"tools/call","params":["name":"delete_watch"]]))
        XCTAssertTrue(String(decoding:bad.data,as:UTF8.self).contains("-32602"))
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
}
