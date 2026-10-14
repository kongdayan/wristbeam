import SwiftUI

struct PreferencesPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var bluetooth: WatchBluetooth
    init(model: AppModel) { self.model = model; self.bluetooth = model.bluetooth }
    var body: some View {
        VStack(alignment:.leading,spacing:23) {
            switch model.page {
            case .appearance: appearance
            case .metricSelection: MetricSelectionPage(model:model)
            case .refresh: refresh
            case .developer: DeveloperSettingsPage(access:model.developer,kinds:MetricKind.allCases.filter { model.availableMetricKinds.contains($0) })
            case .updates: SoftwareUpdatePage(model:model)
            case .about: about
            default: general
            }
        }.frame(maxWidth:780,alignment:.leading).controlSize(.regular)
    }
    private var general: some View {
        VStack(spacing:23) {
            PreferenceBlock(title:"语言与地区") {
                PreferenceLine(title:"语言 / Language",note:"云服务区域随设备账号设置，语言选择不会切换账户。") {
                    Picker("",selection:$model.language) { ForEach(PulseLanguage.allCases) { Text(L10n.text($0.title)).tag($0) } }.labelsHidden()
                }
            }
            PreferenceBlock(title:"应用与连接") {
                PreferenceLine(title:"启动时连接已配对手表",note:"默认关闭。完成授权和首次配对后，可主动开启；以后启动只恢复已保存的手表，不会弹出首次授权。") {
                    Toggle("",isOn:$bluetooth.connectsOnLaunch).labelsHidden().toggleStyle(.switch).disabled(model.preview || model.bluetooth.access != .allowed || !model.bluetooth.hasSavedWatch)
                }
                PreferenceLine(title:"连接后断线自动重连",note:"只恢复本次主动建立的连接。") {
                    Toggle("",isOn:$bluetooth.autoReconnect).labelsHidden().toggleStyle(.switch)
                }
            }
            PreferenceBlock(title:"同步与本地数据") {
                PreferenceLine(title:"同步设置",note:"在同步记录中管理自动上传、同步间隔与原始文件；在设备中管理配对和云账号。") {
                    Button(L10n.text("同步记录")) { model.page = .sync }
                }
                PreferenceLine(title:"设备账号") { Button(L10n.text("设备账号")) { model.page = .account } }
            }
        }
    }
    private var appearance: some View {
        VStack(spacing:23) {
            PreferenceBlock(title:"外观与阅读") {
                PreferenceLine(title:"颜色模式") {
                    Picker("",selection:$model.appearance) { ForEach(PulseAppearance.allCases) { Text(L10n.text($0.title)).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                }
                PreferenceLine(title:"字体大小",note:"字体大小应用于看板、图表、设置、菜单弹窗和浮窗。") {
                    HStack { Slider(value:$model.fontScale,in:1...1.6,step:0.05); Text("\(Int((model.fontScale * 100).rounded()))%").monospacedDigit().frame(width:45) }
                }
            }
            PreferenceBlock(title:"浮窗") {
                PreferenceLine(title:"显示浮动窗口") { Toggle("",isOn:$model.floatingEnabled).labelsHidden().toggleStyle(.switch) }
                PreferenceLine(title:"显示方式",note:"紧凑查看当前值，详细展开历史曲线。") {
                    Picker("",selection:$model.floatingDetailed) { Text(L10n.text("紧凑")).tag(false); Text(L10n.text("详细")).tag(true) }.pickerStyle(.segmented).labelsHidden()
                }
                PreferenceLine(title:"浮窗尺寸") {
                    Picker("",selection:$model.floatingSize) { ForEach(PulsePanelSize.allCases) { Text(L10n.text($0.title)).tag($0) } }.pickerStyle(.segmented).labelsHidden()
                }
                PreferenceLine(title:"指标选择",note:"点击浮窗图标切换指标；横向滚动查看更多，不显示滚动条。") { Button(L10n.text("选择指标")) { model.page = .metricSelection } }
            }
            PreferenceBlock(title:"健康看板") {
                PreferenceLine(title:"看板每行") {
                    Picker("",selection:$model.dashboardColumns) { Text(L10n.text("自动适应")).tag(0); ForEach(1...4,id:\.self) { Text(L10n.text("\($0) 张")).tag($0) } }.labelsHidden()
                }
                PreferenceLine(title:"卡片尺寸") { Picker("",selection:$model.cardSize) { ForEach(PulseCardSize.allCases) { Text(L10n.text($0.title)).tag($0) } }.pickerStyle(.segmented).labelsHidden() }
            }
        }
    }
    private var refresh: some View {
        PreferenceBlock(title:"指标刷新") {
            PreferenceLine(title:"自动刷新云端指标与全天曲线",note:"实时指标按佳明协议通知更新。云端按设置定时刷新，上传完成后立即刷新。连接恢复后继续同步。") { Toggle("",isOn:$model.autoRefreshMetrics).labelsHidden().toggleStyle(.switch) }
            PreferenceLine(title:"指标刷新间隔") { Picker("",selection:$model.metricRefreshInterval) { Text(L10n.text("1 分钟")).tag(1); Text(L10n.text("5 分钟")).tag(5); Text(L10n.text("15 分钟")).tag(15) }.labelsHidden().disabled(!model.autoRefreshMetrics) }
            PreferenceLine(title:"刷新同步指标") { Button(L10n.text("立即刷新指标与曲线")) { model.refreshMetricsNow() }.disabled(model.preview || !model.cloud.isAuthenticated || model.isRefreshingHealth) }
        }
    }
    private var about: some View {
        VStack(spacing:23) {
            VStack(spacing:10) {
                Image(systemName:"waveform.path.ecg").font(.system(size:48)).foregroundStyle(PulseTheme.mint)
                Text(L10n.text("腕映")).font(PulseTheme.font(size:24,weight:.semibold))
                Text(L10n.text("腕上健康，桌面可见。")).foregroundStyle(PulseTheme.secondary)
                Text("v\(model.updater.currentVersion) · \(Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "—")").font(PulseTheme.font(size:12,design:.monospaced))
            }.frame(maxWidth:.infinity).padding(.vertical,18)
            PreferenceBlock(title:"开源项目") {
                PreferenceLine(title:"源代码",note:"独立开源的 macOS 健康伴侣，采用 MIT 许可证。") { Link("GitHub ↗",destination:URL(string:"https://github.com/kongdayan/wristbeam")!) }
                PreferenceLine(title:"提交反馈 ↗") { Link(L10n.text("提交反馈 ↗"),destination:URL(string:"https://github.com/kongdayan/wristbeam/issues")!) }
                PreferenceLine(title:"开源许可") { Link("MIT License ↗",destination:URL(string:"https://github.com/kongdayan/wristbeam/blob/main/LICENSE")!) }
                PreferenceLine(title:"软件更新") { Button(L10n.text("检查更新")) { model.page = .updates } }
            }
            Text(L10n.text("目前兼容 Garmin（佳明）设备，与设备厂商无隶属关系。")).font(PulseTheme.font(size:11)).foregroundStyle(PulseTheme.secondary)
        }
    }
}
