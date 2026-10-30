# 连接与权限引导 · Setup

## 中文

1. 打开应用，进入 **设备 → 连接**。打开软件和浏览设备页都不会申请蓝牙或扫描手表。
2. 首次配对：手表长按 MENU → 手机 → 配对手机，关闭心率广播；手机占用连接时，暂时关闭手机蓝牙。点击 **允许蓝牙并查找手表**，在 macOS 提示中允许访问，再选择手表、核对配对码。已保存的手表可直接点击 **连接已配对手表**，无需每次忘记或重新配对。
3. 允许蓝牙后，分别检查蓝牙连接、佳明数据通道、实时读数和文件通道。单独显示“已连接”不能证明原始文件同步已经就绪。没有数据时展开 **连接不上 / 没有数据**。
4. 云账号可选。仅本地使用无需登录；需要云端记录或上传时，到 **设备 → 设备账号** 开启云同步，选择中国或国际区域，再在佳明官方页面登录。账户应与你的手表绑定账户一致。
5. 到 **同步记录** 选择手动或自动上传。实时读数留在本机，云端接收手表生成的原始运动与健康 FIT。新用户默认手动同步；旧版已保存的选择以及已配对用户原先的自动同步默认值保留。
6. 在主窗口侧栏打开 **设置**：在 **显示设置** 调整字体、主题和布局，在 **指标选择** 分别配置看板、浮窗和菜单栏，在 **网络与刷新** 调整刷新频率。新用户默认不弹出空浮窗，按需开启。折叠区的标题整行都可点击；长页面隐藏滚动条，仍支持正常滚动。

**拒绝蓝牙**：在系统设置 → 隐私与安全性 → 蓝牙允许 WristBeam，再回到连接页。受到系统策略限制时需由设备管理员处理；设备账号与 FIT 导入仍可使用。临时签名的新构建可能需要重新允许访问，应用只在主动连接时请求。

**后台运行**：关闭主窗口后，应用继续在菜单栏运行。退出应用、Mac 休眠或关机会暂停即时同步。启动自动连接默认关闭；完成授权与配对后可主动开启。断线重连只恢复你已主动建立的连接，手动断开后停止重连。

**文件夹监测**：选择的文件夹中新增 FIT 会进入本地队列；自动同步开启后上传到当前设备账号，关闭时等待手动同步。可在同步记录中停止监测。

**升级**：检查 GitHub 版本 → 查看版本说明 → 确认下载 → 校验与重启。正在传输时等任务完成；原有账户、数据和显示设置保留，上一版应用可供恢复。

![首次设备连接的中文界面，隔离演示实例](images/device-setup-zh.png)

## English

Open **Devices → Connection** before granting Bluetooth access. Opening the app or browsing this page never asks for access or starts scanning. Prepare the watch with heart-rate broadcast off, click **Allow Bluetooth and find watch**, allow the macOS request, then select and confirm your watch. A saved watch can use **Connect saved watch** without pairing again.

Check the connection, Garmin channel, live readings and original-file channel separately. A cloud account is optional. New installations start in **Local only** mode.

In **Devices → Device account**, turn **Sync with Garmin cloud** off to stop all Garmin cloud requests, including account validation, token renewal, uploads and health-history reads. Already-running requests are cancelled. Saved credentials remain on this Mac for a later reconnect. Watch Bluetooth and local charts continue to work; overnight HRV, seven-day HRV and other cloud-derived records stop updating. This switch does not change separately enabled developer webhooks or GitHub update checks.

In **Sync records**, **Automatically receive watch files** downloads original FIT files to the Mac. **Automatically upload stored files** is separate and is available only when cloud sync is enabled and an account is connected. Turning cloud sync off also turns automatic uploads off. Re-enabling the cloud restores the account without sending the backlog; use **Upload stored files** to send pending files, or explicitly enable automatic uploads. WristBeam verifies the selected account is associated with the source watch before assigning locally collected files. Files already bound to another account remain blocked.

**Local storage** shows the number of original file copies, days of readings and disk usage. Data has no automatic expiry. **Export stored data** saves a ZIP containing deduplicated original FIT files, `watch-readings.csv` and a manifest. CSV contains timestamp, metric ID and value for watch-origin readings only; account credentials, device metadata fields and cloud caches are excluded. Original FIT files remain byte-for-byte intact and may themselves contain device or personal information, so keep exports private. Exporting preserves local originals. **Open local data** opens storage in Finder for manual management; quit the app before modifying it and preserve `auth` and queue metadata if you want to keep accounts and upload history.

Cloud backfill uses original watch-generated FIT files, not synthesized FIT made from live readings. CSV is for personal use and analysis; it cannot recreate Garmin's historical cloud-only records. Folder monitoring applies only to the selected directory and can be stopped here.

Connecting at launch is a separate opt-in and requires previously granted access plus a saved watch. Reconnection restores only a connection you started; manual disconnect stops retries. Closing the window keeps the menu bar app running, while quitting or Mac sleep pauses immediate syncing. Open the separate **Settings** window: use **Display settings** for panels, text size, themes and layout; **Metric selection** for dashboard/panel/menu metrics; and **Network and refresh** for refresh intervals. Click anywhere on a section header to expand it. Long pages scroll normally with their indicators hidden.

If Bluetooth is denied, enable WristBeam in System Settings → Privacy & Security → Bluetooth and retry. A system restriction needs the administrator's help. An ad hoc build may need renewed system authorization after an update. Updates ask for confirmation before download and wait for active transfers to finish.

See [Apple's Bluetooth authorization states](https://developer.apple.com/documentation/corebluetooth/cbmanagerauthorization) and [Garmin's Instinct 2 pairing instructions](https://www8.garmin.com/manuals/webhelp/GUID-31D23DBB-57C2-4DF7-A0C9-8D1A00AB4BE7/EN-US/GUID-4C14822E-F472-4C3A-B33C-BB50407ADDE5.html).

## 下载与离线 / Downloads and offline access

首次使用可按需选择 **连接手表**（实时读数，无需云账号）或 **连接设备账号**（健康与运动历史，无需蓝牙）。

**运动记录 → 下载管理** 显示当前账号的详情和导出副本、格式及占用空间。运动导出先选择保存位置，取消保存不会启动文件下载。移到废纸篓会先确认，可在 Finder 中恢复；运动摘要、账号和手表接收的原始文件继续保留。

**Activities → Downloads** lists the selected account's cached details and exports, formats and disk usage. Choose a save destination before downloading an export. Moving a copy to Trash requires confirmation and can be reversed in Finder; summaries, accounts and original watch files are kept. Open a downloaded workout offline without fetching it again.

The integrated settings, keyboard commands and browsing context are described in [Daily navigation and sync](daily-workflow.md). Experience changes and verification are tracked in the [maintenance record](maintenance/2026-10-26-experience.md).
