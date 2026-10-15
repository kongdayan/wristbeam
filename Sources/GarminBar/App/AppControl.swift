import Darwin
import Foundation

// Local data controls for running the companion quietly without opening its windows.
// This channel carries command names only, never Garmin credentials or BLE payloads.
enum PulseLocalControl {
    static let notification = Notification.Name("cn.wenyankong.garminpulse.command.v1")
    static var statusURL: URL { AppPaths.root.appendingPathComponent("runtime-state.json") }

    static func handleCommandLine() -> Bool {
        let arguments = CommandLine.arguments
        let controls = ["--status", "--sync", "--sync-recent", "--scan", "--connect", "--reconnect", "--retry-protocol", "--forget-watch", "--refresh-metrics", "--capture-watch-requests", "--stop-watch-capture"]
        guard controls.contains(where: arguments.contains) else { return false }
        guard let data = try? Data(contentsOf: statusURL),
              var state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            print("WristBeam has no runtime state yet. Start the app first.")
            return true
        }
        let active: Bool
        if let pid = state["pid"] as? Int, pid > 0, let reported = state["reportedAt"] as? Double {
            active = Darwin.kill(pid_t(pid), 0) == 0 && Date().timeIntervalSince1970 - reported < 20
        } else { active = false }
        if arguments.contains("--status") {
            state["processActive"] = active
            if let output = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                print(String(data: output, encoding: .utf8) ?? "{}")
            }
            return true
        }
        guard active else {
            print("WristBeam is not currently reporting an active session. Start the app first.")
            return true
        }
        let command: String
        var payload: [String: String] = [:]
        if let index = arguments.firstIndex(of: "--connect") {
            guard arguments.indices.contains(index + 1), let id = UUID(uuidString: arguments[index + 1]) else { print("Use --connect <discovered peripheral UUID>."); return true }
            command = "connect"; payload["watchID"] = id.uuidString
        } else if arguments.contains("--scan") { command = "scan" }
        else if arguments.contains("--reconnect") { command = "reconnect" }
        else if arguments.contains("--retry-protocol") { command = "retry-protocol" }
        else if arguments.contains("--forget-watch") { command = "forget-watch" }
        else if arguments.contains("--capture-watch-requests") { command = "capture-watch-requests" }
        else if arguments.contains("--stop-watch-capture") { command = "stop-watch-capture" }
        else if arguments.contains("--refresh-metrics") { command = "refresh-metrics" }
        else { command = arguments.contains("--sync-recent") ? "recent" : "sync" }
        let request = UUID().uuidString
        payload["command"] = command; payload["request"] = request
        DistributedNotificationCenter.default().postNotificationName(notification, object: nil,
            userInfo: payload, deliverImmediately: true)
        // This acknowledges submission only; --status shows actual download/upload results.
        print("Requested \(command) (\(request)). Use --status to check the result.")
        return true
    }
}
