import Foundation
import CryptoKit
import CoreFoundation

struct DeveloperRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
    static func parse(_ data: Data) throws -> Self? {
        guard data.count <= 65536 else { throw DeveloperError.invalid("Request exceeds 64 KiB") }
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16384 { throw DeveloperError.invalid("Headers exceed 16 KiB") }; return nil
        }
        guard split.lowerBound <= 16384, let text = String(data: data[..<split.lowerBound], encoding: .utf8) else { throw DeveloperError.invalid("Invalid headers") }
        let lines = text.components(separatedBy: "\r\n"), first = lines[0].components(separatedBy: " ")
        guard first.count == 3, first[2] == "HTTP/1.1", first[1].hasPrefix("/"), !first[1].hasPrefix("//") else { throw DeveloperError.invalid("Invalid request line") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw DeveloperError.invalid("Invalid header") }
            let key = String(line[..<colon]).lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, headers[key] == nil else { throw DeveloperError.invalid("Duplicate header") }
            headers[key] = value
        }
        guard headers["transfer-encoding"] == nil else { throw DeveloperError.invalid("Chunked requests are not supported") }
        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.allSatisfy(\.isNumber), let size = Int(raw), size <= 49152 else { throw DeveloperError.invalid("Invalid content length") }; length = size
        } else { guard first[0] != "POST" else { throw DeveloperError.invalid("Content-Length required") }; length = 0 }
        let available = data.count - split.upperBound
        guard available >= length else { return nil }
        guard available == length else { throw DeveloperError.invalid("Pipelined requests are not supported") }
        return Self(method: first[0], target: first[1], headers: headers, body: Data(data[split.upperBound...]))
    }
}

enum DeveloperError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

struct DeveloperResponse {
    var status = 200
    var data: Data
    static func json(_ object: Any, status: Int = 200) -> Self {
        Self(status: status, data: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8))
    }
    var wire: Data {
        let reason = [200:"OK",202:"Accepted",400:"Bad Request",401:"Unauthorized",403:"Forbidden",404:"Not Found",405:"Method Not Allowed",406:"Not Acceptable",415:"Unsupported Media Type",429:"Too Many Requests",500:"Internal Server Error"][status] ?? "Error"
        var result = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n".utf8)
        result.append(data); return result
    }
}

enum DeveloperProtocol {
    static let versions = ["2025-06-18", "2025-03-26"]
    static func equalSecret(_ first: String, _ second: String) -> Bool {
        let a = Array(SHA256.hash(data: Data(first.utf8))), b = Array(SHA256.hash(data: Data(second.utf8)))
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    static func webhookSignature(secret: String, timestamp: String, body: Data) -> String {
        let bytes = Data(timestamp.utf8) + Data(".".utf8) + body
        return HMAC<SHA256>.authenticationCode(for: bytes, using: SymmetricKey(data: Data(secret.utf8))).map { String(format: "%02x", $0) }.joined()
    }
    static func webhookURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let host = url.host, url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else { return nil }
        return url
    }
    static var tools: [[String: Any]] {
        [tool("wristbeam_summary", "Read a local-only date-bounded health summary (1–31 days), sample coverage, missing metrics, overnight HRV and cached workout totals. Does not infer health conditions or refresh data.", properties: ["startDate": ["type": "string"], "endDate": ["type": "string"], "metrics": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 12]], required: ["startDate", "endDate"]),
         tool("wristbeam_status", "Read connection/sync availability, without account or device identifiers."),
         tool("wristbeam_metrics", "Read current cached health readings with units, source, record time and staleness. Not medical advice."),
         tool("wristbeam_catalog", "List available metric IDs and supported fields; definitions do not guarantee watch support."),
         tool("wristbeam_series", "Read one cached day of a metric, retaining gaps. No watch/cloud refresh is triggered.", properties: ["metric": ["type":"string"], "date":["type":"string","description":"Local calendar day YYYY-MM-DD"],"offset":["type":"integer","minimum":0],"limit":["type":"integer","minimum":1,"maximum":1440]], required:["metric","date"]),
         tool("wristbeam_hrv", "Read cloud overnight HRV history or a cached night. Separate from the provisional RR reading.", properties:["date":["type":"string","description":"Optional local night date YYYY-MM-DD"]]),
         tool("wristbeam_activities", "List cached workout summaries, newest first. History may be partial; never triggers cloud access or downloads.", properties: ["startDate":["type":"string"], "endDate":["type":"string"], "type":["type":"string"], "offset":["type":"integer","minimum":0], "limit":["type":"integer","minimum":1,"maximum":100]]),
         tool("wristbeam_activity", "Read one cached workout, heart rate zones and paginated laps. Download details in the app first. No coordinates or file paths.", properties: ["id":["type":"string","description":"Activity ID from wristbeam_activities"], "lapOffset":["type":"integer","minimum":0,"maximum":5000], "lapLimit":["type":"integer","minimum":1,"maximum":100]], required:["id"]),
         tool("wristbeam_activity_series", "Read a page of a downloaded reduced activity chart, not full original samples. Descriptor factor is metadata; values are unconverted. Aligned timestamp series is directTimestamp (epoch milliseconds).", properties: ["id":["type":"string"], "metric":["type":"string"], "offset":["type":"integer","minimum":0], "limit":["type":"integer","minimum":1,"maximum":500]], required:["id","metric"])]
    }
    static func permits(_ route: String, scopes: Set<String>?) -> Bool {
        guard let scopes else { return true }
        let scope = ["status": "status", "metrics": "metrics", "catalog": "metrics", "series": "history", "hrv": "history",
                     "activities": "activities", "activity": "activities", "activity_series": "activities", "summary": "summary"][route]
        return scope.map { scopes.contains($0) } ?? false
    }
    private static func tool(_ name: String, _ description: String, properties: [String:Any] = [:], required: [String] = []) -> [String:Any] {
        ["name":name,"description":description,"inputSchema":["type":"object","properties":properties,"required":required,"additionalProperties":false],"annotations":["readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false]]
    }
    static func route(_ request: DeveloperRequest, token: String, allowedHosts: Set<String>, origin: String, scopes: Set<String>? = nil, requireAPIKey: Bool = true, query: (String, [String:Any]) throws -> Any) -> DeveloperResponse {
        guard let host = request.headers["host"], allowedHosts.contains(host.lowercased()) else { return .json(["error":"Host rejected"],status:403) }
        if let incoming = request.headers["origin"], incoming != origin { return .json(["error":"Origin rejected"],status:403) }
        // Anonymous access is explicit. Supplied invalid/revoked credentials never fall back to it.
        if requireAPIKey || request.headers["authorization"] != nil {
            guard !token.isEmpty, equalSecret(request.headers["authorization"] ?? "", "Bearer " + token) else { return .json(["error":"Bearer token required"],status:401) }
        }
        guard let components = URLComponents(string:"http://localhost" + request.target), components.fragment == nil else { return .json(["error":"Invalid path"],status:400) }
        if components.path == "/mcp" {
            guard request.method == "POST" else { return .json(["error":"Use POST; this server does not open SSE streams"],status:405) }
            if let version = request.headers["mcp-protocol-version"], !versions.contains(version) { return .json(["error":"Unsupported protocol version"],status:400) }
            guard request.headers["content-type"]?.hasPrefix("application/json") == true else { return .json(["error":"JSON required"],status:415) }
            let accept = request.headers["accept"] ?? ""
            guard accept.contains("application/json"), accept.contains("text/event-stream") else { return .json(["error":"Accept application/json and text/event-stream"],status:406) }
            return rpc(request.body, scopes: scopes, query:query)
        }
        guard request.method == "GET" else { return .json(["error":"Read-only API"],status:405) }
        let routes = ["/api/v1/summary":"summary", "/api/v1/status":"status","/api/v1/metrics":"metrics","/api/v1/catalog":"catalog","/api/v1/series":"series","/api/v1/hrv":"hrv","/api/v1/activities":"activities","/api/v1/activity":"activity","/api/v1/activity-series":"activity_series"]
        guard let route = routes[components.path] else { return .json(["error":"Not found"],status:404) }
        guard permits(route, scopes: scopes) else { return .json(["error": "Scope denied"], status: 403) }
        var arguments: [String:Any] = [:]
        for item in components.queryItems ?? [] {
            guard arguments[item.name] == nil, let value = item.value else { return .json(["error":"Duplicate or empty parameter"],status:400) }
            if ["offset","limit","lapOffset","lapLimit"].contains(item.name) { guard let number = Int(value) else { return .json(["error":"Invalid pagination"],status:400) }; arguments[item.name] = number }
            else { arguments[item.name] = value }
        }
        do { return .json(try query(route,arguments)) } catch { return .json(["error":error.localizedDescription],status:400) }
    }
    private static func rpc(_ data: Data, scopes: Set<String>?, query: (String,[String:Any]) throws -> Any) -> DeveloperResponse {
        guard let message = try? JSONSerialization.jsonObject(with:data) as? [String:Any], message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
            return .json(["jsonrpc":"2.0","id":NSNull(),"error":["code":-32600,"message":"Invalid JSON-RPC request"]],status:400)
        }
        guard let id = message["id"] else { return DeveloperResponse(status:202,data:Data()) }
        guard id is String || (id is NSNumber && CFGetTypeID(id as CFTypeRef) != CFBooleanGetTypeID()) else { return .json(["error":"Invalid request ID"],status:400) }
        func result(_ value: Any) -> DeveloperResponse { .json(["jsonrpc":"2.0","id":id,"result":value]) }
        func rpcError(_ code: Int, _ text: String) -> DeveloperResponse { .json(["jsonrpc":"2.0","id":id,"error":["code":code,"message":text]]) }
        let params = message["params"] as? [String:Any] ?? [:]
        let allowedTools = tools.filter { permits(String(($0["name"] as? String ?? "").dropFirst("wristbeam_".count)), scopes: scopes) }
        switch method {
        case "initialize":
            let wanted = params["protocolVersion"] as? String ?? ""
            return result(["protocolVersion":versions.contains(wanted) ? wanted : versions[0],"capabilities":["tools":[:],"resources":[:]],"serverInfo":["name":"wristbeam","version":"1.0.0"],"instructions":"Read-only local cached health data. Missing/stale data is explicit; RR is not validated realtime HRV. No account, upload or device-control tools."])
        case "ping": return result([:])
        case "tools/list": return result(["tools":allowedTools])
        case "resources/list":
            return result(["resources": ["metrics", "status"].filter { permits($0, scopes: scopes) }.map {
                ["uri": "wristbeam://" + $0, "name": $0, "mimeType": "application/json"]
            }])
        case "resources/templates/list": return result(["resourceTemplates":[]])
        case "resources/read":
            guard let uri = params["uri"] as? String, ["wristbeam://metrics","wristbeam://status"].contains(uri), permits(uri.hasSuffix("metrics") ? "metrics" : "status", scopes: scopes) else { return rpcError(-32602,"Unknown resource") }
            do { let value = try query(uri.hasSuffix("metrics") ? "metrics" : "status",[:]); let bytes = try JSONSerialization.data(withJSONObject:value, options:[.sortedKeys]); return result(["contents":[["uri":uri,"mimeType":"application/json","text":String(decoding:bytes,as:UTF8.self)]]]) } catch { return rpcError(-32603,"Resource unavailable") }
        case "tools/call":
            guard let name = params["name"] as? String, allowedTools.contains(where:{$0["name"] as? String == name}), params["arguments"] == nil || params["arguments"] is [String:Any] else { return rpcError(-32602,"Unknown tool or invalid arguments") }
            do {
                let value = try query(String(name.dropFirst("wristbeam_".count)),params["arguments"] as? [String:Any] ?? [:])
                let bytes = try JSONSerialization.data(withJSONObject:value, options:[.sortedKeys])
                return result(["content":[["type":"text","text":String(decoding:bytes,as:UTF8.self)]],"structuredContent":value,"isError":false])
            } catch { return result(["content":[["type":"text","text":error.localizedDescription]],"isError":true]) }
        default: return rpcError(-32601,"Method not found")
        }
    }
}
