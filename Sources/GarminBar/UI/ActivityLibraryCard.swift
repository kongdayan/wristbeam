import SwiftUI
import AppKit

struct ActivitiesPage: View {
    @ObservedObject var model: AppModel
    @State private var showDownloads = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let id = model.selectedActivityID {
                Button { model.selectedActivityID = nil } label: {
                    Label(L10n.text("返回运动记录"), systemImage: "chevron.left")
                        .font(PulseTheme.font(size: 14, weight: .medium)).padding(.vertical, 4)
                }.buttonStyle(.bordered)
                ActivityDetailPage(library: model.activities, id: id).id(id)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack { Text(L10n.text("运动记录")).font(PulseTheme.font(size: 27, weight: .semibold)); Spacer(); downloadsButton }
                    VStack(alignment: .leading, spacing: 12) { Text(L10n.text("运动记录")).font(PulseTheme.font(size: 27, weight: .semibold)); downloadsButton }
                }
                ActivityLibraryCard(library: model.activities) { model.selectedActivityID = $0 }
                if !model.activities.online {
                    Button(L10n.text("连接设备账号")) { model.openSettings(.account) }.buttonStyle(.bordered)
                }
            }
        }.sheet(isPresented: $showDownloads) { ActivityDownloadsView(library: model.activities) }
    }
    private var downloadsButton: some View {
        Button { showDownloads = true } label: { Label(L10n.text("下载管理"), systemImage: "arrow.down.circle") }.buttonStyle(.bordered)
    }
}

struct ActivityLibraryCard: View {
    @ObservedObject var library: ActivityLibrary
    let onSelect: (String) -> Void
    @State private var search = ""
    @State private var page = 0
    private var matching: [GarminActivity] {
        library.index.activities.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.displayType.localizedCaseInsensitiveContains(query) || $0.type.localizedCaseInsensitiveContains(query) }
    }
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var visiblePage: Int { min(page, max(0, (matching.count - 1) / 20)) }
    private var pageLabel: String {
        L10n.format("第 {0} / {1} 页", String(visiblePage + 1), String(max(1, (matching.count + 19) / 20)))
    }
    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(L10n.text("运动库"), systemImage: "figure.run").font(PulseTheme.font(size: 18, weight: .semibold))
                    Spacer()
                    if library.busy { ProgressView().controlSize(.small) }
                    Button { page = 0; library.requestPage(older: false) } label: {
                        Label(L10n.text("刷新运动摘要"), systemImage: "arrow.clockwise")
                    }.disabled(!library.online || library.busy)
                }
                Text(L10n.text("打开运动查看详情；已下载的数据可离线使用。"))
                    .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                DisclosureGroup(L10n.text("刷新设置")) {
                    Picker(L10n.text("自动刷新摘要"), selection: $library.refreshMinutes) {
                        Text(L10n.text("关闭")).tag(0)
                        ForEach([15, 30, 60, 180, 360, 1440], id: \.self) { value in
                            Text(L10n.format("每 {0} 分钟", String(value))).tag(value)
                        }
                    }.frame(maxWidth: 310)
                }.font(PulseTheme.font(size: 12))
                Text(L10n.format("已缓存 {0} 条运动", String(library.index.activities.count)))
                    .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                if !library.online {
                    Text(L10n.text("连接设备云账号后可浏览历史。已下载的内容可离线查看和导出。"))
                        .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                }
                if let refreshed = library.index.refreshedAt {
                    HStack { Text(L10n.text("最近刷新")); Text(refreshed, style: .date); Text(refreshed, style: .time) }
                        .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                }
                if library.busy {
                    HStack {
                        Text(L10n.text(library.operation)).font(PulseTheme.font(size: 12))
                        Spacer()
                        Button(L10n.text("取消")) { library.cancelRequest() }
                    }
                }
                if !library.status.isEmpty { PulseNotice(text: library.status, symbol: library.statusIsError ? "exclamationmark.triangle" : "checkmark.circle", warning: library.statusIsError) }
                if library.index.activities.isEmpty {
                    PulseEmptyState(title: library.busy ? "正在读取运动记录" : "还没有运动记录",
                                    detail: library.busy ? "记录会显示在这里，你可以继续使用其他页面。" : library.online ? "刷新运动摘要，查看已保存在云端的运动。" : "连接设备账号读取运动历史；蓝牙接收的原始文件可在同步记录中查看。", symbol: "figure.run")
                }
                if !library.index.activities.isEmpty {
                    TextField(L10n.text("搜索已缓存的运动名称或类型"), text: $search).textFieldStyle(.roundedBorder)
                        .onChange(of: search) { _ in page = 0 }
                    if matching.isEmpty {
                        PulseEmptyState(title: "没有匹配的运动", detail: "试试其他名称或类型，或清除搜索。", symbol: "magnifyingglass")
                        Button(L10n.text("清除搜索")) { search = "" }
                    }
                    ForEach(Array(matching.dropFirst(visiblePage * 20).prefix(20))) { activity in
                        Button { onSelect(activity.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: activity.displaySymbol).font(.title3).foregroundStyle(PulseTheme.mint).frame(width: 28)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(activity.name.isEmpty ? activity.displayType : activity.name).font(PulseTheme.font(size: 14, weight: .medium)).lineLimit(1)
                                    Text(activity.displayStartTime + " · " + activity.displayType).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                                }
                                Spacer()
                                if let duration = activity.statistics["duration"] { Text(ActivityMetricCatalog.duration(duration)).monospacedDigit() }
                                if library.hasDetail(activity.id) { Label(L10n.text("已下载"), systemImage: "checkmark.circle").font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.mint) }
                                Image(systemName: "chevron.right").foregroundStyle(PulseTheme.secondary)
                            }.padding(.vertical, 10).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                    HStack {
                        Button(L10n.text("上一页")) { page = max(0, visiblePage - 1) }.disabled(visiblePage == 0)
                        Button(L10n.text("下一页")) { page = visiblePage + 1 }.disabled((visiblePage + 1) * 20 >= matching.count)
                        Text(pageLabel).foregroundStyle(PulseTheme.secondary)
                        Spacer()
                        if library.index.reachedEnd { Text(L10n.text("已浏览至历史末尾")).foregroundStyle(PulseTheme.secondary) }
                        else {
                            Button(L10n.text("加载更早的摘要")) { library.requestPage(older: true) }
                                .disabled(!library.online || library.busy)
                        }
                    }.font(PulseTheme.font(size: 12))
                }
            }.buttonStyle(.bordered)
        }
        .task(id: library.online) {
            if library.online, library.index.refreshedAt == nil { library.requestPage(older: false) }
        }
        .onChange(of: library.index.activities.count) { _ in if page * 20 >= matching.count { page = 0 } }
    }
}

struct ActivityDetailPage: View {
    @ObservedObject var library: ActivityLibrary
    let id: String
    @State private var exportStatus = ""
    @State private var exporting = false
    @State private var loading = false
    @State private var exportTask: Task<Void, Never>?
    @State private var exportFailed = false
    @State private var window: NSWindow?
    private var summary: GarminActivity? { library.index.activities.first { $0.id == id } }
    @State private var cached: GarminActivityDetail?
    @State private var cachedRevision = -1
    private var detail: GarminActivityDetail? { cachedRevision == library.cacheRevision ? cached : nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let summary {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top) { title(summary); Spacer(); actions }
                    VStack(alignment: .leading, spacing: 12) { title(summary); actions }
                }
                if loading || library.busy || exporting {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(L10n.text(exporting ? "正在准备导出文件…" : "正在加载运动数据…"))
                        Spacer()
                        if exporting { Button(L10n.text("取消")) { exportTask?.cancel(); library.cancelRequest() } }
                    }
                        .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                }
                if !library.status.isEmpty { PulseNotice(text: library.status, symbol: library.statusIsError ? "exclamationmark.triangle" : "checkmark.circle", warning: library.statusIsError) }
                if !exportStatus.isEmpty { PulseNotice(text: exportStatus, symbol: exportFailed ? "exclamationmark.triangle" : "checkmark.circle", warning: exportFailed) }
                if detail == nil && !loading && !library.busy && !library.online {
                    Text(L10n.text("已保存运动摘要；连接云账号后自动加载详情。"))
                        .foregroundStyle(PulseTheme.secondary)
                }
                ActivityDetailContent(summary: detail?.summary ?? summary, detail: detail)
            } else { Text(L10n.text("尚未下载这条运动的数据")) }
        }
        .background(ActivityWindowReader { window = $0 }.frame(width: 0, height: 0))
        .task(id: library.cacheRevision) { await readCachedDetail() }
        .task(id: library.online) {
            loading = true
            await readCachedDetail()
            await library.openDetail(id)
            await readCachedDetail()
            loading = false
        }
        .onDisappear { exportTask?.cancel() }
    }
    @MainActor private func readCachedDetail() async {
        let revision = library.cacheRevision
        let value = await library.cachedDetail(id)
        guard !Task.isCancelled, revision == library.cacheRevision else { return }
        cached = value; cachedRevision = revision
    }
    private func title(_ summary: GarminActivity) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(summary.name.isEmpty ? summary.displayType : summary.name)
                .font(PulseTheme.font(size: 24, weight: .semibold)).textSelection(.enabled)
            Text(summary.displayStartTime + " · " + summary.displayType)
                .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
        }
    }
    private var actions: some View {
        PulseFlowLayout {
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
        }.buttonStyle(.bordered)
    }
    private func export(_ format: GarminActivityFormat?) {
        guard let window, window.isVisible else { return }
        exporting = true; exportStatus = ""; exportFailed = false
        exportTask = Task { @MainActor in
            defer { exporting = false }
            let panel = ActivityExportPanel.make(id: id, format: format)
            let response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
            guard response == .OK, let destination = panel.url, !Task.isCancelled else { return }
            do {
                let data: Data
                if let format {
                    guard let url = await library.exportFile(id, format: format), !Task.isCancelled else { return }
                    data = try await Task.detached(priority: .utility) { try Data(contentsOf: url) }.value
                } else { data = try library.exportJSON(id) }
                guard !Task.isCancelled else { return }
                try await Task.detached(priority: .utility) { try data.write(to: destination, options: [.atomic]) }.value
                exportStatus = "已导出运动数据"
            } catch {
                guard !Task.isCancelled else { return }
                exportFailed = true; exportStatus = "无法保存运动数据，请检查可用空间"
            }
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
