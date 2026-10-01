; トレイ表示を純粋な変換にし、模擬サービスの状態で検証可能にする。
MwsPresentation(state, detail) {
    labels := Map("Enabled", "有効", "Disabled", "無効", "Partial", "一部無効", "Unknown", "状態不明")
    label := labels.Has(state) ? labels[state] : "状態不明"
    return {label: label, icon: state = "Enabled" ? 18 : state = "Disabled" ? 131 : 110,
        tip: SubStr("Mouse Wake Suppressor`n" label " " detail, 1, 127)}
}

; 受付と結果を分離し、再起動や失われた要求を成功通知に変換しない。
MwsCompletion(state, pending, command) {
    if !pending
        return {clear: false, message: "", success: false}
    if pending.boot != state.boot
        return {clear: true, message: "サービスが再起動しました。先の操作結果は未確認です。", success: false}
    if state.request = pending.id && (state.accepted = "Rejected" || state.accepted = "Restarted" || state.accepted = "VersionMismatch")
        return {clear: true, message: "要求が受け付けられませんでした: " state.accepted, success: false}
    if state.operation = pending.id && state.result != "Pending" {
        labels := Map("Success", "全成功", "Partial", "部分成功", "Failed", "失敗", "Cancelled", "取消")
        label := labels.Has(state.result) ? labels[state.result] : "結果不明"
        return {clear: true, message: label ": " state.message, success: state.result = "Success"}
    }
    if command = "status" && state.result = "Missing"
        return {clear: true, message: "操作の受付または結果を確認できません。現在の状態を確認してください。", success: false}
    return {clear: false, message: "", success: false}
}
