# Mouse Wake Suppressor

Windows 10/11 でモニターの電源が切れた後、マウスを少し動かしただけでモニターが点灯してしまう問題を解決するツールです。

## 問題

Windows の電源管理でモニターが自動OFFになった後、マウスの微振動や誤タッチでモニターが再点灯してしまう。デバイスマネージャーで「このデバイスでコンピューターのスタンバイ状態を解除できるようにする」をOFFにしても、モニター電源OFFからの復帰は防げない場合がある。

## 仕組み

モニターの電源がOFFになったタイミングで、マウスデバイスを PnP (Plug and Play) レベルで無効化します。これはデバイスマネージャーで「デバイスを無効にする」のと同等の操作で、HID ドライバごとアンロードされるため、マウス入力が完全に停止します。

- キーボードは無効化しません（ログイン操作に必要なため）
- Logicool Unifying / Bolt のような複合デバイスでも、Mouse クラスのみを無効化するのでキーボード部分は影響を受けません

## アーキテクチャ

| コンポーネント | 役割 |
|---|---|
| MouseWakeSuppressorService.exe | Windows システムサービス。電源イベントの監視と PnP デバイスの有効化/無効化を担当 |
| MouseWakeSuppressor.ahk | フロントエンド。トレイアイコン、設定 GUI、ホットキーを管理しサービスを制御 |

## 動作要件

- OS: Windows 10 / 11
- ランタイム (AHK側): AutoHotkey v2.0 以降 (https://www.autohotkey.com/)
- ランタイム (サービス側): .NET Framework 4.x (Windows 標準搭載)
- 権限: 一般ユーザー権限で動作。サービスのインストール・開始・停止時のみ UAC 昇格プロンプトが表示されます

## ビルド

build.cmd を実行して MouseWakeSuppressorService.exe をビルドします:

    build.cmd

.NET Framework 4.x の csc.exe が使用されます (%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe)。

## インストール

1. AutoHotkey v2 をインストール (https://www.autohotkey.com/)
2. build.cmd を実行して MouseWakeSuppressorService.exe を生成
3. MouseWakeSuppressor.ahk と MouseWakeSuppressorService.exe を同じフォルダに配置

## 使い方

### 起動

MouseWakeSuppressor.ahk をダブルクリックで起動します。UAC ダイアログが表示されたら「はい」を選択してください (管理者権限が必要です)。

初回起動時にサービスが未インストールであれば自動的にインストールを確認するダイアログが表示されます。

### 初回起動時

マウスデバイスの選択画面が表示されます。モニターOFF時に無効化したいマウスデバイスを選択してください。

- デバイス名、ベンダー名 (Manufacturer)、InstanceId が表示されます
- 複数選択可 (Ctrl+クリック)
- 選択結果は mws_config.ini に保存され、次回以降は自動で読み込まれます

### 自動動作

| イベント | 動作 |
|----------|------|
| モニター電源OFF・輝度低下 (電源管理による自動) | マウスを無効化 |
| モニター電源ON (キーボード入力等で復帰) | マウスを有効化 |
| Windows ログオフ | マウスを有効化 |
| サービス停止 | マウスを有効化 |

### ホットキー

| キー | 動作 |
|------|------|
| Win+Shift+M | マウスの有効/無効を手動トグル |
| Shift+Alt+Ctrl+F1 | マウスの有効/無効を手動トグル |

### トレイアイコン (右クリックメニュー)

- マウス状態の表示と切替 - 左ダブルクリックでもトグル可能
- 対象デバイス一覧 - 現在管理しているマウスデバイスを表示
- 設定リセット - mws_config.ini を削除 (再起動で再選択)
- サービスの開始/停止/再起動/アンインストール
- 終了 - 常駐トレイを閉じる (サービスはバックグラウンドで継続動作)

## 安全対策

### サービス強制停止時

サービスが異常終了した場合、マウスが無効のまま残る可能性があります。次回サービス起動時に自動的にマウスデバイスを有効化するリカバリ処理が含まれています。

### マウスが無効のまま操作できなくなった場合

キーボードは常に有効です。以下の方法で復旧できます:

1. キーボードで管理者コマンドプロンプトを起動 (Win -> cmd と入力 -> Ctrl+Shift+Enter)
2. 以下のコマンドでマウスデバイスを有効化:

       pnputil /enable-device "デバイスのInstanceId"

3. InstanceId が分からない場合:

       pnputil /enum-devices /class Mouse

## スタートアップ登録

AHK スクリプト (フロントエンド) は一般ユーザー権限で動作するため、スタートアップフォルダへの追加で自動起動できます。サービス自体は Automatic スタートに設定されているため、Windows 起動時に自動的に開始されます。

推奨: スタートアップフォルダへの登録 (一般権限):

1. Win+R -> shell:startup -> Enter
2. MouseWakeSuppressor.ahk のショートカットをフォルダ内に作成

代替: タスクスケジューラを使う場合:

1. Win+R -> taskschd.msc -> Enter
2. 「タスクの作成」を選択
3. 「全般」タブ:
   - 名前: MouseWakeSuppressor
   - 「最上位の特権で実行する」は不要 (チェックしない)
4. 「トリガー」タブ:
   - 新規 -> 「ログオン時」を選択
5. 「操作」タブ:
   - 新規 -> プログラム: AutoHotkey v2 の AutoHotkey.exe のパス
   - 引数: MouseWakeSuppressor.ahk のフルパス
6. 「条件」タブ:
   - 「コンピューターを AC 電源で使用している場合のみ...」のチェックを外す

## 設定ファイル

mws_config.ini (スクリプトと同じフォルダに自動生成)

    [Devices]
    InstanceIds=HID\VID_046D&PID_C52B&MI_01&Col01\7&...
    Names=HID-compliant mouse

    [Service]
    ; OS起動後に電源監視を開始するまでの遅延秒数 (デフォルト: 0 = 遅延なし)
    ; 例: 600 = 10分後に監視開始 (起動直後のマウス有効化は即実行される)
    ; StartupDelaySec=600

設定をやり直すには、このファイルを削除してスクリプトを再起動してください (トレイメニューの「設定リセット」からも可能)。

## ライセンス

MIT License
