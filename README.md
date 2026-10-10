# Mouse Wake Suppressor

モニターの消灯時に選択した Mouse クラスのデバイスを無効化し、マウスの微振動による再点灯を防ぐ Windows 用ツールです。キーボードで点灯・アンロックしたときにマウスを復旧します。AutoHotkey v2 の UI と、LocalSystem で動く C# サービスで構成します。

任意で、active console session のロック中に登録キーボードの入力が 30 秒なければモニター OFF を要求できます。この機能は既定で無効です。初回は消灯なしの入力診断を行ってください。

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

`setup.ahk` を使います。必要な管理操作では UAC dialog が表示されるため、管理者の terminal は不要です。repository からの `install` は、バイナリがない場合、または `build.cmd` や C# build input より古い場合に自動で compile します。配置先は `%USERPROFILE%\.local\mws` です。

```bat
setup.ahk install
setup.ahk status
setup.ahk uninstall
```

`install` は既存設定を上書きせず、service の停止、file 更新、再登録、開始を行います。失敗時は旧 file と旧登録先の rollback を試みます。配置済みの `setup.ahk` は source がないため rebuild せず、既存 binary による再登録と開始だけを行います。`status` は昇格せず、service 状態、登録先、必要 file、build 要否を表示します。`uninstall` は service 登録だけを解除し、配置先の全 file、`mws_config.ini`、`%ProgramData%\MouseWakeSuppressor` の復旧記録を保持します。`shell:startup` は管理しないため、UI は必要に応じて手動で起動してください。

配置先には次の file を配置します。

- `MouseWakeSuppressorService.exe`
- `MouseWakeSuppressor.ahk`
- `MwsClient.ahk`
- `MwsView.ahk`
- `setup.ahk`
- `mws_config.ini` (既存設定がある場合)

AHK を起動すると、未インストールの場合だけインストール確認が表示されます。停止中は `Automatic (Delayed Start)` と競合しないよう dialog を出さず、状態を tray に表示します。必要な場合は tray menu から手動で開始できます。未設定の場合は接続後にマウス選択画面が開きます。選択内容は INI に保存します。通常の UI 起動に管理者権限は不要です。

更新時も repository 側の `setup.ahk install` を実行します。service の登録先が異なる場合は旧登録を解除し、期待する配置先で再登録します。更新済み UI を反映するには、必要に応じて AHK を再起動してください。

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

[LockDisplay]
Enabled=0
IdleTimeoutSeconds=30
RetryIntervalMs=1000
KeyboardInstanceIds=

[UI]
PollIntervalMs=1000
BatteryPollIntervalMs=5000
OperationPollIntervalMs=100
IpcTimeoutMs=500
```

`AutomaticDisableDelayMs` は `0..600000`、`OperationTimeoutMs` は `100..600000` の整数です。不正なサービス設定はエラーとして通知し、その設定での無効化を行いません。設定のリロードはトレイから要求できます。無効化前にも再読込します。進行中の操作の timeout は変更しません。

UI の各値は AHK 起動時に読みます。`PollIntervalMs` は AC 接続時、`BatteryPollIntervalMs` は battery または short-term power 使用時の idle polling 間隔です。既定値はそれぞれ `1000`、`5000` ms です。最小値は idle polling が `100`、操作待ち polling が `20`、IPC 期限が `100` ms、最大値はすべて `600000` ms です。範囲外は既定値を使用します。操作要求と power event は idle polling を待たず処理します。サーバー側も各接続に 500 ms の期限を設け、応答しないクライアントを回収します。

AHK の `Pump()` は one-shot timer で必要な時刻にだけ起動します。管理操作中は 250 ms ごと、IPC cancel の回収中は 50 ms ごとに一時的に確認し、idle 中に固定周期の 20 ms timer は使用しません。

`InformationLog=1` のときだけ通常操作の Information ログを出します。Warning / Error は有効で、同じメッセージの再出力を 5 分間抑制します。状態取得はログもファイルも書きません。INI も値が変わった場合だけ保存します。

## IPC

ローカル専用 named pipe `MouseWakeSuppressor-v1` を使用します。一般ユーザーは接続できますが、remote 接続と pipe instance の作成権限は許可しません。操作名は固定で、任意コマンドや executable path は受け付けません。

protocol version は `2` です。endpoint 名は旧版との接続時に明示的な version mismatch を返すため維持しています。service と AHK file を同時更新し、起動済みの AHK も終了して通常ユーザーで起動し直してください。

protocol は UTF-8 の 1 行、tab 区切りです。request は `version / request ID / boot ID / command / 照会する operation ID` の 5 フィールドです。文字列の結果・device 情報は Base64 で encode します。command は `status / enumerate / keyboards / lock-probe / toggle / enable / disable / schedule / reload / reset` です。変更要求は現在の boot ID が必要です。`keyboards` は選択用の Keyboard クラス一覧を返し、`lock-probe` は 5 分間の入力診断を予約します。診断は `Enabled=0` かつキーボード選択済みの場合だけ受け付け、operation 履歴は作らず受付結果と監視状態で通知します。

response は `version / request ID / boot ID / 受付結果 / 集約状態 / 実行中操作 / 予約 / 停止中 / エラー / operation ID / 操作結果 / メッセージ / デバイス一覧 / LockDisplay 監視状態` の 14 フィールドです。監視状態は Base64 です。デバイス行は `;`、その列は `,` 区切りで、`ID / 名前 / メーカー / 実状態 / 復旧要否 / 操作詳細` を返します。

完了結果は直近 256 件をメモリに保持します。サービス再起動や結果の失効、応答 timeout は成功扱いにしません。AHK は `CreateFile`、overlapped `WriteFile / ReadFile` と `CancelIoEx` を使い、接続から応答完了までを timer で制限します。[CallNamedPipe の timeout は接続待ちにしか適用されない](https://learn.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-callnamedpipew)ため使用しません。

従来の SCM custom command `128..132` は、順に toggle、enable、disable、reload、schedule として同じ worker に接続しています。

## 検証範囲

### ロック中の消灯制御

`LockDisplay` は Windows の idle timeout や対象アプリの起動有無とは独立しています。`IdleTimeoutSeconds` は `1..600` 秒、`RetryIntervalMs` は `1000..600000` ms で、既定値は `30` 秒と `1000` ms です。`Enabled` は `0` または `1`、`KeyboardInstanceIds` は `|` 区切りです。未登録での有効化や不正な設定は監視停止として表示します。設定は独立した監視 thread が 500 ms ごとに再読込し、消灯前の lease 更新でも再確認します。

トレイの「ロック中の消灯設定」で物理キーボードだけを選択します。マウス、device handle のない synthetic input、登録していない virtual keyboard は期限を延長しません。Parsec が登録した物理 keyboard と同じ device として入力を注入する環境では区別を保証できません。必ず入力診断で確認してください。

対象はログオン済みの active console session のロック中です。時計表示と認証画面の間の正常な desktop 切替では期限を延長しません。アンロック中の UAC desktop とログオン前には OFF を要求しません。ロック通知の受信時刻を起点とし、service 再起動時は監視開始から計測します。登録入力だけが期限を更新します。通知や API の処理時間により、要求時刻には遅延が生じます。

service は session 内に同一 executable の LocalSystem helper を起動します。[desktop のアクセス制約](https://learn.microsoft.com/en-us/windows/win32/winstation/desktops)に従って入力 desktop を開き、切替時には受信 thread、window、Raw Input 登録を作り直します。IME などの補助 window によって desktop の再割当が拒否される場合があるため、旧 thread を終了してから新しい thread を割り当てます。正常な切替では入力時刻と期限を維持します。Raw Input は header の device handle だけを読み、文字、キー値、キー列は保存も送信もしません。device interface を SetupAPI で Instance ID に解決し、選択済み ID と比較します。

helper の named pipe は起動ごとに別名で作成し、LocalSystem だけを許可します。service と helper は相互に PID、session、世代を照合します。helper は通常 250 ms ごと、消灯の直前にも lease を更新し、通信断で終了します。service は heartbeat の途絶または異常終了時に helper を回収して再起動します。ロック判定、Raw Input、desktop の監視失敗では OFF を停止し、復旧後に待機時間を数え直します。マウス制御の worker、予約、取消世代は共有しません。

[SC_MONITORPOWER](https://learn.microsoft.com/en-us/windows/win32/menurc/wm-syscommand) の OFF 要求後、[GUID_CONSOLE_DISPLAY_STATE](https://learn.microsoft.com/en-us/windows/win32/power/power-setting-guids) (`6FE69556-704A-47A0-8F24-C28D936FDA47`) の OFF 通知を待ちます。送信成功だけでは消灯成功と表示しません。未確認なら設定間隔で再試行し、3 回以上未確認の場合は Warning を出します。同じ警告は 5 分間抑制します。OFF 後に入力なしで ON / dim 通知を受けた場合は設定間隔の猶予後に再要求し、その間に登録入力を受けた場合は取り消します。物理モニターの消灯は OS / driver に依存します。

### 実機への導入手順

service 更新、ロック、消灯、対象アプリの停止は利用者の確認後に行います。

1. `setup.ahk install` で service と UI file を更新し、AHK を通常ユーザーで起動し直します。`Enabled=0` のまま対象の物理キーボードを選択します。
2. 「消灯せず入力を診断 (5 分間)」を選択してロックします。この診断中は本機能から OFF を送りません。Windows 標準の timeout はそのままです。
3. 登録キーボードの Shift などを押し、1 秒以上待ってからアンロックします。「LockDisplay の監視状態」の前回記録で監視成功と入力時刻の更新を確認します。入力時刻は起動後の単調時計の ms、`0` はその監視期間に登録入力を受信していないことを示します。文字は記録しません。
4. 同じ診断を Parsec のみの入力と、マウスのみの入力で繰り返します。登録入力として記録されないことを確認します。判別できない場合や secure desktop で受信できない場合は `Enabled=0` を維持し、その環境を未対応として扱います。
5. 診断成立後に有効化し、`doaxvv.exe` / Parsec の停止、各単独起動、同時起動、Parsec 接続中を比較します。30 秒の要求、物理消灯、入力なしの再点灯後の再消灯、キー復帰、認証、マウス復旧を確認します。
6. キーボードの再接続、helper の異常終了、service 再起動、期限直前のアンロック、ログオフ、session 切替を確認します。監視異常の表示と、復旧時の新たな待機時間も確認します。

自動テストはロック消灯の期限、対象入力の延長、対象外入力の除外、再点灯の猶予、未確認時の再試行、世代取消、監視復旧後の再計測、設定検証を模擬時刻で確認します。通常 desktop で Raw Input interface と Keyboard クラスの Instance ID を読み取り専用で照合します。LocalSystem helper の secure desktop 上での入力受信、実際の異常終了と再起動、Parsec との識別、物理消灯は実機試験が必要です。

2026-10-05 の実機診断では、`Enabled=0` の入力診断で、利用者による物理キーボードの Shift、Space、Shift、アンロックを実施しました。`Default` と `Winlogon` の両 desktop で登録入力を検出し、切替後も監視を継続しました。初回診断で発生した同一 thread の desktop 再割当エラーは、受信 thread を作り直す修正後には再発せず、アンロック後のマウス復旧も確認しました。この結果は Parsec 入力の除外や物理消灯の確認を含みません。

2026-10-06 には、この PC を Parsec client として別 PC の server に接続した状態で強制消灯を試験しました。desktop 切替時に Raw Input handle の変更を再接続と誤判定して入力時刻を消す問題を修正し、Instance ID が同じ場合は期限を維持、新 desktop の入力を受け取る前に handle を再照合するようにしました。C# 27 テストと AHK テストを通過した修正版で、00:15:50 のロックから 00:16:20 の OFF 要求 1 回と OFF 通知まで約 30 秒でした。利用者が物理消灯、Ctrl 1 回での点灯、アンロックを確認し、記録でも入力時刻の保持とマウス復旧を確認しました。試験後は `Enabled=0` に復元しています。利用者の報告では初回試験でも無入力約 30 秒後の再消灯がありましたが、最初の Shift 1 回で点灯しなかった理由は未特定です。固定キーの確認を誘発しないよう、今後の試験では Ctrl を使用します。入力なしの外因による再点灯後の自動再消灯、実際の helper 異常終了、service 再起動、キーボード再接続は別途実機確認が必要です。

自動テストでは、成功、部分失敗、開始失敗、timeout、切断、記録保存失敗、起動復旧、移行、設定変更・reset、重複予約、取消 callback、逆方向要求、停止中の受付拒否、IPC version・boot・切断、ログ抑制、書き込み回数を確認します。AHK は構文と模擬サービスによる通信・トレイ表示値・通知判定・応答待ち中の timer 動作を検証します。

実機での消灯・点灯・ロック・アンロック・ログオフ・サービス停止・OS 再起動、製品用 ACL の権限別接続、トレイと通知の実際の見た目は別途確認が必要です。インストール変更や実デバイス操作はユーザーの確認を得て実施してください。OS やドライバ自身の Registry・ログ書き込みは、アプリの書き込みとは分けて測定します。

サービスは Automatic (Delayed Start) で登録します。

## ライセンス

MIT License
