# Mouse Wake Suppressor

モニターの消灯時に選択した Mouse クラスのデバイスを無効化し、マウスの微振動による再点灯を防ぐ Windows 用ツールです。キーボードで点灯・アンロックしたときにマウスを復旧します。AutoHotkey v2 の UI と、LocalSystem で動く C# サービスで構成します。

## 要件

- Windows 10 version 2004 以降、または Windows 11。[PnPUtil の enable/disable-device の対応 OS](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax)に合わせています。
- .NET Framework 4.x と付属の C# compiler。
- AutoHotkey v2.0 以降。
- インストール、サービスの開始・停止・削除には管理者権限が必要です。通常の UI とマウス操作要求は一般ユーザー権限で使用できます。

Mouse クラス以外は無効化しません。ただしデバイスやドライバ固有の影響は実機で確認してください。AHK とサービスは同時更新が必要です。

## build とテスト

```bat
build.cmd --build
test.cmd --test
```

引数なし、または `--help` ではヘルプを表示します。引数なしの終了コードは `64` です。compiler は既定で `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe` を使用し、`MWS_CSC` で変更できます。build の出力は `__build.log`、テストの compile 出力は `__test_build.log` に保存し、失敗時だけ表示します。外部 test package は不要です。

AHK の構文検証と模擬サービスのテストも実行する場合:

```bat
set "MWS_AHK=C:\path\to\AutoHotkey64.exe"
test.cmd --test
```

テストは `__tests.exe` と一時ディレクトリを作成します。実サービスの開始・停止や実デバイスの変更は行いません。復旧記録のテストは workspace 内の専用ディレクトリを使用し、製品用の ACL 設定を差し替えます。AHK の模擬 endpoint は製品と別名で、終了後に自動停止します。

## 導入と更新

同じフォルダに次の 5 ファイルを配置します。

- `MouseWakeSuppressorService.exe`
- `MouseWakeSuppressor.ahk`
- `MwsClient.ahk`
- `MwsView.ahk`
- `mws_config.ini` (既存設定がある場合)

AHK を起動すると、未インストールの場合はインストール、停止中の場合は開始の確認が表示されます。未設定の場合は接続後にマウス選択画面が開きます。選択内容は INI に保存します。通常の UI 起動に管理者権限は不要です。

更新時は、旧サービスを停止してマウスが復旧したことを確認してから executable と AHK 関連ファイルを入れ替え、サービスと AHK を起動してください。既存の INI を保持します。既存サービスの登録先と更新先が異なる場合は、登録先の確認と再登録が必要です。

管理者の terminal からも管理できます。

```bat
MouseWakeSuppressorService.exe -install
MouseWakeSuppressorService.exe -start
MouseWakeSuppressorService.exe -stop
MouseWakeSuppressorService.exe -restart
MouseWakeSuppressorService.exe -uninstall
```

`/i`、`/u` は従来の alias として維持します。SCM による引数なし起動はサービスとして動作し、対話実行時の引数なし起動はヘルプを表示します。成功は `0`、usage エラーは `64`、権限例外は `77`、その他の管理操作失敗は `74` を返します。build の compiler 不在は `69`、compile 失敗は `65` です。

アンインストールは、停止後に復旧対象が残っている場合、または復旧記録を読めない場合に中止します。復旧記録はアンインストール時にも削除しません。

## 動作

| イベント | 動作 |
|---|---|
| display OFF / Dimmed、セッションロック | 既定 5000 ms 後に無効化 |
| display ON、アンロック、ログオフ | 予約取消と復旧 |
| Win+Shift+M、トレイの状態項目 | 有効なら無効化。それ以外や復旧対象がある場合は復旧 |
| サービス起動 | 設定変更に関係なく復旧記録を処理 |
| サービス停止・OS shutdown | 新規要求を拒否し、予約取消と復旧 |

同じ通知が重なっても予約の期限は延長しません。取消済み callback は世代番号で無効化します。操作は専用 worker が直列に処理し、復旧要求は queue 内の無効化より優先します。実行中の無効化も取消を確認し、後続デバイスの操作を止めます。

AHK はユーザーセッションの display 通知を優先し、console display 通知を fallback に使います。AHK が停止している間は display の変化を検知できませんが、サービスによるセッション通知の処理は継続します。

トレイには `有効 / 無効 / 一部無効 / 状態不明` を表示します。処理中・予約中・エラーは別に表示します。サービス停止と IPC 通信不能も区別します。自動操作の結果も polling で反映します。手動通知は受付時ではなく、該当 request の完了結果に基づいて `全成功 / 部分成功 / 失敗 / 取消` を表示します。

一部の無効化だけが成功した場合、成功したマウスは無効のまま保持します。復旧は成功を確認できた ID だけを完了扱いにし、失敗した ID は再試行できます。もともと外部で無効だったデバイスは新しい復旧対象に取り込みません。そのデバイスは本ツールの復旧後も無効のまま残る場合があります。

## 復旧記録と失敗時の動作

`%ProgramData%\MouseWakeSuppressor\recovery.v1` に、本ツールが復旧すべき ID だけを保存します。ディレクトリとファイルの書き込み権限を LocalSystem と Administrators に限定します。一般ユーザーの UI はこのファイルにアクセスしません。

- 無効化前に全対象を一括記録します。保存できなければ無効化しません。
- 同一ディレクトリの一時ファイルへ write-through で書き、flush 後に atomic replacement します。
- 同じ内容は書き込みません。正常な一括無効化と復旧の一往復では、原則 2 回の記録更新です。初回移行は別です。
- version、ID、checksum を検証します。破損した記録は上書きせず、新規無効化と設定リセットを禁止します。
- 操作前後に [CM_Get_DevNode_Status](https://learn.microsoft.com/en-us/windows/win32/api/cfgmgr32/nf-cfgmgr32-cm_get_devnode_status) で実状態を確認します。未接続・取得失敗・正常起動を確認できない状態は `Unknown` とします。
- `pnputil` の終了コード、timeout、標準出力、標準エラーを結果として保持します。終了コード `50` に特別な成功扱いはありません。
- timeout または取消時は子プロセスを終了・回収してから再確認します。操作後の実状態が不明なら、新規無効化を止めて復旧を待ちます。
- 設定を変更しても復旧対象は失いません。設定リセットは worker 内で復旧を完了してから `[Devices]` だけを削除します。復旧失敗時は設定を保持します。

初回移行では旧 INI の対象を復旧記録へ取り込み、Mouse クラスかどうかを確認して復旧します。旧 `mws_state.txt` は読み書きせず、判断材料にも使用しません。過去に旧 INI から削除された ID は自動復元できません。

OS による強制終了や突然の電源断で復旧が完了しなかった場合は、次回サービス起動時に残った記録を再処理します。記録が破損した場合は、ファイルを保持したまま管理者が対象と実状態を調査してください。ID が分かる場合は管理者の terminal から復旧できます。

```bat
pnputil /enum-devices /class Mouse
pnputil /enable-device "device instance ID"
```

## 設定

```ini
[Devices]
InstanceIds=HID\...|HID\...
Names=マウス A|マウス B

[Service]
AutomaticDisableDelayMs=5000
OperationTimeoutMs=5000
InformationLog=0

[UI]
PollIntervalMs=1000
OperationPollIntervalMs=100
IpcTimeoutMs=500
```

`AutomaticDisableDelayMs` は `0..600000`、`OperationTimeoutMs` は `100..600000` の整数です。不正なサービス設定はエラーとして通知し、その設定での無効化を行いません。設定のリロードはトレイから要求できます。無効化前にも再読込します。進行中の操作の timeout は変更しません。

UI の各値は AHK 起動時に読みます。最小値は通常 polling が `100`、操作待ち polling が `20`、IPC 期限が `100` ms、最大値はすべて `600000` ms です。範囲外は既定値を使用します。サーバー側も各接続に 500 ms の期限を設け、応答しないクライアントを回収します。

`InformationLog=1` のときだけ通常操作の Information ログを出します。Warning / Error は有効で、同じメッセージの再出力を 5 分間抑制します。状態取得はログもファイルも書きません。INI も値が変わった場合だけ保存します。

## IPC

ローカル専用 named pipe `MouseWakeSuppressor-v1` を使用します。一般ユーザーは接続できますが、remote 接続と pipe instance の作成権限は許可しません。操作名は固定で、任意コマンドや executable path は受け付けません。

protocol は UTF-8 の 1 行、tab 区切りです。request は `version / request ID / boot ID / command / 照会する operation ID` の 5 フィールドです。文字列の結果・device 情報は Base64 で encode します。command は `status / enumerate / toggle / enable / disable / schedule / reload / reset` です。変更要求は現在の boot ID が必要です。

response は `version / request ID / boot ID / 受付結果 / 集約状態 / 実行中操作 / 予約 / 停止中 / エラー / operation ID / 操作結果 / メッセージ / デバイス一覧` の 13 フィールドです。デバイス行は `;`、その列は `,` 区切りで、`ID / 名前 / メーカー / 実状態 / 復旧要否 / 操作詳細` を返します。

完了結果は直近 256 件をメモリに保持します。サービス再起動や結果の失効、応答 timeout は成功扱いにしません。AHK は `CreateFile`、overlapped `WriteFile / ReadFile` と `CancelIoEx` を使い、接続から応答完了までを timer で制限します。[CallNamedPipe の timeout は接続待ちにしか適用されない](https://learn.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-callnamedpipew)ため使用しません。

従来の SCM custom command `128..132` は、順に toggle、enable、disable、reload、schedule として同じ worker に接続しています。

## 検証範囲

自動テストでは、成功、部分失敗、開始失敗、timeout、切断、記録保存失敗、起動復旧、移行、設定変更・reset、重複予約、取消 callback、逆方向要求、停止中の受付拒否、IPC version・boot・切断、ログ抑制、書き込み回数を確認します。AHK は構文と模擬サービスによる通信・トレイ表示値・通知判定・応答待ち中の timer 動作を検証します。

実機での消灯・点灯・ロック・アンロック・ログオフ・サービス停止・OS 再起動、製品用 ACL の権限別接続、トレイと通知の実際の見た目は別途確認が必要です。インストール変更や実デバイス操作はユーザーの確認を得て実施してください。OS やドライバ自身の Registry・ログ書き込みは、アプリの書き込みとは分けて測定します。

AHK の自動起動は `shell:startup` に `MouseWakeSuppressor.ahk` のショートカットを配置します。サービスは Automatic (Delayed Start) で登録します。

## ライセンス

MIT License
