import Foundation
import Security
import WidgetKit

@MainActor
final class PulseWidgetPublisher {
    private let queue = DispatchQueue(label: "cn.wenyankong.garminpulse.widget-snapshot", qos: .utility)
    private var lastWrite = Date.distantPast
    private var lastReload = Date.distantPast
    let directory: URL
    let sharedContainerEnabled: Bool
    var status: String { sharedContainerEnabled ? "共享容器已配置，小组件按系统调度刷新" : "扩展与快照已准备，等待签名安装" }

    init() {
        var container: URL?
        if let group = Bundle.main.object(forInfoDictionaryKey: PulseWidgetSnapshot.groupInfoKey) as? String,
           !group.contains("$("), let team = Self.signingTeam(), group.hasPrefix(team + ".") {
            container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        }
        sharedContainerEnabled = container != nil
        directory = container ?? AppPaths.directory("WidgetPreview")
    }
    private static func signingTeam() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let team = (info as NSDictionary?)?[kSecCodeInfoTeamIdentifier] as? String, !team.isEmpty else { return nil }
        return team
    }
    func publish(_ snapshot: PulseWidgetSnapshot, force: Bool = false) {
        guard force || Date().timeIntervalSince(lastWrite) >= 30 else { return }
        lastWrite = Date()
        let file = directory.appendingPathComponent(PulseWidgetSnapshot.fileName)
        let reload = sharedContainerEnabled && Date().timeIntervalSince(lastReload) >= 60
        if reload { lastReload = Date() }
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            do {
                try GarminPrivateFile.write(data, to: file)
                if reload { WidgetCenter.shared.reloadTimelines(ofKind: PulseWidgetSnapshot.widgetKind) }
            } catch { /* The main app's original records remain available. */ }
        }
    }
}
