#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include MwsClient.ahk
#Include MwsView.ahk
#Include setup.ahk

if A_Args.Length != 1 || A_Args[1] != "--test" {
    FileAppend("実デバイスを変更せず AHK と模擬 IPC を検証します。`n使い方: AutoHotkey64.exe Tests.ahk --test`n先に test.cmd --test で __tests.exe を作成してください。`n", "*", "UTF-8")
    ExitApp(64)
}

; 実サービスとは異なる endpoint で、非同期通信と UI の判断を検証する。
global endpoint := "MwsAhkTest-" DllCall("GetCurrentProcessId") "-" A_TickCount
global client := MwsClient(endpoint, 500), sequence := 0, beats := 0
SetTimer(Heartbeat, 10)
try {
    parsed := MwsSetupParseArgs(["install"])
    Check(parsed.command = "install" && !parsed.elevated && parsed.error = "", "setup 引数解析")
    g_mwsSetupConsole := false, g_mwsSetupOutput := "", g_mwsSetupError := false
    MwsSetupWrite("usage`n")
    Check(g_mwsSetupOutput = "usage`n" && !g_mwsSetupError, "setup console 未接続時の出力")
    Check(MwsSetupParseArgs([]).error != "" && MwsSetupParseArgs(["bad"]).error != "", "setup 不正引数")
    Check(MwsSetupMode("C:\repo\setup.ahk", "C:\Users\u\.local\mws\setup.ahk") = "repository", "repository mode")
    Check(MwsSetupMode("C:\USERS\u\.local\mws\setup.ahk", "C:\Users\u\.local\mws\setup.ahk") = "installed", "installed mode")
    Check(MwsSetupOutputIsStale("20260101000000", ["20260102000000"]), "build 要否")
    Check(!MwsSetupOutputIsStale("20260102000000", ["20260101000000"]), "build 済み")
    Check(MwsSetupStateName(4) = "Running" && MwsSetupStateName(1) = "Stopped", "service state 表示")
    Check(MwsSetupPathsMatch('"C:\Users\u\.local\mws\MouseWakeSuppressorService.exe" -x', "c:\users\u\.local\mws\MouseWakeSuppressorService.exe"), "登録 path 比較")
    Run('"' A_ScriptDir '\__tests.exe" --mock ' endpoint, , "Hide", &mockPid)
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
    Check(MwsStartupAction(0) = "install", "未インストール時の導入確認")
    Check(MwsStartupAction(1) = "", "Delayed Start 待機中は開始確認を出さない")
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
    FileAppend("PASS AHK: 非同期 IPC、期限、切断、部分状態、通知、version、再起動、Delayed Start、電源連動 polling`n", "*", "UTF-8")
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
    Check(client.Send("1`t" id "`t" boot "`t" command "`t" watch "`n", (text, error) => (result.text := text, result.error := error, result.done := true)), "重複送信")
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
