; MouseWakeSuppressor.ahk
; ロック画面中にマウスデバイスを PnP レベルで完全無効化し、
; マウス移動によるモニター点灯を防ぐ AHK v2 スクリプト
; キーボードは無効化しない (ログイン操作に必要なため)
;
; 必要権限: 管理者 (pnputil コマンド実行のため)
; ホットキー: Win+Shift+M → マウスを手動トグル
; トレイアイコン: 右クリック → 状態確認・終了

#Requires AutoHotkey v2.0
#SingleInstance Force

; ──────────────────────────────────────────────
; 管理者昇格チェック
; ──────────────────────────────────────────────
if !A_IsAdmin {
    Run '*RunAs "' A_AhkPath '" "' A_ScriptFullPath '"'
    ExitApp
}

; ──────────────────────────────────────────────
; グローバル変数
; ──────────────────────────────────────────────
global g_devices := []         ; [{id: "HID\...", name: "..."}, ...]
global g_mouseDisabled := false
global g_powerNotifyHandle := 0
global g_guidBuffer := 0      ; GC防止用に参照を保持

; ──────────────────────────────────────────────
; 起動時リカバリ: 前回強制終了で無効のまま残った
; デバイスがあれば有効化する
; ──────────────────────────────────────────────
RecoverDevicesOnStartup()

; ──────────────────────────────────────────────
; 初期化
; ──────────────────────────────────────────────
g_devices := LoadOrDetectDevices()

if g_devices.Length = 0 {
    MsgBox "対象マウスデバイスが選択されませんでした。終了します。",
           "Mouse Wake Suppressor", 0x10
    ExitApp
}

; セッション変更通知を登録 (WM_WTSSESSION_CHANGE = 0x02B1)
OnMessage(0x02B1, HandleSessionChange)
if !DllCall("Wtsapi32.dll\WTSRegisterSessionNotification",
            "ptr", A_ScriptHwnd, "uint", 1) {
    MsgBox "セッション変更通知の登録に失敗しました。",
           "Mouse Wake Suppressor", 0x10
    ExitApp
}

; モニター電源状態の通知を登録 (GUID_CONSOLE_DISPLAY_STATE)
; ディスプレイOFF/ON を検知してマウスを無効化/有効化する
g_guidBuffer := Buffer(16)
NumPut("uint",   0x6FE69556, g_guidBuffer, 0)
NumPut("ushort", 0x704A,     g_guidBuffer, 4)
NumPut("ushort", 0x47A0,     g_guidBuffer, 6)
NumPut("uchar",  0x8F, "uchar", 0x24, "uchar", 0xC2, "uchar", 0x8D,
       "uchar",  0x93, "uchar", 0x6F, "uchar", 0xDA, "uchar", 0x47,
       g_guidBuffer, 8)
g_powerNotifyHandle := DllCall("RegisterPowerSettingNotification",
    "ptr", A_ScriptHwnd, "ptr", g_guidBuffer, "uint", 0, "ptr")
OnMessage(0x218, HandlePowerBroadcast)  ; WM_POWERBROADCAST

OnExit(CleanupOnExit)
UpdateTray()

; ──────────────────────────────────────────────
; ホットキー: Win+Shift+M → 手動トグル
; ──────────────────────────────────────────────
#+m:: {
    if g_mouseDisabled
        EnableMouse()
    else
        DisableMouse()
}

; ──────────────────────────────────────────────
; WM_WTSSESSION_CHANGE ハンドラ
; ──────────────────────────────────────────────
HandleSessionChange(wParam, lParam, msg, hwnd) {
    ; ロック時にはマウスを無効化しない (モニターOFFのみで制御)
    if (wParam = 0x8)       ; WTS_SESSION_UNLOCK
        EnableMouse()
    else if (wParam = 0x6)  ; WTS_SESSION_LOGOFF
        ForceEnableMouse()
}

; ──────────────────────────────────────────────
; WM_POWERBROADCAST ハンドラ
; モニター電源状態: 0=OFF, 1=ON, 2=DIMMED
; ──────────────────────────────────────────────
HandlePowerBroadcast(wParam, lParam, msg, hwnd) {
    if (wParam != 0x8013)  ; PBT_POWERSETTINGCHANGE
        return
    ; POWERBROADCAST_SETTING 構造体:
    ;   +0  GUID (16 bytes)
    ;   +16 DataLength (4 bytes)
    ;   +20 Data (DWORD: display state)
    displayState := NumGet(lParam, 20, "uint")
    if (displayState = 0)       ; ディスプレイ OFF
        DisableMouse()
    else if (displayState = 1)  ; ディスプレイ ON
        EnableMouse()
}

; ──────────────────────────────────────────────
; 起動時リカバリ: 設定ファイルから保存済みデバイスを読み、
; 全て pnputil /enable-device で有効化する
; ──────────────────────────────────────────────
RecoverDevicesOnStartup() {
    configFile := A_ScriptDir "\mws_config.ini"
    savedIds := IniRead(configFile, "Devices", "InstanceIds", "")
    if savedIds = ""
        return
    for id in StrSplit(savedIds, "|") {
        id := Trim(id)
        if id != ""
            RunWait 'cmd.exe /c pnputil /enable-device "' id '"',, "Hide"
    }
}

; ──────────────────────────────────────────────
; 設定ファイルからロードまたは新規検出
; ──────────────────────────────────────────────
LoadOrDetectDevices() {
    configFile := A_ScriptDir "\mws_config.ini"

    ; 保存済みの設定があれば読み込む
    savedIds   := IniRead(configFile, "Devices", "InstanceIds", "")
    savedNames := IniRead(configFile, "Devices", "Names", "")
    if savedIds != "" {
        ids   := StrSplit(savedIds, "|")
        names := StrSplit(savedNames, "|")
        devices := []
        for i, id in ids {
            if Trim(id) = ""
                continue
            name := (i <= names.Length) ? names[i] : id
            devices.Push({id: Trim(id), name: Trim(name)})
        }
        if devices.Length > 0
            return devices
    }

    ; powershell.exe (Windows PowerShell 5.1) でマウスデバイスを列挙
    allDevices := EnumMouseDevices()

    if allDevices.Length = 0 {
        MsgBox "Mouse クラスのデバイスが見つかりませんでした。`n`n"
             . "マウスが接続されているか確認してください。",
               "Mouse Wake Suppressor", 0x10
        return []
    }

    ; 1台だけなら自動選択、複数なら GUI で選択
    if allDevices.Length = 1 {
        SaveDeviceConfig(configFile, allDevices)
        return allDevices
    }
    return SelectDevicesGui(allDevices, configFile)
}

; ──────────────────────────────────────────────
; powershell.exe でマウスクラスのデバイスを列挙
; 出力形式: InstanceId<TAB>FriendlyName (1行1デバイス)
; ──────────────────────────────────────────────
EnumMouseDevices() {
    devices := []
    tmpFile := A_Temp "\mws_enum.txt"
    ps1File := A_Temp "\mws_enum.ps1"

    ; PowerShell スクリプトを一時ファイルに書き出して実行 (エスケープ問題を回避)
    ; 出力形式: InstanceId;;FriendlyName;;Manufacturer;;Status
    try FileDelete(ps1File)
    psScript := "Get-PnpDevice -Class Mouse -PresentOnly"
              . " | ForEach-Object {"
              . " $mfr = (Get-PnpDeviceProperty -InstanceId $_.InstanceId"
              . " -KeyName 'DEVPKEY_Device_Manufacturer' -ErrorAction SilentlyContinue"
              . " ).Data; if (-not $mfr) { $mfr = $_.Manufacturer }"
              . " $_.InstanceId + ';;' + $_.FriendlyName + ';;' + $mfr + ';;' + $_.Status"
              . " } | Set-Content -Path '" tmpFile "' -Encoding UTF8"
    FileAppend(psScript, ps1File)

    RunWait 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' ps1File '"',, "Hide"
    try FileDelete(ps1File)

    if !FileExist(tmpFile)
        return devices
    content := FileRead(tmpFile)
    try FileDelete(tmpFile)

    for line in StrSplit(content, "`n") {
        line := Trim(line, "`r `t")
        if line = ""
            continue
        parts := StrSplit(line, ";;")
        id   := (parts.Length >= 1) ? parts[1] : ""
        name := (parts.Length >= 2) ? parts[2] : id
        mfr  := (parts.Length >= 3) ? parts[3] : ""
        stat := (parts.Length >= 4) ? parts[4] : ""
        if id != ""
            devices.Push({id: id, name: name, manufacturer: mfr, status: stat})
    }
    return devices
}

; ──────────────────────────────────────────────
; GUI でデバイスを選択させる
; ──────────────────────────────────────────────
SelectDevicesGui(allDevices, configFile) {
    gw := Gui("+AlwaysOnTop", "Mouse Wake Suppressor — デバイス選択")
    gw.SetFont("s10")
    gw.Add("Text",, "モニターOFF時に無効化するマウスデバイスを選択してください。`n(複数選択可: Ctrl+クリック)")

    displayList := []
    for d in allDevices {
        label := d.name
        if d.manufacturer != ""
            label .= "  (" d.manufacturer ")"
        label .= "  [" d.status "]  " d.id
        displayList.Push(label)
    }
    lb := gw.Add("ListBox", "r10 w600 Multi", displayList)

    gw.Add("Text", "y+8", "選択は設定ファイルに保存されます。再選択するには mws_config.ini を削除。")
    btnOk := gw.Add("Button", "Default w80 y+8", "OK")
    btnCancel := gw.Add("Button", "xp+90 yp", "キャンセル")

    selected := []
    cancelled := false

    btnOk.OnEvent("Click", (*) => (selected := lb.Value, gw.Destroy()))
    btnCancel.OnEvent("Click", (*) => (cancelled := true, gw.Destroy()))
    gw.OnEvent("Close", (*) => (cancelled := true))

    gw.Show()
    while WinExist("Mouse Wake Suppressor — デバイス選択")
        Sleep 100

    if cancelled || selected.Length = 0
        return []

    devices := []
    for idx in selected
        devices.Push(allDevices[idx])

    SaveDeviceConfig(configFile, devices)
    return devices
}

; ──────────────────────────────────────────────
; 設定ファイルに保存
; ──────────────────────────────────────────────
SaveDeviceConfig(configFile, devices) {
    ids := ""
    names := ""
    for i, d in devices {
        ids   .= (i > 1 ? "|" : "") d.id
        names .= (i > 1 ? "|" : "") d.name
    }
    IniWrite(ids,   configFile, "Devices", "InstanceIds")
    IniWrite(names, configFile, "Devices", "Names")
}

; ──────────────────────────────────────────────
; マウスデバイスを PnP レベルで無効化
; ──────────────────────────────────────────────
DisableMouse() {
    global g_mouseDisabled
    if g_mouseDisabled
        return
    for d in g_devices
        RunWait 'cmd.exe /c pnputil /disable-device "' d.id '"',, "Hide"
    g_mouseDisabled := true
    UpdateTray()
}

; ──────────────────────────────────────────────
; マウスデバイスを PnP レベルで有効化
; ──────────────────────────────────────────────
EnableMouse() {
    global g_mouseDisabled
    if !g_mouseDisabled
        return
    for d in g_devices
        RunWait 'cmd.exe /c pnputil /enable-device "' d.id '"',, "Hide"
    g_mouseDisabled := false
    UpdateTray()
}

; ──────────────────────────────────────────────
; 強制有効化 (終了時用: フラグを無視して必ず有効化)
; ──────────────────────────────────────────────
ForceEnableMouse() {
    for d in g_devices
        RunWait 'cmd.exe /c pnputil /enable-device "' d.id '"',, "Hide"
}

; ──────────────────────────────────────────────
; トレイアイコンとメニューを更新
; ──────────────────────────────────────────────
UpdateTray() {
    global g_mouseDisabled, g_devices

    if g_mouseDisabled {
        TraySetIcon "shell32.dll", 131
        A_IconTip := "Mouse Wake Suppressor [マウス無効]`nWin+Shift+M で有効化"
    } else {
        TraySetIcon "shell32.dll", 18
        A_IconTip := "Mouse Wake Suppressor [マウス有効]`nWin+Shift+M で無効化"
    }

    A_TrayMenu.Delete()

    if g_mouseDisabled {
        A_TrayMenu.Add("● マウス: 無効中  → 有効化", (*) => EnableMouse())
        A_TrayMenu.Default := "● マウス: 無効中  → 有効化"
    } else {
        A_TrayMenu.Add("○ マウス: 有効  → 無効化", (*) => DisableMouse())
        A_TrayMenu.Default := "○ マウス: 有効  → 無効化"
    }
    A_TrayMenu.Add()

    ; デバイス一覧
    for d in g_devices {
        label := "  " d.name
        if d.HasProp("manufacturer") && d.manufacturer != ""
            label .= " (" d.manufacturer ")"
        A_TrayMenu.Add(label, (*) => 0)
        A_TrayMenu.Disable(label)
    }
    A_TrayMenu.Add()

    A_TrayMenu.Add("設定リセット (mws_config.ini 削除)", ResetConfig)
    A_TrayMenu.Add("再起動", (*) => RestartScript())
    A_TrayMenu.Add("終了", (*) => ExitApp())
}

; ──────────────────────────────────────────────
; スクリプト再起動
; ──────────────────────────────────────────────
RestartScript() {
    Reload
}

; ──────────────────────────────────────────────
; 設定リセット
; ──────────────────────────────────────────────
ResetConfig(*) {
    configFile := A_ScriptDir "\mws_config.ini"
    if FileExist(configFile)
        FileDelete(configFile)
    result := MsgBox("設定をリセットしました。`n今すぐ再起動しますか？",
                     "Mouse Wake Suppressor", 0x24)  ; Yes/No + Question icon
    if result = "Yes"
        RestartScript()
}

; ──────────────────────────────────────────────
; 終了時: セッション通知解除 + マウスを必ず有効に戻す
; ──────────────────────────────────────────────
CleanupOnExit(exitReason, exitCode) {
    if g_powerNotifyHandle
        DllCall("UnregisterPowerSettingNotification", "ptr", g_powerNotifyHandle)
    DllCall("Wtsapi32.dll\WTSUnRegisterSessionNotification", "ptr", A_ScriptHwnd)
    ForceEnableMouse()
}
