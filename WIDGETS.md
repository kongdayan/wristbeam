# 系统桌面小组件（准备版本）

已准备 WidgetKit 扩展、共享快照、三种尺寸、日夜主题和点击指标打开详细图表的链接。当前 CLT 构建的应用仍为临时签名，**没有安装或注册系统小组件**。浮窗是可用的独立窗口。

## 当前发布范围

0.3.0 只提供健康看板、浮窗和菜单栏三个显示位置，没有系统小组件配置入口，也不定时发布小组件快照。`WidgetExtension/`、共享快照模型、App Group 配置和 URL 链接保留为后续开发资料；Release 构建脚本不嵌入扩展。

扩展代码预备小、中、大尺寸与只读数据展示。系统调度 WidgetKit 刷新，无法保证实时心率逐秒更新；当前实时展示使用浮窗。共享数据设计仅包含选定读数、更新时间、来源和曲线，不包含账号 GUID、密码、令牌或 FIT 文件。

## 将来签名安装

1. 重新设计系统小组件的指标选择入口，并接入当前停用的快照发布流程。这部分尚未恢复和验收。
2. 安装完整 Xcode，在其 Settings → Accounts 添加可签名的 Apple 开发者账号。本机当前没有 Xcode 和签名身份。
3. 打开 `GarminPulse.xcodeproj`，选择 GarminPulse 与 GarminPulseWidget 两个 target 的同一 Development Team。保留相同 App Group：`<TEAM_ID>.cn.wenyankong.garminpulse.shared`。
4. 用 GarminPulse scheme 构建并运行，确认主程序与扩展都已由该团队签名。开发工程预备自动嵌入扩展，面向 macOS 14 及以上；这不代表当前发布包带有扩展。
5. 主程序验证签名团队与 App Group 后才使用系统共享容器。登录和蓝牙由主程序负责，小组件只读共享数据。
6. 在系统添加小组件，分别验收数据共享、刷新、日夜显示与点击进入图表。以上是后续开发流程，尚未完成系统注册和桌面验收。

macOS 支持团队编号前缀的 App Group；无需为这种 macOS 专用标识注册 group，但标识前缀必须匹配应用签名的团队编号。参考 [Apple App Group 文档](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)。

如果修改工程配置，用 `xcodegen generate --spec project.yml` 重新生成。仅检查扩展源代码可运行 `zsh scripts/check-widget.sh`；通过这项检查不代表扩展已签名、嵌入或在系统中注册。
