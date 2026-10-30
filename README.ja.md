# WristBeam

Garmin ウォッチを Mac に接続し、健康データやワークアウトを確認する macOS アプリです。データを Mac に保存し、MCP や API で AI アシスタントや自作ツールから利用できます。

[English](README.md) · [简体中文](README.cn.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Русский](README.ru.md)

**[macOS 版をダウンロード](https://github.com/kongdayan/wristbeam/releases/latest/download/WristBeam-macOS-universal.zip)** · [更新履歴](CHANGELOG.md) · [問題を報告](https://github.com/kongdayan/wristbeam/issues)

macOS 13 以降が必要です。Universal アプリなので、Apple Silicon と Intel のどちらの Mac でも同じファイルを使えます。

## はじめに

1. ダウンロードした ZIP を展開し、**WristBeam.app** を **アプリケーション** フォルダに移動します。
2. **Devices → Connection** を開き、画面の案内に従って Bluetooth を許可し、ウォッチをペアリングします。
3. **Dashboard** でデータを確認します。メニューバーやフローティングパネルの表示項目は **Settings** で選べます。

ウォッチのデータをローカルで使うだけならログインは不要です。Garmin のクラウド履歴やファイルのアップロードを使う場合は、**Devices → Device account** でログインし、**Sync records** で同期方法を選びます。

[接続と設定ガイド](docs/SETUP.md)。現在の配布版はアドホック署名で、Apple の公証は受けていません。

![デモデータを使ったダッシュボード、メニューバー、フローティングパネル](docs/images/showcase-hero.webp)

## 主な機能

- **ローカル保存。** ウォッチから運動・健康データの元の FIT ファイルを受信し、Mac に保存・エクスポートします。クラウド同期は任意です。
- **AI と自動化。** 読み取り専用 MCP、HTTP/HTTPS API、Python SDK で保存済みデータを照会できます。Webhook も設定可能で、連携は有効にするまで動作しません。
- **日々の健康状態。** 心拍数、Body Battery、ストレス、歩数や取得できた推移を、ダッシュボード・メニューバー・パネルに表示します。
- **ワークアウトの確認。** 履歴、統計、グラフを開き、データに応じて JSON、TCX、GPX、元ファイルをエクスポートできます。
- **ウォッチフェイスの管理。** Connect IQ で検索し、Bluetooth でインストールして対応する設定を編集します。使用中のフェイスを切り替えられるかどうかは、ウォッチが提供する操作に依存します。

## 対応機種

**Instinct 2 Solar** は実機で確認済みです。他の Garmin 機種やファームウェアは個別の確認が必要です。取得できる指標は機種とデータソースにより異なり、クラウド由来の記録にはログインが必要です。

[対応機種](docs/DEVICES.md) · [指標一覧](docs/METRICS.md) · [検証範囲](VERIFICATION.md)

## ドキュメントと開発

- [設定とトラブルシューティング](docs/SETUP.md)
- [Connect IQ ウォッチフェイス](docs/CONNECTIQ.md)
- [MCP・API・Python SDK](docs/developer/API.md)
- [開発とコントリビュート](CONTRIBUTING.md) · [セキュリティ](SECURITY.md)
- [その他のスクリーンショット](docs/SHOWCASE.md) · [更新履歴](CHANGELOG.md)

[MIT ライセンス](LICENSE)で公開しています。機種の動作報告、修正、翻訳を歓迎します。
