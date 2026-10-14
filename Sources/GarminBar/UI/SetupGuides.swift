import AppKit
import SwiftUI

struct BluetoothPermissionGuide: View {
    @ObservedObject var bluetooth: WatchBluetooth
    private var title: String {
        switch bluetooth.access {
        case .notDetermined: return "连接前，先允许蓝牙"
        case .allowed: return "蓝牙访问已允许"
        case .denied: return "蓝牙访问已关闭"
        case .restricted: return "蓝牙访问受到系统限制"
        }
    }
    private var detail: String {
        switch bluetooth.access {
        case .notDetermined: return "蓝牙用于查找你选择的手表、接收实时指标和原始文件。点击下方连接按钮后，macOS 才会请求权限；请选择“允许”。"
        case .allowed: return bluetooth.sessionActivated ? "已允许本机访问蓝牙。只连接你选择的手表；可随时断开或在系统设置中关闭访问。" : "系统权限已允许，但尚未开始扫描或连接。准备好后，再点击下方按钮。"
        case .denied: return "请打开“系统设置 → 隐私与安全性 → 蓝牙”，允许 WristBeam 访问，再返回此页重试。你仍可登录设备账号查看云端记录。"
        case .restricted: return "此 Mac 的系统策略限制了蓝牙访问。请联系设备管理员；你仍可使用设备账号和原始 FIT 导入。"
        }
    }
    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(L10n.text(title), systemImage: bluetooth.access == .allowed ? "checkmark.shield" : "lock.shield")
                    .font(PulseTheme.font(size: 17, weight: .semibold)).foregroundStyle(PulseTheme.mint)
                Text(L10n.text(detail)).font(PulseTheme.font(size: 13)).foregroundStyle(PulseTheme.secondary).lineSpacing(4)
                if bluetooth.access == .denied {
                    Button(L10n.text("打开蓝牙隐私设置")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
                    }.buttonStyle(.bordered)
                }
                if bluetooth.managerState == 4 {
                    Text(L10n.text("Mac 蓝牙当前关闭。请在系统蓝牙设置中开启，再返回此页连接。"))
                        .font(PulseTheme.font(size: 13)).foregroundStyle(.orange)
                    Button(L10n.text("打开系统蓝牙设置")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                    }.buttonStyle(.bordered)
                }
            }
        }
    }
}

struct BackgroundConnectionGuide: View {
    @ObservedObject var bluetooth: WatchBluetooth
    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("连接设置")).font(PulseTheme.font(size: 16, weight: .semibold))
                Toggle(L10n.text("启动时连接已配对手表"), isOn: $bluetooth.connectsOnLaunch)
                    .disabled(bluetooth.access != .allowed || !bluetooth.hasSavedWatch)
                Text(L10n.text("默认关闭。完成授权和首次配对后，可主动开启；以后启动只恢复已保存的手表，不会弹出首次授权。"))
                    .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                Toggle(L10n.text("连接后断线自动重连"), isOn: $bluetooth.autoReconnect)
                Text(L10n.text("只恢复本次主动建立的连接。手动断开后停止重连；关闭主窗口仍在菜单栏运行，退出应用或 Mac 休眠会暂停同步。"))
                    .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary).lineSpacing(4)
            }.font(PulseTheme.font(size: 13)).toggleStyle(.switch)
        }
    }
}

struct FirstConnectionGuide: View {
    @ObservedObject var model: AppModel
    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("从设备连接开始")).font(PulseTheme.font(size: 18, weight: .semibold))
                Text(L10n.text("打开软件不会自动申请蓝牙或连接手表。按下面的顺序设置，完成后即可在菜单栏和浮窗查看数据。"))
                    .font(PulseTheme.font(size: 13)).foregroundStyle(PulseTheme.secondary).lineSpacing(4)
                HStack(spacing: 10) {
                    Button { model.openSettings(.watch) } label: { Label(L10n.text("授权与配对"), systemImage: "1.circle") }
                    Button { model.openSettings(.account) } label: { Label(L10n.text("设备账号"), systemImage: "2.circle") }
                    Button { model.openSettings(.sync) } label: { Label(L10n.text("选择同步方式"), systemImage: "3.circle") }
                }.buttonStyle(.bordered).font(PulseTheme.font(size: 13))
            }
        }
    }
}

struct SyncSetupGuide: View {
    @ObservedObject var model: AppModel
    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("选择如何同步")).font(PulseTheme.font(size: 17, weight: .semibold))
                Text(L10n.text("实时指标保存在本机。上传云端的是手表生成的原始运动与健康 FIT，目标为你在设备账号中选择的区域和账户。首次使用默认手动同步。"))
                    .font(PulseTheme.font(size: 13)).foregroundStyle(PulseTheme.secondary).lineSpacing(4)
                HStack {
                    Label(L10n.text(model.cloud.isAuthenticated ? "当前目标：\(model.cloud.region.title)" : "请先连接手表绑定的设备账号"), systemImage: "cloud")
                    Spacer()
                    Button(L10n.text("设备账号")) { model.openSettings(.account) }.buttonStyle(.bordered)
                }.font(PulseTheme.font(size: 13))
                Toggle(L10n.text("自动接收并上传手表文件"), isOn: $model.autoSync)
                Picker(L10n.text("检查新文件的间隔"), selection: $model.syncInterval) {
                    Text(L10n.text("5 分钟")).tag(5); Text(L10n.text("15 分钟")).tag(15); Text(L10n.text("30 分钟")).tag(30)
                }.frame(maxWidth: 300).disabled(!model.autoSync)
                Text(L10n.text("开启后，新收到的文件自动进入队列并上传，失败会保留重试。关闭后停止自动上传，仍可点击“立即同步”；不会删除本地文件。"))
                    .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary).lineSpacing(4)
                if !model.bluetooth.canSyncFiles {
                    Button(L10n.text("按引导连接手表")) { model.openSettings(.watch) }.buttonStyle(.bordered)
                }
            }.font(PulseTheme.font(size: 13)).toggleStyle(.switch)
        }
    }
}
