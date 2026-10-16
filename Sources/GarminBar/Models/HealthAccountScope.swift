import Foundation

enum HealthAccountScope {
    static func resolve(region: GarminRegion, accountGUID: String, networkEnabled: Bool,
                        signedOut: Bool, preferences: AppPreferences) -> String {
        let key = "health.scope." + region.rawValue
        if networkEnabled && !accountGUID.isEmpty {
            let digest = GarminPrivateFile.digest(Data("\(region.rawValue):\(accountGUID)".utf8))
            if preferences.string(forKey: key) != digest { preferences.set(digest, forKey: key) }
            if region == .china {
                let legacy = GarminPrivateFile.digest(Data(accountGUID.utf8))
                if preferences.string(forKey: "health.legacy.china") != legacy { preferences.set(legacy, forKey: "health.legacy.china") }
            }
            return digest
        }
        guard !networkEnabled && !signedOut, let saved = preferences.string(forKey: key), valid(saved) else { return "" }
        return saved
    }
    static func valid(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
