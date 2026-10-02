; Mouse Wake Suppressor: UI、電源通知、期限付き非同期 IPC。
#Requires AutoHotkey v2.0
#SingleInstance Force
#Include MwsClient.ahk
#Include MwsView.ahk

global g_config := A_ScriptDir "\mws_config.ini"
global g_client := MwsClient("MouseWakeSuppressor-v1", Setting("IpcTimeoutMs", 500, 100))
global g_interval := Setting("PollIntervalMs", 1000, 100)
global g_batteryInterval := Setting("BatteryPollIntervalMs", 5000, 100)
global g_fast := Setting("OperationPollIntervalMs", 100, 20)
global g_boot := "", g_pending := 0, g_commands := [], g_next := 0, g_lastTray := ""
global g_handles := [], g_sessionSeen := false, g_sequence := 0, g_admin := 0, g_pumpDue := 0
global g_console := GuidBuffer("{6FE69556-704A-47A0-8F24-C2C28D936FDA}")
global g_session := GuidBuffer("{2B84C20E-AD23-4DDF-93DB-05FFBD7EFCA5}")
global g_powerSource := GuidBuffer("{5D3E9A59-E9D5-4B00-A6BD-FF34FF516548}")
global g_onBattery := OnBatteryPower()
global g_selection := 0
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
startupAction := MwsStartupAction(ServiceState())
if startupAction != ""
    AdminAction(startupAction)
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

; 管理操作だけを昇格し、SCM API を使用するサービス executable に渡す。
AdminAction(command, *) {
    global g_admin
    if g_admin
        return
    if MsgBox("サービスの " command " を実行しますか? (管理者権限が必要です)", "Mouse Wake Suppressor", "YesNo Icon?") != "Yes"
        return
    try {
        Run('*RunAs "' A_ScriptDir '\MouseWakeSuppressorService.exe" -' command, , "Hide", &pid)
        g_admin := DllCall("OpenProcess", "UInt", 0x101000, "Int", 0, "UInt", pid, "Ptr")
        if !g_admin
            throw OSError()
        SchedulePump(250)
    } catch as err {
        MsgBox("管理操作を開始できませんでした: " err.Message, "Mouse Wake Suppressor", "Iconx")
    }
}

; 要求を重複させず、復旧要求は未送信の自動無効化より先に送る。
Request(command, manual := false, *) {
    global g_pending, g_commands, g_next
    if manual && (g_pending || g_commands.Length) {
        TrayTip("先の要求の結果を確認中です。", "Mouse Wake Suppressor")
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

; IPC、polling、管理 process のうち最も近い期限で再開する。
ScheduleNextPump() {
    global g_next, g_admin
    now := DllCall("GetTickCount64", "UInt64")
    delay := g_next > now ? g_next - now : 0
    if g_admin
        delay := Min(delay, 250)
    SchedulePump(delay)
}

; 非同期 IPC と管理 process を監視し、UI thread で待機しない。
Pump() {
    global g_client, g_boot, g_sequence, g_commands, g_pending, g_next, g_interval, g_batteryInterval, g_fast
    global g_admin, g_pumpDue, g_onBattery
    g_pumpDue := 0
    if g_admin {
        wait := DllCall("WaitForSingleObject", "Ptr", g_admin, "UInt", 0)
        if wait = 0 {
            ok := DllCall("GetExitCodeProcess", "Ptr", g_admin, "UInt*", &code := 0)
            DllCall("CloseHandle", "Ptr", g_admin)
            g_admin := 0
            g_next := 0
            TrayTip(ok && code = 0 ? "管理操作が完了しました。" : "管理操作に失敗しました。exit=" code, "Mouse Wake Suppressor")
        } else if wait != 0x102 {
            DllCall("CloseHandle", "Ptr", g_admin)
            g_admin := 0
            TrayTip("管理操作の監視に失敗しました。", "Mouse Wake Suppressor", 2)
        }
    }
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
    g_client.Send("1`t" id "`t" g_boot "`t" command "`t" watch "`n", Receive.Bind(id, command, manual))
    if g_admin
        SchedulePump(250)
}

; 完了通知は送信した request と同じ boot に限定する。
Receive(id, command, manual, text, error) {
    global g_boot, g_pending, g_next, g_fast, g_initialSelection, g_commands
    if error != "" {
        service := ServiceState()
        label := service = 0 ? "サービス未インストール" : service = 1 ? "サービス停止" : service = 2 || service = 3 ? "サービス移行中" : "通信不能"
        ShowTray("Unknown", label " / " error)
        ScheduleNextPump()
        return
    }
    try {
        state := MwsParse(text, id)
        g_boot := state.boot
        completion := MwsCompletion(state, g_pending, command)
        if completion.clear {
            if completion.success && g_pending.command = "reset"
                g_initialSelection := true
            TrayTip(completion.message, "Mouse Wake Suppressor", completion.success ? 1 : 2)
            g_pending := 0
        }
        detail := state.stopping ? "停止処理中" : state.active != "" ? "処理中: " state.active : state.scheduled ? "無効化予約中" : ""
        if state.error != ""
            detail .= " / " state.error
        ShowTray(state.state, detail, state.devices)
        if command = "enumerate" && state.accepted = "Read"
            SelectDevices(state.devices)
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
    A_TrayMenu.Delete()
    A_TrayMenu.Add(label " (Win+Shift+M)", (*) => Request("toggle", true))
    A_TrayMenu.Default := label " (Win+Shift+M)"
    if detail != "" {
        A_TrayMenu.Add(SubStr(detail, 1, 180), (*) => 0)
        A_TrayMenu.Disable(SubStr(detail, 1, 180))
    }
    A_TrayMenu.Add("復旧を再試行", (*) => Request("enable", true))
    A_TrayMenu.Add()
    for index, d in devices {
        item := index ": " d.id " [" d.state "]" (d.recovery ? " 復旧対象" : "")
        A_TrayMenu.Add(item, ShowDevice.Bind(d))
    }
    A_TrayMenu.Add("対象マウスを選択", (*) => Request("enumerate"))
    A_TrayMenu.Add("設定をリロード", (*) => Request("reload", true))
    A_TrayMenu.Add("復旧して設定をリセット", (*) => Request("reset", true))
    A_TrayMenu.Add()
    for action in ["install", "start", "stop", "restart", "uninstall"]
        A_TrayMenu.Add("サービス: " action, AdminAction.Bind(action))
    A_TrayMenu.Add("終了", (*) => ExitApp())
}

; 詳細は必要なときだけ表示し、トレイの短い状態表示と分ける。
ShowDevice(device, *) {
    MsgBox(device.id "`n状態: " device.state "`n復旧対象: " (device.recovery ? "はい" : "いいえ") "`n`n" device.result, "Mouse Wake Suppressor - 操作詳細")
}

; GUI は callback で完了し、固定 Sleep による待機をしない。
SelectDevices(devices) {
    global g_selection, g_config
    if g_selection
        return
    if devices.Length = 0 {
        MsgBox("Mouse クラスのデバイスが見つかりません。", "Mouse Wake Suppressor")
        return
    }
    window := Gui(, "Mouse Wake Suppressor - 対象選択")
    g_selection := window
    window.AddText(, "消灯時に無効化するマウスを選択してください。")
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
        MsgBox("設定保存に失敗しました: " err.Message, "Mouse Wake Suppressor", "Iconx")
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
    global g_handles, g_client, g_admin
    for handle in g_handles
        DllCall("user32\UnregisterPowerSettingNotification", "Ptr", handle)
    if g_client.handle
        DllCall("CancelIoEx", "Ptr", g_client.handle, "Ptr", 0)
    if g_admin
        DllCall("CloseHandle", "Ptr", g_admin)
}
