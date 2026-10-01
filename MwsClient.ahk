#Requires AutoHotkey v2.0

; 全体期限を持つ overlapped I/O。完了回収まで buffer と OVERLAPPED を保持する。
class MwsClient {
    ; endpoint を注入でき、実サービスを操作しない模擬試験にも使用する。
    __New(endpoint := "MouseWakeSuppressor-v1", deadline := 500) {
        this.path := "\\.\pipe\" endpoint
        this.deadline := deadline
        this.busy := false
        this.handle := 0
        this.timer := ObjBindMethod(this, "Tick")
    }

    ; 重複要求を拒否し、接続待ちから応答受信までの時計を開始する。
    Send(text, callback) {
        if this.busy
            return false
        this.busy := true
        this.callback := callback
        this.started := DllCall("GetTickCount64", "UInt64")
        this.stage := "connect"
        this.used := 0
        this.input := Buffer(StrPut(text, "UTF-8"))
        StrPut(text, this.input, "UTF-8")
        this.output := Buffer(262144, 0)
        this.overlap := Buffer(A_PtrSize = 8 ? 32 : 20, 0)
        this.event := DllCall("CreateEventW", "Ptr", 0, "Int", 1, "Int", 0, "Ptr", 0, "Ptr")
        if !this.event {
            this.Finish("", "I/O event を作成できません。")
            return true
        }
        NumPut("Ptr", this.event, this.overlap, A_PtrSize = 8 ? 24 : 16)
        SetTimer(this.timer, 10)
        return true
    }

    ; timer callback は保留 I/O を待たず、完了した分だけを回収する。
    Tick() {
        if this.stage = "cancel" {
            if DllCall("GetOverlappedResult", "Ptr", this.handle, "Ptr", this.overlap, "UInt*", &count := 0, "Int", 0) || A_LastError != 996
                this.Close()
            return
        }
        if DllCall("GetTickCount64", "UInt64") - this.started >= this.deadline {
            this.Fail("IPC 応答期限切れ。操作結果は未確認です。")
            return
        }
        if this.stage = "connect" {
            ; generic write の FILE_CREATE_PIPE_INSTANCE と server の impersonation を要求しない。
            h := DllCall("CreateFileW", "Str", this.path, "UInt", 0x120183, "UInt", 0, "Ptr", 0, "UInt", 3, "UInt", 0x40100000, "Ptr", 0, "Ptr")
            if h = -1 {
                if A_LastError != 2 && A_LastError != 231
                    this.Finish("", "IPC 接続失敗: " A_LastError)
                return
            }
            this.handle := h
            this.Issue("write")
            return
        }
        ok := DllCall("GetOverlappedResult", "Ptr", this.handle, "Ptr", this.overlap, "UInt*", &count := 0, "Int", 0)
        if !ok {
            if A_LastError != 996
                this.Finish("", "IPC 切断: " A_LastError)
            return
        }
        if this.stage = "write" {
            if count != this.input.Size - 1
                this.Finish("", "IPC 要求を送信できませんでした。")
            else
                this.Issue("read")
            return
        }
        if !count {
            this.Finish("", "IPC 応答がありません。")
            return
        }
        this.used += count
        if NumGet(this.output, this.used - 1, "UChar") = 10 {
            this.Finish(StrGet(this.output, this.used - 1, "UTF-8"), "")
        } else if this.used = this.output.Size {
            this.Finish("", "IPC 応答が上限を超えています。")
        } else {
            this.Issue("read")
        }
    }

    ; OVERLAPPED の再利用は直前の操作の完了後に限定する。
    Issue(stage) {
        this.stage := stage
        DllCall("ResetEvent", "Ptr", this.event)
        if stage = "write"
            ok := DllCall("WriteFile", "Ptr", this.handle, "Ptr", this.input, "UInt", this.input.Size - 1, "Ptr", 0, "Ptr", this.overlap)
        else
            ok := DllCall("ReadFile", "Ptr", this.handle, "Ptr", this.output.Ptr + this.used, "UInt", this.output.Size - this.used, "Ptr", 0, "Ptr", this.overlap)
        if !ok && A_LastError != 997
            this.Finish("", "IPC I/O 失敗: " A_LastError)
    }

    ; CancelIoEx は完了を保証しないため、取消後も buffer を解放しない。
    Fail(message) {
        if this.stage = "read" || this.stage = "write" {
            this.stage := "cancel"
            DllCall("CancelIoEx", "Ptr", this.handle, "Ptr", this.overlap)
            this.callback.Call("", message)
        } else {
            this.Finish("", message)
        }
    }

    ; handle を解放してから利用側へ通知し、callback からの次要求を許可する。
    Finish(text, message) {
        callback := this.callback
        this.Close()
        callback.Call(text, message)
    }

    ; 完了済みの I/O 資源だけを解放する。
    Close() {
        SetTimer(this.timer, 0)
        if this.handle
            DllCall("CloseHandle", "Ptr", this.handle)
        if this.event
            DllCall("CloseHandle", "Ptr", this.event)
        this.handle := 0
        this.event := 0
        this.busy := false
    }
}

; Base64 により device 名に含まれる区切り文字と UTF-8 を安全に扱う。
MwsDecode(text) {
    if text = ""
        return ""
    size := 0
    if !DllCall("crypt32\CryptStringToBinaryW", "Str", text, "UInt", 0, "UInt", 1, "Ptr", 0, "UInt*", &size, "Ptr", 0, "Ptr", 0)
        throw ValueError("IPC の文字列が不正です。")
    data := Buffer(size + 1, 0)
    if !DllCall("crypt32\CryptStringToBinaryW", "Str", text, "UInt", 0, "UInt", 1, "Ptr", data, "UInt*", &size, "Ptr", 0, "Ptr", 0)
        throw ValueError("IPC の文字列を復号できません。")
    return StrGet(data, size, "UTF-8")
}

; request ID、version、boot ID を対応付けてから UI に渡す。
MwsParse(text, requestId) {
    p := StrSplit(text, "`t")
    if p.Length != 13 || p[1] != "1" || p[2] != requestId || p[3] = ""
        throw ValueError("IPC protocol または request ID が一致しません。")
    devices := []
    if p[13] != "" {
        for row in StrSplit(p[13], ";") {
            d := StrSplit(row, ",")
            if d.Length != 6
                throw ValueError("IPC の device 情報が不正です。")
            devices.Push({id: MwsDecode(d[1]), name: MwsDecode(d[2]), manufacturer: MwsDecode(d[3]), state: d[4], recovery: d[5] = "1", result: MwsDecode(d[6])})
        }
    }
    return {request: requestId, boot: p[3], accepted: p[4], state: p[5], active: p[6], scheduled: p[7] = "1", stopping: p[8] = "1", error: MwsDecode(p[9]), operation: p[10], result: p[11], message: MwsDecode(p[12]), devices: devices}
}
