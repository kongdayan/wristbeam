import SwiftUI
import AppKit
import Charts

struct ActivityLibraryCard: View {
    @ObservedObject var library: ActivityLibrary
    @State private var selected: GarminActivity?
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
                Text(L10n.text("先浏览摘要，需要时再下载详情或运动文件。"))
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
                        Button { selected = activity } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "figure.run").font(.title3).foregroundStyle(PulseTheme.mint).frame(width: 28)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(activity.name.isEmpty ? activity.type : activity.name).font(PulseTheme.font(size: 14, weight: .medium)).lineLimit(1)
                                    Text((activity.startTimeLocal ?? "—") + " · " + activity.type).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                                }
                                Spacer()
                                if let duration = activity.statistics["duration"] { Text(String(format: "%.0f min", duration / 60)).monospacedDigit() }
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
        .sheet(item: $selected) { item in ActivityDetailSheet(library: library, id: item.id) }
        .onChange(of: library.index.activities.count) { _ in if page * 20 >= matching.count { page = 0 } }
    }
}

private struct ActivityDetailSheet: View {
    @ObservedObject var library: ActivityLibrary
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var exportStatus = ""
    private var summary: GarminActivity? { library.index.activities.first { $0.id == id } }
    private var detail: GarminActivityDetail? { library.detail(id) }
    private var heartPoints: [ActivityHeartPoint] {
        guard let detail, let values = detail.series.first(where: { $0.key == "directHeartRate" })?.values,
              let timestamps = detail.series.first(where: { $0.key == "directTimestamp" })?.values else { return [] }
        var segment = 0
        return values.enumerated().compactMap { index, value in
            guard let value, timestamps.indices.contains(index), let time = timestamps[index], time > 0 else { segment += 1; return nil }
            return ActivityHeartPoint(id: index, time: Date(timeIntervalSince1970: time / 1000), value: value, segment: segment)
        }
    }
    private let statLabels: [(String, String, String)] = [
        ("duration", "时长", "s"), ("distance", "距离", "m"), ("calories", "热量", "kcal"),
        ("averageHR", "平均心率", "bpm"), ("maxHR", "最高心率", "bpm"),
        ("aerobicTrainingEffect", "有氧训练效果", ""), ("anaerobicTrainingEffect", "无氧训练效果", ""),
        ("activityTrainingLoad", "训练负荷", ""), ("steps", "步数", ""), ("totalReps", "重复次数", ""),
        ("activeSets", "训练组数", ""), ("elevationGain", "累计爬升", "m")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("运动详情")).font(PulseTheme.font(size: 22, weight: .semibold))
                Spacer()
                Button(L10n.text("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let summary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(summary.name.isEmpty ? summary.type : summary.name).font(PulseTheme.font(size: 20, weight: .medium)).textSelection(.enabled)
                        Text((summary.startTimeLocal ?? "—") + " · " + summary.type).foregroundStyle(PulseTheme.secondary)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 16) {
                            ForEach(statLabels, id: \.0) { key, label, unit in
                                if let value = (detail?.summary ?? summary).statistics[key] {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(L10n.text(label)).font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                                        Text(String(format: value.rounded() == value ? "%.0f %@" : "%.1f %@", value, unit)).font(PulseTheme.font(size: 18, weight: .medium)).monospacedDigit()
                                    }
                                }
                            }
                        }
                        if detail != nil {
                            Text(L10n.text("详情已下载")).foregroundStyle(PulseTheme.mint)
                            if !heartPoints.isEmpty {
                                Text(L10n.text("心率图表")).font(PulseTheme.font(size: 15, weight: .medium))
                                Chart(heartPoints) { point in
                                    LineMark(x: .value("Time", point.time), y: .value("bpm", point.value), series: .value("Segment", point.segment))
                                        .foregroundStyle(PulseTheme.mint)
                                }.frame(height: 180)
                            }
                            Text(L10n.text("图表为云端缩减采样；完整记录可导出 TCX 或原始文件。"))
                                .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                        } else {
                            Text(L10n.text("当前仅保存摘要。下载详情后可查看图表，AI 也能查询这些数据。"))
                                .font(PulseTheme.font(size: 13)).foregroundStyle(PulseTheme.secondary)
                        }
                        HStack {
                            Button(L10n.text(detail == nil ? "下载详情" : "重新下载详情")) { Task { await library.downloadDetail(id) } }
                                .disabled(!library.online || library.busy)
                            Menu(L10n.text("导出运动")) {
                                Button("JSON") { exportJSON() }
                                ForEach(GarminActivityFormat.allCases) { format in
                                    Button(format.label) { export(format) }
                                        .disabled(!library.online && !library.formats(id).contains(format.rawValue))
                                }
                            }.disabled(library.busy)
                            if library.busy { ProgressView().controlSize(.small) }
                        }.buttonStyle(.bordered)
                        if !library.status.isEmpty { Text(L10n.text(library.status)).foregroundStyle(.orange) }
                        if !exportStatus.isEmpty { Text(L10n.text(exportStatus)).foregroundStyle(PulseTheme.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else { Text(L10n.text("尚未下载这条运动的数据")) }
        }.padding(24).frame(width: 660, height: 570)
    }
    private func save(_ data: Data, extension ext: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "WristBeam-activity-" + id + "." + ext
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: [.atomic]); exportStatus = "已导出运动数据" }
        catch { exportStatus = "无法保存运动数据，请检查可用空间" }
    }
    private func exportJSON() {
        do { save(try library.exportJSON(id), extension: "json") }
        catch { exportStatus = "尚未下载这条运动的数据" }
    }
    private func export(_ format: GarminActivityFormat) {
        Task {
            guard let url = await library.exportFile(id, format: format) else { return }
            do { save(try Data(contentsOf: url), extension: format.fileExtension) }
            catch { exportStatus = "无法保存运动数据，请检查可用空间" }
        }
    }
}

private struct ActivityHeartPoint: Identifiable {
    let id: Int
    let time: Date
    let value: Double
    let segment: Int
}
