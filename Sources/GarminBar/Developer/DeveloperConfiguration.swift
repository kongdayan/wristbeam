import Foundation

struct DeveloperConfiguration: Codable, Equatable {
    // Missing or null in older preferences must keep authentication enabled.
    var requireAPIKey: Bool? = true
    var requiresAPIKey: Bool { requireAPIKey != false }
    var primaryKeyEnabled: Bool? = true
    var enabled = false
    var host = "127.0.0.1"
    var port = 17890
    var https = false
    var publicHost = "localhost"
    var webhookEnabled = false
    var webhookURL = ""
    var webhookInterval = 60
    var webhookMetrics: Set<String> = []
    func clientExample(baseURL: String) -> String {
        var server = ["type": "http", "url": baseURL + "/mcp"] as [String: Any]
        if requiresAPIKey { server["headers"] = ["Authorization": "Bearer <WRISTBEAM_API_KEY>"] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": ["wristbeam": server]], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
