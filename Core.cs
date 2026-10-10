using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;

namespace MouseWakeSuppressor
{
    internal enum DeviceState { Enabled, Disabled, Unknown }
    internal enum LogLevel { Information, Warning, Error }
    internal sealed class Device
    {
        internal string Id, Name, Manufacturer;
        internal DeviceState State;
        internal string Result = "";
        internal bool Recovery;
        internal Device Copy() { return (Device)MemberwiseClone(); }
    }
    internal sealed class Execution
    {
        internal int? ExitCode;
        internal bool TimedOut;
        internal string Output = "", Error = "";
        internal bool Good { get { return ExitCode == 0 && !TimedOut && Error == ""; } }
        internal string Detail { get { return "exit=" + ExitCode + "; timeout=" + TimedOut + "; " + Error + " " + Output; } }
    }
    internal interface IDevices
    {
        List<Device> Enumerate();
        DeviceState Query(string id);
        Execution Run(string id, bool enable, int timeout, Func<bool> cancel);
    }
    internal interface IRecovery
    {
        bool Exists { get; }
        HashSet<string> Load();
        void Save(HashSet<string> ids);
    }
    internal sealed class Settings
    {
        internal List<string> Ids = new List<string>();
        internal int Delay = 5000, Timeout = 5000;
        internal bool Information;
    }
    internal interface IConfig { Settings Load(); void Reset(); }
    internal interface IScheduler { IDisposable After(int milliseconds, Action callback); }
    internal sealed class Scheduler : IScheduler
    {
        /// <summary>取消可能な一回限りの callback を登録します。</summary>
        public IDisposable After(int milliseconds, Action callback) { return new Timer(_ => callback(), null, milliseconds, Timeout.Infinite); }
    }
    internal sealed class Operation
    {
        internal string Id, Command, Result = "Pending", Message = "";
        internal long Generation;
        internal Operation Copy() { return (Operation)MemberwiseClone(); }
    }
    internal sealed class Snapshot
    {
        internal string Boot, State, Active, Error;
        internal bool Scheduled, Stopping;
        internal List<Device> Devices;
        internal List<Device> Available;
        internal Operation Operation;
    }

    // 外部処理は worker 専用。gate 内ではメモリだけを更新し、IPC を待たせない。
    internal sealed class Engine : IDisposable
    {
        internal Func<string> LockStatus = () => "無効";
        internal Func<List<Device>> Keyboards = () => new List<Device>();
        internal Func<string> LockProbe = () => "Rejected";
        private readonly object gate = new object();
        private readonly IDevices hardware;
        private readonly IRecovery journal;
        private readonly IConfig config;
        private readonly IScheduler scheduler;
        private readonly Action<string, LogLevel> log;
        private readonly AutoResetEvent wake = new AutoResetEvent(false);
        private readonly LinkedList<Operation> queue = new LinkedList<Operation>();
        private readonly Dictionary<string, Operation> operations = new Dictionary<string, Operation>();
        private readonly Queue<string> completed = new Queue<string>();
        private readonly Dictionary<string, Device> observed = new Dictionary<string, Device>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, DateTime> logged = new Dictionary<string, DateTime>();
        private readonly string boot = Guid.NewGuid().ToString("N");
        private List<Device> available = new List<Device>();
        private HashSet<string> recovery = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private Settings settings = new Settings();
        private Thread worker;
        private IDisposable reservation;
        private long generation;
        private volatile bool stopping;
        private bool corrupt, uncertain, ready;
        private string active = "startup", error = "";

        internal Engine(IDevices hardware, IRecovery journal, IConfig config, IScheduler scheduler, Action<string, LogLevel> log)
        { this.hardware = hardware; this.journal = journal; this.config = config; this.scheduler = scheduler; this.log = log; }
        internal void Start()
        {
            worker = new Thread(Loop) { IsBackground = true, Name = "device-worker" };
            worker.Start();
        }
        internal Snapshot Read(string request)
        {
            lock (gate)
            {
                Operation op;
                var devices = observed.Values.Select(d => d.Copy()).ToList();
                string state = "Unknown";
                if (ready && devices.Count == 0 && !corrupt) state = "Enabled";
                else if (devices.Count > 0 && devices.All(d => d.State == DeviceState.Enabled)) state = "Enabled";
                else if (devices.Count > 0 && devices.All(d => d.State == DeviceState.Disabled)) state = "Disabled";
                else if (devices.Any(d => d.State == DeviceState.Disabled)) state = "Partial";
                return new Snapshot { Boot = boot, State = state, Active = active, Error = error,
                    Scheduled = reservation != null, Stopping = stopping, Devices = devices, Available = available.Select(d => d.Copy()).ToList(),
                    Operation = operations.TryGetValue(request ?? "", out op) ? op.Copy() : null };
            }
        }
        internal string Submit(string command, string id)
        {
            lock (gate)
            {
                if (stopping) return "Rejected";
                Operation previous;
                if (operations.TryGetValue(id, out previous)) return previous.Command == command ? "Accepted" : "Rejected";
                if (stopping || !ready || queue.Count >= 64) return "Rejected";
                if (command == "schedule") { ScheduleLocked(); return "Accepted"; }
                if (command != "enable" && command != "disable" && command != "toggle" && command != "reload" && command != "reset") return "Rejected";
                bool restore = command == "enable" || command == "reset" ||
                    (command == "toggle" && (recovery.Count > 0 || active == "disable" || observed.Values.Any(d => d.State != DeviceState.Enabled)));
                CancelLocked();
                var op = new Operation { Id = id, Command = command, Generation = generation };
                operations.Add(id, op);
                if (restore) queue.AddFirst(op); else queue.AddLast(op);
                wake.Set();
                return "Accepted";
            }
        }
        internal void Schedule() { lock (gate) { if (ready && !stopping) ScheduleLocked(); } }
        private void ScheduleLocked()
        {
            if (reservation != null || recovery.Count > 0 || active == "disable" || queue.Any(o => o.Command == "disable")) return;
            long expected = ++generation;
            reservation = scheduler.After(settings.Delay, () =>
            {
                lock (gate)
                {
                    // Dispose 後の callback と queue 後の取消の両方を識別する。
                    if (stopping || reservation == null || generation != expected) return;
                    reservation.Dispose(); reservation = null;
                    queue.AddLast(new Operation { Id = Guid.NewGuid().ToString("N"), Command = "disable", Generation = expected });
                    wake.Set();
                }
            });
        }
        private void CancelLocked()
        {
            generation++;
            if (reservation != null) { reservation.Dispose(); reservation = null; }
        }
        internal void BeginStop()
        {
            lock (gate)
            {
                stopping = true;
                CancelLocked();
                foreach (var op in queue) FinishLocked(op, "Cancelled", "サービス停止により取り消しました。");
                queue.Clear(); wake.Set();
            }
        }
        internal bool Join(int timeout) { return worker == null || worker.Join(timeout); }
        internal void Stop() { BeginStop(); if (worker != null) worker.Join(); }
        /// <summary>worker の終了後に待機 handle を解放します。</summary>
        public void Dispose() { Stop(); wake.Dispose(); }
        private void Loop()
        {
            try { Initialize(); }
            catch (Exception ex) { uncertain = true; Fail(ex); }
            lock (gate) { ready = true; active = ""; }
            while (true)
            {
                Operation op = null;
                lock (gate)
                {
                    if (stopping) break;
                    if (queue.Count > 0) { op = queue.First.Value; queue.RemoveFirst(); active = op.Command; }
                }
                if (op != null)
                {
                    try { Execute(op); }
                    catch (Exception ex) { uncertain = true; Fail(ex); lock (gate) FinishLocked(op, "Failed", ex.Message); }
                    finally { lock (gate) active = ""; }
                }
                else
                {
                    try { Refresh(); } catch (Exception ex) { Fail(ex); }
                    wake.WaitOne(1000);
                }
            }
            try { Restore(); } catch (Exception ex) { Fail(ex); }
        }
        private void Initialize()
        {
            // 設定が壊れていても過去の復旧対象を先に読む。
            try { recovery = journal.Load(); }
            catch (Exception ex) { corrupt = true; Fail(ex); }
            bool migration = !corrupt && !journal.Exists;
            bool configLoaded = true;
            try { settings = config.Load(); } catch (Exception ex) { Fail(ex); uncertain = true; configLoaded = false; }
            if (migration)
            {
                // 旧版の設定を一回だけ復旧する。旧状態ファイルには依存しない。
                if (!configLoaded) return;
                foreach (string id in settings.Ids) recovery.Add(id);
                journal.Save(recovery);
            }
            if (!corrupt) Restore();
            Refresh();
        }
        private void Execute(Operation op)
        {
            string command = op.Command;
            if (command == "toggle")
            {
                lock (gate) command = recovery.Count > 0 || observed.Values.Any(d => d.State != DeviceState.Enabled) ? "enable" : "disable";
            }
            lock (gate) active = command;
            string result;
            if (command == "disable")
            {
                lock (gate)
                    if (stopping || op.Generation != generation) { FinishLocked(op, "Cancelled", "予約または要求が取り消されました。"); return; }
                result = Disable(op.Generation);
            }
            else if (command == "enable") result = Restore();
            else if (command == "reset")
            {
                result = Restore();
                if (result == "Success" && !corrupt) { config.Reset(); settings = config.Load(); }
                else result = "Failed";
            }
            else { settings = config.Load(); result = "Success"; }
            Refresh();
            lock (gate)
            {
                string message = result == "Success" ? "操作が完了しました。" : "未完了の対象があります。状態と復旧記録を確認してください。";
                if (result != "Success" && error == "") error = message;
                else if (result == "Success" && !corrupt && !uncertain) error = "";
                FinishLocked(op, result, message);
            }
            if (settings.Information) log(command + ": " + result, LogLevel.Information);
        }
        private string Disable(long expected)
        {
            if (corrupt || uncertain) throw new InvalidOperationException("復旧記録または実状態が不明なため、新規無効化を禁止しています。有効化を再試行してください。");
            settings = config.Load();
            if (settings.Ids.Count == 0) throw new InvalidOperationException("対象マウスが未設定です。トレイメニューから選択してください。");
            var mice = hardware.Enumerate();
            var targets = new List<string>();
            int success = 0, failed = 0;
            foreach (string id in settings.Ids)
            {
                // 設定経由でも Mouse クラス以外の操作を許可しない。
                if (!mice.Any(d => String.Equals(d.Id, id, StringComparison.OrdinalIgnoreCase))) { SetObserved(id, DeviceState.Unknown, "Mouse クラスに見つかりません。"); failed++; continue; }
                DeviceState state = hardware.Query(id);
                if (state == DeviceState.Enabled) targets.Add(id);
                else if (state == DeviceState.Disabled) success++;
                else failed++;
            }
            var saved = CopyRecovery();
            foreach (string id in targets) saved.Add(id);
            // write-ahead: 一括保存に失敗したら一台も無効化しない。
            journal.Save(saved);
            lock (gate) recovery = saved;
            foreach (string id in targets)
            {
                if (Cancelled(expected)) { failed++; continue; }
                if (hardware.Query(id) != DeviceState.Enabled) { failed++; continue; }
                Execution run = hardware.Run(id, false, settings.Timeout, () => Cancelled(expected));
                DeviceState state = hardware.Query(id);
                SetObserved(id, state, run.Detail);
                if (state == DeviceState.Disabled && run.Good) success++; else failed++;
                if (!run.Good || state != DeviceState.Disabled) Warn("無効化未完了: " + id + " " + run.Detail);
                if (state == DeviceState.Unknown)
                {
                    uncertain = true;
                    failed += targets.Count - targets.IndexOf(id) - 1;
                    break;
                }
            }
            return Outcome(success, failed);
        }
        private bool Cancelled(long expected) { lock (gate) return stopping || expected != generation; }
        private string Restore()
        {
            if (corrupt) return "Failed";
            var pending = CopyRecovery();
            int success = 0, failed = 0;
            foreach (string id in CopyRecovery())
            {
                DeviceState before = hardware.Query(id);
                Execution run = null;
                if (before != DeviceState.Enabled) run = hardware.Run(id, true, settings.Timeout, () => false);
                DeviceState after = hardware.Query(id);
                SetObserved(id, after, run == null ? "既に有効です。" : run.Detail);
                // 未接続や API エラーを成功とみなさず、復旧義務を維持する。
                if (after == DeviceState.Enabled) { pending.Remove(id); success++; }
                else { failed++; Warn("復旧未完了: " + id + " " + (run == null ? "" : run.Detail)); }
            }
            journal.Save(pending);
            lock (gate) { recovery = pending; if (pending.Count == 0) { uncertain = false; error = ""; } }
            return Outcome(success, failed);
        }
        private HashSet<string> CopyRecovery() { lock (gate) return new HashSet<string>(recovery, StringComparer.OrdinalIgnoreCase); }
        private static string Outcome(int success, int failed) { return failed == 0 ? "Success" : success == 0 ? "Failed" : "Partial"; }
        private void Refresh()
        {
            var all = hardware.Enumerate();
            lock (gate) available = all;
            var ids = new HashSet<string>(settings.Ids, StringComparer.OrdinalIgnoreCase);
            ids.UnionWith(CopyRecovery());
            foreach (string id in ids) SetObserved(id, hardware.Query(id), null);
            lock (gate)
            {
                foreach (string id in observed.Keys.Where(id => !ids.Contains(id)).ToArray()) observed.Remove(id);
                foreach (Device d in observed.Values) d.Recovery = recovery.Contains(d.Id);
            }
        }
        private void SetObserved(string id, DeviceState state, string result)
        {
            lock (gate)
            {
                Device d;
                if (!observed.TryGetValue(id, out d)) { d = new Device { Id = id, Name = id, Manufacturer = "" }; observed.Add(id, d); }
                d.State = state; d.Recovery = recovery.Contains(id);
                if (result != null) d.Result = result;
            }
        }
        private void FinishLocked(Operation op, string result, string message)
        {
            op.Result = result; op.Message = message;
            if (operations.ContainsKey(op.Id)) completed.Enqueue(op.Id);
            while (completed.Count > 256) operations.Remove(completed.Dequeue());
        }
        private void Fail(Exception ex) { lock (gate) error = ex.Message; Warn(ex.Message, LogLevel.Error); }
        private void Warn(string message, LogLevel level = LogLevel.Warning)
        {
            DateTime last;
            if (logged.TryGetValue(message, out last) && DateTime.UtcNow - last < TimeSpan.FromMinutes(5)) return;
            if (logged.Count > 256) logged.Clear();
            logged[message] = DateTime.UtcNow; log(message, level);
        }
    }
}
