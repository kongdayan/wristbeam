# Changelog

## 0.3.5

- Add an opt-in, ten-minute watch-request capture in Device → Connection, with a local JSON export and English/Chinese labels.
- Show weather-request format and forecast hours, message IDs and queued response statuses; redact coordinates and omit all raw payloads, account data and health values.
- Keep the latest 300 diagnostic events, omit routine file traffic, and preserve the existing capability negotiation and protocol responses. Capture does not enable weather service.
- Add regressions for fragmented messages, unsupported replies, privacy, bounded storage, timeout and restart behavior.

## 0.3.4

- Add local-only mode in Device account. Turning cloud sync off cancels Garmin requests and token renewal while preserving the saved session; watch Bluetooth stays available without a cloud login. New installations start locally.
- Separate automatic watch-file receiving from automatic cloud uploading. Re-enabling the cloud does not upload the backlog until explicitly requested or automatic uploads are enabled. Verify account/watch ownership before assigning local files.
- Keep original FIT files and watch readings on the Mac without automatic expiry. Show storage usage, restore local charts without an account, and export deduplicated original FIT plus watch-only CSV in a ZIP. Credentials and cloud caches are excluded.
- Test offline cold start, in-flight cancellation, explicit batch upload, device ownership, account-free file transfer and private-data export using synthetic fixtures in GitHub Actions.

## 0.3.3

- Fix a crash when switching to English or reopening an installed app with English selected. Load translations from the installed application without depending on SwiftPM build resources.
- Keep update recovery as a ZIP archive and remove extracted application copies after validation, preventing duplicate app entries.
- Test the signed, packaged executable in both system languages with the build and source resources unavailable; verify update replacement, cleanup and rollback.

## 0.3.2

- Move watch battery to device information beside connection status, with a battery icon and percentage; exclude it from health selections, cards, sharing and history. Expose the latest battery reading in the developer status API.
- Simplify device, settings, HRV and update pages by removing redundant subtitles and developer-facing notices.
- Keep charts, missing values, connection guidance and actionable errors; update English translations to match.
- Build application packages and showcase images in GitHub Actions.

## 0.3.1

- Group settings into General, Appearance, Metrics, Refresh, Developer, Updates and About with native-sized preference rows.
- Fix localized export filenames and disable all sharing actions for an empty selection.
- Add Compact / Detailed floating views, selectable metric chips, daily or overnight trends and direct metric detail links; hide scroll indicators.
- Add optional read-only MCP and HTTP/HTTPS APIs, Keychain-backed keys, signed coalesced webhooks, a Python SDK and stdio bridge. Disabled by default.

- Add genuine cloud overnight HRV summaries, seven-day average, status, personal baseline and night/history charts; preserve missing fields and record dates.
- Read watch battery through Garmin device-status messages, with periodic refresh and legacy fallback; keep RR separate from unverified live HRV.
- Document sleep, training and other metric coverage gaps explicitly.

- 健康看板改为紧凑立体卡片，更新时间与标题同排，移除重复来源行；手表与云账号状态合并到标题右侧。
- 布局、卡片尺寸、可用指标分组选择和刷新收进“显示样式”，支持全选、全取消、基础选择和整行展开。
- 带壳分享整个看板、所选卡片或单个数值；冻结预览数据，支持日夜画框、复制 PNG、保存与系统分享，不含账号和设备标识。

- 首次打开先展示设置入口；蓝牙在设备页点击授权/连接后启用。启动自动连接需主动开启，并要求已有系统授权和保存的手表；登录和唤醒不绕过首次引导。
- 新用户默认手动上传，原有同步设置保留；补全账号区域、配对排查、文件夹监测、后台运行和升级引导。连接设置在设备页，上传设置在同步记录，指标刷新在显示设置。
- 中文 README 使用中文展示图、说明与原生中文界面，英文 README 保留英文展示。
- 左侧统一为“设备”，内部分“连接”和“设备账号”；账号按设备平台显示，目前仅提供佳明中国／国际账号。
- 品牌更名为腕映 WristBeam，独立于设备厂商；设备页明确当前兼容佳明，其他品牌等待后续扩展。
- 保留原应用标识、账户、图表、FIT 与设置目录；更新仓库只迁移已知旧地址，升级器接受新旧应用包名并保持身份、签名和下载范围校验。

- 菜单栏改为图标与数值，移除文字缩写；身体电量使用原创人形电池，压力用仪表盘、步数用脚印。悬停和辅助功能保留完整指标名与单位。
- 图标在看板、浮窗、详情与配置中保持一致，适配系统菜单栏外观；新增配置窗口的菜单栏入口。
- MIT 许可，中英日韩俄五份 README，真实菜单栏与展开面板、日夜模式、分组配置的产品展示图。
- 设备支持矩阵及 61 项指标目录，明确实机验证和未验证范围。
- PR / 主分支 / Release 复用质量、密钥、编译、原生 XCTest、安装包和 CodeQL 检查；Dependabot、问题表单、贡献与安全指南。
- Apple Silicon、Intel 与 Universal 自动打包，绑定标签、提交、SHA-256 清单和 GitHub 构建来源证明，全部检查通过后发布。

## 0.3.0

- 可用指标按分组列出，一张表分别勾选健康看板、浮窗、菜单栏；支持整组全选/取消与标题整行折叠。
- 没有实际有效读数的项目隐藏，已有选择保留。系统小组件入口暂时移除。
- 修复静息心率的全天趋势入口错误跳到太阳能。
- 支持简体中文、English、跟随系统；语言和字体设置即时生效。
- GitHub Releases 自动检查、版本提示、确认后升级；校验 SHA-256、应用身份、架构、签名并保留前一版。
- 配对教程、设备列表去重与限制、断线恢复、字体缩放、日夜主题、布局和国际账户隔离。
- README 使用真实 Mac 窗口截图，截图数据来自隔离的演示实例。
