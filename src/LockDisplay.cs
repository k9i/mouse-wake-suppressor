using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace MouseWakeSuppressor
{
    // Raw Input handle は desktop ごとに変わり得るため、正常な再登録では Instance ID を基準にする。
    internal sealed class LockKeyboardMap
    {
        private Dictionary<IntPtr, string> values = new Dictionary<IntPtr, string>();
        internal bool Contains(IntPtr handle) { return values.ContainsKey(handle); }
        internal void Clear() { values.Clear(); }
        internal bool Replace(Dictionary<IntPtr, string> current, bool desktopChanged)
        {
            bool changed;
            if (desktopChanged)
                changed = !new HashSet<string>(values.Values, StringComparer.OrdinalIgnoreCase).SetEquals(current.Values);
            else
                changed = values.Count != current.Count || current.Any(pair => !values.ContainsKey(pair.Key) ||
                    !String.Equals(values[pair.Key], pair.Value, StringComparison.OrdinalIgnoreCase));
            values = new Dictionary<IntPtr, string>(current);
            return changed;
        }
    }

    internal sealed class LockSettings
    {
        internal bool Enabled;
        internal int IdleSeconds = 30, RetryMs = 1000;
        internal List<string> Keyboards = new List<string>();
        internal void Validate()
        {
            if (IdleSeconds < 1 || IdleSeconds > 600 || RetryMs < 1000 || RetryMs > 600000)
                throw new InvalidDataException("LockDisplay の待機秒数は 1..600、再試行間隔は 1000..600000 ms です。");
            foreach (string id in Keyboards) IniConfig.ValidateId(id);
            if (Enabled && Keyboards.Count == 0) throw new InvalidDataException("LockDisplay の対象キーボードが未登録です。");
        }
        internal string Identity { get { return (Enabled ? "1" : "0") + ":" + IdleSeconds + ":" + RetryMs + ":" + String.Join("|", Keyboards.ToArray()); } }
    }

    // 単調時計を注入し、入力と消灯の判定を helper の同一 thread で直列化する。
    internal sealed class LockDeadline
    {
        private readonly LockSettings settings;
        private long due, retry, generation;
        private bool healthy, off, attempted;
        internal int Unconfirmed { get; private set; }
        internal long Activity { get; private set; }
        internal int Requests { get; private set; }
        internal long LastRequest { get; private set; }
        internal long LastDisplayNotification { get; private set; }
        internal int DisplayValue = -1;
        internal string State { get { return !healthy ? "監視停止" : off ? "OFF 通知確認済み" : attempted ? "OFF 通知待ち (未確認: " + Unconfirmed + ")" : "入力待機中"; } }
        internal LockDeadline(LockSettings settings) { this.settings = settings; }
        internal void Reset(long now, bool monitoring)
        {
            // 入力監視の復旧と表示状態は独立させ、確認済み OFF を失わない。
            generation++; healthy = monitoring; attempted = false; Unconfirmed = 0;
            Activity = 0; due = now + settings.IdleSeconds * 1000L; retry = 0;
        }
        internal void Input(long now, bool registeredKeyboard)
        {
            if (!healthy || !registeredKeyboard) return;
            generation++; Activity = now; due = now + settings.IdleSeconds * 1000L;
            attempted = false; retry = 0; Unconfirmed = 0;
        }
        internal void Display(long now, int value)
        {
            DisplayValue = value; LastDisplayNotification = now;
            bool wasOff = off;
            off = value == 0;
            if (off) { Unconfirmed = 0; generation++; }
            else if (wasOff && now >= due) { retry = now + settings.RetryMs; generation++; }
        }
        internal long Ticket(long now) { return healthy && !off && now >= due && now >= retry ? generation : -1; }
        internal bool Commit(long ticket, long now)
        {
            if (ticket < 0 || Ticket(now) != ticket) return false;
            attempted = true; Unconfirmed++; retry = now + settings.RetryMs; generation++;
            Requests++; LastRequest = now;
            return true;
        }
    }
}
