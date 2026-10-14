import Foundation

enum BluetoothAccess: Int, CaseIterable {
    case notDetermined = 0, restricted, denied, allowed
}

enum ConnectionStartupPolicy {
    static func canConnect(automatically: Bool, savedWatch: Bool, access: BluetoothAccess, preview: Bool) -> Bool {
        automatically && savedWatch && access == .allowed && !preview
    }
}
