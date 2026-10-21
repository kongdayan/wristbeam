import SwiftUI
import AppKit

struct ActivitiesPage: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: PulseTheme.sectionSpacing) {
            if let id = model.selectedActivityID {
                PulseBackButton(title: "返回运动记录") { model.goBack() }
                ActivityDetailPage(library: model.activities, id: id).id(id)
            } else {
                Text(L10n.text("运动记录")).font(PulseTheme.font(size: 27, weight: .semibold))
                ActivityLibraryCard(model: model)
            }
        }
    }
}

struct ActivityLibraryCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: ActivityLibrary
    @FocusState private var searchFocused: Bool
    init(model: AppModel) { self.model = model; library = model.activities }
    private var matching: [GarminActivity] { model.activityBrowsing.matching(library.index.activities) }
    private var page: Int { model.activityBrowsing.validPage(count: matching.count) }
    private var state: ActivityListState {
        .resolve(total: library.index.activities.count, matches: matching.count, busy: library.busy,
            failed: !library.status.isEmpty, cloudEnabled: model.cloudSyncEnabled, online: library.online)
    }
    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack { heading; Spacer(); refresh }
                    VStack(alignment: .leading, spacing: 12) { heading; refresh }
                }
                Text(L10n.text("打开运动自动加载详情，已下载内容可离线查看。"))
                    .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                TextField(L10n.text("搜索已缓存的运动名称或类型"), text: Binding(get: { model.activityBrowsing.search }, set: {
                    model.activityBrowsing.search = $0; model.activityBrowsing.page = 0
                })).textFieldStyle(.roundedBorder).focused($searchFocused)
                    .accessibilityIdentifier("activity-search")
                HStack {
                    Text(L10n.format("已缓存 {0} 条运动", String(library.index.activities.count)))
                    Spacer()
                    if let refreshed = library.index.refreshedAt { Text(refreshed, style: .date); Text(refreshed, style: .time) }
                }.font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                if !library.status.isEmpty && !library.index.activities.isEmpty {
                    HStack {
                        Label(L10n.text(library.status), systemImage: "exclamationmark.triangle").foregroundStyle(PulseTheme.warning)
                        Spacer()
                        Button(L10n.text("重试")) { reload() }.disabled(!library.online || library.busy)
                    }.font(PulseTheme.font(size: 12))
                }
                if state == .content {
                    ForEach(model.activityBrowsing.visible(library.index.activities)) { activity in
                        Button { model.selectActivity(activity.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "figure.run").font(.title3).foregroundStyle(PulseTheme.mint).frame(width: 28)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(activity.name.isEmpty ? activity.type : activity.name).font(PulseTheme.font(size: 14, weight: .medium)).lineLimit(2)
                                    Text((activity.startTimeLocal ?? "—") + " · " + activity.type).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                                }
                                Spacer()
                                if let duration = activity.statistics["duration"] { Text(ActivityMetricCatalog.duration(duration)).monospacedDigit() }
                                if library.hasDetail(activity.id) { Image(systemName: "arrow.down.circle.fill").foregroundStyle(PulseTheme.mint).help(L10n.text("详情已下载")) }
                                Image(systemName: "chevron.right").foregroundStyle(PulseTheme.secondary)
                            }.padding(.vertical, 8).padding(.horizontal, 6)
                        }.buttonStyle(PulseRowButtonStyle()).accessibilityIdentifier("activity-" + activity.id)
                        Divider()
                    }
                    HStack {
                        Button(L10n.text("上一页")) { model.activityBrowsing.page = page - 1 }.disabled(page == 0)
                        Text(L10n.format("第 {0} 页", String(page + 1))).monospacedDigit()
                        Button(L10n.text("下一页")) { model.activityBrowsing.page = page + 1 }.disabled((page + 1) * ActivityBrowsingState.pageSize >= matching.count)
                        Spacer()
                    }.font(PulseTheme.font(size: 12))
                } else { emptyState }
                if !library.index.activities.isEmpty && !library.index.reachedEnd {
                    Button(L10n.text("加载更早的摘要")) { Task { await library.loadPage(older: true) } }.disabled(!library.online || library.busy)
                }
                DisclosureGroup(L10n.text("自动刷新摘要")) {
                    Picker(L10n.text("自动刷新摘要"), selection: $library.refreshMinutes) {
                        Text(L10n.text("关闭")).tag(0)
                        ForEach([15, 30, 60, 180, 360, 1440], id: \.self) { Text(L10n.format("每 {0} 分钟", String($0))).tag($0) }
                    }.frame(maxWidth: 310).padding(.top, 8)
                }.font(PulseTheme.font(size: 12))
            }.buttonStyle(PulseButtonStyle())
        }.onChange(of: model.activitySearchRequest) { _ in searchFocused = true }
    }
    private var heading: some View { Label(L10n.text("运动库"), systemImage: "figure.run").font(PulseTheme.font(size: 18, weight: .semibold)) }
    private var refresh: some View {
        HStack {
            if library.busy { ProgressView().controlSize(.small) }
            Button { reload() } label: { Label(L10n.text("刷新运动摘要"), systemImage: "arrow.clockwise") }.disabled(!library.online || library.busy)
        }
    }
    private func reload() { Task { await library.loadPage(older: false) } }
    @ViewBuilder private var emptyState: some View {
        switch state {
        case .noMatches:
            PulseEmptyState(title: "没有匹配的运动", detail: "试试其他名称或类型，或清除搜索查看全部缓存。", symbol: "magnifyingglass") {
                Button(L10n.text("清除搜索")) { model.activityBrowsing.search = ""; model.activityBrowsing.page = 0 }
            }
        case .localOnly:
            PulseEmptyState(title: "暂无缓存的运动摘要", detail: "本地原始文件可在同步记录中查看和导出。浏览云端运动历史可连接设备账号。", symbol: "externaldrive") {
                Button(L10n.text("同步记录")) { model.openSettings(.sync) }
                Button(L10n.text("设备账号")) { model.openSettings(.account) }
            }
        case .signedOut:
            PulseEmptyState(title: "连接账号以浏览运动", detail: "登录设备云账号后，读取运动摘要；详情按需下载。", symbol: "person.crop.circle") {
                Button(L10n.text("连接账户")) { model.openSettings(.account) }
            }
        case .loading:
            PulseEmptyState(title: "正在加载运动数据…", detail: "", symbol: "arrow.clockwise") { ProgressView().controlSize(.small) }
        case .failed:
            PulseEmptyState(title: "运动记录加载失败", detail: library.status, symbol: "exclamationmark.triangle") {
                Button(L10n.text("重试")) { reload() }.disabled(!library.online || library.busy)
            }
        case .empty:
            PulseEmptyState(title: "暂无运动记录", detail: "刷新运动摘要，或先保存一条运动并同步到设备云端。", symbol: "figure.run") {
                Button(L10n.text("刷新运动摘要")) { reload() }.disabled(!library.online || library.busy)
                Button(L10n.text("同步记录")) { model.openSettings(.sync) }
            }
        case .content: EmptyView()
        }
    }
}

struct ActivityDetailPage: View {
    @ObservedObject var library: ActivityLibrary
    let id: String
    @State private var exportStatus = ""
    @State private var exporting = false
    @State private var loading = false
    @State private var window: NSWindow?
    private var summary: GarminActivity? { library.index.activities.first { $0.id == id } }
    private var detail: GarminActivityDetail? { library.detail(id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let summary {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top) { title(summary); Spacer(); actions }
                    VStack(alignment: .leading, spacing: 12) { title(summary); actions }
                }
                if loading || library.busy {
                    HStack { ProgressView().controlSize(.small); Text(L10n.text(exporting ? "正在准备导出文件…" : "正在加载运动数据…")) }
                        .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                }
                if !library.status.isEmpty { Text(L10n.text(library.status)).foregroundStyle(.orange) }
                if !exportStatus.isEmpty { Text(L10n.text(exportStatus)).foregroundStyle(PulseTheme.secondary) }
                if detail == nil && !loading && !library.busy && !library.online {
                    Text(L10n.text("已保存运动摘要；连接云账号后自动加载详情。"))
                        .foregroundStyle(PulseTheme.secondary)
                }
                ActivityDetailContent(summary: detail?.summary ?? summary, detail: detail)
            } else { Text(L10n.text("尚未下载这条运动的数据")) }
        }
        .background(ActivityWindowReader { window = $0 }.frame(width: 0, height: 0))
        .task(id: library.online) {
            loading = true
            await library.openDetail(id)
            loading = false
        }
    }
    private func title(_ summary: GarminActivity) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(summary.name.isEmpty ? summary.type : summary.name)
                .font(PulseTheme.font(size: 24, weight: .semibold)).textSelection(.enabled)
            Text((summary.startTimeLocal ?? "—") + " · " + summary.type)
                .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
        }
    }
    private var actions: some View {
        HStack {
            Button { Task { await library.downloadDetail(id) } } label: {
                Label(L10n.text("刷新详情"), systemImage: "arrow.clockwise")
            }.disabled(!library.online || library.busy || loading || exporting)
            Menu {
                Button("JSON") { export(nil) }
                ForEach(GarminActivityFormat.allCases) { format in
                    Button(format.label) { export(format) }
                        .disabled(!library.online && !library.formats(id).contains(format.rawValue))
                }
            } label: { Label(L10n.text("导出运动"), systemImage: "square.and.arrow.up") }
                .disabled(library.busy || loading || exporting)
        }.buttonStyle(PulseButtonStyle()).fixedSize(horizontal: true, vertical: false)
    }
    private func export(_ format: GarminActivityFormat?) {
        exporting = true; exportStatus = ""
        Task { @MainActor in
            defer { exporting = false }
            do {
                let data: Data
                if let format {
                    guard let url = await library.exportFile(id, format: format) else { return }
                    data = try Data(contentsOf: url)
                } else { data = try library.exportJSON(id) }
                guard let window, window.isVisible else { return }
                let panel = ActivityExportPanel.make(id: id, format: format)
                let response = await withCheckedContinuation { continuation in
                    panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                }
                guard response == .OK, let url = panel.url else { return }
                try data.write(to: url, options: [.atomic])
                exportStatus = "已导出运动数据"
            } catch { exportStatus = "无法保存运动数据，请检查可用空间" }
        }
    }
}

@MainActor enum ActivityExportPanel {
    static func make(id: String, format: GarminActivityFormat?) -> NSSavePanel {
        let panel = NSSavePanel()
        // Dynamic TCX/GPX UTTypes can make NSSavePanel append the extension twice.
        // The downloaded bytes were already validated; keep the suggested name literal.
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "WristBeam-activity-" + id + "." + (format?.fileExtension ?? "json")
        panel.canCreateDirectories = true
        return panel
    }
}

/// Resolve the hosting window, including when more than one app window is open.
private struct ActivityWindowReader: NSViewRepresentable {
    let receive: (NSWindow?) -> Void
    func makeNSView(context: Context) -> WindowView { let view = WindowView(); view.receive = receive; return view }
    func updateNSView(_ nsView: WindowView, context: Context) { nsView.receive = receive }
    final class WindowView: NSView {
        var receive: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.receive?(self?.window) }
        }
    }
}
