import AppKit
import SwiftUI

private struct ConnectIQSaveRequest {
    let app: ConnectIQApp
    let scope: String
}

struct ConnectIQPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var library: ConnectIQLibrary
    @State private var automaticReadUnitID: UInt32?
    @State private var catalogLoadPending = false
    @State private var lookupError = false
    @State private var showDetail = false
    @State private var saveRequest: ConnectIQSaveRequest?
    @State private var showDownloadConfirmation = false
    @State private var preparingInstall = false
    @State private var watchActionAppID: String?
    @State private var watchActionIsInstall = false
    @State private var settingsFace: GFDIInstalledWatchFace?
    @State private var settingsSaved = false
    @FocusState private var searchFocused: Bool

    init(model: AppModel) { self.model = model; library = model.connectIQ }

    var body: some View {
        VStack(alignment: .leading, spacing: PulseLayout.sectionGap) {
            Picker(L10n.text("Connect IQ"), selection: $model.connectIQScope) {
                Text(L10n.text("已安装")).tag(0)
                Text(L10n.text("发现表盘")).tag(1)
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 440)
            if model.connectIQScope == 0 { watchFaces } else { discovery }
        }
        .buttonStyle(PulseButtonStyle())
        .task(id: automaticReadScope) { await automaticallyReadInventory() }
        .onChange(of: model.connectIQCatalogTab) { value in
            if model.connectIQScope == 1 && library.online && !model.preview && value != 2 && (value == 0 ? library.history.isEmpty : library.featured.isEmpty) { refresh() }
        }
        .onChange(of: model.connectIQSearchText) { _ in lookupError = false }
        .onChange(of: library.searchQuery) { query in if query.isEmpty && model.connectIQCatalogTab == 2 { model.connectIQCatalogTab = 1 } }
        .onAppear {
            library.reconcile()
            library.refreshRuntimeMappings(appIDs: model.bluetooth.installedWatchFaces.map(\.id))
            if model.connectIQScope == 0 && !model.preview { library.refreshInstalledMetadata(appIDs: model.bluetooth.installedWatchFaces.map(\.id)) }
            if model.connectIQScope == 1 && library.history.isEmpty { catalogLoadPending = true; loadCatalogWhenReady() }
        }
        .onChange(of: model.bluetooth.installedWatchFaces.map(\.id)) { ids in
            library.refreshRuntimeMappings(appIDs: ids)
            if model.connectIQScope == 0 && !model.preview { library.refreshInstalledMetadata(appIDs: ids) }
        }
        .onChange(of: library.busy) { busy in
            if !busy && model.connectIQScope == 0 && !model.preview { library.refreshInstalledMetadata(appIDs: model.bluetooth.installedWatchFaces.map(\.id)) }
            if !busy { loadCatalogWhenReady() }
        }
        .onChange(of: model.cloud.deviceId) { _ in
            library.reconcile(); saveRequest = nil; showDownloadConfirmation = false
            settingsSaved = false; showDetail = false
            library.refreshRuntimeMappings(appIDs: model.bluetooth.installedWatchFaces.map(\.id))
            if model.connectIQScope == 1 { catalogLoadPending = true; loadCatalogWhenReady() }
        }
        .onChange(of: model.cloud.accountGUID) { _ in
            settingsSaved = false; showDetail = false
            library.refreshRuntimeMappings(appIDs: model.bluetooth.installedWatchFaces.map(\.id))
        }
        .onChange(of: model.cloud.loginRevision) { _ in settingsSaved = false; showDetail = false }
        .onChange(of: model.cloud.region) { _ in settingsSaved = false; showDetail = false }
        .onChange(of: model.watchUnitID) { _ in settingsSaved = false }
        .onChange(of: model.bluetooth.isConnected) { _ in settingsSaved = false }
        .sheet(item: $settingsFace) { face in
            ConnectIQSettingsSheet(model: model, face: face, onSaved: { settingsSaved = true })
        }
        .sheet(isPresented: $showDetail) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Connect IQ").font(.headline)
                    Spacer()
                    Button(L10n.text("关闭")) { showDetail = false }
                        .keyboardShortcut(.cancelAction)
                }
                ScrollView(showsIndicators: false) {
                    if let app = library.selected { detail(app) }
                    else {
                        VStack(spacing: 14) {
                            if library.busy { ProgressView() }
                            Image(systemName: "applewatch").font(.system(size: 36)).foregroundStyle(PulseTheme.secondary)
                            Text(L10n.text(library.busy ? "正在加载表盘…" : "表盘资料暂不可用"))
                        }.frame(maxWidth: .infinity).padding(.vertical, 70)
                    }
                }.frame(maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                ConnectIQSurface {
                    VStack(alignment: .leading, spacing: 12) {
                        if let app = library.selected { detailActions(app) }
                        detailDownloadFooter
                    }
                }
            }
            .buttonStyle(PulseButtonStyle())
            .padding(20).frame(width: 660, height: 680)
            .background(PulseTheme.background)
            .alert(L10n.text("下载表盘到 Mac？"), isPresented: $showDownloadConfirmation) {
                Button(L10n.text("取消"), role: .cancel) { saveRequest = nil }
                Button(L10n.text("确认下载")) {
                    guard !model.preview, let request = saveRequest else { return }
                    saveRequest = nil
                    library.download(request.app, confirmedScope: request.scope)
                }
            } message: {
                Text(L10n.text("下载可能会在佳明云端创建此手表的安装任务，下次佳明同步时可能安装。文件会保存到“下载/WristBeam/ConnectIQ”文件夹；不会在此切换当前表盘。"))
            }
        }
    }

    @ViewBuilder private var operationFeedback: some View {
        if library.busy || (!library.status.isEmpty && !(library.savedURL != nil && ["已找到本地表盘文件", "已下载到 Mac"].contains(library.status))) {
            HStack(spacing: 10) {
                if library.busy { ProgressView().controlSize(.small) }
                Text(L10n.text(library.status.isEmpty ? "正在处理 Connect IQ…" : library.status))
                    .font(PulseTheme.font(size: 12)).textSelection(.enabled)
                Spacer(minLength: 4)
                if library.busy {
                    Button(L10n.text(library.isDownloading ? "取消下载" : "取消")) { library.cancel() }
                }
            }.padding(12)
                .background(PulseTheme.mint.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        if !library.queueNotice.isEmpty {
            Text(L10n.text(library.queueNotice)).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
        }
        if let url = library.savedURL { downloadResult(url) }
    }
    private var discovery: some View {
                VStack(alignment: .leading, spacing: 16) {
                    ViewThatFits(in: .horizontal) {
                        HStack { discoveryTitle; Spacer(minLength: 12); if model.cloudSyncEnabled && model.cloud.isAuthenticated { deviceMenu } }
                        VStack(alignment: .leading, spacing: 8) { discoveryTitle; if model.cloudSyncEnabled && model.cloud.isAuthenticated { deviceMenu } }
                    }
                    if (!model.cloudSyncEnabled || !model.cloud.isAuthenticated) && !model.preview {
                        Text(L10n.text("登录佳明账号后，可查看表盘和下载到 Mac")).foregroundStyle(PulseTheme.secondary)
                        Button(L10n.text("设备账号")) { model.openSettings(.account) }
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").foregroundStyle(PulseTheme.secondary)
                            TextField(L10n.text("搜索表盘名称、关键词或粘贴链接"), text: $model.connectIQSearchText)
                                .textFieldStyle(.roundedBorder).focused($searchFocused).onSubmit { lookupApp() }
                            if !model.connectIQSearchText.isEmpty {
                                Button {
                                    model.connectIQSearchText = ""; searchFocused = true
                                    if model.connectIQCatalogTab == 2 { library.clearSearch(); model.connectIQCatalogTab = 1 }
                                } label: { Image(systemName: "xmark.circle.fill").frame(width: 28, height: 28).contentShape(Rectangle()) }
                                    .buttonStyle(.plain).foregroundStyle(PulseTheme.secondary)
                                    .accessibilityLabel(L10n.text("清空搜索"))
                                    .disabled(library.busy)
                            }
                            Button(L10n.text("搜索")) { lookupApp() }
                                .buttonStyle(PulseButtonStyle(prominent: true))
                                .disabled(!library.online || model.connectIQSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.busy || model.preview)
                        }
                        if lookupError {
                            Label(L10n.text("请输入 1–128 个字符的表盘名称、关键词或有效的佳明商店链接"), systemImage: "exclamationmark.circle")
                                .font(PulseTheme.font(size: 11)).foregroundStyle(.orange)
                        }
                        HStack {
                            Picker(L10n.text("发现表盘"), selection: $model.connectIQCatalogTab) {
                                Text(L10n.text("云端下载记录")).tag(0)
                                Text(L10n.text("推荐表盘")).tag(1)
                                if !library.searchQuery.isEmpty { Text(L10n.text("搜索结果")).tag(2) }
                            }.pickerStyle(.menu).labelsHidden().disabled(library.busy)
                            Spacer()
                            Button { refresh() } label: { Label(L10n.text("刷新"), systemImage: "arrow.clockwise") }
                                .disabled(!library.online || library.busy || model.preview)
                        }
                        if model.connectIQCatalogTab == 0 {
                            Text(L10n.text("下载记录不代表手表当前安装或正在使用的表盘")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                        }
                        operationFeedback
                        catalogFeedback
                        if model.connectIQCatalogTab == 0 { historyRows } else if model.connectIQCatalogTab == 1 { featuredRows } else { searchRows }
                    }
                }
    }
    private func loadCatalogWhenReady() {
        guard model.connectIQScope == 1, catalogLoadPending, library.online, !library.busy, !model.preview else { return }
        catalogLoadPending = false
        refresh()
    }
    private var discoveryTitle: some View {
        Label(L10n.text("发现表盘"), systemImage: "square.grid.2x2")
            .font(PulseTheme.font(size: 17, weight: .semibold)).fixedSize()
    }
    private var deviceMenu: some View {
        Menu {
            Picker(L10n.text("设备"), selection: Binding(get: { model.cloud.deviceId }, set: { model.cloud.deviceId = $0 })) {
                Text(L10n.text("选择手表")).tag("")
                ForEach(model.cloud.devices) { device in Text(device.name).tag(device.id) }
            }
        } label: {
            Label(model.cloud.devices.first(where: { $0.id == model.cloud.deviceId })?.name ?? L10n.text("选择手表"), systemImage: "applewatch")
                .font(PulseTheme.font(size: 12, weight: .medium)).lineLimit(1)

        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel(L10n.text("设备"))
        .disabled(library.busy)
    }
    @ViewBuilder private var catalogFeedback: some View {
        if (model.connectIQCatalogTab == 0 ? library.history.isEmpty : model.connectIQCatalogTab == 1 ? library.featured.isEmpty : library.searchResults.isEmpty) {
            VStack(spacing: 12) {
                if library.busy { ProgressView().controlSize(.small) }
                else { Image(systemName: "square.grid.2x2").font(.system(size: 26)).foregroundStyle(PulseTheme.secondary) }
                Text(L10n.text(library.busy ? "正在加载表盘…" : model.connectIQCatalogTab == 0 ? "暂无下载记录" : model.connectIQCatalogTab == 1 ? "暂无推荐表盘" : "未找到匹配的表盘，试试其他关键词"))
                    .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 28)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
    private func lookupApp() {
        guard library.online, !library.busy, !model.preview else { return }
        let id = ConnectIQLibrary.appID(from: model.connectIQSearchText)
        guard id != nil || ConnectIQService.searchKeywords(from: model.connectIQSearchText) != nil else { lookupError = true; return }
        lookupError = false
        searchFocused = false
        if let id { openDetail(id) }
        else { showDetail = false; model.connectIQCatalogTab = 2; library.search(model.connectIQSearchText) }
    }
    private func openDetail(_ id: String) {
        guard library.online, !library.busy, !model.preview else { return }
        library.select(id)
        showDetail = true
    }

    private var watchFaces: some View {
        VStack(alignment: .leading, spacing: PulseLayout.groupGap) {
            ViewThatFits(in: .horizontal) {
                HStack { inventoryHeading; Spacer(minLength: 12); inventoryRefresh }
                VStack(alignment: .leading, spacing: 12) { inventoryHeading; inventoryRefresh }
            }
            if !model.bluetooth.isConnected {
                PulseEmptyState(title: "连接手表", detail: "连接后自动读取已安装表盘", symbol: "applewatch") {
                    Button(L10n.text("连接手表")) { model.openSettings(.watch) }
                }
            } else if connectedUnitID == nil {
                PulseNotice(text: "所选设备与连接的手表不同", warning: true)
                Button(L10n.text("选择手表")) { model.openSettings(.account) }
            } else {
                if model.bluetooth.watchFaceBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text(model.bluetooth.watchFaceStatus.isEmpty ? "正在读取手表已安装表盘" : model.bluetooth.watchFaceStatus))
                    }.font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                } else if automaticReadUnitID == nil && !model.preview {
                    Text(L10n.text("数据通道就绪、同步完成后自动读取"))
                        .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                }
                if !model.bluetooth.installedWatchFaces.isEmpty { installedFaces }
                else if model.bluetooth.installedWatchFaceAvailableSpace != nil && !model.bluetooth.watchFaceBusy {
                    PulseEmptyState(title: "未找到已安装表盘", detail: "", symbol: "watchface.applewatch.case") {
                        Button(L10n.text("发现表盘")) { model.connectIQScope = 1 }
                    }
                }
                if !model.bluetooth.watchFaceBusy && automaticReadUnitID != nil && !model.bluetooth.watchFaceStatus.isEmpty {
                    Text(L10n.text(model.bluetooth.watchFaceStatus))
                        .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.bluetooth.watchFaceOpenStatus.isEmpty {
                Text(L10n.text(model.bluetooth.watchFaceOpenStatus))
                    .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary).textSelection(.enabled)
            }
            if model.bluetooth.watchFaceOpenBusy { ProgressView().controlSize(.small) }
            if settingsSaved {
                Label(L10n.text("配置已保存，手表回读确认一致"), systemImage: "checkmark.circle.fill")
                    .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.mint)
            }
            if !model.bluetooth.watchFaces.isEmpty {
                Text(L10n.text("可切换表盘")).font(PulseTheme.font(size: 13, weight: .semibold))
                ForEach(model.bluetooth.watchFaces) { face in
                    HStack {
                        Text(face.title)
                        Spacer()
                        if face.isSelected == true { Label(L10n.text("当前表盘"), systemImage: "checkmark.circle.fill").foregroundStyle(PulseTheme.mint) }
                        else {
                            Button(L10n.text("切换到此表盘")) {
                                if let id = connectedUnitID { model.bluetooth.selectWatchFace(face, expectedUnitID: id) }
                            }.disabled(!canReadWatchFaces || face.isSelected != false)
                            if face.isSelected == nil { Text(L10n.text("当前状态未知")).foregroundStyle(PulseTheme.secondary) }
                        }
                    }
                }
            }
        }
    }
    private var inventoryHeading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.text("手表上的表盘"), systemImage: "applewatch")
                .font(PulseTheme.font(size: 17, weight: .semibold))
            if model.bluetooth.isConnected {
                PulseFlowLayout(spacing: 12) {
                    Text(model.bluetooth.connectedName)
                    if let bytes = model.bluetooth.installedWatchFaceAvailableSpace {
                        Text(L10n.format("已安装 {0} 个表盘", String(model.bluetooth.installedWatchFaces.count)))
                        Text(L10n.text("可用空间") + ": " + ByteCountFormatStyle(style: .file, locale: L10n.locale).format(Int64(clamping: bytes)))
                    }
                }.font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
            }
        }
    }
    private var inventoryRefresh: some View {
        Button { refreshInventory() } label: { Label(L10n.text("刷新"), systemImage: "arrow.clockwise") }
            .buttonStyle(.bordered).disabled(!canReadWatchFaces).help(L10n.text("读取手表表盘"))
    }
    private var installedFaces: some View {
        VStack(spacing: 0) {
            ForEach(model.bluetooth.installedWatchFaces) { face in
                if face.id != model.bluetooth.installedWatchFaces.first?.id { Divider().padding(.leading, 72) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        installedFaceIdentity(face).frame(minWidth: 200)
                        installedFaceActions(face).fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        installedFaceIdentity(face)
                        installedFaceActions(face)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 12)
            }
        }.background(PulseTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PulseTheme.separator, lineWidth: 1))
    }
    private func installedFaceIdentity(_ face: GFDIInstalledWatchFace) -> some View {
        HStack(spacing: 12) {
            ConnectIQArtwork(url: model.preview ? nil : library.apps[face.id]?.iconURL, width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(library.apps[face.id]?.localizedName ?? face.name)
                    .font(PulseTheme.font(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                PulseFlowLayout(spacing: 8) {
                    if let bytes = face.fileSize { Text(ByteCountFormatStyle(style: .file, locale: L10n.locale).format(Int64(clamping: bytes))) }
                }.font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func installedFaceActions(_ face: GFDIInstalledWatchFace) -> some View {
        PulseFlowLayout(spacing: 8) {
            Button(L10n.text("表盘设置")) { settingsSaved = false; settingsFace = face }
                .disabled(!canReadWatchFaces || !library.online || UInt32(model.cloud.deviceId) != face.unitID)
            Button(L10n.text("详情")) { openDetail(face.id) }
                .disabled(!library.online || library.busy || model.preview)
        }.buttonStyle(.bordered)
    }
    private var automaticReadScope: String {
        "\(model.connectIQScope):\(model.bluetooth.isConnected):\(model.watchUnitID):\(model.cloud.deviceId):\(model.cloud.loginRevision)"
    }
    private func automaticallyReadInventory() async {
        guard model.connectIQScope == 0, !model.preview else { return }
        automaticReadUnitID = nil
        while !Task.isCancelled && model.bluetooth.isConnected {
            if let id = connectedUnitID, automaticReadUnitID == id { return }
            if canReadWatchFaces, let id = connectedUnitID,
               model.bluetooth.refreshWatchFaces(expectedUnitID: id) {
                automaticReadUnitID = id
                return
            }
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
        }
    }
    private func refreshInventory() {
        guard canReadWatchFaces, let id = connectedUnitID else { return }
        if model.bluetooth.refreshWatchFaces(expectedUnitID: id) { automaticReadUnitID = id }
    }
    private var canReadWatchFaces: Bool {
        !model.preview && connectedUnitID != nil && model.bluetooth.protocolReady && model.bluetooth.canSyncFiles
            && !model.bluetooth.isTransferringFiles && !model.bluetooth.watchFaceBusy
            && !model.bluetooth.watchFaceOpenBusy && !model.bluetooth.connectIQInstallBusy && !model.bluetooth.connectIQSettingsBusy
    }
    private var connectedUnitID: UInt32? {
        guard model.bluetooth.isConnected, let id = UInt32(model.watchUnitID), id > 0 else { return nil }
        if model.cloud.networkEnabled && model.cloud.isAuthenticated && !model.cloud.deviceId.isEmpty {
            guard UInt32(model.cloud.deviceId) == id else { return nil }
        }
        return id
    }
    private var historyRows: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
            ForEach(Array(library.history.sorted { $0.date > $1.date }.enumerated()), id: \.offset) { _, row in
                catalogCard(id: row.appID, name: library.apps[row.appID]?.localizedName ?? L10n.text("表盘资料暂不可用"),
                            url: library.apps[row.appID]?.iconURL,
                            subtitle: "\(row.version) · \(row.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale)))")
            }
            }
            if library.historyHasMore {
                Button(L10n.text("加载更多")) { library.refreshHistory(older: true) }.disabled(library.busy)
            }
        }
    }
    private var featuredRows: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
            ForEach(library.featured) { app in
                catalogCard(id: app.id, name: app.localizedName, url: app.iconURL, subtitle: L10n.text("商店版本") + ": " + app.version)
            }
            }
            if library.featuredHasMore {
                Button(L10n.text("加载更多")) { library.refreshFeatured(older: true) }.disabled(library.busy)
            }
        }
    }
    private var searchRows: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(library.searchQuery).font(PulseTheme.font(size: 13, weight: .medium)).textSelection(.enabled)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(library.searchResults) { app in
                    catalogCard(id: app.id, name: app.localizedName, url: app.iconURL, subtitle: L10n.text("商店版本") + ": " + app.version)
                }
            }
            if library.searchHasMore {
                Button(L10n.text("加载更多")) { library.search(library.searchQuery, older: true) }.disabled(library.busy)
            }
        }
    }
    private func catalogCard(id: String, name: String, url: URL?, subtitle: String) -> some View {
        Button { openDetail(id) } label: {
            HStack(spacing: 12) {
                ConnectIQArtwork(url: model.preview ? nil : url, width: 60, height: 60)
                VStack(alignment: .leading, spacing: 6) {
                    Text(name).font(PulseTheme.font(size: 13, weight: .medium)).lineLimit(2)
                    Text(subtitle).font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(PulseTheme.secondary.opacity(0.6))
            }.frame(minHeight: 68)
        }
        .buttonStyle(PulseButtonStyle(card: true))
        .disabled(!library.online || library.busy || model.preview)
        .help(name)
    }
    private func detailActions(_ app: ConnectIQApp) -> some View {
        PulseFlowLayout(spacing: 10) {
            Button { requestDownload(app) } label: { Label(L10n.text("下载到 Mac"), systemImage: "arrow.down.to.line") }
                .buttonStyle(PulseButtonStyle(prominent: true))
                .disabled(!library.online || library.busy || model.preview || !canDownload(app))
            Button { install(app) } label: { Label(L10n.text("安装到手表"), systemImage: "applewatch") }
                .disabled(preparingInstall || !canInstall(app))
            if let url = URL(string: "https://\(model.cloud.region == .china ? "apps.garmin.cn" : "apps.garmin.com")/apps/\(app.id)") {
                Link(destination: url) { Label(L10n.text("在佳明商店查看"), systemImage: "arrow.up.right.square") }
                    .help(L10n.text("在佳明商店查看")).accessibilityLabel(L10n.text("在佳明商店查看"))
            }
        }
    }
    private func detail(_ app: ConnectIQApp) -> some View {
        ConnectIQSurface {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    ConnectIQArtwork(url: model.preview ? nil : app.iconURL, width: 88, height: 88)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(app.localizedName).font(PulseTheme.font(size: 20, weight: .semibold))
                        Text(L10n.text("商店版本") + ": " + app.version).foregroundStyle(PulseTheme.secondary)
                        Text(L10n.text(compatibility(app))).font(PulseTheme.font(size: 11))
                            .foregroundStyle(isIncompatible(app) ? Color.orange : PulseTheme.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Button(L10n.text("检查手表安装状态")) {
                        guard !model.preview, let id = connectedUnitID,
                              let runtimeID = library.verifiedRuntimeAppID(appID: app.id) else { return }
                        watchActionAppID = app.id; watchActionIsInstall = false
                        model.bluetooth.probeConnectIQApplication(appID: runtimeID, expectedUnitID: id)
                    }.disabled(model.preview || library.runtimeAppIDs[app.id] == nil || connectedUnitID == nil || !model.bluetooth.canOpenInstalledWatchFace
                               || model.bluetooth.watchFaceBusy || model.bluetooth.watchFaceOpenBusy
                               || model.bluetooth.connectIQInstallBusy || model.bluetooth.isTransferringFiles)
                    Text(L10n.text("安装后请在手表上选择表盘")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                }
                if library.localPackage?.appID == app.id && library.runtimeAppIDs[app.id] == nil {
                    Text(L10n.text("下载并校验表盘后可检查安装状态")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                }
                if library.localPackage?.appID != app.id {
                    Text(L10n.text("先下载到 Mac，再安装到手表")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                }
                if !app.screenshotURLs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(app.screenshotURLs.enumerated()), id: \.offset) { _, url in
                                ConnectIQArtwork(url: model.preview ? nil : url, width: 200, height: 230)
                            }
                        }.padding(.bottom, 6)
                    }.clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                Text(app.localizedDescription).font(PulseTheme.font(size: 12)).lineSpacing(5).textSelection(.enabled)
                if !app.permissions.isEmpty {
                    Text(L10n.text("所需权限") + ": " + app.permissions.joined(separator: ", "))
                        .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                }
                if app.hasTrialMode { Text(L10n.text("包含试用模式")).foregroundStyle(PulseTheme.secondary) }

            }
        }
    }
    private var detailDownloadFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let actionID = watchActionAppID, actionID == library.selected?.id, !preparingInstall {
                if watchActionIsInstall && model.bluetooth.connectIQInstallBusy {
                    ProgressView(value: model.bluetooth.connectIQInstallProgress).tint(PulseTheme.mint)
                }
                if watchActionIsInstall && !model.bluetooth.connectIQInstallStatus.isEmpty {
                    Text(L10n.text(model.bluetooth.connectIQInstallStatus)).font(PulseTheme.font(size: 12)).textSelection(.enabled)
                }
                if !watchActionIsInstall && !model.bluetooth.watchFaceOpenStatus.isEmpty {
                    Text(L10n.text(model.bluetooth.watchFaceOpenStatus)).font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                }
            }
            if library.busy || !library.status.isEmpty {
                HStack(spacing: 10) {
                    if library.busy { ProgressView().controlSize(.small) }
                    if !library.status.isEmpty {
                        Text(L10n.text(library.status)).font(PulseTheme.font(size: 12)).textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    if library.isDownloading { Button(L10n.text("取消下载")) { library.cancel() } }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(PulseTheme.mint)
                Text(downloadFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(downloadFolder.path)
                Spacer(minLength: 8)
                Button(L10n.text("在 Finder 中显示")) {
                    if let url = library.savedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    else { NSWorkspace.shared.open(library.downloadRoot) }
                }.disabled(!FileManager.default.fileExists(atPath: downloadFolder.path))
            }
            if !library.queueNotice.isEmpty {
                Text(L10n.text(library.queueNotice)).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
    private var downloadFolder: URL { library.savedURL?.deletingLastPathComponent() ?? library.downloadRoot }
    private var selectedPartNumber: String? { model.cloud.devices.first { $0.id == model.cloud.deviceId }?.partNumber }
    private func isIncompatible(_ app: ConnectIQApp) -> Bool {
        guard let part = selectedPartNumber, !app.compatiblePartNumbers.isEmpty else { return false }
        return !app.compatiblePartNumbers.contains(part)
    }
    private func canDownload(_ app: ConnectIQApp) -> Bool {
        guard app.isWatchFace, let part = selectedPartNumber, !part.isEmpty else { return false }
        return app.compatiblePartNumbers.contains(part)
    }
    private func canInstall(_ app: ConnectIQApp) -> Bool {
        guard !model.preview, canDownload(app), library.online, !library.busy,
              library.localPackage?.appID == app.id, let id = connectedUnitID,
              model.cloud.isAuthenticated, !model.cloud.accountGUID.isEmpty,
              UInt32(model.cloud.deviceId) == id else { return false }
        return model.bluetooth.canInstallConnectIQ && !model.bluetooth.connectIQInstallBusy
            && !model.bluetooth.watchFaceBusy && !model.bluetooth.watchFaceOpenBusy && !model.bluetooth.isTransferringFiles
    }
    private func install(_ app: ConnectIQApp) {
        guard !preparingInstall, canInstall(app) else { return }
        let confirmationScope = library.confirmationScope
        preparingInstall = true; watchActionAppID = app.id; watchActionIsInstall = true
        Task { @MainActor in
            defer { preparingInstall = false }
            guard let prepared = await library.prepareInstallation(app, confirmedScope: confirmationScope),
                  canInstall(app), library.confirmationScope == confirmationScope,
                  let id = connectedUnitID, UInt32(prepared.deviceID) == id,
                  prepared.accountGUID == model.cloud.accountGUID else { return }
            model.bluetooth.installConnectIQPackage(prepared.package.data, appID: app.id,
                expectedSHA256: prepared.package.file.sha256, sourceMessageID: prepared.sourceMessageID,
                expectedUnitID: id, expectedAccountGUID: prepared.accountGUID)
        }
    }
    private func compatibility(_ app: ConnectIQApp) -> String {
        guard app.isWatchFace else { return "此应用不是表盘" }
        guard let part = selectedPartNumber, !part.isEmpty, !app.compatiblePartNumbers.isEmpty else { return "兼容性待确认" }
        return isIncompatible(app) ? "不兼容所选手表" : "兼容所选手表"
    }
    private func refresh() {
        guard !model.preview else { return }
        if model.connectIQCatalogTab == 0 { library.refreshHistory() }
        else if model.connectIQCatalogTab == 1 { library.refreshFeatured() }
        else { library.search(library.searchQuery) }
    }
    private func downloadResult(_ url: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill").foregroundStyle(PulseTheme.mint)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("已保存到本地文件夹")).font(PulseTheme.font(size: 12, weight: .medium)).foregroundStyle(PulseTheme.mint)
                Text(library.selected?.localizedName ?? url.lastPathComponent)
                    .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(L10n.text("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(PulseTheme.mint.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    private func requestDownload(_ app: ConnectIQApp) {
        guard !model.preview, library.online, canDownload(app) else { return }
        saveRequest = ConnectIQSaveRequest(app: app, scope: library.confirmationScope)
        showDownloadConfirmation = true
    }
}

/// Public artwork uses the same bounded, cookie-free loader as downloaded previews.
private struct ConnectIQArtwork: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat
    @Environment(\.displayScale) private var scale
    @State private var image: NSImage?
    @State private var loadedKey = ""
    @State private var failedKey = ""
    private var pixels: Int { min(1024, max(32, Int((max(width, height) * scale).rounded(.up)))) }
    private var requestKey: String { (url?.absoluteString ?? "none") + "#" + String(pixels) }
    var body: some View {
        Group {
            if loadedKey == requestKey, let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: min(width * 0.16, 16), style: .continuous)).padding(4)
            } else if url == nil || failedKey == requestKey { placeholder }
            else { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(width: width, height: height)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: min(width * 0.24, 20), style: .continuous))
        .accessibilityLabel(L10n.text(failedKey == requestKey ? "表盘预览暂不可用" : "表盘预览"))
        .task(id: requestKey) {
            let key = requestKey
            image = nil; failedKey = ""; loadedKey = ""
            guard let url else { return }
            do {
                let result = try await ConnectIQArtworkCache.image(url: url, pixels: pixels)
                guard !Task.isCancelled else { return }
                image = result; loadedKey = key
            } catch {
                guard !Task.isCancelled else { return }
                failedKey = key
            }
        }
    }
    private var placeholder: some View {
        Image(systemName: "applewatch").font(.system(size: min(width * 0.4, 36)))
            .foregroundStyle(PulseTheme.secondary.opacity(0.6)).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor private enum ConnectIQArtworkCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let value = NSCache<NSString, NSImage>(); value.countLimit = 80; value.totalCostLimit = 32 * 1024 * 1024
        return value
    }()
    static func image(url: URL, pixels: Int) async throws -> NSImage {
        let key = (url.absoluteString + "#" + String(pixels)) as NSString
        if let image = cache.object(forKey: key) { return image }
        let data = try await ConnectIQPackageStore.loadArtwork(url)
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard let image = ConnectIQPackageStore.artworkThumbnail(data, maximumPixels: pixels) else { throw CocoaError(.fileReadCorruptFile) }
            return image
        }
        let decoded = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        let image = NSImage(cgImage: decoded, size: NSSize(width: CGFloat(decoded.width), height: CGFloat(decoded.height)))
        cache.setObject(image, forKey: key, cost: decoded.bytesPerRow * decoded.height)
        return image
    }
}
