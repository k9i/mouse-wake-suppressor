#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include ..\src\MwsClient.ahk
#Include ..\src\MwsView.ahk

if A_Args.Length != 1 || A_Args[1] != "--test" {
    FileAppend("実デバイスを変更せず AHK と模擬 IPC を検証します。`n使い方: tests\test.cmd --test (MWS_AHK を指定)`n", "*", "UTF-8")
    ExitApp(64)
}

; 実サービスとは異なる endpoint で、非同期通信と UI の判断を検証する。
global endpoint := "MwsAhkTest-" DllCall("GetCurrentProcessId") "-" A_TickCount
global client := MwsClient(endpoint, 500), sequence := 0, beats := 0
SetTimer(Heartbeat, 10)
try {
    report := "入力診断のロック待ち (消灯要求なし) / 前回: session=5 / 入力診断 (消灯要求なし): 入力待機中 / desktop=Winlogon#3 / OFF 要求=0@0 / 表示通知=1@15231953 / 入力時刻=15236312 ms"
    explanation := MwsLockExplanation(report, 15240312)
    Check(InStr(explanation, "準備完了") && InStr(explanation, "前回のロック中") && InStr(explanation, "検出あり") && InStr(explanation, "4 秒前"), "現在と前回の診断結果を分離")
    Check(InStr(explanation, "0 回が正常") && !InStr(explanation, "session="), "診断は消灯せず内部情報は詳細へ")
    Check(InStr(MwsLockSummary("無効 / 前回: " report), "OFF"), "前回の診断で現在の無効状態を上書きしない")
    Check(InStr(MwsLockSummary("ロック待ち"), "ON"), "有効とロック待ちを明示")
    Check(InStr(MwsLockSummary("監視停止: failed"), "エラー"), "監視エラーを隠さない")
    Check(InStr(MwsLockSummary("session=5 / OFF 通知待ち (未確認: 1)"), "まだ確認できていません"), "消灯要求を成功扱いしない")
    Check(InStr(MwsLockExplanation("session=5 / 入力待機中 / 入力時刻=0 ms", 5000), "未検出"), "未検出を成功扱いしない")
    Check(InStr(MwsLockSummary("unknown future status"), "確認できません"), "未知の状態は不明として扱う")
    ; 表示名の変更で service との INI 契約を壊さない。
    uiSource := FileRead(A_ScriptDir "\..\src\MouseWakeSuppressor.ahk", "UTF-8")
    Check(!RegExMatch(uiSource, 'Ini(?:Read|Write)\([^\r\n]*"ロック中の強制消灯"'), "INI section は表示名に翻訳しない")
    Check(InStr(uiSource, 'IniWrite(section, g_config, "LockDisplay")'), "service が読む section に設定を保存")
    ; 実サービスへ送信せず、menu に割り当てた callback の操作先を確認する。
    calls := []
    rootMenu := A_TrayMenu
    actions := MwsBuildTray(rootMenu, "有効", "", [], (command, manual := false, *) => calls.Push(command ":" manual), (*) => 0, (*) => calls.Push("monitor"))
    Check(rootMenu.Default = "" && DllCall("GetMenuDefaultItem", "Ptr", rootMenu.Handle, "UInt", 0, "UInt", 0, "UInt") = 0xFFFFFFFF, "ダブルクリックの default 操作を解除")
    loop 2
        Check(DllCall("GetMenuState", "Ptr", rootMenu.Handle, "UInt", A_Index - 1, "UInt", 0x400, "UInt") & 3, "状態とショートカット説明は選択不可")
    mouseMenu := DllCall("GetSubMenu", "Ptr", rootMenu.Handle, "Int", 3, "Ptr")
    lockMenu := DllCall("GetSubMenu", "Ptr", rootMenu.Handle, "Int", 4, "Ptr")
    Check(mouseMenu && lockMenu, "機能別 submenu")
    for spec in [{handle: mouseMenu, actions: actions.mouse, expected: ["enumerate:0", "enable:1", "reload:1", "reset:1"]},
                 {handle: lockMenu, actions: actions.lock, expected: ["keyboards:0", "lock-probe:0", "monitor"]}] {
        for index, expected in spec.expected {
            id := DllCall("GetMenuItemID", "Ptr", spec.handle, "Int", index - 1, "UInt")
            Check(id != 0xFFFFFFFF, "menu item の登録")
            spec.actions[index].Call("item", index, rootMenu)
            Check(calls.Length && calls.Pop() = expected, "menu command: " expected)
        }
    }
    Check(MwsLockSettingsError(true, "", "30", "1000") != "", "キーボード未選択では有効化しない")
    Check(MwsLockSettingsError(false, "", "30", "1000") = "", "既定は無効")
    Check(MwsLockSettingsError(true, "HID\A", "0", "1000") != "", "待機秒数下限")
    Check(MwsLockSettingsError(true, "HID\A", "30", "999") != "", "再試行間隔下限")
    Check(MwsLockSettingsError(true, "HID\A", "30", "1000") = "", "有効な消灯設定")
    Run('"' EnvGet("MWS_TEST_EXE") '" --mock ' endpoint, , "Hide", &mockPid)
    start := A_TickCount
    loop {
        reply := Exchange("status")
        if reply.error = ""
            break
        if A_TickCount - start > 4000
            throw Error("模擬サービスを起動できません: " reply.error)
        Sleep(30)
    }
    initial := reply.state
    Check(initial.state = "Enabled", "起動状態")
    Check(MwsPollInterval(false, false, 1000, 5000, 100) = 1000, "AC idle polling")
    Check(MwsPollInterval(true, false, 1000, 5000, 100) = 5000, "battery idle polling")
    Check(MwsPollInterval(true, true, 1000, 5000, 100) = 100, "操作中 polling")
    Check(!MwsAcLineOnBattery(1) && MwsAcLineOnBattery(0) && MwsAcLineOnBattery(255), "起動時の電源判定")
    Check(!MwsPowerSourceOnBattery(0) && MwsPowerSourceOnBattery(1) && MwsPowerSourceOnBattery(2), "電源変更通知の判定")
    Check(MwsEarlierDue(1000, 1500) = 1000 && MwsEarlierDue(1000, 500) = 500, "早い timer 予約を維持")
    enum := Exchange("enumerate", initial.boot)
    Check(enum.state.devices.Length = 2 && InStr(enum.state.devices[1].name, "マウス"), "SetupAPI 代替列挙と UTF-8")
    disabled := Exchange("disable", initial.boot)
    pending := {id: disabled.id, boot: initial.boot}
    state := Completed(pending)
    Check(state.result = "Partial" && state.state = "Partial", "部分無効")
    view := MwsPresentation(state.state, "")
    Check(view.label = "一部無効" && view.icon = 110, "部分状態のトレイ")
    Check(InStr(view.tip, "マウス: 一部無効"), "tooltip はマウスの状態を明記")
    TraySetIcon("shell32.dll", view.icon)
    A_IconTip := view.tip
    notice := MwsCompletion(state, pending, "status")
    Check(notice.clear && !notice.success && InStr(notice.message, "部分成功"), "部分成功通知")
    enabled := Exchange("toggle", initial.boot)
    state := Completed({id: enabled.id, boot: initial.boot})
    Check(state.result = "Success" && state.state = "Enabled", "部分状態の toggle 復旧")
    Check(MwsCompletion(state, {id: enabled.id, boot: "old-boot"}, "status").success = false, "再起動時に誤通知しない")
    wrong := false
    try MwsParse("2`tx`tboot`tRead`tEnabled`t`t0`t0`t`t`tMissing`t`t", "x")
    catch
        wrong := true
    Check(wrong, "version mismatch")
    Check(!MwsCompletion(state, 0, "status").clear, "重複通知しない")
    client := MwsClient(endpoint "-slow", 150)
    before := beats, clock := A_TickCount
    stalled := Exchange("status")
    Check(stalled.error != "" && A_TickCount - clock < 600 && beats - before >= 3, "全体期限と UI heartbeat")
    UntilIdle(client)
    client := MwsClient(endpoint "-drop", 500)
    dropped := Exchange("status")
    Check(dropped.error != "", "途中切断を成功扱いしない")
    FileAppend("PASS AHK: 非同期 IPC、期限、切断、部分状態、通知、version、再起動、電源連動 polling`n", "*", "UTF-8")
    ExitApp(0)
} catch as err {
    FileAppend("FAIL AHK: " err.Message " / " err.Stack "`n", "**", "UTF-8")
    ExitApp(1)
}

; I/O 待機中も timer が動くことを検証する。
Heartbeat() {
    global beats
    beats++
}

; テストの失敗は通知 dialog ではなく終了コードに反映する。
Check(condition, message) {
    if !condition
        throw Error(message)
}

; 待機ループはテスト harness のみ。製品 UI は callback で処理する。
Exchange(command, boot := "", watch := "") {
    global client, sequence
    id := "ahk-" (++sequence)
    result := {done: false, text: "", error: "", id: id}
    Check(client.Send("2`t" id "`t" boot "`t" command "`t" watch "`n", (text, error) => (result.text := text, result.error := error, result.done := true)), "重複送信")
    Check(!client.Send("duplicate", (*) => 0), "重複要求を防止")
    start := A_TickCount
    while !result.done {
        if A_TickCount - start > 3000
            throw Error("callback が返りません。")
        Sleep(10)
    }
    if result.error = ""
        result.state := MwsParse(result.text, id)
    return result
}

; 固定待機を成功条件にせず、該当 request の完了を検証する。
Completed(pending) {
    start := A_TickCount
    loop {
        reply := Exchange("status", pending.boot, pending.id)
        Check(reply.error = "", "状態応答")
        if reply.state.operation = pending.id && reply.state.result != "Pending"
            return reply.state
        if A_TickCount - start > 3000
            throw Error("操作が完了しません。")
        Sleep(10)
    }
}

; timeout callback 後も取消 I/O の回収完了を確認する。
UntilIdle(connection) {
    start := A_TickCount
    while connection.busy {
        if A_TickCount - start > 2000
            throw Error("取消 I/O が回収されません。")
        Sleep(10)
    }
}
