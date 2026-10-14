import SwiftUI

struct PairingGuide: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var bluetooth: WatchBluetooth
    @State private var showHelp = false
    init(model: AppModel) { self.model = model; bluetooth = model.bluetooth }
    private var stage: Int {
        bluetooth.canSyncFiles && bluetooth.liveSampleCount > 0 ? 3 : bluetooth.isConnected ? 2 : bluetooth.sessionActivated ? 1 : 0
    }
    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.text("一步步连接手表")).font(PulseTheme.font(size: 17, weight: .semibold))
                HStack(spacing: 12) {
                    ForEach(Array(["授权与准备", "扫描选择", "确认与握手", "验证同步"].enumerated()), id: \.offset) { index, title in
                        VStack(spacing: 8) {
                            Text(L10n.text("\(index + 1)")).font(PulseTheme.font(size: 14, weight: .semibold)).frame(width: 32, height: 32)
                                .background(index <= stage ? PulseTheme.mint.opacity(0.18) : Color.primary.opacity(0.06)).clipShape(Circle())
                            Text(L10n.text(title)).font(PulseTheme.font(size: 12)).foregroundStyle(index == stage ? Color.primary : PulseTheme.secondary)
                        }.frame(maxWidth: .infinity)
                    }
                }
                if stage < 2 {
                    Text(L10n.text("本能 2 太阳能：长按 MENU → 手机 → 配对手机。让手表靠近 Mac；手机若占用连接，暂时关闭手机蓝牙。保持心率广播关闭。")).font(PulseTheme.font(size: 13)).lineSpacing(4)
                    HStack(spacing: 10) {
                        Button { bluetooth.beginPairing() } label: {
                            Label(L10n.text(bluetooth.access == .notDetermined ? "允许蓝牙并查找手表" : bluetooth.isScanning ? "重新扫描" : "手表已准备，查找设备"), systemImage: "antenna.radiowaves.left.and.right")
                        }.buttonStyle(.borderedProminent).tint(PulseTheme.mint).foregroundStyle(PulseTheme.onAccent)
                        if bluetooth.hasSavedWatch && !bluetooth.isScanning && !bluetooth.isConnecting {
                            Button(L10n.text("连接已配对手表")) { bluetooth.reconnectSaved() }.buttonStyle(.bordered)
                        }
                        if bluetooth.isScanning { Button(L10n.text("停止扫描")) { bluetooth.stopScan() }.buttonStyle(.bordered) }
                    }.disabled(model.preview || bluetooth.access == .denied || bluetooth.access == .restricted)
                    if bluetooth.isScanning { ProgressView(L10n.text("在下方选择出现的 Garmin 手表…")).controlSize(.small) }
                } else {
                    Text(L10n.text("如 Mac 或手表出现配对码，请核对并确认。蓝牙连接后，还需要完成佳明通道注册、设备协商和文件握手。")).font(PulseTheme.font(size: 13)).lineSpacing(4)
                }
                VStack(alignment: .leading, spacing: 12) {
                    check("蓝牙连接", done: bluetooth.isConnected, detail: bluetooth.status)
                    check("佳明协议协商", done: bluetooth.protocolReady, detail: bluetooth.transferStatus)
                    check("实时指标", done: bluetooth.liveSampleCount > 0, detail: bluetooth.lastLiveSampleAt.map { "已收到 \(bluetooth.liveSampleCount) 条读数 · 最近 \($0.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(L10n.locale)))" } ?? "等待佳明服务通知")
                    check("原始文件通道", done: bluetooth.canSyncFiles, detail: bluetooth.canSyncFiles ? "就绪，可检查运动与全天健康文件" : "尚未就绪，配对完成并不代表文件通道可用")
                }
                HStack {
                    if bluetooth.isConnected { Button(L10n.text("重新建立协议通道")) { bluetooth.retryProtocol() }.buttonStyle(.bordered).disabled(model.preview) }
                    Button(L10n.text("检查并同步文件")) { model.syncNow() }.buttonStyle(.bordered).disabled(!bluetooth.canSyncFiles || model.preview)
                    Spacer()
                    Button(L10n.text(showHelp ? "收起排查说明" : "连接不上 / 没有数据")) { showHelp.toggle() }.buttonStyle(.bordered)
                }
                if bluetooth.canSyncFiles {
                    HStack {
                        Text(L10n.text("通道就绪后，在设备账号登录同一账户，再选择手动或自动同步。"))
                            .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                        Spacer()
                        Button(L10n.text(model.cloud.isAuthenticated ? "设置同步方式" : "连接设备账号")) {
                            model.openSettings(model.cloud.isAuthenticated ? .sync : .account)
                        }.buttonStyle(.bordered)
                    }
                }
                if showHelp {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.text("1. 搜不到：确认 Mac 蓝牙权限已允许；手表停留在手机配对界面，再点“重新扫描”。"))
                        Text(L10n.text("2. 搜到但连不上：暂时关闭手机蓝牙。重配对后，手表的蓝牙标识可能改变，请选择新扫描到的手表。"))
                        Text(L10n.text("3. 已连上但没有读数：核对系统与手表的确认提示；查看上方协议状态，再点“重新建立协议通道”。"))
                        Text(L10n.text("4. 有读数但文件不同步：登录手表绑定的同一区域、同一佳明账户。运动结束后要选择“保存”；待上传目录为空时，可在同步记录中读取最近一次运动。"))
                        Text(L10n.text("5. 如果明确提示应用层加密或 CoreTransfer / MLR 未支持，本版本会显示该限制，已保存的文件继续保留。"))
                        Link(L10n.text("佳明本能 2 官方配对说明 ↗"), destination: URL(string: "https://www8.garmin.com/manuals/webhelp/GUID-31D23DBB-57C2-4DF7-A0C9-8D1A00AB4BE7/EN-US/GUID-4C14822E-F472-4C3A-B33C-BB50407ADDE5.html")!)
                    }.font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary).lineSpacing(4)
                }
            }
        }
    }
    private func check(_ title: String, done: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(done ? PulseTheme.mint : PulseTheme.secondary).font(PulseTheme.font(size: 18))
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(title)).font(PulseTheme.font(size: 13, weight: .semibold))
                Text(L10n.text(detail)).font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}
