#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon

global g_mwsSetupConsole := false, g_mwsSetupOutput := "", g_mwsSetupError := false

; 単体 test から include できるよう、直接実行時だけ CLI を開始する。
if A_LineFile = A_ScriptFullPath {
    g_mwsSetupConsole := MwsSetupAttachParentConsole()
    exitCode := MwsSetupMain(A_Args)
    if !g_mwsSetupConsole && g_mwsSetupOutput != ""
        MsgBox(RTrim(g_mwsSetupOutput, "`r`n"), "Mouse Wake Suppressor", g_mwsSetupError ? "Iconx" : "Iconi")
    ExitApp(exitCode)
}

; file association 経由の GUI process でも、起動元 terminal へ出力できるようにする。
MwsSetupAttachParentConsole() {
    DllCall("kernel32\AttachConsole", "UInt", 0xFFFFFFFF)
    output := DllCall("kernel32\GetStdHandle", "Int", -11, "Ptr")
    return output && output != -1 && DllCall("kernel32\GetFileType", "Ptr", output, "UInt") != 0
}

; console がない起動では、最後に 1 個の dialog として表示するため内容を蓄積する。
MwsSetupWrite(message, error := false) {
    global g_mwsSetupConsole, g_mwsSetupOutput, g_mwsSetupError
    if g_mwsSetupConsole {
        try {
            FileAppend(message, error ? "**" : "*", "UTF-8")
            return
        } catch {
            ; 無効化された handle へ再試行せず、以後は dialog 用 buffer に切り替える。
            g_mwsSetupConsole := false
        }
    }
    g_mwsSetupOutput .= message
    g_mwsSetupError := g_mwsSetupError || error
}

; setup CLI の終了コードを一箇所で決定する。
MwsSetupMain(args) {
    parsed := MwsSetupParseArgs(args)
    if parsed.help {
        MwsSetupUsage()
        return 0
    }
    if parsed.error != "" {
        if parsed.error != "引数がありません。"
            MwsSetupWrite(parsed.error "`n", true)
        MwsSetupUsage()
        return 64
    }
    expectedDir := EnvGet("USERPROFILE") "\.local\mws"
    repositoryMode := MwsSetupMode(A_ScriptFullPath, expectedDir "\setup.ahk") = "repository"
    if parsed.command = "status"
        return MwsSetupStatus(expectedDir, repositoryMode)
    if !parsed.elevated && parsed.command = "install" && repositoryMode {
        code := MwsSetupPrepareBuild(A_ScriptDir)
        if code != 0
            return code
    }
    if !A_IsAdmin
        return MwsSetupElevate(parsed.command)
    return parsed.command = "install" ? MwsSetupInstall(expectedDir, repositoryMode) : MwsSetupUninstall(expectedDir)
}

; 利用者向け command と内部の昇格 marker を厳密に分離する。
MwsSetupParseArgs(args) {
    result := {command: "", elevated: false, help: false, error: ""}
    if args.Length = 0 {
        result.error := "引数がありません。"
        return result
    }
    if args.Length = 1 && args[1] = "--help" {
        result.help := true
        return result
    }
    if args.Length > 2 || (args.Length = 2 && args[2] != "--elevated") {
        result.error := "不正な引数です。"
        return result
    }
    command := StrLower(args[1])
    if command != "install" && command != "status" && command != "uninstall" {
        result.error := "不明な command です: " args[1]
        return result
    }
    if args.Length = 2 && command = "status" {
        result.error := "status に内部 option は指定できません。"
        return result
    }
    result.command := command
    result.elevated := args.Length = 2
    return result
}

; 引数なしでも契約と利用可能な command が分かるよう詳細を表示する。
MwsSetupUsage() {
    MwsSetupWrite("Mouse Wake Suppressor を build、配置、service 登録します。`n"
        . "使い方: setup.ahk install|status|uninstall`n`n"
        . "  install    必要なら build し、%USERPROFILE%\.local\mws へ配置します。`n"
        . "  status     service、登録先、配置 file、build 要否を表示します。`n"
        . "  uninstall  service 登録だけを削除し、配置 file と設定を保持します。`n"
        . "  --help     この help を表示します。`n")
}

; 配置済み copy には source がないため、script の正規化済み path だけで mode を決める。
MwsSetupMode(scriptPath, installedPath) {
    return MwsSetupNormalizePath(scriptPath) = MwsSetupNormalizePath(installedPath) ? "installed" : "repository"
}

; Windows の path 比較で大文字小文字と末尾 separator の差を無視する。
MwsSetupNormalizePath(path) {
    return StrLower(RTrim(StrReplace(path, "/", "\"), "\"))
}

; command line の quoting を除き、SCM に登録された executable path を抽出する。
MwsSetupExecutablePath(commandLine) {
    text := Trim(commandLine)
    if SubStr(text, 1, 1) = '"' {
        closing := InStr(text, '"', false, 2)
        return closing ? SubStr(text, 2, closing - 2) : ""
    }
    space := InStr(text, " ")
    return space ? SubStr(text, 1, space - 1) : text
}

; service 登録先は command line の option ではなく executable path 同士で比較する。
MwsSetupPathsMatch(commandLine, expectedExecutable) {
    actual := MwsSetupExecutablePath(commandLine)
    return actual != "" && MwsSetupNormalizePath(actual) = MwsSetupNormalizePath(expectedExecutable)
}

; output がない場合と、いずれかの build input より古い場合だけ rebuild する。
MwsSetupOutputIsStale(binaryTime, inputTimes) {
    if binaryTime = ""
        return true
    for inputTime in inputTimes
        if inputTime = "" || inputTime > binaryTime
            return true
    return false
}

; repository の build input を列挙し、source 不足と compiler failure を区別する。
MwsSetupPrepareBuild(sourceDir) {
    inputs := ["build.cmd", "MouseWakeSuppressorService.cs", "Core.cs", "WindowsPlatform.cs", "Ipc.cs", "LockDisplay.cs", "LockNative.cs", "LockDisplayHost.cs", "LockInputHelper.cs"]
    times := []
    for name in inputs {
        path := sourceDir "\" name
        if !FileExist(path) {
            MwsSetupWrite("必要な source がありません: " path "`n", true)
            return 66
        }
        times.Push(FileGetTime(path, "M"))
    }
    binary := sourceDir "\MouseWakeSuppressorService.exe"
    binaryTime := FileExist(binary) ? FileGetTime(binary, "M") : ""
    if !MwsSetupOutputIsStale(binaryTime, times)
        return 0
    try exitCode := RunWait('"' sourceDir '\build.cmd" --build', sourceDir)
    catch as err {
        MwsSetupWrite("build を開始できません: " err.Message "`n", true)
        return 74
    }
    if exitCode != 0 {
        MwsSetupWrite("build に失敗しました。exit=" exitCode "`n", true)
        return exitCode
    }
    return FileExist(binary) ? 0 : 66
}

; UAC dialog の取消と昇格 process の失敗を呼出元の終了コードへ反映する。
MwsSetupElevate(command) {
    try {
        Run('*RunAs "' A_AhkPath '" "' A_ScriptFullPath '" ' command ' --elevated', A_ScriptDir, , &pid)
        process := DllCall("OpenProcess", "UInt", 0x101000, "Int", false, "UInt", pid, "Ptr")
        if !process
            throw OSError()
        try {
            DllCall("WaitForSingleObject", "Ptr", process, "UInt", 0xFFFFFFFF)
            if !DllCall("GetExitCodeProcess", "Ptr", process, "UInt*", &exitCode := 0)
                throw OSError()
            return exitCode
        } finally DllCall("CloseHandle", "Ptr", process)
    } catch as err {
        MwsSetupWrite("管理者権限を取得できませんでした: " err.Message "`n", true)
        return 77
    }
}

; SCM の状態と登録 command line を read-only access で取得する。
MwsSetupQueryService() {
    result := {exists: false, state: 0, commandLine: "", error: ""}
    scm := DllCall("advapi32\OpenSCManagerW", "Ptr", 0, "Ptr", 0, "UInt", 1, "Ptr")
    if !scm {
        result.error := OSError().Message
        return result
    }
    service := DllCall("advapi32\OpenServiceW", "Ptr", scm, "WStr", "MouseWakeSuppressor", "UInt", 5, "Ptr")
    if !service {
        errorCode := A_LastError
        DllCall("advapi32\CloseServiceHandle", "Ptr", scm)
        if errorCode != 1060
            result.error := OSError(errorCode).Message
        return result
    }
    result.exists := true
    try {
        status := Buffer(36, 0)
        if !DllCall("advapi32\QueryServiceStatusEx", "Ptr", service, "Int", 0, "Ptr", status, "UInt", status.Size, "UInt*", &needed := 0)
            result.error := OSError().Message
        else
            result.state := NumGet(status, 4, "UInt")
        DllCall("advapi32\QueryServiceConfigW", "Ptr", service, "Ptr", 0, "UInt", 0, "UInt*", &size := 0)
        if A_LastError != 122 {
            result.error := OSError().Message
        } else {
            config := Buffer(size, 0)
            if !DllCall("advapi32\QueryServiceConfigW", "Ptr", service, "Ptr", config, "UInt", size, "UInt*", &size)
                result.error := OSError().Message
            else {
                ; DWORD 3 個の後に pointer alignment が入る。
                offset := A_PtrSize = 8 ? 16 : 12
                imagePointer := NumGet(config, offset, "Ptr")
                result.commandLine := imagePointer ? StrGet(imagePointer, "UTF-16") : ""
            }
        }
    } finally {
        DllCall("advapi32\CloseServiceHandle", "Ptr", service)
        DllCall("advapi32\CloseServiceHandle", "Ptr", scm)
    }
    return result
}

; Windows SERVICE_* 値を locale 非依存の表示へ変換する。
MwsSetupStateName(state) {
    names := Map(1, "Stopped", 2, "StartPending", 3, "StopPending", 4, "Running", 5, "ContinuePending", 6, "PausePending", 7, "Paused")
    return names.Has(state) ? names[state] : "Unknown(" state ")"
}

; status は環境を変更せず、診断に必要な事実をすべて表示する。
MwsSetupStatus(expectedDir, repositoryMode) {
    service := MwsSetupQueryService()
    if service.error != "" {
        MwsSetupWrite("service の照会に失敗しました: " service.error "`n", true)
        return 74
    }
    expectedExe := expectedDir "\MouseWakeSuppressorService.exe"
    MwsSetupWrite("mode: " (repositoryMode ? "repository" : "installed") "`n")
    MwsSetupWrite("expected directory: " expectedDir "`n")
    MwsSetupWrite("service: " (service.exists ? MwsSetupStateName(service.state) : "NotInstalled") "`n")
    MwsSetupWrite("registered executable: " (service.exists ? service.commandLine : "-") "`n")
    MwsSetupWrite("registration matches: " (service.exists && MwsSetupPathsMatch(service.commandLine, expectedExe) ? "yes" : "no") "`n")
    for name in MwsSetupRequiredFiles()
        MwsSetupWrite(name ": " (FileExist(expectedDir "\" name) ? "present" : "missing") "`n")
    MwsSetupWrite(repositoryMode ? "build required: " (MwsSetupBuildRequired(A_ScriptDir) ? "yes" : "no") "`n" : "build source: unavailable`n")
    return 0
}

; status では source 不足も build が必要な状態として報告する。
MwsSetupBuildRequired(sourceDir) {
    inputs := ["build.cmd", "MouseWakeSuppressorService.cs", "Core.cs", "WindowsPlatform.cs", "Ipc.cs", "LockDisplay.cs", "LockNative.cs", "LockDisplayHost.cs", "LockInputHelper.cs"]
    times := []
    for name in inputs {
        path := sourceDir "\" name
        if !FileExist(path)
            return true
        times.Push(FileGetTime(path, "M"))
    }
    binary := sourceDir "\MouseWakeSuppressorService.exe"
    return MwsSetupOutputIsStale(FileExist(binary) ? FileGetTime(binary, "M") : "", times)
}

; 配置契約を install と status で共有する。
MwsSetupRequiredFiles() {
    return ["MouseWakeSuppressorService.exe", "MouseWakeSuppressor.ahk", "MwsClient.ahk", "MwsView.ahk", "setup.ahk"]
}

; staging 完了後にだけ service を止め、更新途中の欠損時間を短くする。
MwsSetupInstall(expectedDir, repositoryMode) {
    sourceDir := repositoryMode ? A_ScriptDir : expectedDir
    if repositoryMode {
        code := MwsSetupPrepareBuild(sourceDir)
        if code != 0
            return code
    }
    for name in MwsSetupRequiredFiles()
        if !FileExist(sourceDir "\" name) {
            MwsSetupWrite("必要な配置 file がありません: " sourceDir "\" name "`n", true)
            return 66
        }
    SplitPath(expectedDir, , &parentDir)
    stageDir := parentDir "\mws.stage." DllCall("GetCurrentProcessId")
    backupDir := parentDir "\mws.backup." DllCall("GetCurrentProcessId")
    try {
        DirCreate(stageDir)
        for name in MwsSetupRequiredFiles()
            FileCopy(sourceDir "\" name, stageDir "\" name, true)
        if !FileExist(expectedDir "\mws_config.ini") && FileExist(sourceDir "\mws_config.ini")
            FileCopy(sourceDir "\mws_config.ini", stageDir "\mws_config.ini", true)
    } catch as err {
        MwsSetupRemoveTree(stageDir)
        MwsSetupWrite("staging に失敗しました: " err.Message "`n", true)
        return 73
    }
    previous := MwsSetupQueryService()
    if previous.error != "" {
        MwsSetupRemoveTree(stageDir)
        MwsSetupWrite("service の照会に失敗しました: " previous.error "`n", true)
        return 74
    }
    expectedExe := expectedDir "\MouseWakeSuppressorService.exe"
    sameRegistration := previous.exists && MwsSetupPathsMatch(previous.commandLine, expectedExe)
    previousExe := previous.exists ? MwsSetupExecutablePath(previous.commandLine) : ""
    previousFiles := Map()
    for name in MwsSetupRequiredFiles()
        previousFiles[name] := FileExist(expectedDir "\" name) != ""
    changedService := false
    failureCode := 73
    try {
        if previous.exists {
            code := MwsSetupRunService(previousExe, sameRegistration ? "-stop" : "-uninstall")
            if code != 0 {
                failureCode := 74
                throw Error("既存 service の停止または解除に失敗しました。exit=" code)
            }
            changedService := true
        }
        if DirExist(expectedDir) {
            DirCreate(backupDir)
            for name in MwsSetupRequiredFiles()
                if FileExist(expectedDir "\" name)
                    FileCopy(expectedDir "\" name, backupDir "\" name, true)
        } else
            DirCreate(expectedDir)
        for name in MwsSetupRequiredFiles()
            FileCopy(stageDir "\" name, expectedDir "\" name, true)
        if FileExist(stageDir "\mws_config.ini") && !FileExist(expectedDir "\mws_config.ini")
            FileCopy(stageDir "\mws_config.ini", expectedDir "\mws_config.ini", false)
        code := MwsSetupRunService(expectedExe, sameRegistration ? "-start" : "-install")
        if code != 0 {
            failureCode := 74
            throw Error("service の登録または開始に失敗しました。exit=" code)
        }
        MwsSetupRemoveTree(stageDir)
        MwsSetupRemoveTree(backupDir)
        MwsSetupWrite("導入が完了しました: " expectedDir "`n")
        return 0
    } catch as err {
        rollbackError := MwsSetupRollback(expectedDir, backupDir, previous, previousExe, sameRegistration, changedService, previousFiles)
        MwsSetupRemoveTree(stageDir)
        message := "導入に失敗しました: " err.Message
        message .= rollbackError != "" ? "`nrollback にも失敗しました: " rollbackError : "`n旧状態へ rollback しました。"
        MwsSetupWrite(message "`n", true)
        return rollbackError != "" ? 74 : failureCode
    }
}

; 更新失敗時は配置 file を戻してから、元の登録先と稼働状態を復元する。
MwsSetupRollback(expectedDir, backupDir, previous, previousExe, sameRegistration, changedService, previousFiles) {
    errors := []
    ; 新しい登録が途中まで作成されていても、旧登録の復元前に除去する。
    if !sameRegistration {
        try {
            current := MwsSetupQueryService()
            expectedExe := expectedDir "\MouseWakeSuppressorService.exe"
            if current.error != ""
                throw Error(current.error)
            if current.exists && MwsSetupPathsMatch(current.commandLine, expectedExe) && MwsSetupRunService(expectedExe, "-uninstall") != 0
                throw Error("途中登録された service を解除できません。")
        } catch as err {
            errors.Push("新規 service の解除: " err.Message)
        }
    }
    try {
        for name in MwsSetupRequiredFiles() {
            if previousFiles[name] {
                if !FileExist(backupDir "\" name)
                    throw Error("backup がありません: " name)
                else
                    FileCopy(backupDir "\" name, expectedDir "\" name, true)
            } else if FileExist(expectedDir "\" name)
                FileDelete(expectedDir "\" name)
        }
    } catch as err {
        errors.Push("file 復元: " err.Message)
    }
    if changedService {
        try {
            if previous.exists {
                restoreExe := sameRegistration ? expectedDir "\MouseWakeSuppressorService.exe" : previousExe
                command := sameRegistration ? (previous.state = 4 ? "-start" : "") : "-install"
                if command != "" && MwsSetupRunService(restoreExe, command) != 0
                    throw Error("service CLI が失敗しました。")
                if !sameRegistration && previous.state != 4 && MwsSetupRunService(restoreExe, "-stop") != 0
                    throw Error("旧 service の停止状態を復元できません。")
            }
        } catch as err {
            errors.Push("service 復元: " err.Message)
        }
    }
    if errors.Length
        return MwsSetupJoin(errors, "; ") "。backup: " backupDir
    MwsSetupRemoveTree(backupDir)
    return ""
}

; service CLI の標準 error をそのまま利用者へ示す。
MwsSetupRunService(executable, command) {
    if executable = "" || !FileExist(executable)
        return 66
    try return RunWait('"' executable '" ' command, , "Hide")
    catch as err {
        MwsSetupWrite("service CLI を開始できません: " err.Message "`n", true)
        return 74
    }
}

; uninstall は service 登録だけを削除し、設定と復旧手段を意図的に保持する。
MwsSetupUninstall(expectedDir) {
    service := MwsSetupQueryService()
    if service.error != "" {
        MwsSetupWrite("service の照会に失敗しました: " service.error "`n", true)
        return 74
    }
    if !service.exists {
        MwsSetupWrite("service は登録されていません。配置 file は保持しました。`n")
        return 0
    }
    code := MwsSetupRunService(MwsSetupExecutablePath(service.commandLine), "-uninstall")
    if code != 0 {
        MwsSetupWrite("service の解除に失敗しました。exit=" code "。配置 file と復旧記録は保持されています。`n", true)
        return code = 77 ? 77 : 74
    }
    MwsSetupWrite("service 登録を解除しました。配置先 " expectedDir " は保持しました。`n")
    return 0
}

; cleanup failure は本処理を失敗にしない。
MwsSetupRemoveTree(path) {
    if !DirExist(path)
        return
    try DirDelete(path, true)
}

; 古い AutoHotkey runtime でも配列の結合に依存しない。
MwsSetupJoin(items, separator) {
    result := ""
    for item in items
        result .= (result = "" ? "" : separator) item
    return result
}
