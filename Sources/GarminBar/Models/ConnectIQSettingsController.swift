import Foundation
import Combine

/// One editor lifetime, bound to an account, registered device and installed app version.
/// Settings values are intentionally not persisted or included in diagnostics.
@MainActor final class ConnectIQSettingsController: ObservableObject {
    @Published private(set) var editorRequest: URLRequest?
    @Published private(set) var identity = UUID().uuidString
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    let appName: String

    private let cloud: GarminChinaCloud
    private let bluetooth: WatchBluetooth
    private let face: GFDIInstalledWatchFace
    private var context: ConnectIQSettingsContext?
    private var accountScope: String?
    private var generation = UUID()
    private var pending: Task<GFDIConnectIQSettingsSnapshot, Error>?
    private var subscriptions = Set<AnyCancellable>()

    init(cloud: GarminChinaCloud, bluetooth: WatchBluetooth, face: GFDIInstalledWatchFace) {
        self.cloud = cloud; self.bluetooth = bluetooth; self.face = face; appName = face.name
        cloud.objectWillChange.merge(with: bluetooth.objectWillChange).sink { [weak self] in
            Task { @MainActor [weak self] in self?.invalidateIfContextChanged() }
        }.store(in: &subscriptions)
    }

    private var scope: String {
        "\(cloud.region.rawValue):\(cloud.accountGUID):\(cloud.loginRevision):\(cloud.deviceId)"
    }
    private var available: Bool {
        cloud.networkEnabled && cloud.isAuthenticated && !cloud.accountGUID.isEmpty
            && cloud.deviceId == String(face.unitID)
            && bluetooth.isConnected && bluetooth.protocolReady
            && bluetooth.installedWatchFaces.contains(where: {
                $0.id == face.id && $0.unitID == face.unitID && $0.version == face.version
            })
    }
    private func check(_ token: UUID) throws {
        guard token == generation, accountScope == scope, available, !Task.isCancelled else {
            throw ConnectIQSettingsCloudError.contextChanged
        }
    }
    private func invalidateIfContextChanged() {
        guard accountScope != nil, (editorRequest != nil || busy), accountScope != scope || !available else { return }
        cancel()
        status = "设备或账户已变化，请重新打开表盘设置"
    }

    func load(dark: Bool) async {
        cancel()
        guard available else { status = ConnectIQSettingsCloudError.unavailable.localizedDescription; return }
        accountScope = scope
        let token = generation
        busy = true; status = "正在读取手表当前配置"
        defer { if generation == token { busy = false; pending = nil } }
        do {
            let target = try cloud.connectIQSettingsContext(for: face)
            let task = Task { try await bluetooth.readConnectIQSettings(appID: face.id, expectedUnitID: face.unitID) }
            pending = task
            let snapshot = try await task.value
            try check(token)
            guard snapshot.appID == face.id, snapshot.unitID == face.unitID else { throw ConnectIQSettingsCloudError.contextChanged }
            context = target
            editorRequest = try target.editorRequest(settingsJSON: snapshot.jsonData, dark: dark)
            status = "已读取手表当前配置"
        } catch {
            guard generation == token else { return }
            editorRequest = nil
            status = error is CancellationError ? "读取已取消" : error.localizedDescription
        }
    }

    func save(jsonData: Data) async throws {
        guard !busy, let context, editorRequest != nil, available, accountScope == scope else {
            throw ConnectIQSettingsCloudError.contextChanged
        }
        try ConnectIQSettingsContext.validateJSON(jsonData)
        let token = generation
        busy = true; status = "正在生成表盘配置"
        defer { if generation == token { busy = false; pending = nil } }
        let task = Task { [self] in
            let binary = try await cloud.serializeConnectIQSettings(jsonData, context: context, deviceID: String(face.unitID))
            try check(token)
            status = "正在保存到手表并回读确认"
            return try await bluetooth.saveConnectIQSettings(appID: face.id, settingsData: binary, expectedUnitID: face.unitID)
        }
        pending = task
        do {
            let result = try await task.value
            try check(token)
            guard result.appID == face.id, result.unitID == face.unitID, result.savedAndVerified else {
                throw ConnectIQSettingsCloudError.invalidResponse
            }
            status = "配置已保存，手表回读确认一致"
        } catch {
            guard token == generation else { throw ConnectIQSettingsCloudError.contextChanged }
            status = error is CancellationError ? "保存已取消，请重新读取确认手表状态" : error.localizedDescription
            throw error
        }
    }

    func cancel() {
        let wasBusy = busy
        generation = UUID(); identity = generation.uuidString
        pending?.cancel(); pending = nil
        if wasBusy { bluetooth.cancelConnectIQSettings(appID: face.id, expectedUnitID: face.unitID) }
        busy = false; editorRequest = nil; context = nil; accountScope = nil
    }
}
