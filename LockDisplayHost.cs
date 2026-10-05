using System;
using System.Diagnostics;
using System.Collections.Generic;
using System.Threading;

namespace MouseWakeSuppressor
{
    internal sealed class LockDisplayHost : IDisposable
    {
        private readonly object gate = new object();
        private readonly IniConfig config;
        private readonly Action<string, LogLevel> log;
        private readonly AutoResetEvent wake = new AutoResetEvent(false);
        private readonly Thread worker;
        private volatile bool stopping;
        private bool invalidated;
        private long invalidation;
        private Process helper;
        private PipeServer pipe;
        private int session = -1;
        private string generation = "", identity = "", status = "初期化中", lastReport = "";
        private readonly Dictionary<string, long> logged = new Dictionary<string, long>();
        private LockSettings settings;
        private long heartbeat, probeUntil, lockStarted, helperStarted;
        private bool diagnostic;
        internal LockDisplayHost(IniConfig config, Action<string, LogLevel> log)
        {
            this.config = config; this.log = log;
            worker = new Thread(Loop) { IsBackground = true, Name = "lock-display" }; worker.Start();
        }
        internal string Read() { lock (gate) return status + (helper == null && lastReport != "" ? " / 前回: " + lastReport : ""); }
        internal string Probe()
        {
            lock (gate)
            {
                try
                {
                    LockSettings value = config.LoadLock();
                    if (value.Enabled || value.Keyboards.Count == 0) throw new InvalidOperationException("診断はキーボード選択後、Enabled=0 で開始してください。");
                    probeUntil = LockNative.Now + 300000; invalidated = true; invalidation++; wake.Set();
                    status = "入力診断を予約しました (5 分間、消灯要求なし)。ロックして確認してください。";
                    return "Accepted";
                }
                catch (Exception ex) { status = "診断開始失敗: " + ex.Message; return "Rejected"; }
            }
        }
        internal void SessionChanged(int changedSession, bool locked)
        {
            lock (gate)
            {
                if (changedSession != session && changedSession != LockNative.ConsoleSession) return;
                invalidated = true; invalidation++; lockStarted = locked ? LockNative.Now : 0;
            }
            wake.Set();
        }
        private string Exchange(string request, uint client)
        {
            lock (gate)
            {
                string[] fields = request.TrimEnd('\n').Split('\t');
                if (stopping || invalidated || helper == null || client != helper.Id || fields.Length != 6 ||
                    fields[0] != "2" || fields[1] != generation || fields[2] != session.ToString()) return "STOP\n";
                try
                {
                    if (!LockNative.Locked(session) || config.LoadLock().Identity != identity) return "STOP\n";
                    long activity;
                    if (!long.TryParse(fields[3], out activity) || activity < 0 || activity > LockNative.Now) return "STOP\n";
                    string detail = System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(fields[5]));
                    if (detail.Length > 1024) return "STOP\n";
                    heartbeat = LockNative.Now;
                    status = "session=" + session + " / " + detail + " / 入力時刻=" + activity + " ms";
                    lastReport = status;
                    if (fields[4] != "OK") Warn(detail.StartsWith("OFF 通知待ち", StringComparison.Ordinal) ? "OFF 通知を連続して確認できません。" : detail);
                    return "2\t" + generation + "\t" + session + "\t" + settings.IdleSeconds + "\t" + settings.RetryMs + "\t" + Protocol.Encode(String.Join("|", settings.Keyboards.ToArray())) + "\t" + (diagnostic ? "0" : "1") + "\t" + helperStarted + "\n";
                }
                catch (Exception ex) { status = "監視停止: " + ex.Message; Warn(ex.Message); return "STOP\n"; }
            }
        }
        private void Loop()
        {
            while (!stopping)
            {
                try
                {
                    long observedInvalidation;
                    lock (gate) observedInvalidation = invalidation;
                    LockSettings next = config.LoadLock();
                    int target = LockNative.ConsoleSession;
                    bool probe;
                    lock (gate) probe = !next.Enabled && LockNative.Now < probeUntil;
                    if (probe && next.Keyboards.Count == 0) throw new InvalidOperationException("入力診断のキーボードが未登録です。");
                    bool locked = (next.Enabled || probe) && LockNative.Locked(target);
                    bool restart, unhealthy;
                    lock (gate)
                    {
                        restart = invalidated || identity != next.Identity || target != session || probe != diagnostic;
                        unhealthy = helper != null && (helper.HasExited || LockNative.Now - heartbeat > 3000);
                    }
                    if (unhealthy)
                    {
                        lock (gate) Warn("helper が終了したか、監視応答が途絶えました。再起動後に待機時間を数え直します。");
                        restart = true;
                    }
                    if (!locked || restart) StopHelper();
                    lock (gate)
                    {
                        if (observedInvalidation != invalidation) continue;
                        invalidated = false; settings = next; identity = next.Identity; session = target; diagnostic = probe;
                        if (next.Enabled) probeUntil = 0;
                        if (!next.Enabled && !probe) status = "無効";
                        else if (!locked) status = probe ? "入力診断のロック待ち (消灯要求なし)" : "ロック待ち";
                        else if (helper == null)
                        {
                            generation = Guid.NewGuid().ToString("N");
                            string name = "MwsLock-" + generation;
                            pipe = new PipeServer(null, name, "D:P(A;;GA;;;SY)", Exchange);
                            heartbeat = LockNative.Now;
                            helperStarted = lockStarted > 0 ? lockStarted : heartbeat;
                            lockStarted = 0;
                            helper = LockNative.Launch(session, name, generation);
                            status = "helper の監視開始待ち";
                        }
                    }
                }
                catch (Exception ex)
                {
                    StopHelper();
                    lock (gate) { status = "監視停止: " + ex.Message; Warn(ex.Message); }
                }
                wake.WaitOne(500);
            }
            StopHelper();
        }
        private void Warn(string message)
        {
            long now = LockNative.Now, last;
            if (logged.TryGetValue(message, out last) && now - last < 300000) return;
            if (logged.Count >= 256) logged.Clear();
            logged[message] = now; log("LockDisplay: " + message, LogLevel.Warning);
        }
        private void StopHelper()
        {
            Process process; PipeServer server;
            lock (gate) { process = helper; helper = null; server = pipe; pipe = null; generation = ""; }
            if (server != null) server.Dispose();
            if (process != null)
            {
                try
                {
                    if (!process.WaitForExit(1500)) { process.Kill(); process.WaitForExit(); }
                }
                catch (InvalidOperationException) { /* 既に終了した process は回収済み。 */ }
                catch (System.ComponentModel.Win32Exception ex) { lock (gate) Warn("helper の回収に失敗しました: " + ex.Message); }
                finally { process.Dispose(); }
            }
        }
        /// <summary>lease を無効化して helper と監視 thread を回収します。</summary>
        public void Dispose()
        {
            stopping = true; wake.Set(); worker.Join(); wake.Dispose();
        }
    }
}
