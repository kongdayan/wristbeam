import Foundation

enum BluetoothAccess: Int, CaseIterable {
    case notDetermined = 0, restricted, denied, allowed
}

enum ConnectionStartupPolicy {
    enum WakeAction { case none, reconnect, restartTransport }
    static func canConnect(automatically: Bool, savedWatch: Bool, access: BluetoothAccess, preview: Bool) -> Bool {
        automatically && savedWatch && access == .allowed && !preview
    }
    static func canResume(activated: Bool, requested: Bool, automatic: Bool, connected: Bool, connecting: Bool) -> Bool {
        activated && requested && automatic && !connected && !connecting
    }
    static func afterWake(activated: Bool, requested: Bool, automatic: Bool, connected: Bool, connecting: Bool) -> WakeAction {
        guard activated && requested && automatic else { return .none }
        return connected || connecting ? .restartTransport : .reconnect
    }
}

enum WatchConnectionStage: String, CaseIterable {
    case permission, bluetoothOff, idle, discovering, discovered, connecting, negotiating, ready, receiving
    var title: String {
        switch self {
        case .permission: return "等待蓝牙授权"
        case .bluetoothOff: return "蓝牙已关闭"
        case .idle: return "等待连接手表"
        case .discovering: return "正在寻找手表"
        case .discovered: return "已发现手表"
        case .connecting: return "正在建立蓝牙连接"
        case .negotiating: return "正在准备数据通道"
        case .ready: return "数据通道已就绪"
        case .receiving: return "正在接收手表数据"
        }
    }
    static func resolve(access: BluetoothAccess, powered: Bool?, scanning: Bool, discovered: Bool,
                        connecting: Bool, connected: Bool, protocolReady: Bool, lastSample: Date?, now: Date) -> Self {
        if access != .allowed { return .permission }
        if powered == false { return .bluetoothOff }
        if connected {
            if protocolReady {
                return lastSample.map { now.timeIntervalSince($0) < 90 } == true ? .receiving : .ready
            }
            return .negotiating
        }
        if connecting { return .connecting }
        if scanning { return .discovering }
        return discovered ? .discovered : .idle
    }
}
