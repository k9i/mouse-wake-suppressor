; Mouse Wake Suppressor: UI、電源通知、期限付き非同期 IPC。
#Requires AutoHotkey v2.0
#SingleInstance Force
#Include MwsClient.ahk
#Include MwsView.ahk

; source からの起動で service と異なる INI を編集しない。
if FileExist(A_ScriptDir "\MouseWakeSuppressorService.cs") {
    MsgBox("ここは開発用の source です。setup.cmd install で配置し、Program Files\MouseWakeSuppressor 内の MouseWakeSuppressor.ahk を起動してください。", "起動先を確認してください")
    ExitApp(64)
}

global g_config := A_ScriptDir "\mws_config.ini"
global g_client := MwsClient("MouseWakeSuppressor-v1", Setting("IpcTimeoutMs", 500, 100))
global g_interval := Setting("PollIntervalMs", 1000, 100)
global g_batteryInterval := Setting("BatteryPollIntervalMs", 5000, 100)
global g_fast := Setting("OperationPollIntervalMs", 100, 20)
global g_boot := "", g_pending := 0, g_commands := [], g_next := 0, g_lastTray := ""
global g_handles := [], g_sessionSeen := false, g_sequence := 0, g_pumpDue := 0
global g_console := GuidBuffer("{6FE69556-704A-47A0-8F24-C28D936FDA47}")
global g_session := GuidBuffer("{2B84C20E-AD23-4DDF-93DB-05FFBD7EFCA5}")
global g_powerSource := GuidBuffer("{5D3E9A59-E9D5-4B00-A6BD-FF34FF516548}")
global g_onBattery := OnBatteryPower()
global g_selection := 0
global g_lockStatus := "接続待ち"
global g_initialSelection := IniRead(g_config, "Devices", "InstanceIds", "") = ""

ShowTray("Unknown", "接続待ち")
OnMessage(0x218, PowerChanged)
for guid in [g_session, g_console, g_powerSource] {
    handle := DllCall("user32\RegisterPowerSettingNotification", "Ptr", A_ScriptHwnd, "Ptr", guid, "UInt", 0, "Ptr")
    if handle
        g_handles.Push(handle)
}
OnExit(Cleanup)
SchedulePump()
#+m::Request("toggle", true)

; 誤設定で polling が停止しないよう、範囲外は既定値に戻す。
Setting(key, fallback, minimum) {
    global g_config
    value := IniRead(g_config, "UI", key, fallback)
    return IsInteger(value) && value >= minimum && value <= 600000 ? Integer(value) : fallback
}

; API 失敗や不明値では省電力側へ倒し、不要な wake-up を増やさない。
OnBatteryPower() {
    status := Buffer(12, 0)
    return !DllCall("kernel32\GetSystemPowerStatus", "Ptr", status, "Int") || MwsAcLineOnBattery(NumGet(status, 0, "UChar"))
}

; SCM API の状態値を使用し、表示言語や sc 出力に依存しない。
ServiceState() {
    scm := DllCall("advapi32\OpenSCManagerW", "Ptr", 0, "Ptr", 0, "UInt", 1, "Ptr")
    if !scm
        return -1
    service := 0
    try {
        service := DllCall("advapi32\OpenServiceW", "Ptr", scm, "Str", "MouseWakeSuppressor", "UInt", 4, "Ptr")
        if !service
            return A_LastError = 1060 ? 0 : -1
        status := Buffer(36, 0)
        if !DllCall("advapi32\QueryServiceStatusEx", "Ptr", service, "Int", 0, "Ptr", status, "UInt", status.Size, "UInt*", &needed := 0)
            return -1
        return NumGet(status, 4, "UInt")
    } finally {
        if service
            DllCall("advapi32\CloseServiceHandle", "Ptr", service)
        DllCall("advapi32\CloseServiceHandle", "Ptr", scm)
    }
}

; 要求を重複させず、復旧要求は未送信の自動無効化より先に送る。
Request(command, manual := false, *) {
    global g_pending, g_commands, g_next
    if manual && (g_pending || g_commands.Length) {
        TrayTip("先の要求の結果を確認中です。", "マウス再点灯防止")
        return
    }
    if command = "enable" {
        retained := []
        for item in g_commands
            if item.command != "schedule"
                retained.Push(item)
        g_commands := retained
        g_commands.InsertAt(1, {command: command, manual: manual})
    } else {
        for item in g_commands
            if !manual && item.command = command
                return
        g_commands.Push({command: command, manual: manual})
    }
    g_next := 0
    SchedulePump()
}

; 最も早い期限だけを one-shot timer に登録し、idle 中の定期 wake-up を避ける。
SchedulePump(delay := 0) {
    global g_pumpDue
    now := DllCall("GetTickCount64", "UInt64")
    requestedDue := now + Max(1, Integer(delay))
    due := MwsEarlierDue(g_pumpDue, requestedDue)
    if due != requestedDue
        return
    g_pumpDue := due
    SetTimer(Pump, -Max(1, due - now))
}

; 次の polling 期限で再開する。
ScheduleNextPump() {
    global g_next
    now := DllCall("GetTickCount64", "UInt64")
    delay := g_next > now ? g_next - now : 0
    SchedulePump(delay)
}

; 非同期 IPC を監視し、UI thread で待機しない。
Pump() {
    global g_client, g_boot, g_sequence, g_commands, g_pending, g_next, g_interval, g_batteryInterval, g_fast
    global g_pumpDue, g_onBattery
    g_pumpDue := 0
    if g_client.busy {
        ; timeout callback 後も CancelIoEx の完了回収まで client が busy のため再確認する。
        SchedulePump(50)
        return
    }
    now := DllCall("GetTickCount64", "UInt64")
    if now < g_next {
        ScheduleNextPump()
        return
    }
    id := DllCall("GetCurrentProcessId") "-" A_TickCount "-" (++g_sequence)
    command := "status"
    manual := false
    if g_commands.Length && g_boot != "" {
        item := g_commands.RemoveAt(1)
        command := item.command
        manual := item.manual
        if manual
            g_pending := {id: id, boot: g_boot, command: command}
    }
    watch := g_pending ? g_pending.id : ""
    g_next := now + MwsPollInterval(g_onBattery, g_pending, g_interval, g_batteryInterval, g_fast)
    g_client.Send("2`t" id "`t" g_boot "`t" command "`t" watch "`n", Receive.Bind(id, command, manual))
}

; 完了通知は送信した request と同じ boot に限定する。
Receive(id, command, manual, text, error) {
    global g_boot, g_pending, g_next, g_fast, g_initialSelection, g_commands
    global g_lockStatus
    if error != "" {
        g_lockStatus := "通信不能: " error
        service := ServiceState()
        label := service = 0 ? "サービス未インストール" : service = 1 ? "サービス停止" : service = 2 || service = 3 ? "サービス移行中" : "通信不能"
        ShowTray("Unknown", label " / " error)
        ScheduleNextPump()
        return
    }
    try {
        state := MwsParse(text, id)
        g_lockStatus := state.lockDisplay
        g_boot := state.boot
        completion := MwsCompletion(state, g_pending, command)
        if completion.clear {
            if completion.success && g_pending.command = "reset"
                g_initialSelection := true
            TrayTip(completion.message, "マウス再点灯防止", completion.success ? 1 : 2)
            g_pending := 0
        }
        detail := state.stopping ? "停止処理中" : state.active != "" ? "処理中: " state.active : state.scheduled ? "無効化予約中" : ""
        if state.error != ""
            detail .= " / " state.error
        detail .= " / 強制消灯: " MwsLockSummary(state.lockDisplay)
        ShowTray(state.state, detail, state.devices)
        if command = "enumerate" && state.accepted = "Read"
            SelectDevices(state.devices)
        if command = "keyboards" && state.accepted = "Read"
            SelectKeyboards(state.devices)
        if command = "lock-probe"
            TrayTip(state.accepted = "Accepted" ? "入力診断を開始しました。5 分以内にロックして確認してください。消灯要求は送りません。" : "入力診断を開始できません。ロック中の強制消灯の監視状態を確認してください。", "ロック中の強制消灯")
        if g_initialSelection && state.active = "" && state.error = "" && state.accepted = "Read" {
            g_initialSelection := false
            Request("enumerate")
        }
        if g_commands.Length && g_boot != ""
            g_next := 0
        if g_pending
            g_next := DllCall("GetTickCount64", "UInt64") + g_fast
        ScheduleNextPump()
    } catch as err {
        ShowTray("Unknown", "protocol エラー: " err.Message)
        ScheduleNextPump()
    }
}

; 表示内容が変わった場合だけトレイを再構築する。
ShowTray(state, detail, devices := []) {
    global g_lastTray
    view := MwsPresentation(state, detail)
    label := view.label
    key := state "|" detail
    for d in devices
        key .= "|" d.id d.state d.recovery d.result
    if key = g_lastTray
        return
    g_lastTray := key
    TraySetIcon("shell32.dll", view.icon)
    A_IconTip := view.tip
    MwsBuildTray(A_TrayMenu, label, detail, devices, TrayRequest, ShowDevice, ShowLockStatus, (*) => ExitApp())
}

; 診断の目的と判定方法を示してから、利用者の操作で開始する。
TrayRequest(command, manual := false, *) {
    if command != "lock-probe" {
        Request(command, manual)
        return
    }
    window := Gui(, "入力診断 - キーボードの確認")
    window.AddText("w640", MwsDiagnosticHelp())
    window.AddButton("Default", "診断を開始").OnEvent("Click", (*) => (Request("lock-probe"), window.Destroy()))
    window.AddButton("x+12", "閉じる").OnEvent("Click", (*) => window.Destroy())
    window.Show()
}

; 詳細は必要なときだけ表示し、トレイの短い状態表示と分ける。
ShowLockStatus(*) {
    global g_lockStatus
    snapshot := g_lockStatus
    window := Gui(, "ロック中の強制消灯 - 監視状態")
    window.AddText("w640", MwsLockExplanation(snapshot, DllCall("GetTickCount64", "UInt64")))
    window.AddText("w640", "表示は開いた時点の情報です。最新の状態は開き直して確認してください。")
    window.AddButton(, "入力診断の手順").OnEvent("Click", (*) => MsgBox(MwsDiagnosticHelp(), "入力診断の手順"))
    window.AddButton("x+12", "技術詳細").OnEvent("Click", (*) => ShowLockDetails(snapshot))
    window.AddButton("x+12 Default", "閉じる").OnEvent("Click", (*) => window.Destroy())
    window.Show()
}

; 調査用の原文を通常表示から分離し、コピー可能な形で残す。
ShowLockDetails(snapshot) {
    window := Gui(, "ロック中の強制消灯 - 技術詳細")
    window.AddEdit("w740 r12 ReadOnly", snapshot)
    window.AddText("w740", "session はログオン session、desktop は入力画面と切替回数です。@ の後と入力時刻は OS 起動後の ms で、0 は未記録です。表示通知は 0=消灯、1=点灯、2=減光、-1=未取得です。")
    window.Show()
}

; 詳細は必要なときだけ表示し、トレイの短い状態表示と分ける。
ShowDevice(device, *) {
    MsgBox(device.id "`n状態: " device.state "`n復旧対象: " (device.recovery ? "はい" : "いいえ") "`n`n" device.result, "マウス再点灯防止 - 操作詳細")
}

; GUI は callback で完了し、固定 Sleep による待機をしない。
SelectDevices(devices) {
    global g_selection, g_config
    if g_selection
        return
    if devices.Length = 0 {
        MsgBox("Mouse クラスのデバイスが見つかりません。", "マウス再点灯防止")
        return
    }
    window := Gui(, "マウス再点灯防止 - 対象マウス")
    g_selection := window
    window.AddText(, "再点灯防止のため、消灯・減光・ロック時に無効化するマウスを選択してください。")
    list := window.AddListView("w820 r12 Checked", ["名前", "メーカー", "状態", "Instance ID"])
    selected := "|" IniRead(g_config, "Devices", "InstanceIds", "") "|"
    for d in devices
        list.Add(InStr(selected, "|" d.id "|") ? "Check" : "", d.name, d.manufacturer, d.state, d.id)
    list.ModifyCol()
    window.AddButton("Default", "保存").OnEvent("Click", SaveSelection.Bind(window, list, devices))
    window.OnEvent("Close", CloseSelection.Bind(window))
    window.Show()
}

; 同じ値は INI に書き戻さず、復旧対象はサービスに保持させる。
SelectKeyboards(devices) {
    global g_selection, g_config
    if g_selection
        return
    window := Gui(, "ロック中の強制消灯 - 設定")
    g_selection := window
    window.AddText(, "無入力時間を監視する物理キーボードを選択してください。入力のたびに消灯までの時間を数え直します。キーボードは無効化しません。")
    window.AddText(, "Parsec などの virtual device は選択せず、初回は消灯要求を送らない入力診断で確認してください。")
    list := window.AddListView("w900 r12 Checked", ["名前", "メーカー", "状態", "Instance ID"])
    selected := "|" IniRead(g_config, "LockDisplay", "KeyboardInstanceIds", "") "|"
    for d in devices
        list.Add(InStr(selected, "|" d.id "|") ? "Check" : "", d.name, d.manufacturer, d.state, d.id)
    list.ModifyCol()
    enabled := window.AddCheckbox(, "ロック中の強制消灯を使う")
    enabled.Value := IniRead(g_config, "LockDisplay", "Enabled", "0") = "1"
    window.AddText(, "消灯までの無入力時間 (秒, 1..600)")
    idle := window.AddEdit("Number w120", IniRead(g_config, "LockDisplay", "IdleTimeoutSeconds", "30"))
    window.AddText(, "消灯要求の再試行間隔 (ms, 1000..600000)")
    retry := window.AddEdit("Number w120", IniRead(g_config, "LockDisplay", "RetryIntervalMs", "1000"))
    window.AddButton("Default", "保存").OnEvent("Click", SaveKeyboards.Bind(window, list, devices, enabled, idle, retry))
    window.OnEvent("Close", CloseSelection.Bind(window))
    window.Show()
}

; 複数キーの更新途中では有効化せず、完成した設定だけを service に使用させる。
SaveKeyboards(window, list, devices, enabled, idle, retry, *) {
    global g_config
    ids := "", row := 0
    while row := list.GetNext(row, "Checked")
        ids .= (ids = "" ? "" : "|") devices[row].id
    problem := MwsLockSettingsError(enabled.Value, ids, idle.Value, retry.Value)
    if problem != "" {
        MsgBox(problem, "ロック中の強制消灯", "Iconx")
        return
    }
    try {
        ; section 単位で置き換え、旧 timeout と新 ID の混在を避ける。
        section := "Enabled=" enabled.Value "`nIdleTimeoutSeconds=" idle.Value "`nRetryIntervalMs=" retry.Value "`nKeyboardInstanceIds=" ids
        IniWrite(section, g_config, "LockDisplay")
        CloseSelection(window)
        Request("reload", true)
    } catch as err {
        MsgBox("設定保存に失敗しました: " err.Message, "ロック中の強制消灯", "Iconx")
    }
}

; 同じ値は INI に書き戻さず、復旧対象はサービスに保持させる。
SaveSelection(window, list, devices, *) {
    global g_config
    ids := "", names := "", row := 0
    while row := list.GetNext(row, "Checked") {
        ids .= (ids = "" ? "" : "|") devices[row].id
        names .= (names = "" ? "" : "|") devices[row].name
    }
    try {
        if IniRead(g_config, "Devices", "InstanceIds", "") != ids
            IniWrite(ids, g_config, "Devices", "InstanceIds")
        if IniRead(g_config, "Devices", "Names", "") != names
            IniWrite(names, g_config, "Devices", "Names")
        CloseSelection(window)
        Request("reload", true)
    } catch as err {
        MsgBox("設定保存に失敗しました: " err.Message, "マウス再点灯防止", "Iconx")
    }
}

; 閉じた GUI の参照を残さず再選択を許可する。
CloseSelection(window, *) {
    global g_selection
    window.Destroy()
    g_selection := 0
}

; OS の GUID parser を使用して endian の取り違えを防ぐ。
GuidBuffer(text) {
    data := Buffer(16, 0)
    if DllCall("ole32\CLSIDFromString", "Str", text, "Ptr", data, "Int") != 0
        throw ValueError("GUID が不正です。")
    return data
}

; session 固有の表示通知を優先し、ON では予約取消と復旧を要求する。
PowerChanged(wParam, lParam, *) {
    global g_session, g_console, g_powerSource, g_sessionSeen, g_onBattery, g_next
    if wParam != 0x8013 || !lParam || NumGet(lParam, 16, "UInt") < 4
        return
    if DllCall("ntdll\RtlCompareMemory", "Ptr", lParam, "Ptr", g_powerSource, "UPtr", 16, "UPtr") = 16 {
        ; short-term power も battery として扱い、AC 以外では wake-up を抑える。
        onBattery := MwsPowerSourceOnBattery(NumGet(lParam, 20, "UInt"))
        if onBattery != g_onBattery {
            g_onBattery := onBattery
            g_next := 0
            SchedulePump()
        }
        return
    }
    if DllCall("ntdll\RtlCompareMemory", "Ptr", lParam, "Ptr", g_session, "UPtr", 16, "UPtr") = 16 {
        g_sessionSeen := true
    } else if DllCall("ntdll\RtlCompareMemory", "Ptr", lParam, "Ptr", g_console, "UPtr", 16, "UPtr") != 16 || g_sessionSeen {
        return
    }
    value := NumGet(lParam, 20, "UInt")
    if value = 1
        Request("enable")
    else if value = 0 || value = 2
        Request("schedule")
}

; 終了時の OS 資源を解放する。保留 I/O の buffer は process 終了まで保持する。
Cleanup(*) {
    global g_handles, g_client
    for handle in g_handles
        DllCall("user32\UnregisterPowerSettingNotification", "Ptr", handle)
    if g_client.handle
        DllCall("CancelIoEx", "Ptr", g_client.handle, "Ptr", 0)
}
