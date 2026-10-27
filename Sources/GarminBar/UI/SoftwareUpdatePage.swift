import SwiftUI

struct SoftwareUpdatePage: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var updater: PulseUpdater
    init(model: AppModel) { self.model = model; updater = model.updater }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if updater.validationFixture != nil { Label(L10n.text("本地升级验证 · 未发布测试包"), systemImage: "testtube.2").foregroundStyle(.orange) }
            PulseCard {
                VStack(alignment: .leading, spacing: 16) {
                    PulseFlowLayout(spacing: 12) {
                        Label(L10n.text("腕映"), systemImage: "waveform.path.ecg").font(PulseTheme.font(size: 18, weight: .semibold))
                        Text("v\(updater.displayVersion)").font(PulseTheme.font(size: 15, design: .monospaced))
                    }
                    Text(L10n.text(updater.status)).font(PulseTheme.font(size: 13)).textSelection(.enabled)
                    if let date = updater.lastChecked { Text(L10n.text("上次检查：\(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary) }
                    PulseFlowLayout {
                        Button { Task { await updater.check() } } label: { Label(L10n.text(updater.isChecking ? "正在检查…" : "检查更新"), systemImage: "arrow.triangle.2.circlepath") }
                            .buttonStyle(PulseButtonStyle()).disabled(updater.isChecking || updater.isInstalling || model.preview)
                        if updater.installable { Button(L10n.text("下载并升级")) { updater.requestUpgrade() }.buttonStyle(PulseButtonStyle(prominent: true)).disabled(updater.isInstalling || model.hasActiveFileOperations) }
                        if let repo = updater.parsedRepository { Link(L10n.text("GitHub Releases ↗"), destination: repo.url.appendingPathComponent("releases")) }
                    }
                    if let progress = updater.downloadProgress {
                        ProgressView(value: progress, total: 1).tint(PulseTheme.mint)
                            .accessibilityLabel(L10n.text("下载更新"))
                        HStack {
                            Text(ByteCountFormatter.string(fromByteCount: updater.downloadedBytes, countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: updater.totalDownloadBytes, countStyle: .file))
                                .font(PulseTheme.font(size: 12)).monospacedDigit()
                            Spacer()
                            Button(L10n.text("取消下载")) { updater.cancelDownload() }
                        }
                    } else if updater.isInstalling { ProgressView().controlSize(.small) }
                    if model.hasActiveFileOperations {
                        Text(L10n.text("文件同步结束后即可升级。")).font(PulseTheme.font(size: 12)).foregroundStyle(PulseTheme.secondary)
                    }
                }
            }
            if updater.available, let release = updater.release {
                PulseCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.text("新版本 \(release.tagName)")).font(PulseTheme.font(size: 16, weight: .semibold))
                        Text(L10n.text(release.body ?? "请在 GitHub 查看版本说明")).font(PulseTheme.font(size: 12)).textSelection(.enabled)
                        if !updater.installable { Text(L10n.text("该版本尚未提供适合本机架构且带校验信息的安装包")).foregroundStyle(.orange) }
                        Link(L10n.text("查看版本说明 ↗"), destination: release.htmlURL)
                    }
                }
            }
            PreferenceBlock(title: "更新设置") {
                PreferenceLine(title: "自动检查新版本", note: "启动后检查，运行期间每 12 小时检查一次。发现新版本时提示，确认后才下载和安装。") {
                    Toggle("", isOn: $updater.automaticChecks).labelsHidden().toggleStyle(.switch)
                }
                PreferenceLine(title: "GitHub 仓库，例如 owner/repo") {
                    TextField("owner/repo", text: $updater.repository).textFieldStyle(.roundedBorder).disabled(updater.isChecking || updater.isInstalling)
                }
            }
            if updater.parsedRepository == nil { Text(L10n.text("请输入有效的 GitHub owner/repo 或仓库链接")).foregroundStyle(.orange) }
            Text(L10n.text("升级会保留账户授权、显示设置与本地原始数据，并保留上一版应用用于恢复。")).font(PulseTheme.font(size: 11)).foregroundStyle(PulseTheme.secondary)
        }
    }
}
