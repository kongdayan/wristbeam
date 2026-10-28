# Changelog

## 0.3.11-beta.4 — 2026-10-28

- Improve native popup controls, sidebar selection visibility, keyboard focus and large-text layouts across the integrated settings flow.
- Keep Settings in the main sidebar, with its categories revealed when opened. Use the system accent color for sidebar selection.
- Fit the main window at 760×600 and let content reflow at larger text sizes. Show the current page or metric in the window title.
- Check the compact layout with synthetic Chinese/English, light/dark and enlarged-text native renders.

## 0.3.11-beta.3 — 2026-10-27

- Keep settings inside the main application window. Settings and Command–comma open the remembered category in the existing sidebar/content layout; appearance, metrics, refresh, developer options, updates and About share that navigation.
- Preserve activity search, pagination and scroll position when returning from settings. Attach update confirmations to the main window and keep sheet/modal navigation guards.
- Remove the separate preferences window and validate normal/large-text integrated settings with native synthetic screenshots. Numeric version remains 0.3.11, build 20. The beta 2 validation was cancelled before publication to update an obsolete routing assertion.

## 0.3.11-beta.1 — 2026-10-27

- Adapt dashboard cards, actions and connection status to narrow windows and larger text; keep battery percentages on one line. Preserve Connect IQ, independent preferences and browsing/scroll restoration.
- Offer independent live-watch and cloud-history onboarding. Clarify data origins, timestamps, loading, cancellation and local export results.
- Add account-scoped download management with sizes, Finder reveal and reversible Trash. Keep original watch files and account data.
- Bound Connect IQ artwork decoding/cache use, reuse encoded share images, and improve native share preview feedback and screenshot resource cleanup.
- Publish this preview as a GitHub prerelease, excluded from the stable updater. The app's numeric bundle version is 0.3.11 (build 18); About and Software updates show the beta tag.

## 0.3.10 — 2026-10-23

- Expand Sync settings, Files and uploads, and other sections by clicking anywhere on their header. Keep controls inside expanded sections independent, with consistent borders and hover/focus feedback.
- Align Settings and Open menu bar actions, enlarge utility buttons, and make metric-selection cells easier to click. Scale checkboxes with text size.
- Keep preference controls aligned beside wrapping descriptions and adapt developer actions to narrow windows and larger text. Simplify expanded connection and sync settings.
- Hide scroll indicators across pages, preferences, menu popovers, sharing, Connect IQ, raw metric tables and embedded web pages while preserving scrolling and saved positions.
- Validate native disclosure/selection click targets and scrolling, including macOS 14 window activation, and include native before/after screenshots in the UI review.
- Refresh all five README translations, native showcase images and setup navigation; bring the Japanese, Korean and Russian feature lists up to date.
- Update the pinned checkout and artifact-download GitHub Actions.

## 0.3.9 — 2026-10-21

- Add Connect IQ watch-face management on Mac: text search, store details, package download/install, installed apps and device settings. Updates and reinstalls transfer the package even when the app UUID is already present. Chinese and English interface text follows the app language.
- Separate preferences into their own window, group dashboard metrics, and guide device connection with progressive setup and troubleshooting.
- Unify local-only status across the sidebar, dashboard, menu and sync center. Show stored data without cloud-login or pending-upload prompts when cloud sync is off.
- Keep activity searches, pages and scroll position when returning from details; open details at the top and restore the previous dashboard position on Back. Clear activity browsing context when accounts change.
- Reorganize sync around current status, primary actions and Watch → Local → Cloud. Keep settings, file tools and logs in expandable sections, with useful next actions for activity empty/error states.
- Share button/row feedback and Back controls. Add Command–1…5 navigation, Command–[ Back, Command–F activity search and Command–R refresh, with sheet/modal guards.
- Validate native scroll restoration, independent preferences and sheet keyboard behavior using isolated fixtures. Build/test Apple Silicon and Intel packages in GitHub Actions, with provenance checks and same-commit release artifact reuse.

- Add a “Require access key” switch for MCP and the read-only HTTP API, enabled by default for new and existing configurations. Explicit keyless mode accepts requests without an Authorization header; supplied credentials still enforce validity and client scopes. Show active authentication status and matching client configuration examples.

## 0.3.7

- Manage MCP/API and Webhook keys locally: show, copy, paste/import, export and regenerate keys without Keychain authorization. Offer explicit legacy key import, verify clipboard writes, and surface pending settings and listener errors. Add signed-package credential, clipboard and MCP checks.

- Add a dedicated Activities sidebar: browse paginated workout history, open a record to load details automatically, and optionally refresh summaries on a schedule.
- Read key statistics, interactive charts, heart-rate zones and expandable laps on one scrolling page. Prioritize heart rate, arrange secondary charts responsively and keep full statistics expandable; omit duration curves and zero-only distance graphs without removing their cached/export/API data.
- Export validated TCX, GPX and original ZIP files on demand, or JSON and cached files offline. Fix file-download HTTP 406 errors and duplicate save-panel extensions; report missing GPS tracks clearly.
- Add read-only MCP/REST workout list, detail, series, zones and paginated lap queries, with Python SDK support. AI queries read local caches and do not initiate cloud downloads.
- Keep caches private and account/region scoped; cloud-off cancels activity requests. Cover automatic loading, concurrent opens, cancellation, optional sections, units, offline access and privacy with regression tests.

## 0.3.6

- Add opt-in watch weather with city search, on-demand Mac location, a 15-minute cache and manual resend. Choose Open-Meteo or the connected Garmin cloud account; sources never switch silently.
- Encode current conditions, hourly/daily forecasts and available Garmin alerts as FIT messages over the existing Bluetooth channel, with per-frame acknowledgement, bounded retries and cancellation. Open-Meteo does not provide alerts.
- Keep Garmin weather paused in local-only mode. Independently enabled Open-Meteo uses no Garmin account or credentials.
- Group routine diagnostic messages by direction and type, including counts and last-seen times; retain compatibility with older captures.
- Add weather parser, protocol, transport cancellation and diagnostic classification regressions.

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
