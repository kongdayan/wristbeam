import SwiftUI

struct WatchWeatherCard: View {
    @ObservedObject var weather: WatchWeatherController
    let preview: Bool

    var body: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(L10n.text("手表天气"), systemImage: "cloud.sun.fill").font(PulseTheme.font(size: 15, weight: .semibold))
                    Spacer()
                    Toggle(L10n.text("同步天气"), isOn: $weather.enabled).toggleStyle(.switch).disabled(preview)
                }
                Picker(L10n.text("天气来源"), selection: $weather.source) {
                    Text("Open-Meteo").tag(WatchWeatherSource.openMeteo)
                    Text(L10n.text("设备云账号")).tag(WatchWeatherSource.garmin)
                }.pickerStyle(.segmented).disabled(preview)
                Text(L10n.text(weather.source == .openMeteo ? "开启后，所选位置将用于查询 Open-Meteo 天气，每 15 分钟更新一次。" : "使用设备云账号获取天气，每 15 分钟更新一次。"))
                    .font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                if weather.source == .openMeteo {
                    Link(L10n.text("天气数据：Open-Meteo · 预警暂不提供"), destination: URL(string: "https://open-meteo.com/")!)
                        .font(PulseTheme.font(size: 11))
                }
                HStack {
                    TextField(L10n.text("输入城市名称"), text: $weather.cityQuery).textFieldStyle(.roundedBorder).onSubmit { weather.searchCity() }
                    Button(L10n.text("查找城市")) { weather.searchCity() }.disabled(weather.locationBusy || preview)
                    Button { weather.locate() } label: { Label(L10n.text("获取当前位置"), systemImage: "location.fill") }.disabled(weather.locationBusy || preview)
                }
                if weather.locationBusy { ProgressView().controlSize(.small) }
                if !weather.locationStatus.isEmpty {
                    Text(L10n.text(weather.locationStatus)).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                }
                ForEach(Array(weather.candidates.enumerated()), id: \.offset) { _, candidate in
                    Button { weather.select(candidate) } label: {
                        HStack { Image(systemName: "mappin.and.ellipse"); Text(candidate.name); Spacer(); Image(systemName: "checkmark.circle") }
                            .frame(maxWidth: .infinity, minHeight: 40).contentShape(Rectangle())
                    }.buttonStyle(PulseRowButtonStyle())
                }
                if let location = weather.location {
                    Label(location.name, systemImage: "mappin.circle.fill").font(PulseTheme.font(size: 12, weight: .medium))
                }
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.text(weather.status)).font(PulseTheme.font(size: 12))
                        if let date = weather.lastDelivered {
                            HStack(spacing: 4) { Text(L10n.text("最近发送")); Text(date, style: .time) }
                                .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                        }
                    }
                    Spacer()
                    if weather.refreshing { ProgressView().controlSize(.small) }
                    Button(L10n.text("更新并发送")) { weather.refresh() }.disabled(!weather.available || weather.refreshing || preview)
                }
                if weather.missingSections.contains(where: { $0 != "alerts" || weather.source == .garmin }) {
                    Text(L10n.text("部分预报或预警暂未获取，将在下次更新时重试。"))
                        .font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
                }
            }
        }
    }
}
