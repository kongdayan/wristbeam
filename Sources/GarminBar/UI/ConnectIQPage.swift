import AppKit
import SwiftUI

private struct ConnectIQSaveRequest {
    let app: ConnectIQApp
    let scope: String
}

struct ConnectIQPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var library: ConnectIQLibrary
    @State private var lookup = ""
    @State private var lookupError = false
    @State private var tab = 0
    @State private var showDetail = false
    @State private var saveRequest: ConnectIQSaveRequest?
    @State private var showDownloadConfirmation = false
    @State private var preparingInstall = false
    @State private var watchActionAppID: String?
    @State private var watchActionIsInstall = false
    @State private var settingsFace: GFDIInstalledWatchFace?
    @State private var settingsSaved = false
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel) { self.model = model; library = model.connectIQ }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            watchFaces
            ConnectIQSurface {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Label(L10n.text("发现表盘"), systemImage: "square.grid.2x2")
                            .font(PulseTheme.font(size: 18, weight: .semibold))
                        Spacer()
                        if model.cloudSyncEnabled && model.cloud.isAuthenticated { deviceMenu }
                    }
                    if !model.cloudSyncEnabled || !model.cloud.isAuthenticated {
                        Text(L10n.text("登录佳明账号后，可查看表盘和下载到 Mac")).foregroundStyle(PulseTheme.secondary)
                        Button(L10n.text("设备账号")) { model.openSettings(.account) }
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").foregroundStyle(PulseTheme.secondary)
                            TextField(L10n.text("搜索表盘名称、关键词或粘贴链接"), text: $lookup)
                                .textFieldStyle(.plain).focused($searchFocused).onSubmit { lookupApp() }
                            if !lookup.isEmpty {
                                Button {
                                    lookup = ""; searchFocused = true
                                    if tab == 2 { library.clearSearch(); tab = 1 }
                                } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(PulseTheme.secondary)
                                    .accessibilityLabel(L10n.text("清空搜索"))
                                    .disabled(library.busy)
                            }
                            Button(L10n.text("搜索")) { lookupApp() }
                                .buttonStyle(PulseButtonStyle(prominent: true))
                                .disabled(!library.online || lookup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.busy || model.preview)
                        }
                        .padding(8).padding(.leading, 6)
                        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(searchFocused ? PulseTheme.mint.opacity(0.6) : Color.primary.opacity(0.07), lineWidth: 1))
                        if lookupError {
                            Label(L10n.text("请输入 1–128 个字符的表盘名称、关键词或有效的佳明商店链接"), systemImage: "exclamationmark.circle")
                                .font(PulseTheme.font(size: 11)).foregroundStyle(.orange)
                        }
                        HStack {
                            HStack(spacing: 4) {
                                catalogTab("云端下载记录", index: 0)
                                catalogTab("推荐表盘", index: 1)
                                if !library.searchQuery.isEmpty { catalogTab("搜索结果", index: 2) }
                            }
                            .padding(4)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            Spacer()
                            Button { refresh() } label: { Label(L10n.text("刷新"), systemImage: "arrow.clockwise") }
                                .disabled(!library.online || library.busy || model.preview)
                        }
                        if tab == 0 {
                            Text(L10n.text("下载记录不代表手表当前安装或正在使用的表盘")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                        }
                        operationFeedback
                        catalogFeedback
                        if tab == 0 { historyRows } else if tab == 1 { featuredRows } else { searchRows }
                    }
                }
            }
        }
        .buttonStyle(PulseButtonStyle())
        .onChange(of: lookup) { _ in lookupError = false }
        .onChange(of: library.searchQuery) { query in if query.isEmpty && tab == 2 { tab = 1 } }
        .onAppear {
            library.reconcile()
            library.refreshRuntimeMappings(appIDs: model.bluetooth.installedWatchFaces.map(\.id))
            if library.online && library.history.isEmpty && !library.busy && !model.preview { refresh() }
        }
        .onChange(of: model.bluetooth.installedWatchFaces.map(\.id)) { ids in library.refreshRuntimeMappings(appIDs: ids) }
        .onChange(of: model.cloud.deviceId) { _ in
            library.reconcile(); saveRequest = nil; showDownloadConfirmation = false
            settingsSaved = false; showDetail = false
            library.refreshRuntimeMappings(appIDs: model.bluetooth.installedWatchFaces.map(\.id))
            if library.online && !model.preview { refresh() }
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
    private var deviceMenu: some View {
        Menu {
            Picker(L10n.text("设备"), selection: Binding(get: { model.cloud.deviceId }, set: { model.cloud.deviceId = $0 })) {
                Text(L10n.text("选择手表")).tag("")
                ForEach(model.cloud.devices) { device in Text(device.name).tag(device.id) }
            }
        } label: {
            Label(model.cloud.devices.first(where: { $0.id == model.cloud.deviceId })?.name ?? L10n.text("选择手表"), systemImage: "applewatch")
                .font(PulseTheme.font(size: 12, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(PulseTheme.mint.opacity(0.08), in: Capsule())
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel(L10n.text("设备"))
        .disabled(library.busy)
    }
    private func catalogTab(_ title: String, index: Int) -> some View {
        Button {
            guard tab != index else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { tab = index }
            if library.online && !model.preview && index != 2 && (index == 0 ? library.history.isEmpty : library.featured.isEmpty) { refresh() }
        } label: {
            Text(L10n.text(title))
                .font(PulseTheme.font(size: 12, weight: tab == index ? .semibold : .regular))
                .foregroundStyle(tab == index ? PulseTheme.mint : PulseTheme.secondary)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(tab == index ? PulseTheme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }.buttonStyle(.plain)
            .accessibilityAddTraits(tab == index ? [.isSelected] : [])
            .disabled(library.busy)
    }
    @ViewBuilder private var catalogFeedback: some View {
        if (tab == 0 ? library.history.isEmpty : tab == 1 ? library.featured.isEmpty : library.searchResults.isEmpty) {
            VStack(spacing: 12) {
                if library.busy { ProgressView().controlSize(.small) }
                else { Image(systemName: "square.grid.2x2").font(.system(size: 26)).foregroundStyle(PulseTheme.secondary) }
                Text(L10n.text(library.busy ? "正在加载表盘…" : tab == 0 ? "暂无下载记录" : tab == 1 ? "暂无推荐表盘" : "未找到匹配的表盘，试试其他关键词"))
                    .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 28)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
    private func lookupApp() {
        guard library.online, !library.busy, !model.preview else { return }
        let id = ConnectIQLibrary.appID(from: lookup)
        guard id != nil || ConnectIQService.searchKeywords(from: lookup) != nil else { lookupError = true; return }
        lookupError = false
        searchFocused = false
        if let id { openDetail(id) }
        else { showDetail = false; tab = 2; library.search(lookup) }
    }
    private func openDetail(_ id: String) {
        guard library.online, !library.busy, !model.preview else { return }
        library.select(id)
        showDetail = true
    }

    private var watchFaces: some View {
        ConnectIQSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(L10n.text("手表上的表盘"), systemImage: "applewatch")
                        .font(PulseTheme.font(size: 18, weight: .semibold))
                    Spacer()
                    Button(L10n.text("读取手表表盘")) {
                        guard canReadWatchFaces, let id = connectedUnitID else { return }
                        model.bluetooth.refreshWatchFaces(expectedUnitID: id)
                    }.disabled(!canReadWatchFaces)
                        .buttonStyle(PulseButtonStyle(prominent: canReadWatchFaces))
                }
                if model.bluetooth.isConnected {
                    Text(model.bluetooth.connectedName).foregroundStyle(PulseTheme.secondary)
                    if !model.bluetooth.protocolReady || !model.bluetooth.canSyncFiles {
                        Text(L10n.text("等待手表数据通道就绪")).foregroundStyle(PulseTheme.secondary)
                    } else if model.bluetooth.isTransferringFiles {
                        Text(L10n.text("正在同步，完成后可读取表盘")).foregroundStyle(PulseTheme.secondary)
                    } else if connectedUnitID == nil {
                        if let id = UInt32(model.watchUnitID), id > 0 {
                            Text(L10n.text("云端所选手表与当前连接不同，请在下方选择已连接的手表")).foregroundStyle(.orange)
                        } else {
                            Text(L10n.text("等待读取手表设备信息")).foregroundStyle(PulseTheme.secondary)
                        }
                    }
                }
                if !model.bluetooth.isConnected {
                    HStack(spacing: 12) {
                        Text(L10n.text("连接手表后，可读取并切换手表支持的表盘")).foregroundStyle(PulseTheme.secondary)
                        Spacer()
                        Button(L10n.text("连接手表")) { model.openSettings(.watch) }
                    }.padding(14)
                        .background(PulseTheme.mint.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if model.bluetooth.protocolReady && model.bluetooth.canSyncFiles && !model.bluetooth.isTransferringFiles && !model.bluetooth.watchFaceStatus.isEmpty {
                    Text(L10n.text(model.bluetooth.watchFaceStatus)).font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                }
                if !model.bluetooth.watchFaceOpenStatus.isEmpty {
                    Text(L10n.text(model.bluetooth.watchFaceOpenStatus))
                        .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary).textSelection(.enabled)
                }
                if settingsSaved {
                    Label(L10n.text("配置已保存，手表回读确认一致"), systemImage: "checkmark.circle.fill")
                        .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.mint)
                }
                if !model.bluetooth.installedWatchFaces.isEmpty { installedFaces }
                if !model.bluetooth.watchFaces.isEmpty {
                    Text(L10n.text("可切换表盘")).font(PulseTheme.font(size: 12, weight: .semibold))
                }
                ForEach(model.bluetooth.watchFaces) { face in
                    HStack {
                        Text(face.title)
                        Spacer()
                        if face.isSelected == true { Label(L10n.text("当前表盘"), systemImage: "checkmark.circle.fill").foregroundStyle(PulseTheme.mint) }
                        else {
                            Button(L10n.text("切换到此表盘")) {
                                if let id = connectedUnitID { model.bluetooth.selectWatchFace(face, expectedUnitID: id) }
                            }.disabled(connectedUnitID == nil || model.bluetooth.watchFaceBusy || model.bluetooth.watchFaceOpenBusy || model.bluetooth.connectIQInstallBusy || model.preview || face.isSelected != false)
                            if face.isSelected == nil { Text(L10n.text("当前状态未知")).foregroundStyle(PulseTheme.secondary) }
                        }
                    }
                }
                if model.bluetooth.watchFaceBusy || model.bluetooth.watchFaceOpenBusy { ProgressView().controlSize(.small) }
            }
        }
    }
    private var installedFaces: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let bytes = model.bluetooth.installedWatchFaceAvailableSpace {
                Text(L10n.text("可用空间") + ": " + ByteCountFormatStyle(style: .file, locale: L10n.locale).format(Int64(clamping: bytes)))
                    .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
            }
            ForEach(model.bluetooth.installedWatchFaces) { face in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                    ConnectIQArtwork(url: model.preview ? nil : library.apps[face.id]?.iconURL, width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(library.apps[face.id]?.localizedName ?? face.name).font(PulseTheme.font(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        if library.runtimeAppIDs[face.id] == nil {
                            Text(L10n.text("下载后可从 Mac 打开")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                        }
                        if let bytes = face.fileSize {
                            Text(ByteCountFormatStyle(style: .file, locale: L10n.locale).format(Int64(clamping: bytes)))
                                .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                        }
                    }
                    Spacer()
                    Label(L10n.text("已安装"), systemImage: "checkmark.circle.fill")
                        .font(PulseTheme.font(size: 10)).foregroundStyle(PulseTheme.mint)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(PulseTheme.mint.opacity(0.08), in: Capsule())
                    }
                    HStack(spacing: 8) {
                    Button(L10n.text("在手表打开")) {
                        guard !model.preview, let id = connectedUnitID, face.unitID == id,
                              let runtimeID = library.verifiedRuntimeAppID(appID: face.id) else { return }
                        model.bluetooth.openInstalledWatchFace(face, expectedUnitID: id, runtimeAppID: runtimeID)
                    }.disabled(model.preview || library.runtimeAppIDs[face.id] == nil || !model.bluetooth.canOpenInstalledWatchFace || model.bluetooth.watchFaceBusy
                               || model.bluetooth.watchFaceOpenBusy || model.bluetooth.connectIQInstallBusy || model.bluetooth.isTransferringFiles || connectedUnitID != face.unitID)
                    Button(L10n.text("设置")) { settingsSaved = false; settingsFace = face }
                        .buttonStyle(PulseButtonStyle(prominent: true))
                        .disabled(!canReadWatchFaces || !library.online || UInt32(model.cloud.deviceId) != face.unitID)
                    Spacer(minLength: 0)
                    Button(L10n.text("详情")) { openDetail(face.id) }
                        .disabled(!library.online || library.busy || model.preview)
                    }
                }.padding(14)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
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
            }.frame(height: 68)
        }
        .buttonStyle(PulseButtonStyle(card: true))
        .disabled(!library.online || library.busy || model.preview)
        .help(name)
    }
    private func detailActions(_ app: ConnectIQApp) -> some View {
        HStack(spacing: 10) {
            Button { requestDownload(app) } label: { Label(L10n.text("下载到 Mac"), systemImage: "arrow.down.to.line") }
                .buttonStyle(PulseButtonStyle(prominent: true))
                .disabled(!library.online || library.busy || model.preview || !canDownload(app))
            Button { install(app) } label: { Label(L10n.text("安装到手表"), systemImage: "applewatch") }
                .disabled(preparingInstall || !canInstall(app))
            Spacer(minLength: 0)
            if let url = URL(string: "https://\(model.cloud.region == .china ? "apps.garmin.cn" : "apps.garmin.com")/apps/\(app.id)") {
                Link(destination: url) { Image(systemName: "arrow.up.right.square") }
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
                    Text(L10n.text("安装后可在已安装列表中请求打开")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                }
                if library.localPackage?.appID == app.id && library.runtimeAppIDs[app.id] == nil {
                    Text(L10n.text("本地包暂不支持从 Mac 打开")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
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
        let scope = library.confirmationScope
        preparingInstall = true; watchActionAppID = app.id; watchActionIsInstall = true
        Task { @MainActor in
            defer { preparingInstall = false }
            guard let prepared = await library.prepareInstallation(app, confirmedScope: scope),
                  canInstall(app), library.confirmationScope == scope,
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
        if tab == 0 { library.refreshHistory() }
        else if tab == 1 { library.refreshFeatured() }
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

/// Public artwork requests carry no Garmin authentication headers.
private struct ConnectIQArtwork: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat
    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: min(width * 0.16, 16), style: .continuous))
                    .padding(4)
            case .empty:
                if url != nil { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { placeholder }
            case .failure: placeholder
            @unknown default: placeholder
            }
        }
        .frame(width: width, height: height)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: min(width * 0.24, 20), style: .continuous))
        .accessibilityLabel(L10n.text("表盘预览"))
    }
    private var placeholder: some View {
        Image(systemName: "applewatch").font(.system(size: min(width * 0.4, 36)))
            .foregroundStyle(PulseTheme.secondary.opacity(0.6)).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
