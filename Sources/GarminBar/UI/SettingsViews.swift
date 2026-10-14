import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsRootView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg").font(PulseTheme.font(size: 25)).foregroundStyle(PulseTheme.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("腕映")).font(PulseTheme.font(size: 18, weight: .semibold))
                        Text(L10n.text("腕上健康，桌面可见。")).font(PulseTheme.font(size: 9, weight: .medium)).foregroundStyle(PulseTheme.secondary)
                    }
                }.padding(.top, 20)
                VStack(spacing: 5) {
                    ForEach(AppPage.navigationPages) { page in
                        Button { model.detailMetric = nil; model.page = page } label: {
                            HStack(spacing: 12) { Image(systemName: page.symbol).frame(width: 18); Text(L10n.text(page.title)); Spacer() }
                                .font(PulseTheme.font(size: 12, weight: model.page.navigationPage == page ? .semibold : .regular))
                                .padding(.horizontal, 12).padding(.vertical, 12)
                                .foregroundStyle(model.page.navigationPage == page ? PulseTheme.mint : Color.primary.opacity(0.55))
                                .background(model.page.navigationPage == page ? PulseTheme.mint.opacity(0.08) : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                Button { model.onShowMenu?() } label: {
                    Label(L10n.text("打开菜单栏"), systemImage: "menubar.rectangle")
                }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 9) {
                    HStack { StatusDot(active: model.bluetooth.isConnected); Text(L10n.text(model.bluetooth.isConnected ? "手表已连接" : "等待手表")) }
                    HStack { StatusDot(active: model.cloud.isAuthenticated); Text(L10n.text(model.cloud.isAuthenticated ? "\(model.cloud.region.title)已连接" : "账户待登录")) }
                }.font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
                HStack {
                    Text(L10n.text("本能 2 太阳能 · macOS")).font(PulseTheme.font(size: 9)).foregroundStyle(Color.primary.opacity(0.25))
                    Spacer()
                    Button(L10n.text("退出")) { model.onQuit?() }.buttonStyle(.plain).font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
                }.padding(.bottom, 10)
            }.padding(.horizontal, 18).frame(width: 210)
                .background(Color.primary.opacity(0.025))
            Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    if let kind = model.detailMetric {
                        MetricDetailView(model: model, kind: kind)
                    } else {
                    pageHeader
                    switch model.page {
                    case .overview: OverviewPage(model: model)
                    case .watch, .account: DevicePage(model: model)
                    case .sync: SyncPage(model: model)
                    case .appearance: AppearancePage(model: model)
                    case .updates: SoftwareUpdatePage(model: model)
                    }
                    }
                }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.id(model.language).background(PulseTheme.background).foregroundStyle(.primary)
            .font(PulseTheme.font(size: 13)).controlSize(.large)
            .preferredColorScheme(model.preferredColorScheme)
            .environment(\.locale, L10n.locale)
            .sheet(isPresented: $model.showLogin) { LoginSheet(model: model) }
    }
    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.text(model.page.navigationPage.title)).font(PulseTheme.font(size: 27, weight: .semibold))
            Text(L10n.text(subtitle)).font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
        }
    }
    private var subtitle: String {
        switch model.page {
        case .overview: return "让手表的数据，在你的 Mac 上安静地流动。"
        case .watch, .account: return "目前兼容 Garmin（佳明）手表，后续可扩展其他品牌和设备。"
        case .sync: return "实时读数保存在本地，手表文件进入持久上传队列。"
        case .appearance: return "分别选择各窗口的指标，调整字体、布局、主题和刷新。"
        case .updates: return "通过 GitHub 检查版本，确认后下载并升级。"
        }
    }
}

struct OverviewPage: View {
    @ObservedObject var model: AppModel
    private var columns: [GridItem] {
        model.dashboardColumns == 0 ? [GridItem(.adaptive(minimum: model.cardSize.minimumWidth * model.fontScale), spacing: 12)] : Array(repeating: GridItem(.flexible(minimum: 120), spacing: 12), count: min(4, max(1, model.dashboardColumns)))
    }
    var body: some View {
        VStack(spacing: 20) {
            if model.preview { Label(L10n.text("演示数据 · 用于功能展示"), systemImage: "info.circle").font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.mint).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Picker(L10n.text("每行"), selection: $model.dashboardColumns) {
                    Text(L10n.text("自动适应")).tag(0)
                    ForEach(1...4, id: \.self) { Text(L10n.text("\($0) 张卡片")).tag($0) }
                }.frame(maxWidth: 240)
                Picker(L10n.text("卡片"), selection: $model.cardSize) {
                    ForEach(PulseCardSize.allCases) { Text(L10n.text($0.title)).tag($0) }
                }.frame(maxWidth: 230)
                Spacer()
            }
            Text(L10n.text("拖动卡片调整顺序；点击卡片进入全天图表和原始时间记录。")).font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary).frame(maxWidth: .infinity, alignment: .leading)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(model.dashboardVisibleMetrics) { kind in
                    MetricCard(model: model, kind: kind)
                        .onDrag { NSItemProvider(object: kind.rawValue as NSString) }
                        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                            guard let provider = providers.first else { return false }
                            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                                guard let raw = object as? String, let dragged = MetricKind(rawValue: raw) else { return }
                                Task { @MainActor in model.dashboardOrder = MetricLayout.moving(dragged, before: kind, in: model.dashboardVisibleMetrics) }
                            }
                            return true
                        }
                        .contextMenu {
                            Button(L10n.text("移到最前")) { model.dashboardOrder = [kind.rawValue] + model.dashboardVisibleMetrics.filter { $0 != kind }.map(\.rawValue) }
                            Button(L10n.text("从健康看板隐藏")) { model.dashboardMetrics.remove(kind) }
                        }
                }
            }
            if model.dashboardVisibleMetrics.isEmpty { Text(L10n.text(model.availableMetricKinds.isEmpty ? "正在等候手表或账户数据；连接后显示可用指标。" : "健康看板还没有选择指标。点击“选择指标”添加一组。")).foregroundStyle(PulseTheme.secondary).padding(30) }
            HStack {
                Text(L10n.text(model.healthStatus)).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                Spacer()
                Button(L10n.text("选择指标")) { model.selectionDestination = .dashboard; model.page = .appearance }.buttonStyle(.bordered)
                Button(L10n.text("刷新同步指标")) { model.refreshMetricsNow() }.buttonStyle(.bordered).disabled(model.preview || model.isRefreshingHealth)
            }
            PulseCard {
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(L10n.text(model.bluetooth.connectedName), systemImage: "applewatch").font(PulseTheme.font(size: 14, weight: .semibold))
                        Text(L10n.text(model.bluetooth.status)).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                    }
                    Spacer()
                    Button(L10n.text(model.bluetooth.isConnected ? "管理连接" : "连接手表")) { model.page = .watch }
                        .buttonStyle(.borderedProminent).tint(PulseTheme.mint).foregroundStyle(PulseTheme.onAccent)
                }
            }
            PulseCard {
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(L10n.text("\(model.cloud.region.title)云"), systemImage: "cloud").font(PulseTheme.font(size: 14, weight: .semibold))
                        Text(L10n.text(model.cloud.isAuthenticated ? model.cloud.accountName : "登录后自动上传运动与健康文件")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                    }
                    Spacer()
                    Button(L10n.text(model.cloud.isAuthenticated ? "查看同步" : "连接账户")) { model.page = model.cloud.isAuthenticated ? .sync : .account }
                        .buttonStyle(.bordered)
                }
            }
            Text(L10n.text("实时读数来自手表；全天趋势来自已同步记录，并加入 Mac 接收到的读数。缺测时段留空，统计值单独展示。"))
                .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DevicePage: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Picker(L10n.text("设备"), selection: Binding(get: { model.page == .account ? AppPage.account : .watch }, set: { model.page = $0 })) {
                Text(L10n.text("连接")).tag(AppPage.watch)
                Text(L10n.text("设备账号")).tag(AppPage.account)
            }.pickerStyle(.segmented).controlSize(.large)
            if model.page == .account {
                PulseCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L10n.text("当前设备平台：Garmin（佳明）"), systemImage: "applewatch").font(PulseTheme.font(size: 15, weight: .semibold))
                        Text(L10n.text("账号由设备平台决定。当前佳明设备使用佳明中国或国际账号。"))
                            .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                    }
                }
                AccountPage(model: model)
            } else { WatchPage(model: model) }
        }
    }
}

struct WatchPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var bluetooth: WatchBluetooth
    init(model: AppModel) { self.model = model; bluetooth = model.bluetooth }
    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            PairingGuide(model: model)
            PulseCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack { StatusDot(active: bluetooth.isConnected); Text(L10n.text(bluetooth.status)).font(PulseTheme.font(size: 13, weight: .medium)); Spacer() }
                    Text(L10n.text(bluetooth.bluetoothStatus)).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                    HStack(spacing: 10) {
                        Button { bluetooth.isScanning ? bluetooth.stopScan() : bluetooth.scan() } label: {
                            Label(L10n.text(bluetooth.isScanning ? "停止扫描" : "扫描附近手表"), systemImage: bluetooth.isScanning ? "stop.circle" : "antenna.radiowaves.left.and.right")
                        }.buttonStyle(.borderedProminent).tint(PulseTheme.mint).foregroundStyle(PulseTheme.onAccent).disabled(model.preview)
                        if bluetooth.isConnected || bluetooth.isConnecting { Button(L10n.text(bluetooth.isConnecting ? "取消连接" : "断开")) { bluetooth.disconnect() }.buttonStyle(.bordered) }
                        Button(L10n.text("忘记软件中的手表")) { bluetooth.forgetSavedWatch() }.buttonStyle(.bordered).disabled(model.preview)
                        Spacer()
                        Button(L10n.text("蓝牙设置")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!) }.buttonStyle(.plain).font(PulseTheme.font(size: 11))
                    }
                }
            }
            if bluetooth.nearby.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Text(L10n.text("准备你的手表")).font(PulseTheme.font(size: 13, weight: .semibold))
                    Text(L10n.text("从手表的“手机 → 配对手机”进入正常佳明连接。实时指标与文件都使用佳明服务；扫描结果会出现在这里。"))
                        .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary).lineSpacing(6)
                }.padding(5)
            } else {
                VStack(spacing: 9) {
                    ForEach(bluetooth.nearby) { watch in
                        PulseCard {
                            HStack(spacing: 14) {
                                Image(systemName: "applewatch").font(PulseTheme.font(size: 25)).foregroundStyle(PulseTheme.mint)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(L10n.text(watch.name)).font(PulseTheme.font(size: 13, weight: .semibold))
                                    Text(L10n.text("\(watch.serviceSummary) · \(watch.rssi) dBm · \(watch.shortID)")).font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
                                }
                                Spacer()
                                Button(L10n.text("连接")) { bluetooth.connect(watch.id) }.buttonStyle(.bordered).disabled(!watch.offersGarmin)
                            }
                        }
                    }
                }
            }
            Toggle(L10n.text("显示其他附近设备"), isOn: $bluetooth.showAllDevices).font(PulseTheme.font(size: 11)).toggleStyle(.checkbox)
            Text(L10n.text("按蓝牙标识去重，扫描时清理 20 秒未出现的设备，最多显示 40 台，佳明手表优先。相同名称可能属于不同设备。")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
            if bluetooth.isConnected {
                PulseCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.text("已发现的指标")).font(PulseTheme.font(size: 13, weight: .semibold))
                        ForEach(MetricKind.allCases.filter { $0.definition.service != nil || $0 == .watchBattery }) { kind in
                            HStack { MetricIcon(kind: kind).foregroundStyle(PulseTheme.color(kind)); Text(L10n.text(kind.title)); Spacer(); Text(L10n.text(bluetooth.availableMetrics.contains(kind) ? "已收到或已发现" : bluetooth.registeredMetrics.contains(kind) ? "已订阅，等待读数" : "未开放或待检测")).foregroundStyle(PulseTheme.secondary) }.font(PulseTheme.font(size: 12))
                        }
                        Divider().overlay(Color.primary.opacity(0.07))
                        Text(L10n.text(bluetooth.transferStatus)).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                        Button(L10n.text("导出连接诊断")) { NSWorkspace.shared.activateFileViewerSelecting([bluetooth.diagnosticsURL()]) }.buttonStyle(.plain).font(PulseTheme.font(size: 11))
                    }
                }
            }
        }
    }
}

struct AccountPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var cloud: GarminChinaCloud
    init(model: AppModel) { self.model = model; cloud = model.cloud }
    var body: some View {
        VStack(spacing: 19) {
            PulseCard {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L10n.text("账户区域"), selection: Binding(get: { cloud.region }, set: { model.showLogin = false; cloud.switchRegion($0) })) {
                        ForEach(GarminRegion.allCases) { Text(L10n.text($0.title)).tag($0) }
                    }.pickerStyle(.segmented).disabled(model.uploads.isSyncing)
                    Text(L10n.text("中国与国际账户分别保存登录授权、关联设备、图表缓存和上传任务。切换区域会保留另一边的会话与记录。")).font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                }
            }
            PulseCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Image(systemName: "cloud.fill").font(PulseTheme.font(size: 30)).foregroundStyle(PulseTheme.mint)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.text(cloud.isAuthenticated ? cloud.accountName : "Garmin Connect · \(cloud.region.title)")).font(PulseTheme.font(size: 16, weight: .semibold))
                            Text(L10n.text("connect.\(cloud.region.domain)")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                        }
                        Spacer(); StatusDot(active: cloud.isAuthenticated)
                    }
                    Text(L10n.text(cloud.status)).font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary).textSelection(.enabled)
                    if cloud.isAuthenticated {
                        HStack {
                            Button(L10n.text("刷新账户")) { Task { await cloud.refreshAccount() } }.buttonStyle(.bordered)
                            Spacer()
                            Button(L10n.text("退出账户")) { cloud.logout() }.buttonStyle(.plain).foregroundStyle(PulseTheme.secondary)
                        }
                    } else {
                        Button { cloud.prepareLogin(); model.showLogin = true } label: { Label(L10n.text("登录并连接\(cloud.region.title)"), systemImage: "person.crop.circle.badge.checkmark") }
                            .buttonStyle(.borderedProminent).tint(PulseTheme.mint).foregroundStyle(PulseTheme.onAccent).disabled(model.preview)
                    }
                }
            }
            PulseCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("你的登录过程")).font(PulseTheme.font(size: 13, weight: .semibold))
                    Text(L10n.text("在佳明官方页面填写账号、密码和验证码。认证成功后，软件保存授权令牌并自动续期，密码不保存在本地。"))
                        .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary).lineSpacing(4)
                    Link(L10n.text("打开\(cloud.region.title)网站 ↗"), destination: cloud.region.portal).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.mint)
                }
            }
            if cloud.isAuthenticated {
                PulseCard {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(L10n.text("同步设备")).font(PulseTheme.font(size: 13, weight: .semibold))
                        if !cloud.devices.isEmpty {
                            Picker(L10n.text("账户关联手表"), selection: $cloud.deviceId) {
                                ForEach(cloud.devices) { device in Text(L10n.text(device.name)).tag(device.id) }
                            }.onChange(of: cloud.deviceId) { value in model.watchUnitID = value }
                        }
                        TextField(L10n.text("设备编号（连接手表后自动识别）"), text: $model.watchUnitID).textFieldStyle(.roundedBorder)
                        Text(L10n.text("\(cloud.devices.count) 台设备已关联当前账户。原始文件的设备归属保持不变。"))
                            .font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
                    }
                }
            }
        }
    }
}

struct SyncPage: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            PulseCard {
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L10n.text("\(model.uploads.pendingCount) 个文件待同步")).font(PulseTheme.font(size: 18, weight: .semibold))
                        Text(L10n.text(model.uploads.status)).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                        Text(L10n.text("手表：\(model.bluetooth.transferStatus)")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    VStack(spacing: 8) {
                        Button(L10n.text("立即同步")) { model.syncNow() }.buttonStyle(.borderedProminent).tint(PulseTheme.mint).foregroundStyle(PulseTheme.onAccent).disabled(model.preview)
                        Button(L10n.text("同步最近一次运动")) { model.syncRecentActivity() }.buttonStyle(.bordered).font(PulseTheme.font(size: 10)).disabled(model.preview || !model.bluetooth.canSyncFiles)
                    }
                }
            }
            HStack(spacing: 10) {
                Button { model.importFIT() } label: { Label(L10n.text("导入原始 FIT"), systemImage: "square.and.arrow.down") }.buttonStyle(.bordered).disabled(model.preview)
                Button { model.watchFITFolder() } label: { Label(L10n.text("同步 FIT 文件夹"), systemImage: "folder.badge.plus") }.buttonStyle(.bordered).disabled(model.preview)
                Button { NSWorkspace.shared.open(AppPaths.root) } label: { Label(L10n.text("打开本地数据"), systemImage: "folder") }.buttonStyle(.bordered)
            }
            if let directory = model.uploads.watchedDirectory {
                HStack {
                    Text(L10n.text("自动同步：\(directory.lastPathComponent)")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                    Spacer()
                    Button(L10n.text("停止文件夹同步")) { model.uploads.stopWatching() }.buttonStyle(.plain).font(PulseTheme.font(size: 11))
                }
            }
            Text(L10n.text("已下载文件在本地保存后上传；失败会保留并重试。实时心率、压力和步数另存为本地历史，云端健康记录使用手表生成的原始文件。"))
                .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary).lineSpacing(4)
            if !model.uploads.visibleJobs.isEmpty {
                VStack(spacing: 8) {
                    ForEach(model.uploads.visibleJobs.prefix(12)) { job in
                        PulseCard {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(L10n.text(job.dataType.label)).font(PulseTheme.font(size: 12, weight: .medium)).help(L10n.text(job.originalName))
                                    Text(job.createdAt, style: .time).font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
                                    Spacer()
                                    Text(L10n.text(job.state.label)).font(PulseTheme.font(size: 10)).foregroundStyle(job.state.isComplete ? PulseTheme.mint : PulseTheme.secondary)
                                }
                                Text(L10n.text(job.detail)).font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
                                if job.dataType == .activity, job.state.isComplete,
                                   let id = job.cloudStatus?.activityID, !id.isEmpty, id.allSatisfy({ $0.isNumber }),
                                   let url = URL(string: "https://connect.\(model.cloud.region.domain)/modern/activity/\(id)") {
                                    Link(L10n.text("在\(model.cloud.region.title)查看运动 ↗"), destination: url).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.mint)
                                }
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("最近活动")).font(PulseTheme.font(size: 13, weight: .semibold))
                ForEach(model.events.prefix(25)) { event in
                    HStack(alignment: .top, spacing: 15) {
                        Text(event.date, style: .time).font(PulseTheme.font(size: 10, design: .monospaced)).foregroundStyle(PulseTheme.secondary).frame(width: 66, alignment: .leading)
                        Text(L10n.text(event.message)).font(PulseTheme.font(size: 11)).foregroundStyle(Color.primary.opacity(0.72)).textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }
            }.padding(.top, 9)
        }
    }
}

struct AppearancePage: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var expanded: Set<MetricCategory> = [.heart, .body, .movement, .solar]
    private var matching: [MetricKind] {
        MetricKind.allCases.filter { model.availableMetricKinds.contains($0) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.category.title.localizedCaseInsensitiveContains(search)) }
    }
    private var columnWidth: CGFloat { 82 * min(1.2, model.fontScale) }
    var body: some View {
        VStack(spacing: 19) {
            PulseCard {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.text("外观与阅读")).font(PulseTheme.font(size: 16, weight: .semibold))
                    Picker(L10n.text("语言 / Language"), selection: $model.language) { ForEach(PulseLanguage.allCases) { Text(L10n.text($0.title)).tag($0) } }.pickerStyle(.segmented)
                    Picker(L10n.text("颜色模式"), selection: $model.appearance) { ForEach(PulseAppearance.allCases) { Text(L10n.text($0.title)).tag($0) } }.pickerStyle(.segmented)
                    HStack {
                        Text(L10n.text("字体大小"))
                        Slider(value: $model.fontScale, in: 1...1.6, step: 0.05)
                        Text(L10n.text("\(Int((model.fontScale * 100).rounded()))%")).monospacedDigit().frame(width: 64)
                        Button(L10n.text("重置")) { model.fontScale = 1.15 }.buttonStyle(.bordered)
                    }
                    Text(L10n.text("字体大小应用于看板、图表、设置、菜单弹窗和浮窗。")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                }
            }
            PulseCard {
                VStack(alignment: .leading, spacing: 15) {
                    Text(L10n.text("窗口布局")).font(PulseTheme.font(size: 16, weight: .semibold))
                    HStack {
                        Picker(L10n.text("看板每行"), selection: $model.dashboardColumns) { Text(L10n.text("自动适应")).tag(0); ForEach(1...4, id: \.self) { Text(L10n.text("\($0) 张")).tag($0) } }
                        Picker(L10n.text("卡片尺寸"), selection: $model.cardSize) { ForEach(PulseCardSize.allCases) { Text(L10n.text($0.title)).tag($0) } }
                    }
                    Toggle(L10n.text("显示浮动窗口"), isOn: $model.floatingEnabled).toggleStyle(.switch)
                    Picker(L10n.text("浮窗尺寸"), selection: $model.floatingSize) { ForEach(PulsePanelSize.allCases) { Text(L10n.text("\($0.title) · \($0.columns) 列")).tag($0) } }.pickerStyle(.segmented)
                    Text(L10n.text("看板卡片可以拖动排序。菜单栏显示前 5 项，点击后查看其余；浮窗可拖动、滚动。")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                }
            }
            PulseCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L10n.text("指标与显示位置")).font(PulseTheme.font(size: 16, weight: .semibold))
                        Spacer()
                        Button(L10n.text(expanded.count == MetricCategory.allCases.count ? "收起所有组" : "展开所有组")) { expanded = expanded.count == MetricCategory.allCases.count ? [] : Set(MetricCategory.allCases) }.buttonStyle(.bordered)
                    }
                    Text(L10n.text("只列出手表已开放或账户已返回的指标。每行分别选择三个位置，选择会自动保存。")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                    TextField(L10n.text("搜索指标或分组"), text: $search).textFieldStyle(.roundedBorder)
                    HStack(spacing: 0) {
                        Text(L10n.text("指标")).font(PulseTheme.font(size: 12, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(MetricDestination.allCases) { destination in
                            VStack(spacing: 5) {
                                Text(L10n.text(destination.title)).font(PulseTheme.font(size: 11, weight: .semibold)).lineLimit(1)
                                Menu {
                                    Button(L10n.text("全选")) { model.select(matching, enabled: true, destination: destination) }
                                    Button(L10n.text("全取消")) { model.select(matching, enabled: false, destination: destination) }
                                } label: { Text(L10n.text("已选 \(matching.filter { model.selectedMetrics(for: destination).contains($0) }.count)")) }
                                .menuStyle(.borderlessButton).font(PulseTheme.font(size: 10)).fixedSize()
                            }.frame(width: columnWidth)
                        }
                    }.padding(.vertical, 6)
                    Divider()
                    if matching.isEmpty {
                        Text(L10n.text(search.isEmpty ? "连接手表或读取账户数据后，可用指标会出现在这里。" : "没有匹配的可用指标")).foregroundStyle(PulseTheme.secondary).padding(.vertical, 24)
                    }
                    ForEach(MetricCategory.allCases.filter { category in matching.contains { $0.category == category } }) { category in
                        let items = matching.filter { $0.category == category }
                        let isExpanded = expanded.contains(category) || !search.isEmpty
                        Button {
                            if expanded.contains(category) { expanded.remove(category) } else { expanded.insert(category) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: category.symbol).frame(width: 22).foregroundStyle(PulseTheme.mint)
                                Text(L10n.text(category.title)).font(PulseTheme.font(size: 14, weight: .semibold))
                                Spacer(minLength: 8)
                                Text(L10n.text("\(items.count) 项")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(PulseTheme.font(size: 13, weight: .semibold)).frame(width: 25)
                            }.padding(.vertical, 12).padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                                .background(PulseTheme.mint.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).accessibilityLabel(L10n.text(category.title)).accessibilityValue(isExpanded ? L10n.text("已展开") : L10n.text("已收起"))
                        if isExpanded {
                            HStack(spacing: 0) {
                                Text(L10n.text("整组选取")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                ForEach(MetricDestination.allCases) { destination in
                                    let selectedCount = items.filter { model.selectedMetrics(for: destination).contains($0) }.count
                                    Button { model.select(items, enabled: selectedCount != items.count, destination: destination) } label: {
                                        Image(systemName: selectedCount == 0 ? "square" : selectedCount == items.count ? "checkmark.square.fill" : "minus.square.fill")
                                            .font(PulseTheme.font(size: 18)).foregroundStyle(selectedCount == 0 ? PulseTheme.secondary : PulseTheme.mint)
                                            .frame(width: columnWidth, height: 40).contentShape(Rectangle())
                                    }.buttonStyle(.plain).help(L10n.format("{0}：整组全选 / 全取消", destination.title))
                                    .accessibilityLabel(L10n.format("{0} · {1} · 整组选取", category.title, destination.title))
                                    .contextMenu {
                                        Button(L10n.text("全选")) { model.select(items, enabled: true, destination: destination) }
                                        Button(L10n.text("全取消")) { model.select(items, enabled: false, destination: destination) }
                                    }
                                }
                            }
                            ForEach(items) { kind in
                                HStack(spacing: 0) {
                                    Button { model.select([kind], enabled: !model.dashboardMetrics.contains(kind), destination: .dashboard) } label: {
                                        HStack(spacing: 9) {
                                            MetricIcon(kind: kind).foregroundStyle(PulseTheme.color(kind)).frame(width: 22)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(L10n.text(kind.title)).font(PulseTheme.font(size: 12)).multilineTextAlignment(.leading)
                                                Text(L10n.text("\(model.display(kind)) \(kind.unit)")).font(PulseTheme.font(size: 11, design: .monospaced)).foregroundStyle(PulseTheme.secondary)
                                            }
                                            Spacer(minLength: 4)
                                        }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).contentShape(Rectangle())
                                    }.buttonStyle(.plain).help(L10n.text("点击名称切换健康看板；右侧分别选择显示位置"))
                                    ForEach(MetricDestination.allCases) { destination in
                                        Toggle(L10n.text(kind.title), isOn: Binding(get: { model.selectedMetrics(for: destination).contains(kind) }, set: { model.select([kind], enabled: $0, destination: destination) }))
                                            .labelsHidden().toggleStyle(.checkbox).frame(width: columnWidth, height: 44)
                                            .accessibilityLabel(L10n.text("\(kind.title) · \(destination.title)"))
                                    }
                                }
                                Divider().opacity(0.45)
                            }
                            if category == .solar {
                                Picker(L10n.text("日照估算阈值"), selection: $model.sunlightThreshold) { ForEach([1.0, 10, 20, 50, 100], id: \.self) { value in Text(L10n.text("太阳能强度 ≥ \(Int(value))%")).tag(value) } }.font(PulseTheme.font(size: 11))
                                Text(L10n.text("日照时长按有效分钟记录估算；光照记录不能区分室内灯光与户外阳光。")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                            }
                        }
                    }
                }
            }
            PulseCard {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.text("自动连接与同步")).font(PulseTheme.font(size: 14, weight: .semibold))
                    Toggle(L10n.text("断线后自动重连"), isOn: Binding(get: { model.bluetooth.autoReconnect }, set: { model.bluetooth.autoReconnect = $0 }))
                    Toggle(L10n.text("自动接收并上传手表文件"), isOn: $model.autoSync)
                    Picker(L10n.text("检查新文件的间隔"), selection: $model.syncInterval) { Text(L10n.text("5 分钟")).tag(5); Text(L10n.text("15 分钟")).tag(15); Text(L10n.text("30 分钟")).tag(30) }.frame(maxWidth: 300)
                    Toggle(L10n.text("自动刷新云端指标与全天曲线"), isOn: $model.autoRefreshMetrics)
                    Picker(L10n.text("指标刷新间隔"), selection: $model.metricRefreshInterval) { Text(L10n.text("1 分钟")).tag(1); Text(L10n.text("5 分钟")).tag(5); Text(L10n.text("15 分钟")).tag(15) }.frame(maxWidth: 300).disabled(!model.autoRefreshMetrics)
                    Button(L10n.text("立即刷新指标与曲线")) { model.refreshMetricsNow() }.buttonStyle(.bordered).disabled(!model.cloud.isAuthenticated || model.isRefreshingHealth)
                    Text(L10n.text("实时指标按佳明协议通知更新。云端按设置定时刷新，上传完成后立即刷新。连接恢复后继续同步。")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                }.font(PulseTheme.font(size: 12)).toggleStyle(.switch)
            }
        }
    }
}

struct LoginSheet: View {
    @ObservedObject var model: AppModel
    @State private var callbackURL = ""
    @State private var callbackError = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.text("连接\(model.cloud.region.title)账户"), systemImage: "lock.shield").font(PulseTheme.font(size: 14, weight: .semibold))
                Spacer()
                Button(L10n.text("关闭")) { model.showLogin = false }.buttonStyle(.bordered)
            }.padding(17).background(PulseTheme.background)
            HStack(spacing: 12) {
                Picker(L10n.text("登录方式"), selection: Binding(get: { model.cloud.loginMode }, set: { model.cloud.prepareLogin(mode: $0) })) {
                    ForEach(GarminLoginMode.allCases) { mode in Text(L10n.text(mode.label)).tag(mode) }
                }.labelsHidden().frame(width: 175)
                Button(L10n.text("在浏览器中登录 ↗")) {
                    model.cloud.prepareLogin(mode: .portal)
                    NSWorkspace.shared.open(model.cloud.makeLoginURL())
                }.buttonStyle(.plain)
                Button(L10n.text("复制登录配置链接")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.cloud.makeLoginURL().absoluteString, forType: .string)
                }.buttonStyle(.plain)
                Spacer()
            }.font(PulseTheme.font(size: 11)).padding(.horizontal, 17).padding(.bottom, 12).background(PulseTheme.background)
            GarminLoginWebView(cloud: model.cloud)
            DisclosureGroup(L10n.text("浏览器登录后的连接")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("如内置页面无法登录，可在浏览器完成登录，再将最终的官方回跳地址粘贴到这里。地址只在本机用于完成认证。"))
                        .font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
                    HStack {
                        SecureField(L10n.text("粘贴官方认证回跳地址"), text: $callbackURL).textFieldStyle(.roundedBorder)
                        Button(L10n.text("连接")) {
                            if let url = URL(string: callbackURL), model.cloud.handleNavigation(url) { callbackURL = ""; callbackError = "" }
                            else { callbackError = "此地址未包含当前登录方式的有效官方回跳凭据" }
                        }
                    }
                    if !callbackError.isEmpty { Text(L10n.text(callbackError)).font(PulseTheme.font(size: 10)).foregroundStyle(.orange) }
                }
            }.font(PulseTheme.font(size: 11)).padding(14).background(PulseTheme.background)
            HStack { Text(L10n.text(model.cloud.status)).font(PulseTheme.font(size: 11)); Spacer() }.padding(14).background(PulseTheme.background)
        }.frame(width: 760, height: 680).foregroundStyle(.primary).preferredColorScheme(model.preferredColorScheme)
    }
}
