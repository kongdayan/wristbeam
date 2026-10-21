import Foundation

/// Shared interpretation of connection, storage and cloud state across app surfaces.
struct WorkflowPresentation {
    var connected: Bool
    var connecting: Bool
    var receiving: Bool
    var cloudEnabled: Bool
    var authenticated: Bool
    var uploading: Bool
    var pendingFiles: Int
    var hasLocalData: Bool
    var storageFailed: Bool
    var connectionTitle: String { receiving ? "正在接收手表数据" : connected ? "手表已连接" : connecting ? "正在连接手表" : "等待手表" }
    var accountTitle: String { !cloudEnabled ? "仅本地" : authenticated ? "云账号已连接" : "连接账户" }
    var accountSymbol: String { cloudEnabled ? "cloud" : "externaldrive" }
    var cloudActive: Bool { cloudEnabled && authenticated }
    var storageTitle: String { storageFailed ? "本地保存或读取异常" : hasLocalData ? "已保存到本机" : "等待接收数据" }
    var transferTitle: String {
        if !cloudEnabled { return storageTitle }
        if uploading { return "正在上传" }
        if pendingFiles > 0 { return L10n.format("{0} 份文件可补传", String(pendingFiles)) }
        return "没有待上传文件"
    }
    var summary: String { storageFailed ? storageTitle : receiving ? connectionTitle : cloudEnabled && uploading ? transferTitle : storageTitle }
}

/// In-memory list state survives view reconstruction without persisting searches to disk.
struct ActivityBrowsingState: Equatable {
    var search = ""
    var page = 0
    static let pageSize = 20
    func matching(_ activities: [GarminActivity]) -> [GarminActivity] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return activities.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.type.localizedCaseInsensitiveContains(query) }
    }
    func validPage(count: Int) -> Int { min(max(0, page), max(0, (count - 1) / Self.pageSize)) }
    func visible(_ activities: [GarminActivity]) -> [GarminActivity] {
        let rows = matching(activities)
        return Array(rows.dropFirst(validPage(count: rows.count) * Self.pageSize).prefix(Self.pageSize))
    }
}

enum ActivityListState: Equatable {
    case content, loading, localOnly, signedOut, empty, noMatches, failed
    static func resolve(total: Int, matches: Int, busy: Bool, failed: Bool, cloudEnabled: Bool, online: Bool) -> Self {
        if total > 0 { return matches == 0 ? .noMatches : .content }
        if busy { return .loading }
        if !cloudEnabled { return .localOnly }
        if !online { return .signedOut }
        if failed { return .failed }
        return .empty
    }
}

@MainActor final class ScrollPositions {
    var offsets: [String: CGFloat] = [:]
    func clearActivities() { offsets = offsets.filter { !$0.key.hasPrefix("activity.") && $0.key != "page.activities" } }
}

