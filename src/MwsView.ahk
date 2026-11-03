; トレイ表示を純粋な変換にし、模擬サービスの状態で検証可能にする。
MwsLockSettingsError(enabled, ids, idle, retry) {
    if enabled && ids = ""
        return "先に無入力時間を監視するキーボードを選択してください。"
    if !IsInteger(idle) || idle < 1 || idle > 600
        return "消灯までの無入力時間は 1..600 秒の整数で指定してください。"
    if !IsInteger(retry) || retry < 1000 || retry > 600000
        return "消灯要求の再試行間隔は 1000..600000 ms の整数で指定してください。"
    return ""
}

; トレイ表示を純粋な変換にし、模擬サービスの状態で検証可能にする。
MwsPresentation(state, detail) {
    labels := Map("Enabled", "有効", "Disabled", "無効", "Partial", "一部無効", "Unknown", "状態不明")
    label := labels.Has(state) ? labels[state] : "状態不明"
    return {label: label, icon: state = "Enabled" ? 18 : state = "Disabled" ? 131 : 110,
        tip: SubStr("Mouse Wake Suppressor`nマウス: " label " " detail, 1, 127)}
}

; 状態表示と操作を分離し、ダブルクリックによる意図しない無効化を防ぐ。
MwsBuildTray(rootMenu, label, detail, devices, request, showDevice, showLock) {
    rootMenu.Delete()
    for text in ["マウス: " label, "Win+Shift+M: マウス無効化 / 復旧"] {
        rootMenu.Add(text, (*) => 0)
        rootMenu.Disable(text)
    }
    if detail != "" {
        text := SubStr(detail, 1, 180)
        rootMenu.Add(text, (*) => 0)
        rootMenu.Disable(text)
    }
    rootMenu.Add()
    mouse := Menu()
    mouseActions := [request.Bind("enumerate", false), request.Bind("enable", true), request.Bind("reload", true), request.Bind("reset", true)]
    for index, text in ["対象マウス...", "復旧を再試行", "設定を再読み込み", "復旧してマウス選択をリセット"]
        mouse.Add(text, mouseActions[index])
    if devices.Length {
        mouse.Add()
        for index, d in devices
            mouse.Add(index ": " d.id " [" d.state "]" (d.recovery ? " 復旧対象" : ""), showDevice.Bind(d))
    }
    lock := Menu()
    lockActions := [request.Bind("keyboards", false), request.Bind("lock-probe", false), showLock]
    for index, text in ["設定...", "入力診断 (5 分間)", "監視状態..."]
        lock.Add(text, lockActions[index])
    rootMenu.Add("マウス再点灯防止", mouse)
    rootMenu.Add("ロック中の強制消灯", lock)
    rootMenu.Add()
    rootMenu.AddStandard()
    rootMenu.Default := ""
    return {mouse: mouseActions, lock: lockActions}
}

; 現在の状態と前回の記録を混同せず、service の状態を短い案内にする。
MwsLockSummary(raw) {
    current := StrSplit(raw, " / 前回: ")[1]
    if InStr(current, "通信不能") || current = "接続待ち"
        return "service と通信できていないため、現在の状態は不明です。"
    if InStr(current, "監視停止") || InStr(current, "失敗")
        return "監視エラー。監視状態の技術詳細を確認してください。"
    if InStr(current, "入力診断のロック待ち") || InStr(current, "入力診断を予約")
        return "入力診断の準備完了。5 分の受付時間内にロックしてください。消灯要求は送りません。"
    if current = "無効"
        return "強制消灯は OFF です。使う場合は設定で ON にしてください。"
    if current = "ロック待ち"
        return "強制消灯は ON です。ロック後に無入力時間を数えます。"
    if InStr(current, "入力診断")
        return "キーボードの入力を診断中です。消灯要求は送りません。"
    if InStr(current, "OFF 通知確認済み")
        return "OS から消灯通知を受信しました。"
    if InStr(current, "OFF 通知待ち")
        return "消灯を要求しましたが、OS からの消灯通知はまだ確認できていません。"
    if InStr(current, "入力待機中")
        return "監視中です。登録キーボードの無入力時間が設定値に達すると消灯を要求します。"
    if InStr(current, "開始") || current = "初期化中"
        return "入力監視を準備しています。"
    return "状態を確認できません。技術詳細を確認してください。"
}

; 時刻の数字や内部 ID の代わりに、利用者が確認できる結果を示す。
MwsLockExplanation(raw, now) {
    parts := StrSplit(raw, " / 前回: ", , 2)
    text := "現在: " MwsLockSummary(parts[1])
    report := parts.Length = 2 ? parts[2] : parts[1]
    if parts.Length = 2
        text .= "`n`n前回のロック中の記録 (今回の診断結果とは限りません):`n" MwsLockSummary(report)
    if RegExMatch(report, "入力時刻=(\d+) ms", &match) {
        stamp := Integer(match[1])
        text .= "`n登録キーボードの入力: " (stamp > 0 ? "検出あり" : "この監視期間では未検出")
        if stamp > 0 && stamp <= now
            text .= " (最後の検出は約 " Floor((now - stamp) / 1000) " 秒前)"
    }
    if RegExMatch(report, "OFF 要求=(\d+)@", &match)
        text .= "`n消灯を要求した回数: " match[1] (InStr(report, "入力診断") ? " (入力診断では 0 回が正常)" : "")
    if RegExMatch(report, "表示通知=(-?\d+)@", &match) {
        labels := Map("0", "消灯", "1", "点灯", "2", "減光", "-1", "未取得")
        text .= "`nOS が最後に通知した画面状態: " (labels.Has(match[1]) ? labels[match[1]] : "不明")
    }
    if InStr(report, "入力診断")
        text .= "`n`n登録入力の検出だけで、Parsec などを区別できたとは判断できません。アンロック時のキー入力も含まれます。「入力診断の手順」を参照してください。"
    return text
}

; 診断は消灯の成否ではなく、登録キーボードの入力識別を確認するために使う。
MwsDiagnosticHelp() {
    return "目的: 選択した物理キーボードの入力が検出されるかを確認します。診断中、この機能は消灯要求を送りません。Windows 標準の消灯設定は動作します。"
        . "`n`n準備: 設定で対象キーボードを選択して保存し、「ロック中の強制消灯を使う」を OFF にします。"
        . "`n`n1. 診断を開始し、5 分以内に Win+L でロックします。"
        . "`n2. 対象キーボードの Ctrl を押し、数秒待ってからアンロックします。"
        . "`n3. 「監視状態」を開き直し、前回の記録で「登録キーボードの入力: 検出あり」、監視エラーなし、消灯要求 0 回を確認します。未検出なら選択や接続を見直してください。"
        . "`n`n対象外入力の確認: マウスのみ、Parsec のみの試験を別々に行います。アンロック操作も登録入力として記録されるため、「検出あり」だけでは対象外入力を誤検出したか判断できません。技術詳細の入力時刻と操作時刻を照合し、判断できなければ未確認として扱います。"
        . "`n`n確認後: 設定を ON に戻し、設定した無入力時間で実際に消灯することを別途確認します。"
}

; 操作結果の確認速度を維持しつつ、battery 使用時の idle wake-up を減らす。
MwsPollInterval(onBattery, pending, regularInterval, batteryInterval, fastInterval) {
    return pending ? fastInterval : onBattery ? batteryInterval : regularInterval
}

; GetSystemPowerStatus の不明値は省電力側へ倒す。
MwsAcLineOnBattery(acLineStatus) {
    return acLineStatus != 1
}

; power setting の battery と short-term power を同じ省電力方針にする。
MwsPowerSourceOnBattery(powerSource) {
    return powerSource != 0
}

; 後から来た遅い予約で、既に必要な早い wake-up を延期しない。
MwsEarlierDue(currentDue, requestedDue) {
    return !currentDue || requestedDue < currentDue ? requestedDue : currentDue
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
