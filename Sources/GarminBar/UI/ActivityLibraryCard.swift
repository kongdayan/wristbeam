import SwiftUI
import AppKit

struct ActivitiesPage: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let id = model.selectedActivityID {
                Button { model.selectedActivityID = nil } label: {
                    Label(L10n.text("返回运动记录"), systemImage: "chevron.left")
                        .font(PulseTheme.font(size: 14, weight: .medium)).padding(.vertical, 4)
                }.buttonStyle(.bordered)
                ActivityDetailPage(library: model.activities, id: id).id(id)
            } else {
                Text(L10n.text("运动记录")).font(PulseTheme.font(size: 27, weight: .semibold))
                ActivityLibraryCard(library: model.activities) { model.selectedActivityID = $0 }
            }
        }
    }
}

struct ActivityLibraryCard: View {
    @ObservedObject var library: ActivityLibrary
    let onSelect: (String) -> Void
    @State private var search = ""
    @State private var page = 0
    private var matching: [GarminActivity] {
        library.index.activities.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.type.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(L10n.text("运动库"), systemImage: "figure.run").font(PulseTheme.font(size: 18, weight: .semibold))
                    Spacer()
                    if library.busy { ProgressView().controlSize(.small) }
                    Button { Task { page = 0; await library.loadPage(older: false) } } label: {
                        Label(L10n.text("刷新运动摘要"), systemImage: "arrow.clockwise")
                    }.disabled(!library.online || library.busy)
                }
                Text(L10n.text("打开运动自动加载详情，已下载内容可离线查看。"))
                    .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                HStack {
                    Picker(L10n.text("自动刷新摘要"), selection: $library.refreshMinutes) {
                        Text(L10n.text("关闭")).tag(0)
                        ForEach([15, 30, 60, 180, 360, 1440], id: \.self) { value in
                            Text(L10n.format("每 {0} 分钟", String(value))).tag(value)
                        }
                    }.frame(maxWidth: 310)
                    Spacer()
                    Text(L10n.format("已缓存 {0} 条运动", String(library.index.activities.count)))
                        .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                }
                if !library.online {
                    Text(L10n.text("连接设备云账号后可浏览历史。已下载的内容可离线查看和导出。"))
                        .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                }
                if let refreshed = library.index.refreshedAt {
                    HStack { Text(L10n.text("最近刷新")); Text(refreshed, style: .date); Text(refreshed, style: .time) }
                        .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                }
                if !library.status.isEmpty { Text(L10n.text(library.status)).font(PulseTheme.font(size: 12)).foregroundStyle(.orange) }
                if !library.index.activities.isEmpty {
                    TextField(L10n.text("搜索已缓存的运动名称或类型"), text: $search).textFieldStyle(.roundedBorder)
                        .onChange(of: search) { _ in page = 0 }
                    ForEach(Array(matching.dropFirst(page * 20).prefix(20))) { activity in
                        Button { onSelect(activity.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "figure.run").font(.title3).foregroundStyle(PulseTheme.mint).frame(width: 28)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(activity.name.isEmpty ? activity.type : activity.name).font(PulseTheme.font(size: 14, weight: .medium)).lineLimit(1)
                                    Text((activity.startTimeLocal ?? "—") + " · " + activity.type).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                                }
                                Spacer()
                                if let duration = activity.statistics["duration"] { Text(ActivityMetricCatalog.duration(duration)).monospacedDigit() }
                                if library.hasDetail(activity.id) { Image(systemName: "arrow.down.circle.fill").foregroundStyle(PulseTheme.mint).help(L10n.text("详情已下载")) }
                                Image(systemName: "chevron.right").foregroundStyle(PulseTheme.secondary)
                            }.padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                    HStack {
                        Button(L10n.text("上一页")) { page = max(0, page - 1) }.disabled(page == 0)
                        Button(L10n.text("下一页")) { page += 1 }.disabled((page + 1) * 20 >= matching.count)
                        Spacer()
                        if library.index.reachedEnd { Text(L10n.text("已浏览至历史末尾")).foregroundStyle(PulseTheme.secondary) }
                        else {
                            Button(L10n.text("加载更早的摘要")) { Task { await library.loadPage(older: true) } }
                                .disabled(!library.online || library.busy)
                        }
                    }.font(PulseTheme.font(size: 12))
                }
            }.buttonStyle(.bordered)
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
        }.buttonStyle(.bordered)
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
