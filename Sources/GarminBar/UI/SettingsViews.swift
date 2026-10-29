import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsRootView: View {
    @ObservedObject var model: AppModel
    var onLayout: (([String: CGRect]) -> Void)? = nil
    @State private var columns: NavigationSplitViewVisibility = .all
    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg").font(PulseTheme.font(size: 25)).foregroundStyle(PulseTheme.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("腕映")).font(PulseTheme.font(size: 18, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7).accessibilityIdentifier("app-brand")
                            .background { if onLayout != nil { recordBounds("app-brand") } }
                        Text(L10n.text("腕上健康，桌面可见。")).font(PulseTheme.font(size: 9, weight: .medium)).foregroundStyle(PulseTheme.secondary)
                    }
                }.padding(.top, 12)
                sidebarNavigation
                VStack(spacing: 8) {
                    Button { model.onShowMenu?() } label: {
                        sidebarAction("打开菜单栏", symbol: "menubar.rectangle")
                    }
                }.buttonStyle(PulseRowButtonStyle())
                VStack(alignment: .leading, spacing: 9) {
                    HStack { StatusDot(active: model.bluetooth.isConnected); Text(L10n.text(model.workflow.connectionTitle)) }
                    HStack { StatusDot(active: model.workflow.cloudActive); Text(L10n.text(model.workflow.accountTitle)) }
                }.font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
                .padding(.bottom, 14)
            }.padding(.horizontal, 18).frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.025))
                .navigationSplitViewColumnWidth(min: 210 * sidebarScale, ideal: 230 * sidebarScale, max: 320)
        } detail: {
            ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: PulseTheme.sectionSpacing) {
                    if let kind = model.detailMetric {
                        if kind.isOvernightHRV { HRVDetailView(model: model, kind: kind) } else { MetricDetailView(model: model, kind: kind) }
                    } else {
                    if model.page != .overview && model.page != .activities { pageHeader }
                    switch model.page {
                    case .overview: OverviewPage(model: model)
                    case .activities: ActivitiesPage(model: model)
                    case .connectIQ: ConnectIQPage(model: model)
                    case .watch, .account: DevicePage(model: model)
                    case .sync: SyncPage(model: model)
                    case .settings, .appearance, .metricSelection, .refresh, .developer, .updates, .about:
                        PreferencesPage(model: model)
                    }
                    }
                }.id("settings-top").frame(maxWidth: contentMaximumWidth, alignment: .leading)
                    .padding(PulseLayout.pageInset)
                    .frame(maxWidth: .infinity, alignment: model.page.isSettings || model.page == .overview ? .center : .leading)
                    .background(ScrollPositionKeeper(positions: model.scrollPositions, key: model.mainScrollKey))
            }.id(model.mainScrollKey)
            .onChange(of: model.activityBrowsing) { _ in
                if model.page == .activities && model.selectedActivityID == nil { scroll.scrollTo("settings-top", anchor: .top) }
            }
            }
        }.navigationSplitViewStyle(.balanced).id(model.language).background(PulseTheme.background).foregroundStyle(.primary)
            .onChange(of: model.page) { page in if page.isSettings { columns = .all } }
            .font(PulseTheme.font(size: 13)).controlSize(.regular).buttonStyle(PulseButtonStyle()).tint(PulseTheme.mint)
            .preferredColorScheme(model.preferredColorScheme)
            .environment(\.locale, L10n.locale)
            .sheet(isPresented: $model.showLogin) { LoginSheet(model: model) }
            .coordinateSpace(name: "wristbeam-main-content")
    }
    private var contentMaximumWidth: CGFloat {
        if model.page.isSettings { return 780 }
        if model.page == .overview && model.detailMetric == nil { return PulseLayout.dashboardMaximumWidth }
        return .infinity
    }
    private var sidebarNavigation: some View {
        ScrollViewReader { sidebar in
            List(selection: Binding<AppPage?>(get: { selectedSidebarPage }, set: { if let page = $0 { model.openSettings(page) } })) {
                Section {
                    ForEach(AppPage.navigationPages) { page in sidebarPage(page) }
                }
                Section {
                    sidebarPage(.settings)
                }
                if model.page.isSettings {
                    Section(L10n.text("设置")) {
                        ForEach(AppPage.settingsPages.filter { $0 != .settings }) { page in sidebarPage(page) }
                    }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden).tint(Color.accentColor)
                .environment(\.defaultMinListRowHeight, 36)
                .background { if onLayout != nil { recordBounds("sidebar-list") } }
                .task(id: "\(selectedSidebarPage.id):\(model.fontScale)") {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    sidebar.scrollTo(selectedSidebarPage.id, anchor: .center)
                }
        }
    }
    private var selectedSidebarPage: AppPage { model.page == .account ? .watch : model.page }
    private func sidebarPage(_ page: AppPage) -> some View {
        let title = page == .settings ? L10n.text("常规设置") : page.title
        return HStack(spacing: 9) {
            Image(systemName: page.symbol).frame(width: 18).accessibilityHidden(true)
            Text(title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.font(PulseTheme.font(size: 12)).padding(.vertical, 4).tag(page).id(page.id)
            .help(title).accessibilityElement(children: .combine)
            .background { if onLayout != nil && selectedSidebarPage == page { recordBounds("sidebar-selection") } }
    }
    private var sidebarScale: CGFloat { CGFloat(max(1, min(1.25, model.fontScale / 1.15))) }
    private func sidebarAction(_ title: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18)
            Text(L10n.text(title)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }
    private var pageHeader: some View {
        Text(L10n.text(model.page == .settings ? "常规设置" : model.page.title))
            .font(PulseTheme.font(size: 27, weight: .semibold))
            .accessibilityIdentifier("page-title")
            .background { if onLayout != nil { recordBounds("page-title") } }
    }
    private func recordBounds(_ identifier: String) -> some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .named("wristbeam-main-content"))
            Color.clear.onAppear { onLayout?([identifier: frame]) }
                .onChange(of: frame) { onLayout?([identifier: $0]) }
        }
    }
}

struct OverviewPage: View {
    @ObservedObject var model: AppModel
    @State private var showStyle = false
    @State private var shareRequest: DashboardShareRequest?
    @State private var contentWidth: CGFloat = 0
    private func columns(for metrics: [MetricKind]) -> [GridItem] {
        let minimum = model.cardSize.minimumWidth * max(1, model.fontScale / 1.15)
        let count = MetricLayout.columnCount(width: contentWidth, minimum: minimum, preferred: model.dashboardColumns)
        return Array(repeating: GridItem(.flexible(), spacing: PulseLayout.groupGap, alignment: .top), count: max(1, min(count, metrics.count)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: PulseLayout.sectionGap) {
            VStack(alignment: .leading, spacing: PulseLayout.groupGap) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) { title; Spacer(minLength: 12); DashboardConnectionStatus(model: model) }
                VStack(alignment: .leading, spacing: 12) { title; DashboardConnectionStatus(model: model) }
            }
            if !model.storageIssues.isEmpty {
                Button { model.openSettings(.sync) } label: {
                    Label(L10n.text("本地保存或读取异常"), systemImage: "exclamationmark.triangle")
                }.buttonStyle(PulseButtonStyle()).tint(.orange)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { refreshStatus; Spacer(minLength: 8); dashboardActions }
                VStack(alignment: .leading, spacing: 12) { refreshStatus; dashboardActions }
            }
            }
            if model.preview && model.previewSetup {
                Button(L10n.text("加载演示数据")) { model.previewSetup = false; model.enablePreview() }.buttonStyle(PulseButtonStyle())
            }
            if (!model.preview || model.previewSetup) && !model.bluetooth.sessionActivated && !model.bluetooth.isConnected && model.availableMetricKinds.isEmpty && !model.cloud.isAuthenticated { FirstConnectionGuide(model: model) }
            if model.dashboardGrouped {
                ForEach(MetricLayout.dashboardSections(model.dashboardVisibleMetrics)) { section in
                    VStack(alignment: .leading, spacing: PulseLayout.groupGap) {
                        HStack(spacing: PulseLayout.itemGap) {
                            Text(section.title).font(PulseTheme.font(size: 16, weight: .semibold))
                            Text("\(section.metrics.count)").font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                            Spacer(minLength: 0)
                        }.accessibilityAddTraits(.isHeader)
                        metricGrid(section.metrics, emphasized: section.id == "focus")
                    }
                }
            } else {
                metricGrid(model.dashboardVisibleMetrics)
            }
            if model.dashboardVisibleMetrics.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2").font(.largeTitle)
                    Text(L10n.text(model.availableMetricKinds.isEmpty ? "正在等候手表或账户数据；连接后显示可用指标。" : "在“显示样式”中选择要展示的指标。"))
                    Button(L10n.text("显示样式")) { showStyle = true }
                }.foregroundStyle(PulseTheme.secondary).frame(maxWidth: .infinity).padding(30)
            }
        }.background {
            GeometryReader { proxy in
                Color.clear.onAppear { contentWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { contentWidth = $0 }
            }
        }.sheet(item: $shareRequest) { request in DashboardShareSheet(model: model, request: request) }
    }
    private func metricGrid(_ metrics: [MetricKind], emphasized: Bool = false) -> some View {
        let gridColumns = columns(for: metrics)
        return LazyVGrid(columns: gridColumns, alignment: .leading, spacing: PulseLayout.groupGap) {
            ForEach(metrics) { kind in
                MetricCard(model: model, kind: kind, emphasized: emphasized)
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
                        Button(L10n.text("分享这项数值")) { shareRequest = DashboardShareRequest(kinds: [kind], valueOnly: true) }
                        Button(L10n.text("分享这张卡片")) { shareRequest = DashboardShareRequest(kinds: [kind]) }
                        Button(L10n.text("移到最前")) { model.dashboardOrder = [kind.rawValue] + model.dashboardVisibleMetrics.filter { $0 != kind }.map(\.rawValue) }
                        Button(L10n.text("从健康看板隐藏")) { model.dashboardMetrics.remove(kind) }
                    }
            }
        }.frame(maxWidth: CGFloat(gridColumns.count) * PulseLayout.metricMaximumWidth * max(1, model.fontScale / 1.15)
            + CGFloat(gridColumns.count - 1) * PulseLayout.groupGap, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var refreshStatus: some View {
        HStack(spacing: 8) {
            if model.isRefreshingHealth { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("正在刷新健康数据…")) }
            Text(L10n.text(model.preview ? "演示数据 · 用于功能展示" : model.healthStatus))
                .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var dashboardActions: some View {
        PulseFlowLayout(spacing: 8) {
            Button { model.refreshMetricsNow() } label: { Label(L10n.text("刷新"), systemImage: "arrow.clockwise") }
                .help(L10n.text(model.cloud.isAuthenticated ? "刷新同步指标" : "连接设备账号后可刷新云端数据"))
                .disabled(model.preview || !model.cloud.isAuthenticated || model.isRefreshingHealth)
            Button { shareRequest = DashboardShareRequest(kinds: model.dashboardVisibleMetrics) } label: { Label(L10n.text("分享"), systemImage: "square.and.arrow.up") }
                .disabled(model.dashboardVisibleMetrics.isEmpty)
            Button { showStyle.toggle() } label: { Label(L10n.text("显示样式"), systemImage: "slider.horizontal.3") }
                .popover(isPresented: $showStyle, arrowEdge: .bottom) { DashboardStylePanel(model: model) }
        }.buttonStyle(PulseButtonStyle()).controlSize(.regular)
    }
    private var title: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("健康看板")).font(PulseTheme.font(size: 27, weight: .semibold))
            Text(Date(), format: .dateTime.month().day().weekday())
                .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
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
            }.labelsHidden().pickerStyle(.segmented).controlSize(.large)
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
    @State private var showPairing = false
    @State private var showDiagnostics = false
    @State private var showForgetConfirmation = false
    init(model: AppModel) { self.model = model; bluetooth = model.bluetooth }
    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            if bluetooth.hasSavedWatch || bluetooth.isConnected || bluetooth.isConnecting {
                connectionSummary
            }
            if bluetooth.access != .allowed || !bluetooth.sessionActivated || bluetooth.managerState == 4 {
                BluetoothPermissionGuide(bluetooth: bluetooth)
            }
            if (bluetooth.hasSavedWatch || bluetooth.canSyncFiles) && !bluetooth.isScanning && !bluetooth.isConnecting {
                PulseDisclosure(L10n.text("配对与连接帮助"), isExpanded: $showPairing) {
                    PairingGuide(model: model).padding(.top, 10)
                }.font(PulseTheme.font(size: 13)).padding(.horizontal, 5)
            } else { PairingGuide(model: model) }
            if !bluetooth.nearby.isEmpty && (!bluetooth.isConnected || bluetooth.isScanning) {
                nearbyDevices
            }
            PulseDisclosure(L10n.text("连接设置")) {
                BackgroundConnectionGuide(bluetooth: bluetooth)
            }.font(PulseTheme.font(size: 13))
            WatchWeatherCard(weather: model.weather, preview: model.preview)
            PulseDisclosure(L10n.text("诊断与高级选项"), isExpanded: $showDiagnostics) {
                diagnostics
            }.font(PulseTheme.font(size: 13))
        }.confirmationDialog(L10n.text("忘记这只手表？"), isPresented: $showForgetConfirmation, titleVisibility: .visible) {
            Button(L10n.text("忘记软件中的手表"), role: .destructive) { bluetooth.forgetSavedWatch() }
            Button(L10n.text("取消"), role: .cancel) { }
        } message: {
            Text(L10n.text("下次需要重新连接。已保存的健康数据和账号会保留。"))
        }
    }
    private var connectionSummary: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack { StatusDot(active: bluetooth.isConnected); Text(L10n.text(bluetooth.connectionStage(now: model.now).title)).font(PulseTheme.font(size: 13, weight: .medium)); Spacer(); WatchBatteryBadge(model: model) }
                if bluetooth.isConnected {
                    Text(L10n.text(bluetooth.connectedName)).font(PulseTheme.font(size: 20, weight: .semibold))
                }
                if bluetooth.canSyncFiles {
                    ViewThatFits(in: .horizontal) {
                        HStack { receiveButton; syncOptionsButton }
                        VStack(alignment: .leading, spacing: 10) { receiveButton; syncOptionsButton }
                    }
                } else if bluetooth.isConnected && !bluetooth.protocolReady {
                    Button(L10n.text("重新准备数据通道")) { bluetooth.retryProtocol() }.buttonStyle(PulseButtonStyle())
                } else if !bluetooth.isConnected && !bluetooth.isConnecting && bluetooth.hasSavedWatch {
                    Button(L10n.text("重新连接手表")) { bluetooth.reconnectSaved() }
                        .buttonStyle(PulseButtonStyle(prominent: true)).tint(PulseTheme.mint).foregroundStyle(PulseTheme.onAccent).disabled(model.preview)
                }
                Text(L10n.text(bluetooth.bluetoothStatus)).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                HStack(spacing: 10) {
                    if bluetooth.isConnected || bluetooth.isConnecting { Button(L10n.text(bluetooth.isConnecting ? "取消连接" : "断开")) { bluetooth.disconnect() }.buttonStyle(PulseButtonStyle()) }
                    Menu {
                        Button(L10n.text("忘记软件中的手表"), role: .destructive) { showForgetConfirmation = true }
                            .disabled(model.preview || !bluetooth.hasSavedWatch)
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L10n.text("设备选项"))
                    Spacer()
                    Button(L10n.text("蓝牙设置")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!) }.buttonStyle(PulseButtonStyle(compact: true)).font(PulseTheme.font(size: 11))
                }
            }
        }
    }
    private var nearbyDevices: some View {
        VStack(spacing: 9) {
            ForEach(bluetooth.nearby) { watch in
                PulseCard {
                    HStack(spacing: 14) {
                        Image(systemName: "applewatch").font(PulseTheme.font(size: 25)).foregroundStyle(PulseTheme.mint)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.text(watch.name)).font(PulseTheme.font(size: 13, weight: .semibold))
                            Text(watch.shortID).font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
                        }
                        Spacer()
                        Button(L10n.text("连接")) { bluetooth.connect(watch.id) }.buttonStyle(PulseButtonStyle()).disabled(model.preview || !watch.offersGarmin || bluetooth.isConnecting)
                    }
                }
            }
        }
    }
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(L10n.text("显示其他附近设备"), isOn: $bluetooth.showAllDevices).font(PulseTheme.font(size: 11)).toggleStyle(.checkbox)
            WatchRequestCaptureCard(capture: bluetooth.requestCapture, connected: bluetooth.isConnected, preview: model.preview)
            if bluetooth.isConnected {
                PulseCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.text("已发现的指标")).font(PulseTheme.font(size: 13, weight: .semibold))
                        ForEach(MetricKind.allCases.filter { !$0.isDeviceStatus && $0.definition.service != nil }) { kind in
                            HStack { MetricIcon(kind: kind).foregroundStyle(PulseTheme.color(kind)); Text(L10n.text(kind.title)); Spacer(); Text(L10n.text(bluetooth.availableMetrics.contains(kind) ? "已收到或已发现" : bluetooth.registeredMetrics.contains(kind) ? "已订阅，等待读数" : "未开放或待检测")).foregroundStyle(PulseTheme.secondary) }.font(PulseTheme.font(size: 12))
                        }
                        Divider().overlay(Color.primary.opacity(0.07))
                        Text(L10n.text(bluetooth.transferStatus)).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                        Button(L10n.text("导出连接诊断")) { NSWorkspace.shared.activateFileViewerSelecting([bluetooth.diagnosticsURL()]) }.buttonStyle(PulseButtonStyle(compact: true)).font(PulseTheme.font(size: 11))
                    }
                }
            }
        }
    }
    private var receiveButton: some View {
        Button(L10n.text("接收手表数据")) { model.syncNow() }
            .buttonStyle(PulseButtonStyle(prominent: true)).tint(PulseTheme.mint).foregroundStyle(PulseTheme.onAccent).disabled(model.preview)
    }
    private var syncOptionsButton: some View {
        Button(L10n.text("选择同步方式")) { model.openSettings(.sync) }.buttonStyle(PulseButtonStyle())
    }
}

struct AccountPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var cloud: GarminChinaCloud
    @State private var refreshingAccount = false
    init(model: AppModel) { self.model = model; cloud = model.cloud }
    var body: some View {
        VStack(spacing: 19) {
            PulseCard {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L10n.text("同步到佳明云"), isOn: $model.cloudSyncEnabled).toggleStyle(.switch)
                    Text(L10n.text(model.cloudSyncEnabled ? "登录后可读取云端记录。暂存文件由你选择上传。" : "仅本地：无需云账号，直接接收手表数据。"))
                        .font(PulseTheme.font(size: 13)).foregroundStyle(PulseTheme.secondary)
                    if !model.cloudSyncEnabled {
                        Button(L10n.text("查看本地暂存与导出")) { model.openSettings(.sync) }.buttonStyle(PulseButtonStyle())
                    }
                }
            }
            if model.cloudSyncEnabled {
            PulseCard {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L10n.text("账户区域"), selection: Binding(get: { cloud.region }, set: { model.showLogin = false; cloud.switchRegion($0) })) {
                        ForEach(GarminRegion.allCases) { Text(L10n.text($0.title)).tag($0) }
                    }.pickerStyle(.segmented).disabled(model.uploads.isSyncing)
                    Text(L10n.text("先选择手表绑定的账户区域：中国账户使用佳明中国，其他账户使用国际区。请选择同一个佳明账号，避免文件归属不匹配。"))
                        .font(PulseTheme.font(size: 13)).foregroundStyle(PulseTheme.secondary).lineSpacing(4)
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
                        PulseFlowLayout {
                            Button(L10n.text(refreshingAccount ? "正在刷新账户…" : "刷新账户")) {
                                guard !refreshingAccount else { return }
                                refreshingAccount = true
                                Task { defer { refreshingAccount = false }; await cloud.refreshAccount() }
                            }.buttonStyle(PulseButtonStyle()).disabled(refreshingAccount || model.preview || !model.cloudSyncEnabled)
                            if refreshingAccount { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("正在刷新账户…")) }
                            Button(L10n.text("退出账户")) { cloud.logout() }.buttonStyle(PulseButtonStyle(compact: true)).foregroundStyle(PulseTheme.secondary)
                        }
                    } else {
                        Text(L10n.text("点击登录后，在佳明官方页面输入账号、密码和验证码。软件仅保存可续期的授权令牌，不保存密码；上传方式由你在同步记录中选择。"))
                            .font(PulseTheme.font(size: 13)).foregroundStyle(PulseTheme.secondary).lineSpacing(4)
                        Button { cloud.prepareLogin(); model.showLogin = true } label: { Label(L10n.text("登录并连接\(cloud.region.title)"), systemImage: "person.crop.circle.badge.checkmark") }
                            .buttonStyle(PulseButtonStyle(prominent: true)).tint(PulseTheme.mint).foregroundStyle(PulseTheme.onAccent).disabled(model.preview)
                    }
                }
            }
            PulseCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("登录完成之后")).font(PulseTheme.font(size: 13, weight: .semibold))
                    Text(L10n.text("先确认下方关联设备与你的手表一致，再到同步记录选择手动或自动上传。退出账户会停止该账户的云访问，本地原始文件继续保留。"))
                        .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary).lineSpacing(4)
                    Button(L10n.text("前往同步设置")) { model.openSettings(.sync) }.buttonStyle(PulseButtonStyle())
                    Link(L10n.text("打开\(cloud.region.title)网站 ↗"), destination: cloud.region.portal).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.mint)
                }
            }
            if cloud.isAuthenticated {
                PulseCard {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(L10n.text("同步设备")).font(PulseTheme.font(size: 13, weight: .semibold))
                        if !cloud.devices.isEmpty {
                            PulseMenuPicker("账户关联手表", selection: $cloud.deviceId, choices: cloud.devices.map { .init(L10n.text($0.name), $0.id) })
                                .onChange(of: cloud.deviceId) { value in model.watchUnitID = value }
                        }
                        PulseDisclosure(L10n.text("手动指定设备")) {
                            TextField(L10n.text("设备编号（连接手表后自动识别）"), text: $model.watchUnitID).textFieldStyle(.roundedBorder)
                        }
                        Text(L10n.text("\(cloud.devices.count) 台设备已关联当前账户。"))
                            .font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
                    }
                }
            }
            }
        }
    }
}

struct MetricSelectionPage: View {
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
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L10n.text("指标与显示位置")).font(PulseTheme.font(size: 16, weight: .semibold))
                        Spacer()
                        Button(L10n.text(expanded.count == MetricCategory.allCases.count ? "收起所有组" : "展开所有组")) { expanded = expanded.count == MetricCategory.allCases.count ? [] : Set(MetricCategory.allCases) }.buttonStyle(PulseButtonStyle())
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
                        }.buttonStyle(PulseRowButtonStyle()).accessibilityLabel(L10n.text(category.title)).accessibilityValue(isExpanded ? L10n.text("已展开") : L10n.text("已收起"))
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
                                    .accessibilityValue(L10n.text(selectedCount == 0 ? "未选择" : selectedCount == items.count ? "已选择" : "部分选择"))
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
                                            .labelsHidden().toggleStyle(PulseSelectionToggleStyle()).frame(width: columnWidth)
                                            .accessibilityLabel(L10n.text("\(kind.title) · \(destination.title)"))
                                    }
                                }
                                Divider().opacity(0.45)
                            }
                            if category == .solar {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(L10n.text("日照估算阈值")).font(PulseTheme.font(size: 11))
                                    PulseMenuPicker("日照估算阈值", selection: $model.sunlightThreshold,
                                        choices: [1.0, 10, 20, 50, 100].map { .init(L10n.text("太阳能强度 ≥ \(Int($0))%"), $0) })
                                }
                                Text(L10n.text("日照时长按有效分钟记录估算；光照记录不能区分室内灯光与户外阳光。")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                            }
                        }
                    }
                }
            }

        }
    }
}

struct LoginSheet: View {
    @ObservedObject var model: AppModel
    @State private var callbackURL = ""
    @State private var callbackError = ""
    @State private var loginLoading = false
    @State private var copyStatus = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.text("连接\(model.cloud.region.title)账户"), systemImage: "lock.shield").font(PulseTheme.font(size: 14, weight: .semibold))
                Spacer()
                if loginLoading { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("正在打开官方登录页…")) }
                Button(L10n.text("关闭")) { model.showLogin = false }.buttonStyle(PulseButtonStyle()).keyboardShortcut(.cancelAction)
            }.padding(17).background(PulseTheme.background)
            PulseFlowLayout(spacing: 12) {
                PulseMenuPicker("登录方式", selection: Binding(get: { model.cloud.loginMode }, set: { model.cloud.prepareLogin(mode: $0) }),
                    choices: GarminLoginMode.allCases.map { .init(L10n.text($0.label), $0) }).fixedSize()
                Button(L10n.text("在浏览器中登录 ↗")) {
                    model.cloud.prepareLogin(mode: .portal)
                    NSWorkspace.shared.open(model.cloud.makeLoginURL())
                }.buttonStyle(PulseButtonStyle())
                Button(L10n.text("重新加载")) { model.cloud.prepareLogin() }.buttonStyle(PulseButtonStyle())
                Button(L10n.text("复制登录配置链接")) {
                    NSPasteboard.general.clearContents()
                    copyStatus = NSPasteboard.general.setString(model.cloud.makeLoginURL().absoluteString, forType: .string) ? "链接已复制" : "复制失败，请重试"
                }.buttonStyle(PulseButtonStyle())
            }.font(PulseTheme.font(size: 11)).padding(.horizontal, 17).padding(.bottom, 12).background(PulseTheme.background)
            if !copyStatus.isEmpty { Text(L10n.text(copyStatus)).font(PulseTheme.font(size: 11)).padding(.horizontal, 17).padding(.bottom, 8) }
            GarminLoginWebView(cloud: model.cloud, isLoading: $loginLoading)
            PulseDisclosure(L10n.text("浏览器登录后的连接")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("如内置页面无法登录，可在浏览器完成登录，再将最终的官方回跳地址粘贴到这里。地址只在本机用于完成认证。"))
                        .font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary)
                    HStack {
                        SecureField(L10n.text("粘贴官方认证回跳地址"), text: $callbackURL).textFieldStyle(.roundedBorder)
                            .accessibilityLabel(L10n.text("粘贴官方认证回跳地址"))
                        Button(L10n.text("连接")) {
                            if let url = URL(string: callbackURL), model.cloud.handleNavigation(url) { callbackURL = ""; callbackError = "" }
                            else { callbackError = "此地址未包含当前登录方式的有效官方回跳凭据" }
                        }.buttonStyle(PulseButtonStyle(prominent: true)).disabled(callbackURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !callbackError.isEmpty { Text(L10n.text(callbackError)).font(PulseTheme.font(size: 10)).foregroundStyle(.orange) }
                }
            }.font(PulseTheme.font(size: 11)).padding(14).background(PulseTheme.background)
            HStack { Text(L10n.text(model.cloud.status)).font(PulseTheme.font(size: 11)); Spacer() }.padding(14).background(PulseTheme.background)
        }.frame(width: 760, height: 680).foregroundStyle(.primary).preferredColorScheme(model.preferredColorScheme)
    }
}

struct WatchRequestCaptureCard: View {
    @ObservedObject var capture: WatchRequestCapture
    let connected: Bool
    let preview: Bool
    @State private var expanded = false

    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 12) {
                Button { expanded.toggle() } label: {
                    HStack {
                        Label(L10n.text("手表请求诊断"), systemImage: "waveform.path")
                        Spacer()
                        Text(L10n.text(capture.isCapturing ? "正在捕获" : "已停止"))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }.font(PulseTheme.font(size: 14, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                }.buttonStyle(PulseRowButtonStyle()).accessibilityValue(L10n.text(expanded ? "已展开" : "已收起"))
                Text(L10n.text(connected ? "打开手表天气页面或切换表盘，查看本连接收到的消息。" : "连接手表后打开天气页面；也可先开始捕获，再连接手表。"))
                    .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                PulseFlowLayout {
                    Button(L10n.text(capture.isCapturing ? "停止捕获" : "捕获 10 分钟")) {
                        if capture.isCapturing { capture.stop() } else { capture.start(); expanded = true }
                    }.buttonStyle(PulseButtonStyle(prominent: true)).disabled(preview)
                    Button(L10n.text("导出请求记录")) {
                        if capture.persist() { NSWorkspace.shared.activateFileViewerSelecting([capture.url]) }
                    }.buttonStyle(PulseButtonStyle()).disabled(capture.log.startedAt == nil || preview)
                    Button(L10n.text("清空记录")) { capture.clear() }.buttonStyle(PulseButtonStyle()).disabled(preview || capture.log.startedAt == nil)
                }
                if capture.storageError {
                    Text(L10n.text("请求记录保存失败，请检查本地存储权限。"))
                        .font(PulseTheme.font(size: 12)).foregroundStyle(.orange)
                }
                if expanded {
                    Text(L10n.text("仅保存消息类型和安全字段，隐藏位置与原始内容。"))
                        .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                    Text(L10n.format("消息明细 {0} 条 · 常规通信 {1} 条", String(capture.log.totalEvents), String(capture.log.omittedRoutineMessages)))
                        .font(PulseTheme.font(size: 12, weight: .medium))
                    if !capture.log.routineCategories.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.text("常规通信分类")).fontWeight(.semibold)
                            Text(L10n.text("收到的消息包含请求、数据和回复；协议确认不代表手表发起了新请求。"))
                                .foregroundStyle(PulseTheme.secondary)
                            ForEach(capture.log.routineCategories.sorted { $0.id < $1.id }) { category in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: category.direction == .watchToMac ? "arrow.down.left" : "arrow.up.right")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(L10n.text(category.name))
                                        Text(categoryDetail(category)).foregroundStyle(PulseTheme.secondary)
                                    }
                                    Spacer()
                                    Text(L10n.format("{0} 条", String(category.count))).monospacedDigit()
                                    Text(category.lastSeen, style: .time).monospacedDigit().foregroundStyle(PulseTheme.secondary)
                                }
                            }
                        }.font(PulseTheme.font(size: 12))
                    }
                    if capture.log.historicalRoutineMessages > 0 {
                        Text(L10n.format("旧记录中有 {0} 条常规消息未分类；新捕获将显示分类。", String(capture.log.historicalRoutineMessages)))
                            .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                    }
                    if capture.log.unclassifiedRoutineMessages > 0 {
                        Text(L10n.format("另有 {0} 条常规消息超出分类容量。", String(capture.log.unclassifiedRoutineMessages)))
                            .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                    }
                    if capture.log.events.isEmpty {
                        Text(L10n.text("尚无消息明细；常规通信请查看上方分类。"))
                            .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(capture.log.events.suffix(30).reversed()) { event in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Image(systemName: event.direction == .watchToMac ? "arrow.down.left" : "arrow.up.right")
                                        Text(L10n.text(event.name)).fontWeight(.medium)
                                        Spacer()
                                        Text(event.time, style: .time).monospacedDigit()
                                    }
                                    Text(detail(event)).foregroundStyle(PulseTheme.secondary).textSelection(.enabled)
                                }.font(PulseTheme.font(size: 12))
                                Divider()
                            }
                        }
                        Text(L10n.text("显示最近 30 条；导出保留最近 300 条。排队发送不代表手表已收到。"))
                            .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                    }
                }
            }
        }
    }

    private func categoryDetail(_ category: GFDIRequestLog.RoutineCategory) -> String {
        let direction = L10n.text(category.direction == .watchToMac ? "手表 → Mac" : "应用排队发送")
        var parts = [direction, "#\(category.number)"]
        if let target = category.replyTo {
            parts.append(L10n.format("确认 #{0}", String(target)))
        }
        return parts.joined(separator: " · ")
    }

    private func detail(_ event: GFDIRequestLog.Event) -> String {
        let direction = L10n.text(event.direction == .watchToMac ? "手表 → Mac" : "应用排队发送")
        var parts = [direction, "#\(event.number)", "\(event.payloadBytes) B"]
        if let target = event.replyTo, let status = event.status {
            let result = status == 0 ? L10n.text("成功") : status == 2 ? L10n.text("不支持") : "\(status)"
            parts.append(L10n.format("回复 #{0}：{1}", String(target), result))
        }
        if let format = event.weatherFormat, let hours = event.forecastHours {
            parts.append(L10n.format("格式 {0} · 预报 {1} 小时 · 位置已隐藏", String(format), String(hours)))
        } else if event.weatherPayloadValid == false {
            parts.append(L10n.text("天气消息长度不符合已知格式"))
        }
        return parts.joined(separator: " · ")
    }
}
