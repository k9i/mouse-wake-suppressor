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
        A_TrayMenu.Add("サービスを停止", (*) => (ServiceStop(), Sleep(300), UpdateTray()))
        A_TrayMenu.Add("サービスを再起動", (*) => (ServiceStop(), Sleep(500), ServiceStart(), Sleep(300), UpdateTray()))
    } else {
        A_TrayMenu.Add("サービスを開始", (*) => (ServiceStart(), Sleep(300), UpdateTray()))
    }
    A_TrayMenu.Add("サービスをアンインストール", (*) => UninstallServiceMenu())
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
