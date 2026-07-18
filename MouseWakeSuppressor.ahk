; MouseWakeSuppressor.ahk
; ロック画面中やモニター消灯中にマウスデバイスを PnP レベルで完全無効化し、
; マウス移動によるモニター点灯やスリープ解除を防ぐ AHK v2 スクリプト
;
; このスクリプトは、設定 GUI、トレイアイコン、手動トグルのホットキーを管理し、
; 実際のデバイス無効化/有効化および電源イベントの監視は
; バックグラウンドで動作する Windows システムサービス "MouseWakeSuppressor" が行います。
;
; 必要権限: 一般ユーザー権限で動作 (サービスインストール/開始/停止時のみ UAC 昇格)
; ホットキー: Win+Shift+M → マウスを手動トグル

#Requires AutoHotkey v2.0-
#SingleInstance Force

; ──────────────────────────────────────────────
; グローバル変数
; ──────────────────────────────────────────────
global g_devices := []         ; [{id: "HID\...", name: "..."}, ...]
global g_lastState := ""       ; トレイ更新のキャッシュ用
global g_powerNotifyHandles := [] ; RegisterPowerSettingNotification の戻り値
global g_sessionDisplayNotificationSeen := false ; セッション表示通知を受信済みか
global g_consoleDisplayGuid := "{6FE69556-704A-47A0-8F24-C2C28D936FDA}"
global g_sessionDisplayGuid := "{2B84C20E-AD23-4DDF-93DB-05FFBD7EFCA5}"

; ──────────────────────────────────────────────
; 初期化
; ──────────────────────────────────────────────
; サービスのインストール確認と自動開始
if !IsServiceInstalled() {
    result := MsgBox("Mouse Wake Suppressor サービスがインストールされていません。`nインストールしますか？ (UAC 昇格が必要です)", 
                     "Mouse Wake Suppressor", 0x24)
    if result = "Yes" {
        ServiceInstall()
        Sleep(1500)  ; サービス起動を待機
        if !IsServiceRunning() {
            MsgBox "サービスの起動に失敗しました。管理者として実行して再試行してください。",
                   "Mouse Wake Suppressor", 0x10
            ExitApp
        }
    } else {
        MsgBox "サービスがインストールされない場合、本スクリプトは動作しません。終了します。", 
               "Mouse Wake Suppressor", 0x10
        ExitApp
    }
} else if !IsServiceRunning() {
    result := MsgBox("サービスが停止しています。起動しますか？ (UAC 昇格が必要です)",
                     "Mouse Wake Suppressor", 0x24)
    if result = "Yes" {
        ServiceStart()
        Sleep(1000)
    }
}

; 対象デバイスのロード、未設定の場合は GUI 選択
g_devices := LoadOrDetectDevices(true)

if g_devices.Length = 0 {
    MsgBox "対象マウスデバイスが選択されませんでした。終了します。",
           "Mouse Wake Suppressor", 0x10
    ExitApp
}

; トレイアイコンとメニューの初期表示
UpdateTray()

; 1秒おきにサービスの状態を監視してトレイアイコンを自動同期
SetTimer(UpdateTray, 1000)

; ──────────────────────────────────────────────
; ホットキー: Win+Shift+M → 手動トグル
; ──────────────────────────────────────────────
#+m:: {
    ServiceControl(128) ; トグル
    Sleep(150)
    UpdateTray()
}

; ──────────────────────────────────────────────
; ホットキー: Shift+Alt+Ctrl+F1 → 手動トグル
; ──────────────────────────────────────────────
^!+F1:: {
    ServiceControl(128) ; トグル
    Sleep(150)
    UpdateTray()
}

; ──────────────────────────────────────────────
; 画面ロック・消灯の検出 (試験的実装)
; サービスは Session 0 (SYSTEM) で動作するため、ユーザーセッションの
; 画面ロック・消灯イベントを受信できない場合がある。
; このスクリプトはユーザーセッション内で直接検出し、サービス経由で pnputil を実行する。
; ──────────────────────────────────────────────

; セッション変更通知を登録 (画面ロック/アンロック検出)
DllCall("Wtsapi32\WTSRegisterSessionNotification", "Ptr", A_ScriptHwnd, "UInt", 0)

; ユーザーセッションの表示状態を主経路として購読する。
; GUID_CONSOLE_DISPLAY_STATE も、セッション通知が届かない環境用の
; フォールバックとして併せて購読する。
RegisterDisplayPowerNotifications()

OnMessage(0x2B1, OnWtsSessionChange)  ; WM_WTSSESSION_CHANGE
OnMessage(0x218, OnPowerBroadcast)    ; WM_POWERBROADCAST

OnExit(CleanupNotifications)

; ──────────────────────────────────────────────
; サービス制御用ヘルパー
; ──────────────────────────────────────────────
IsServiceInstalled() {
    return RunWait('sc query MouseWakeSuppressor',, "Hide") != 1060 ; ERROR_SERVICE_DOES_NOT_EXIST = 1060
}

IsServiceRunning() {
    tmpFile := A_Temp "\mws_sc.txt"
    try FileDelete(tmpFile)
    RunWait 'cmd.exe /c sc query MouseWakeSuppressor > "' tmpFile '"',, "Hide"
    if !FileExist(tmpFile)
        return false
    content := FileRead(tmpFile)
    try FileDelete(tmpFile)
    return InStr(content, "STATE") && InStr(content, "RUNNING")
}

ServiceInstall() {
    serviceExe := A_ScriptDir "\MouseWakeSuppressorService.exe"
    if !FileExist(serviceExe) {
        MsgBox "サービス実行ファイルが見つかりません: `n" serviceExe, "Mouse Wake Suppressor", 0x10
        return
    }
    ; -install はサービス登録・DACL設定・起動を内包する。管理者権限で実行。
    try RunWait '*RunAs "' serviceExe '" -install',, "Hide"
}

ServiceUninstall() {
    serviceExe := A_ScriptDir "\MouseWakeSuppressorService.exe"
    if FileExist(serviceExe) {
        ; -uninstall はサービス停止・登録解除を内包する。管理者権限で実行。
        try RunWait '*RunAs "' serviceExe '" -uninstall',, "Hide"
    }
}

ServiceStart() {
    if A_IsAdmin {
        RunWait 'sc start MouseWakeSuppressor',, "Hide"
    } else {
        try RunWait '*RunAs cmd.exe /c "sc start MouseWakeSuppressor"',, "Hide"
    }
}

ServiceStop() {
    if A_IsAdmin {
        RunWait 'sc stop MouseWakeSuppressor',, "Hide"
    } else {
        try RunWait '*RunAs cmd.exe /c "sc stop MouseWakeSuppressor"',, "Hide"
    }
}

ServiceControl(code) {
    ; サービス DACL により一般ユーザーでも実行可能
    RunWait 'sc control MouseWakeSuppressor ' code,, "Hide"
}

; ──────────────────────────────────────────────
; ディスプレイ電源通知の登録
; ──────────────────────────────────────────────
RegisterDisplayPowerNotifications() {
    global g_powerNotifyHandles, g_consoleDisplayGuid, g_sessionDisplayGuid

    sessionHandle := RegisterPowerNotification(g_sessionDisplayGuid)
    consoleHandle := RegisterPowerNotification(g_consoleDisplayGuid)

    if !sessionHandle && !consoleHandle {
        MsgBox "ディスプレイ電源状態の通知を登録できませんでした。`n"
             . "自動消灯時のマウス無効化は動作しない可能性があります。",
               "Mouse Wake Suppressor", 0x30
    }
}

RegisterPowerNotification(guid) {
    global g_powerNotifyHandles

    guidBuf := GuidToBuffer(guid)
    handle := DllCall("user32\RegisterPowerSettingNotification",
        "Ptr", A_ScriptHwnd, "Ptr", guidBuf.Ptr, "UInt", 0, "Ptr")
    if handle
        g_powerNotifyHandles.Push(handle)
    return handle
}

GuidToBuffer(guid) {
    guid := Trim(guid, "{}")
    parts := StrSplit(guid, "-")
    if parts.Length != 5
        throw ValueError("Invalid GUID: " guid)

    data4 := parts[4] parts[5]
    if StrLen(data4) != 16
        throw ValueError("Invalid GUID: " guid)

    guidBuf := Buffer(16, 0)
    NumPut("UInt", "0x" parts[1], guidBuf, 0)
    NumPut("UShort", "0x" parts[2], guidBuf, 4)
    NumPut("UShort", "0x" parts[3], guidBuf, 6)
    Loop 8
        NumPut("UChar", "0x" SubStr(data4, (A_Index - 1) * 2 + 1, 2), guidBuf, A_Index + 7)
    return guidBuf
}

GuidMatches(ptr, guid) {
    guidBuf := GuidToBuffer(guid)
    Loop 16 {
        offset := A_Index - 1
        if NumGet(ptr, offset, "UChar") != NumGet(guidBuf, offset, "UChar")
            return false
    }
    return true
}

GetMouseStateFromService() {
    stateFile := A_ScriptDir "\mws_state.txt"
    if !FileExist(stateFile)
        return "UNKNOWN"
    try {
        content := Trim(FileRead(stateFile))
        if content == "1"
            return "ENABLED"
        if content == "0"
            return "DISABLED"
    }
    return "UNKNOWN"
}

; ──────────────────────────────────────────────
; 設定ファイルからロードまたは新規検出
; ──────────────────────────────────────────────
LoadOrDetectDevices(showGui := true) {
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

    if !showGui
        return []

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
        ServiceControl(131) ; サービスに設定リロードを通知
        return allDevices
    }
    return SelectDevicesGui(allDevices, configFile)
}

; ──────────────────────────────────────────────
; powershell.exe でマウスクラスのデバイスを列挙
; ──────────────────────────────────────────────
EnumMouseDevices() {
    devices := []
    tmpFile := A_Temp "\mws_enum.txt"
    ps1File := A_Temp "\mws_enum.ps1"

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
    gw := Gui("+AlwaysOnTop", "Mouse Wake Suppressor - デバイス選択")
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
    while WinExist("Mouse Wake Suppressor - デバイス選択")
        Sleep 100

    if cancelled || selected.Length = 0
        return []

    devices := []
    for idx in selected
        devices.Push(allDevices[idx])

    SaveDeviceConfig(configFile, devices)
    ServiceControl(131) ; サービスに設定リロードを通知
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
; トレイアイコンとメニューを更新
; ──────────────────────────────────────────────
UpdateTray() {
    global g_lastState, g_devices

    currentState := GetMouseStateFromService()
    serviceRunning := IsServiceRunning()
    
    if !serviceRunning {
        currentState := "STOPPED"
    }

    ; 状態キャッシュチェック
    if (currentState == g_lastState)
        return
    g_lastState := currentState

    if currentState == "DISABLED" {
        TraySetIcon "shell32.dll", 131
        A_IconTip := "Mouse Wake Suppressor`nMouse [DISABLED] (Win+Shift+M to Enable)"
    } else if currentState == "ENABLED" {
        TraySetIcon "shell32.dll", 18
        A_IconTip := "Mouse Wake Suppressor`nMouse [ENABLED] (Win+Shift+M to Disable)"
    } else {
        TraySetIcon "shell32.dll", 110
        A_IconTip := "Mouse Wake Suppressor`nService is NOT running!"
    }
    A_TrayMenu.Delete()
    A_TrayMenu.AddStandard()
    try {
      A_TrayMenu.Delete("&Help")
      A_TrayMenu.Delete("&Window Spy")
      A_TrayMenu.Delete("&Pause Script")
    }
    A_TrayMenu.Add() ; セパレータライン
    if currentState == "DISABLED" {
        A_TrayMenu.Add("Mouse: DISABLED (-> to Enable)", (*) => (ServiceControl(128), Sleep(150), UpdateTray()))
        A_TrayMenu.Default := "Mouse: DISABLED (-> to Enable)"
    } else if currentState == "ENABLED" {
        A_TrayMenu.Add("Mouse: ENABLED (-> to Disable)", (*) => (ServiceControl(128), Sleep(150), UpdateTray()))
        A_TrayMenu.Default := "Mouse: ENABLED (-> to Disable)"
    } else if currentState == "STOPPED" {
        A_TrayMenu.Add("サービスが停止しています (開始する)", (*) => (ServiceStart(), Sleep(500), UpdateTray()))
        A_TrayMenu.Default := "サービスが停止しています (開始する)"
    }
    A_TrayMenu.Add()

    ; デバイス一覧
    g_devices := LoadOrDetectDevices(false)
    for d in g_devices {
        label := "  " d.name
        if d.HasProp("manufacturer") && d.manufacturer != ""
            label .= " (" d.manufacturer ")"
        A_TrayMenu.Add(label, (*) => 0)
        A_TrayMenu.Disable(label)
    }
    A_TrayMenu.Add()

    A_TrayMenu.Add("設定リセット (mws_config.ini 削除)", ResetConfig)
    
    if serviceRunning {
        A_TrayMenu.Add("サービスを停止(要管理者権限)", (*) => (ServiceStop(), Sleep(300), UpdateTray()))
        A_TrayMenu.Add("サービスを再起動(要管理者権限)", (*) => (ServiceStop(), Sleep(500), ServiceStart(), Sleep(300), UpdateTray()))
    } else {
        A_TrayMenu.Add("サービスを開始(要管理者権限)", (*) => (ServiceStart(), Sleep(300), UpdateTray()))
    }
    A_TrayMenu.Add("サービスをアンインストール(要管理者権限)", (*) => UninstallServiceMenu())
    A_TrayMenu.Add()
    A_TrayMenu.Add("終了 (常駐トレイを閉じる)", (*) => ExitApp())
}

; ──────────────────────────────────────────────
; 設定リセット
; ──────────────────────────────────────────────
ResetConfig(*) {
    configFile := A_ScriptDir "\mws_config.ini"
    if FileExist(configFile)
        FileDelete(configFile)
    
    ServiceControl(131) ; サービスの設定リロード

    result := MsgBox("設定をリセットしました。`n新しいマウスを選択しますか？",
                     "Mouse Wake Suppressor", 0x24)
    if result = "Yes" {
        Reload
    }
}

; ──────────────────────────────────────────────
; アンインストールハンドラー
; ──────────────────────────────────────────────
UninstallServiceMenu() {
    result := MsgBox("Mouse Wake Suppressor サービスをアンインストールしますか？`n(常駐トレイも終了します)", 
                     "Mouse Wake Suppressor", 0x24)
    if result = "Yes" {
        ServiceUninstall()
        ExitApp()
    }
}

; ──────────────────────────────────────────────
; セッション変更ハンドラ (画面ロック/アンロック)
; ──────────────────────────────────────────────
OnWtsSessionChange(wParam, lParam, msg, hwnd) {
    if wParam = 7 {        ; WTS_SESSION_LOCK
        ServiceControl(130) ; マウス無効化
        Sleep(150)
        UpdateTray()
    } else if wParam = 8 { ; WTS_SESSION_UNLOCK
        ServiceControl(129) ; マウス有効化
        Sleep(150)
        UpdateTray()
    } else if wParam = 6 { ; WTS_SESSION_LOGOFF
        ServiceControl(129) ; マウス強制有効化 (コマンド129=Enable)
        Sleep(150)
        UpdateTray()
    }
}

; ──────────────────────────────────────────────
; 電源ブロードキャストハンドラ (ディスプレイ消灯/点灯)
; ──────────────────────────────────────────────
OnPowerBroadcast(wParam, lParam, msg, hwnd) {
    global g_consoleDisplayGuid, g_sessionDisplayGuid, g_sessionDisplayNotificationSeen

    if wParam = 0x8013 && lParam != 0 { ; PBT_POWERSETTINGCHANGE
        ; POWERBROADCAST_SETTING 構造体: GUID(16B) + DataLength(4B) + Data
        dataLength := NumGet(lParam, 16, "UInt")
        if dataLength < 4
            return

        if GuidMatches(lParam, g_sessionDisplayGuid) {
            g_sessionDisplayNotificationSeen := true
        } else if GuidMatches(lParam, g_consoleDisplayGuid) {
            ; セッション通知が利用できる場合は、そのセッション固有の状態を優先する。
            if g_sessionDisplayNotificationSeen
                return
        } else {
            return
        }

        displayState := NumGet(lParam, 20, "UInt")
        if displayState = 0 or displayState = 2 { ; OFF or Dimmed
            ServiceControl(130) ; マウス無効化
            Sleep(150)
            UpdateTray()
        } else if displayState = 1 {               ; ON
            ServiceControl(129) ; マウス有効化
            Sleep(150)
            UpdateTray()
        }
    }
}

; ──────────────────────────────────────────────
; 終了時のクリーンアップ
; ──────────────────────────────────────────────
CleanupNotifications(exitReason, exitCode) {
    global g_powerNotifyHandles
    DllCall("Wtsapi32\WTSUnRegisterSessionNotification", "Ptr", A_ScriptHwnd)
    for handle in g_powerNotifyHandles {
        if handle
            DllCall("user32\UnregisterPowerSettingNotification", "Ptr", handle)
    }
}
