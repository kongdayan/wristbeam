import SwiftUI

struct ActivityDownloadsView: View {
    @ObservedObject var library: ActivityLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var pendingRemoval: ActivityDownload?
    private var matching: [ActivityDownload] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.downloads.filter { download in
            let name = library.index.activities.first { $0.id == download.activityID }?.name ?? ""
            return query.isEmpty || name.localizedCaseInsensitiveContains(query) || download.formatLabel.localizedCaseInsensitiveContains(query)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("下载管理")).font(PulseTheme.font(size: 22, weight: .semibold))
                Spacer()
                Button(L10n.text("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(L10n.format("{0} 个下载文件 · {1}", String(library.downloads.count), ByteCountFormatter.string(fromByteCount: library.downloadBytes, countStyle: .file)))
                .font(PulseTheme.font(size: 13, weight: .medium)).monospacedDigit()
            Text(L10n.text("运动详情和导出文件保存在本机。移到废纸篓后可在 Finder 恢复；再次离线查看前需重新下载。手表接收的原始文件不受影响。"))
                .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField(L10n.text("搜索运动或文件格式"), text: $search).textFieldStyle(.roundedBorder)
                if library.scanningDownloads { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("正在读取下载文件…")) }
                Button { Task { await library.refreshDownloads() } } label: {
                    Label(L10n.text("刷新"), systemImage: "arrow.clockwise")
                }.disabled(library.scanningDownloads || library.managingDownloads)
            }
            if !library.status.isEmpty {
                PulseNotice(text: library.status, symbol: library.statusIsError ? "exclamationmark.triangle" : "info.circle", warning: library.statusIsError)
            }
            if matching.isEmpty {
                PulseEmptyState(title: search.isEmpty ? "还没有下载文件" : "没有匹配的文件",
                                detail: search.isEmpty ? "打开运动下载详情，或导出 TCX、GPX 和原始文件后，在这里管理。" : "试试其他运动名称或文件格式。", symbol: "arrow.down.circle")
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(matching) { download in
                        HStack(spacing: 12) {
                            Image(systemName: download.fileExtension == "json" ? "chart.xyaxis.line" : "doc.zipper").foregroundStyle(PulseTheme.mint).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(library.index.activities.first { $0.id == download.activityID }?.name ?? L10n.text("运动记录"))
                                    .font(PulseTheme.font(size: 13, weight: .medium)).lineLimit(2)
                                Text(download.formatLabel + " · " + ByteCountFormatter.string(fromByteCount: download.bytes, countStyle: .file))
                                    .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                            }
                            Spacer()
                            Menu {
                                Button(L10n.text("在 Finder 中显示")) { library.revealDownload(download) }
                                Button(L10n.text("移到废纸篓…"), role: .destructive) { pendingRemoval = download }
                            } label: { Label(L10n.text("文件操作"), systemImage: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).fixedSize()
                                .disabled(library.busy || library.managingDownloads)
                        }.padding(.vertical, 12)
                        Divider()
                    }
                }
            }.frame(minHeight: 180, maxHeight: .infinity)
        }.padding(24).frame(width: 620, height: 540).background(PulseTheme.background)
            .task(id: library.cacheRevision) { await library.refreshDownloads() }
            .confirmationDialog(L10n.text("将下载文件移到废纸篓？"), isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
                if let download = pendingRemoval {
                    Button(L10n.text("移到废纸篓"), role: .destructive) { Task { await library.moveDownloadToTrash(download) }; pendingRemoval = nil }
                }
                Button(L10n.text("取消"), role: .cancel) { pendingRemoval = nil }
            } message: { Text(L10n.text("已下载的这份副本将暂时无法离线使用。运动摘要会保留；可在 Finder 的废纸篓中恢复。")) }
    }
}
