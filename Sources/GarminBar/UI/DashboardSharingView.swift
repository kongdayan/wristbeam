import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DashboardShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var metrics: [SharedMetric]
    @State private var capturedAt = Date()
    @State private var preview: Bool
    @State private var selected: Set<MetricKind>
    @State private var valueOnly: Bool
    @State private var dark = false
    @State private var image: NSImage?
    @State private var pngData: Data?
    @State private var retry = 0
    @State private var saving = false
    @State private var renderedKey = ""
    @State private var error: String?
    @State private var notice = ""

    @MainActor init(model: AppModel, request: DashboardShareRequest) {
        let snapshot: [SharedMetric] = request.kinds.compactMap { kind in
            guard let sample = model.metrics[kind] else { return nil }
            return SharedMetric(kind: kind, value: model.display(kind), updatedAt: sample.timestamp,
                                unavailable: model.isStale(kind) || model.metricNotes[kind] != nil,
                                series: DashboardSharing.sanitizedSeries(model.series(for: kind)))
        }
        _metrics = State(initialValue: snapshot)
        _preview = State(initialValue: model.preview)
        _selected = State(initialValue: Set(request.kinds))
        _valueOnly = State(initialValue: request.valueOnly)
        _dark = State(initialValue: model.preferredColorScheme == .dark)
    }
    private var currentImage: NSImage? { renderedKey == renderKey ? image : nil }
    private var chosen: [SharedMetric] { DashboardSharing.selected(metrics, ids: selected, valueOnly: valueOnly) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("分享健康看板")).font(PulseTheme.font(size: 21, weight: .semibold))
                    Text(L10n.text("仅分享下方预览中的健康数据，不包含账号和设备信息。"))
                        .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                }
                Spacer()
                Button(L10n.text("完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("选择分享内容")).font(PulseTheme.font(size: 13, weight: .semibold))
                    HStack {
                        Button(L10n.text("全部")) { selected = Set(metrics.map(\.kind)); valueOnly = false }
                        Button(L10n.text("清空")) { selected = [] }
                    }.buttonStyle(.bordered)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(metrics) { metric in
                                Button {
                                    if selected.contains(metric.kind) { selected.remove(metric.kind) }
                                    else { if valueOnly { selected = [] }; selected.insert(metric.kind) }
                                } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: selected.contains(metric.kind) ? "checkmark.square.fill" : "square").foregroundStyle(PulseTheme.mint)
                                        Text(metric.kind.title).multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }.padding(.vertical, 7).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityValue(L10n.text(selected.contains(metric.kind) ? "已选择" : "未选择"))
                            }
                        }
                    }.frame(height: 270)
                    Toggle(L10n.text("仅分享单个数值"), isOn: $valueOnly).toggleStyle(.checkbox)
                        .onChange(of: valueOnly) { value in
                            if value, let first = metrics.first(where: { selected.contains($0.kind) }) { selected = [first.kind] }
                        }
                    Toggle(L10n.text("深色画框"), isOn: $dark).toggleStyle(.checkbox)
                    Text(L10n.text("图片保留此刻的数据；关闭后重新打开可获取最新读数。"))
                        .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                }.frame(width: 200)
                ScrollView {
                    if let image = currentImage {
                        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: 490)
                            .accessibilityLabel(L10n.format("分享图片预览，{0} 个指标", String(chosen.count)))
                    } else if chosen.isEmpty {
                        PulseEmptyState(title: "选择分享内容", detail: "选择至少一个指标以预览。", symbol: "photo")
                    } else if let error {
                        VStack(spacing: 12) {
                            PulseNotice(text: error, symbol: "exclamationmark.triangle", warning: true)
                            Button(L10n.text("重新生成图片")) { retry += 1 }
                        }.padding(20).frame(width: 490, height: 250)
                    } else {
                        VStack(spacing: 12) { ProgressView(); Text(L10n.text("正在生成图片…")).font(PulseTheme.font(size: 12)) }
                            .frame(width: 490, height: 250)
                    }
                }.frame(width: 490, height: 445).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
            }
            if !notice.isEmpty { PulseNotice(text: notice, symbol: "checkmark.circle") }
            if currentImage != nil, let error { PulseNotice(text: error, symbol: "exclamationmark.triangle", warning: true) }
            HStack {
                Spacer()
                Button(L10n.text("复制图片")) {
                    guard let image = currentImage else { return }
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.writeObjects([image]) { error = nil; notice = "图片已复制" }
                    else { error = L10n.text("无法复制图片，请尝试保存。") }
                }.disabled(currentImage == nil)
                Button(L10n.text(saving ? "正在保存图片…" : "保存图片…")) { save() }.disabled(currentImage == nil || saving)
                NativeImageShareButton(image: currentImage).frame(width: 95, height: 30).disabled(currentImage == nil)
            }.buttonStyle(.bordered)
        }.padding(24).frame(width: 760)
            .task(id: renderKey) {
                image = nil; pngData = nil; error = nil; notice = ""
                do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
                await render()
            }
    }
    private var renderKey: String { selected.map(\.rawValue).sorted().joined(separator: ",") + "\(valueOnly)-\(dark)-\(retry)" }
    @MainActor private func render() async {
        let key = renderKey
        guard !chosen.isEmpty else { image = nil; return }
        let canvas = DashboardShareCanvas(metrics: chosen, capturedAt: capturedAt, valueOnly: valueOnly, preview: preview, dark: dark)
        let renderer = ImageRenderer(content: canvas.environment(\.colorScheme, dark ? .dark : .light).environment(\.locale, L10n.locale))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { error = L10n.text("图片生成失败，请重试。"); return }
        let data = await Task.detached(priority: .utility) {
            autoreleasepool { NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) }
        }.value
        guard !Task.isCancelled, key == renderKey else { return }
        guard let data else { error = L10n.text("图片生成失败，请重试。"); return }
        image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2))
        pngData = data; renderedKey = key
    }
    @MainActor private func save() {
        guard currentImage != nil, let data = pngData else { return }
        saving = true; error = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "WristBeam-\(GarminHealthMetrics.calendarDate(capturedAt)).png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { saving = false; return }
            Task { @MainActor in
                defer { saving = false }
                do {
                    try await Task.detached(priority: .utility) { try data.write(to: url, options: .atomic) }.value
                    notice = "图片已保存"
                } catch { self.error = L10n.text("保存失败，请选择可写入的位置。") }
            }
        }
    }
}

private struct DashboardShareCanvas: View {
    let metrics: [SharedMetric]
    let capturedAt: Date
    let valueOnly: Bool
    let preview: Bool
    let dark: Bool
    private var columns: Int { valueOnly ? 1 : min(3, metrics.count) }
    private var width: CGFloat { valueOnly ? 480 : CGFloat(columns) * 250 + 88 }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Image(systemName: "waveform.path.ecg").font(.system(size: 26)).foregroundStyle(PulseTheme.mint)
                Text("WristBeam").font(.system(size: 22, weight: .semibold, design: .rounded))
                Spacer()
                Text(capturedAt, format: .dateTime.year().month().day()).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 6) {
                    ForEach(0..<3) { index in Circle().fill([Color.red, .orange, .green][index].opacity(0.65)).frame(width: 8, height: 8) }
                    Spacer()
                    Text(L10n.text(preview ? "演示数据 · 用于功能展示" : "健康看板")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                cardRows
            }.padding(20).background(PulseTheme.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(dark ? 0.13 : 0.9)))
                .shadow(color: .black.opacity(dark ? 0.25 : 0.1), radius: 16, x: 0, y: 10)
            HStack {
                Text(L10n.text("腕上健康，桌面可见。"))
                Spacer()
                Text(capturedAt, format: .dateTime.hour().minute())
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(28).frame(width: width)
            .background(LinearGradient(colors: dark ? [Color(red: 0.08, green: 0.14, blue: 0.18), Color(red: 0.12, green: 0.20, blue: 0.19)] : [Color(red: 0.85, green: 0.95, blue: 0.90), Color(red: 0.92, green: 0.93, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .foregroundStyle(dark ? Color.white : Color.black)
    }
    private var cardRows: some View {
        VStack(spacing: 18) {
            ForEach(0..<((metrics.count + columns - 1) / columns), id: \.self) { row in
                let items = Array(metrics.dropFirst(row * columns).prefix(columns))
                HStack(alignment: .top, spacing: 12) {
                    ForEach(items) { metric in shareCard(metric).frame(maxWidth: .infinity) }
                    ForEach(0..<max(0, columns - items.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                }
            }
        }
    }
    private func shareCard(_ metric: SharedMetric) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                MetricIcon(kind: metric.kind).foregroundStyle(PulseTheme.color(metric.kind))
                Text(metric.kind.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Spacer(minLength: 0)
                if let updated = metric.updatedAt { Text(updated, format: metric.kind.isOvernightHRV ? .dateTime.month().day() : .dateTime.hour().minute()).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(metric.value).font(.system(size: valueOnly ? 64 : 32, weight: .medium, design: .rounded)).monospacedDigit()
                Text(metric.kind.unit).font(.system(size: 11)).foregroundStyle(.secondary)
            }.lineLimit(1).minimumScaleFactor(0.5)
            if metric.unavailable { Text(L10n.text("请留意读数更新时间")).font(.system(size: 11)).foregroundStyle(.secondary) }
            if !valueOnly {
                if metric.kind.isOvernightHRV && metric.kind != .hrvStatus {
                    HRVTrendMiniChart(series: metric.series).frame(height: 54)
                } else if let timeline = metric.kind.timelineKind {
                    MetricMiniChart(series: metric.series, kind: timeline).frame(height: 54)
                } else { Text(L10n.text("当日汇总")).font(.system(size: 11)).foregroundStyle(.secondary).frame(height: 54, alignment: .bottom) }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(PulseTheme.color(metric.kind).opacity(dark ? 0.08 : 0.045), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct NativeImageShareButton: NSViewRepresentable {
    var image: NSImage?
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: L10n.text("系统分享…"), target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        return button
    }
    func updateNSView(_ view: NSButton, context: Context) { context.coordinator.image = image; view.isEnabled = image != nil }
    final class Coordinator: NSObject {
        var image: NSImage?
        var picker: NSSharingServicePicker?
        @objc func share(_ sender: NSButton) {
            guard let image else { return }
            picker = NSSharingServicePicker(items: [image])
            picker?.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
