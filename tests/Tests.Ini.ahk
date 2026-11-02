#Requires AutoHotkey v2.0
#NoTrayIcon
; Program Files を模した一時 directory で、通常ユーザーの保存権限を確認する。
if A_Args.Length != 1
    ExitApp(64)
try {
    directory := A_Args[1]
    ini := directory "\mws_config.ini"
    IniWrite("HID\TEST", ini, "Devices", "InstanceIds")
    IniWrite("Enabled=0`nIdleTimeoutSeconds=30`nRetryIntervalMs=1000`nKeyboardInstanceIds=", ini, "LockDisplay")
    if IniRead(ini, "Devices", "InstanceIds") != "HID\TEST" || IniRead(ini, "LockDisplay", "Enabled") != "0"
        throw Error("INI の保存値が一致しません。")
    for path in [directory "\service.exe", directory "\new-file.txt"] {
        denied := false
        try FileAppend("forbidden", path)
        catch
            denied := true
        if !denied
            throw Error("書き込みが制限されていません: " path)
    }
    FileAppend("PASS AHK: 一般ユーザーの INI 保存と executable / directory の書き込み制限`n", "*", "UTF-8")
    ExitApp(0)
} catch as err {
    FileAppend("FAIL INI: " err.Message "`n", "**", "UTF-8")
    ExitApp(1)
}
