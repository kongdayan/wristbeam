import AppKit

@MainActor enum NavigationWindowPolicy {
    static func allowsNavigation(key: NSWindow?, main: NSWindow?, preferences: NSWindow?, modal: NSWindow?) -> Bool {
        guard modal == nil else { return false }
        // Once a sheet becomes key it has a sheetParent, not an attachedSheet.
        // Also inspect owner windows while focus is moving into or out of a sheet.
        return ![key, main, preferences].compactMap { $0 }.contains {
            $0.sheetParent != nil || $0.attachedSheet != nil
        }
    }
}
