using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Text;
using System.Threading;

namespace MouseWakeSuppressor
{
    internal static class Tests
    {
        private static int count;
        private static int Main(string[] args)
        {
            // テスト異常は stderr と exit code に残し、OS の error dialog を表示しない。
            SetErrorMode(3);
            if (args.Length == 2 && args[0] == "--mock")
            {
                try { return Mock(args[1]); }
                catch (Exception ex) { Console.Error.WriteLine(ex); return 1; }
            }
            if (args.Length != 1 || args[0] != "--test") { Console.WriteLine("実デバイスを変更しないテストです。使い方: __tests.exe --test | --mock <pipe名>"); return 64; }
            try
            {
                Run("正常往復と状態照会の書き込み回数", RoundTrip);
                Run("部分失敗と部分状態の toggle", Partial);
                Run("保存失敗では無効化しない", SaveFailure);
                Run("設定変更後の復旧", ConfigChange);
                Run("復旧失敗時の reset 保護と再試行", ResetFailure);
                Run("起動時の復旧と破損記録の保護", Startup);
                Run("旧版設定の一回限りの移行", Migration);
                Run("timeout と不明状態で後続無効化を禁止", TimeoutFailure);
                Run("終了コード 50 を成功扱いしない", Exit50);
                Run("既に無効だった対象を取り込まない", AlreadyDisabled);
                Run("重複予約と stale callback", Reservations);
                Run("操作中の照会と逆方向要求", Concurrent);
                Run("停止中要求と復旧優先", Shutdown);
                Run("write-ahead と異常終了後の復旧", CrashRecovery);
                Run("復旧後の記録保存失敗でも対象を保持", RestoreSaveFailure);
                Run("通常ログの抑制と同一障害の抑制", Logging);
                Run("IPC version、boot、request の対応", ProtocolChecks);
                Run("復旧記録の atomic 更新と破損検出", FileJournal);
                Run("子プロセスの開始失敗と timeout 回収", Processes);
                Run("named pipe の切断と再接続", Pipes);
                Run("ロック消灯の境界と入力の分類", LockTiming);
                Run("再点灯の猶予と OFF 未確認の再試行", LockRetry);
                Run("取消、監視復旧、再接続と再起動", LockRecovery);
                Run("LockDisplay 設定の検証", LockConfiguration);
                Run("Raw Input と SetupAPI のキーボード ID 対応", KeyboardInterfaces);
                Run("入力診断の IPC 受付と旧 boot 拒否", LockProtocol);
                Run("desktop 間の keyboard handle 再照合と期限保持", DesktopKeyboardMap);
                Console.WriteLine("PASS: " + count + " tests"); return 0;
            }
            catch (Exception ex) { Console.Error.WriteLine("FAIL: " + ex); return 1; }
        }
        [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern uint SetErrorMode(uint mode);
        private static void Run(string name, Action test) { test(); count++; Console.WriteLine("PASS " + name); }
        private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
        private static LockDeadline Deadline()
        {
            var value = new LockDeadline(new LockSettings()); value.Reset(0, true); return value;
        }
        private static void DesktopKeyboardMap()
        {
            var map = new LockKeyboardMap(); var value = Deadline();
            map.Replace(new Dictionary<IntPtr, string> { { new IntPtr(1), "HID\\K" } }, false);
            value.Input(1000, true);
            bool reset = map.Replace(new Dictionary<IntPtr, string> { { new IntPtr(2), "hid\\k" } }, true);
            if (reset) value.Reset(10000, true);
            Check(!reset && value.Activity == 1000 && value.Ticket(31000) >= 0, "正常な desktop 切替で入力時刻と期限を維持");
            Check(!map.Contains(new IntPtr(1)) && map.Contains(new IntPtr(2)), "新 desktop の最初の入力を照合できる");
            Check(!map.Replace(new Dictionary<IntPtr, string> { { new IntPtr(2), "HID\\K" } }, false), "対象外デバイスの変更では延長しない");
            Check(map.Replace(new Dictionary<IntPtr, string> { { new IntPtr(3), "HID\\K" } }, false), "同じ desktop での再接続は検出");
            Check(map.Replace(new Dictionary<IntPtr, string> { { new IntPtr(3), "HID\\OTHER" } }, false), "handle 再利用は検出");
            Check(map.Replace(new Dictionary<IntPtr, string>(), true), "desktop 切替中の対象脱落は検出");
        }
        private static void LockTiming()
        {
            var value = Deadline();
            Check(value.Ticket(29999) < 0 && value.Ticket(30000) >= 0, "30 秒境界");
            value.Input(29999, false);
            Check(value.Ticket(30000) >= 0, "マウス、remote、未登録の入力は延長しない");
            long old = value.Ticket(30000);
            value.Input(30000, true);
            Check(!value.Commit(old, 30000), "確認中のキーボード入力で古い要求を取り消す");
            Check(value.Ticket(59999) < 0 && value.Ticket(60000) >= 0, "登録キーボードだけが 30 秒延長する");
            value.Reset(0, true); value.Display(20000, 0); value.Input(25000, true); value.Display(25001, 1);
            Check(value.Ticket(54999) < 0 && value.Ticket(55000) >= 0, "キー操作による復帰の期限");
        }
        private static void LockRetry()
        {
            var value = Deadline();
            Check(value.Commit(value.Ticket(30000), 30000), "初回要求");
            Check(value.State.Contains("通知待ち") && value.Unconfirmed == 1, "送信だけでは成功にしない");
            Check(value.Ticket(30999) < 0 && value.Ticket(31000) >= 0, "未確認時の最短再試行間隔");
            value.Commit(value.Ticket(31000), 31000);
            Check(value.Unconfirmed == 2, "未確認回数");
            value.Display(31001, 0);
            Check(value.Unconfirmed == 0 && value.Ticket(99999) < 0, "OFF 確認後は再送しない");
            value.Display(40000, 1);
            Check(value.Ticket(40999) < 0 && value.Ticket(41000) >= 0, "再点灯後の猶予");
            value.Display(40200, 1);
            Check(value.Ticket(41000) >= 0, "重複 ON で猶予を延長しない");
            value.Input(40999, true);
            Check(value.Ticket(41000) < 0 && value.Ticket(70999) >= 0, "猶予中の入力で再消灯取消");
        }
        private static void LockRecovery()
        {
            var value = Deadline(); long stale = value.Ticket(30000);
            value.Reset(30000, false);
            Check(!value.Commit(stale, 30000) && value.Ticket(99999) < 0, "アンロック、session 変更、監視失敗で取消");
            value.Reset(100000, true);
            Check(!value.Commit(stale, 130000), "旧世代を再利用しない");
            Check(value.Ticket(129999) < 0 && value.Ticket(130000) >= 0, "復旧と再接続後は新たな 30 秒");
            var restarted = Deadline(); restarted.Reset(200000, true);
            Check(restarted.Ticket(229999) < 0 && restarted.Ticket(230000) >= 0, "service 再起動後も新たな 30 秒");
            restarted.Display(230001, 0); restarted.Reset(240000, false); restarted.Reset(250000, true);
            Check(restarted.Ticket(280000) < 0, "入力監視の再接続で確認済み OFF を失わない");
            restarted.Display(280001, 1);
            Check(restarted.Ticket(281000) < 0 && restarted.Ticket(281001) >= 0, "監視復旧後の再点灯も猶予を設ける");
        }
        private static void LockConfiguration()
        {
            string directory = Path.Combine(Path.GetTempPath(), "__mws_lock_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            var config = new IniConfig(directory);
            var value = config.LoadLock();
            Check(!value.Enabled && value.IdleSeconds == 30 && value.RetryMs == 1000 && value.Keyboards.Count == 0, "既定は無効");
            string path = Path.Combine(directory, "mws_config.ini");
            foreach (string body in new[] { "Enabled=1", "Enabled=yes", "IdleTimeoutSeconds=0", "IdleTimeoutSeconds=601", "RetryIntervalMs=999", "KeyboardInstanceIds=invalid" })
            {
                File.WriteAllText(path, "[LockDisplay]\n" + body + "\n");
                bool failed = false; try { config.LoadLock(); } catch (InvalidDataException) { failed = true; }
                Check(failed, "不正設定の拒否: " + body);
            }
            File.WriteAllText(path, "[LockDisplay]\nEnabled=1\nIdleTimeoutSeconds=45\nRetryIntervalMs=2000\nKeyboardInstanceIds=HID\\A|hid\\a\n");
            value = config.LoadLock();
            Check(value.Enabled && value.IdleSeconds == 45 && value.RetryMs == 2000 && value.Keyboards.Count == 1, "設定と重複排除");
        }
        private static void KeyboardInterfaces()
        {
            // 読み取りだけで native layout と interface -> instance ID の経路を検証する。
            var available = new WindowsDevices(true).Enumerate();
            uint count = 0, size = (uint)System.Runtime.InteropServices.Marshal.SizeOf(typeof(LockNative.RawDevice));
            Check(LockNative.GetRawInputDeviceList(null, ref count, size) != uint.MaxValue, "Raw Input 一覧サイズ");
            var raw = new LockNative.RawDevice[count];
            uint found = LockNative.GetRawInputDeviceList(raw, ref count, size);
            Check(found != uint.MaxValue, "Raw Input 一覧");
            int mapped = 0;
            for (int i = 0; i < found; i++)
            {
                if (raw[i].Type != 1) continue;
                var name = new StringBuilder(4096); uint capacity = (uint)name.Capacity;
                Check(LockNative.GetRawInputDeviceInfo(raw[i].Handle, 0x20000007, name, ref capacity) != uint.MaxValue, "Raw Input device name");
                if (!name.ToString().StartsWith(@"\\?\", StringComparison.Ordinal)) continue;
                string id = LockNative.InstanceId(name.ToString());
                Check(available.Any(d => String.Equals(d.Id, id, StringComparison.OrdinalIgnoreCase)), "Keyboard クラスとの一致");
                mapped++;
            }
            Console.WriteLine("INFO: Raw Input keyboard interfaces=" + mapped + " (ロック中の入力受信は未検証)");
            int session = LockNative.ConsoleSession;
            if (session >= 0) LockNative.Locked(session);
        }
        private static void LockProtocol()
        {
            using (var f = new Fixture())
            {
                f.Start(); int probes = 0;
                f.Engine.LockProbe = () => { probes++; return "Accepted"; };
                f.Engine.LockStatus = () => "監視停止: テスト";
                f.Engine.Keyboards = () => new List<Device> { new Device { Id = "HID\\K", Name = "Keyboard", Manufacturer = "", State = DeviceState.Enabled } };
                string boot = f.Engine.Read("").Boot;
                string[] response = Protocol.Reply(f.Engine, "2\tprobe\told\tlock-probe\t\n").TrimEnd('\n').Split('\t');
                Check(response.Length == 14 && response[3] == "Restarted" && probes == 0, "旧 boot では診断しない");
                response = Protocol.Reply(f.Engine, "2\tprobe\t" + boot + "\tlock-probe\t\n").TrimEnd('\n').Split('\t');
                Check(response[3] == "Accepted" && probes == 1 && Encoding.UTF8.GetString(Convert.FromBase64String(response[13])).Contains("監視停止"), "診断受付と状態 encode");
                response = Protocol.Reply(f.Engine, "2\tkeys\t\tkeyboards\t\n").TrimEnd('\n').Split('\t');
                Check(response[3] == "Read" && response[12].Contains(Protocol.Encode("HID\\K")), "キーボード選択一覧");
                f.Engine.Keyboards = () => { throw new IOException("列挙失敗"); };
                Check(Protocol.Reply(f.Engine, "2\tkeys\t\tkeyboards\t\n").Contains("Rejected"), "列挙失敗の明示");
            }
        }
        private static void Until(Func<bool> condition)
        {
            var watch = Stopwatch.StartNew();
            while (!condition()) { if (watch.ElapsedMilliseconds > 5000) throw new Exception("テスト待機期限切れ"); Thread.Sleep(5); }
        }
        private static HashSet<string> Ids(params string[] ids) { return new HashSet<string>(ids, StringComparer.OrdinalIgnoreCase); }
        private sealed class MemoryJournal : IRecovery
        {
            internal HashSet<string> Data = Ids();
            internal int Writes;
            internal bool Bad, FailSave, Present = true;
            /// <summary>通常起動の既存記録を模擬します。</summary>
            public bool Exists { get { return Present; } }
            /// <summary>破損読み込みを注入できます。</summary>
            public HashSet<string> Load() { if (Bad) throw new IOException("破損"); return Ids(Data.ToArray()); }
            /// <summary>変更時だけ保存し、永続化失敗を注入できます。</summary>
            public void Save(HashSet<string> ids)
            {
                if (FailSave) throw new IOException("保存失敗");
                if (!Present || !Data.SetEquals(ids)) { Data = Ids(ids.ToArray()); Writes++; Present = true; }
            }
        }
        private sealed class Configuration : IConfig
        {
            internal Settings Value = new Settings { Ids = new List<string> { "HID\\A", "HID\\B" } };
            internal int Resets;
            /// <summary>設定の差し替えを模擬します。</summary>
            public Settings Load() { return Value; }
            /// <summary>reset 実行の有無を記録します。</summary>
            public void Reset() { Resets++; Value = new Settings(); }
        }
        private sealed class FakeScheduler : IScheduler
        {
            internal List<Action> Callbacks = new List<Action>();
            /// <summary>取消済み callback も強制発火できるよう保持します。</summary>
            public IDisposable After(int milliseconds, Action callback) { Callbacks.Add(callback); return new Ticket(); }
            private sealed class Ticket : IDisposable
            {
                /// <summary>実際の時間を進めず取消だけを模擬します。</summary>
                public void Dispose() { }
            }
        }
        private sealed class Hardware : IDevices
        {
            internal readonly Dictionary<string, DeviceState> States = new Dictionary<string, DeviceState> { { "HID\\A", DeviceState.Enabled }, { "HID\\B", DeviceState.Enabled } };
            internal readonly List<string> Calls = new List<string>();
            internal Func<string, bool, Func<bool>, Execution> Hook;
            /// <summary>実デバイスに触れず一覧を返します。</summary>
            public List<Device> Enumerate() { lock (States) return States.Select(p => new Device { Id = p.Key, Name = "マウス " + p.Key, Manufacturer = "試験", State = p.Value }).ToList(); }
            /// <summary>未接続も含む実状態を模擬します。</summary>
            public DeviceState Query(string id) { lock (States) { DeviceState state; return States.TryGetValue(id, out state) ? state : DeviceState.Unknown; } }
            internal void Set(string id, DeviceState state) { lock (States) States[id] = state; }
            /// <summary>操作失敗や timeout を注入し、呼び出しを記録します。</summary>
            public Execution Run(string id, bool enable, int timeout, Func<bool> cancel)
            {
                lock (Calls) Calls.Add((enable ? "+" : "-") + id);
                if (Hook != null) return Hook(id, enable, cancel);
                Set(id, enable ? DeviceState.Enabled : DeviceState.Disabled);
                return new Execution { ExitCode = 0 };
            }
        }
        private sealed class Fixture : IDisposable
        {
            internal readonly Hardware Hardware = new Hardware();
            internal readonly MemoryJournal Journal = new MemoryJournal();
            internal readonly Configuration Config = new Configuration();
            internal readonly FakeScheduler Timer = new FakeScheduler();
            internal Engine Engine;
            internal void Start()
            {
                Engine = new Engine(Hardware, Journal, Config, Timer, (s, i) => { }); Engine.Start();
                Until(() => Engine.Read("").Active != "startup");
            }
            internal Operation Do(string command)
            {
                string id = Guid.NewGuid().ToString("N");
                Check(Engine.Submit(command, id) == "Accepted", "受付失敗: " + command);
                Until(() => Engine.Read(id).Operation.Result != "Pending");
                return Engine.Read(id).Operation;
            }
            /// <summary>偽デバイスだけを復旧して worker を回収します。</summary>
            public void Dispose() { if (Engine != null) Engine.Dispose(); }
        }
        private static void RoundTrip()
        {
            using (var f = new Fixture())
            {
                f.Start(); Check(f.Do("disable").Result == "Success", "無効化");
                Check(f.Engine.Read("").State == "Disabled", "無効状態");
                int writes = f.Journal.Writes;
                for (int i = 0; i < 1000; i++) Protocol.Reply(f.Engine, "2\tpoll\t\tstatus\t\n");
                Check(f.Journal.Writes == writes, "照会で書き込み");
                Check(f.Do("enable").Result == "Success", "復旧");
                Check(f.Journal.Writes == 2 && f.Journal.Data.Count == 0, "一往復の記録更新は 2 回");
            }
        }
        private static void Partial()
        {
            using (var f = new Fixture())
            {
                f.Start();
                f.Hardware.Hook = (id, enable, cancel) => { if (id == "HID\\B" && !enable) return new Execution { ExitCode = 1 }; f.Hardware.Set(id, enable ? DeviceState.Enabled : DeviceState.Disabled); return new Execution { ExitCode = 0 }; };
                Check(f.Do("disable").Result == "Partial", "部分成功");
                Check(f.Engine.Read("").State == "Partial" && f.Journal.Data.Count == 2, "成功分を維持");
                Check(f.Do("toggle").Result == "Success" && f.Engine.Read("").State == "Enabled", "partial toggle は復旧");
            }
        }
        private static void SaveFailure()
        {
            using (var f = new Fixture())
            {
                f.Start(); f.Journal.FailSave = true;
                Check(f.Do("disable").Result == "Failed" && f.Hardware.Calls.Count == 0, "保存失敗後に操作した");
                f.Journal.FailSave = false;
            }
        }
        private static void ConfigChange()
        {
            using (var f = new Fixture())
            {
                f.Start(); f.Do("disable"); f.Config.Value = new Settings(); f.Do("reload");
                Check(f.Do("enable").Result == "Success" && f.Hardware.Query("HID\\A") == DeviceState.Enabled, "旧対象を紛失");
            }
        }
        private static void ResetFailure()
        {
            using (var f = new Fixture())
            {
                f.Start(); f.Do("disable");
                f.Hardware.Hook = (id, enable, cancel) => new Execution { ExitCode = 1 };
                Check(f.Do("reset").Result == "Failed" && f.Config.Resets == 0 && f.Journal.Data.Count == 2, "reset が設定を失った");
                f.Hardware.Hook = null;
                Check(f.Do("reset").Result == "Success" && f.Config.Resets == 1 && f.Journal.Data.Count == 0, "reset 再試行");
            }
        }
        private static void Startup()
        {
            using (var f = new Fixture())
            {
                f.Journal.Data.Add("HID\\A"); f.Hardware.Set("HID\\A", DeviceState.Disabled); f.Config.Value = new Settings(); f.Start();
                Check(f.Journal.Data.Count == 0 && f.Hardware.Query("HID\\A") == DeviceState.Enabled, "設定変更後の起動復旧");
            }
            using (var f = new Fixture())
            {
                f.Journal.Bad = true; f.Start();
                Check(f.Do("disable").Result == "Failed" && f.Hardware.Calls.Count == 0 && f.Journal.Writes == 0, "破損を上書き");
                Check(f.Do("reset").Result == "Failed" && f.Config.Resets == 0, "破損時 reset");
            }
        }
        private static void TimeoutFailure()
        {
            using (var f = new Fixture())
            {
                f.Start();
                f.Hardware.Hook = (id, enable, cancel) => { f.Hardware.Set(id, DeviceState.Unknown); return new Execution { TimedOut = true }; };
                Check(f.Do("disable").Result == "Failed" && f.Hardware.Calls.Count == 1, "不明後も無効化");
                f.Do("disable"); Check(f.Hardware.Calls.Count == 1, "新規無効化を受理");
                Check(f.Do("enable").Result != "Success" && f.Journal.Data.Count > 0, "未接続を成功扱い");
                f.Hardware.Hook = null; Check(f.Do("enable").Result == "Success", "復旧再試行できない");
            }
        }
        private static void Migration()
        {
            using (var f = new Fixture())
            {
                f.Journal.Present = false; f.Hardware.Set("HID\\A", DeviceState.Disabled); f.Start();
                Check(f.Journal.Present && f.Journal.Data.Count == 0 && f.Hardware.Query("HID\\A") == DeviceState.Enabled, "旧版の復旧");
                f.Hardware.Set("HID\\A", DeviceState.Disabled);
                f.Do("reload"); Check(f.Hardware.Query("HID\\A") == DeviceState.Disabled, "移行を繰り返した");
            }
        }
        private static void RestoreSaveFailure()
        {
            using (var f = new Fixture())
            {
                f.Start(); f.Do("disable"); f.Journal.FailSave = true;
                Check(f.Do("enable").Result == "Failed" && f.Journal.Data.Count == 2, "記録保存失敗時に対象を忘れた");
                f.Journal.FailSave = false;
                Check(f.Do("enable").Result == "Success" && f.Journal.Data.Count == 0, "記録保存を再試行できない");
            }
        }
        private static void Logging()
        {
            var hardware = new Hardware(); var journal = new MemoryJournal(); var config = new Configuration();
            int logs = 0;
            using (var engine = new Engine(hardware, journal, config, new FakeScheduler(), (s, level) => Interlocked.Increment(ref logs)))
            {
                engine.Start(); Until(() => engine.Read("").Active != "startup");
                for (int i = 0; i < 100; i++) engine.Read("");
                Check(logs == 0, "照会でログ出力");
                engine.Submit("disable", "first"); Until(() => engine.Read("first").Operation.Result != "Pending");
                Check(logs == 0, "通常動作で Information 出力");
                hardware.Hook = (id, enable, cancel) => new Execution { ExitCode = 50 };
                engine.Submit("enable", "retry1"); Until(() => engine.Read("retry1").Operation.Result != "Pending");
                int first = logs;
                engine.Submit("enable", "retry2"); Until(() => engine.Read("retry2").Operation.Result != "Pending");
                Check(first == 2 && logs == first, "同一障害が重複ログ");
                hardware.Hook = null;
            }
        }
        private static void Exit50()
        {
            using (var f = new Fixture())
            {
                f.Start(); f.Do("disable"); f.Hardware.Hook = (id, enable, cancel) => new Execution { ExitCode = 50 };
                Check(f.Do("enable").Result == "Failed" && f.Journal.Data.Count == 2, "50 を成功扱い");
                f.Hardware.Hook = null;
            }
        }
        private static void AlreadyDisabled()
        {
            using (var f = new Fixture())
            {
                f.Hardware.Set("HID\\A", DeviceState.Disabled); f.Start(); f.Do("disable");
                Check(!f.Journal.Data.Contains("HID\\A"), "既存無効を取り込んだ");
                f.Do("enable"); Check(f.Hardware.Query("HID\\A") == DeviceState.Disabled, "外部無効を変更した");
            }
        }
        private static void Reservations()
        {
            using (var f = new Fixture())
            {
                f.Start(); f.Engine.Schedule(); f.Engine.Schedule(); Check(f.Timer.Callbacks.Count == 1, "予約が重複");
                f.Do("enable"); f.Timer.Callbacks[0](); Thread.Sleep(30);
                Check(f.Hardware.Calls.Count == 0, "取消 callback が実行された");
                f.Engine.Schedule(); f.Timer.Callbacks[1](); Until(() => f.Engine.Read("").State == "Disabled");
            }
        }
        private static void Concurrent()
        {
            using (var f = new Fixture())
            using (var entered = new ManualResetEvent(false))
            {
                f.Start();
                f.Hardware.Hook = (id, enable, cancel) => {
                    if (!enable) { entered.Set(); Until(cancel); return new Execution { Error = "cancel" }; }
                    f.Hardware.Set(id, DeviceState.Enabled); return new Execution { ExitCode = 0 };
                };
                f.Engine.Submit("disable", "disable"); Check(entered.WaitOne(3000), "操作開始");
                var watch = Stopwatch.StartNew(); f.Engine.Read(""); Check(watch.ElapsedMilliseconds < 100, "照会が操作を待つ");
                Check(f.Do("enable").Result == "Success", "逆方向要求が復旧しない");
                Check(!f.Hardware.Calls.Contains("-HID\\B"), "取消後に後続無効化");
            }
        }
        private static void Shutdown()
        {
            using (var f = new Fixture())
            {
                f.Start(); f.Do("disable"); f.Engine.BeginStop();
                Check(f.Engine.Submit("disable", "late") == "Rejected", "停止中に受付");
                Check(f.Engine.Join(3000) && f.Journal.Data.Count == 0, "停止時復旧");
            }
        }
        private static void CrashRecovery()
        {
            using (var f = new Fixture())
            {
                f.Start();
                f.Hardware.Hook = (id, enable, cancel) => {
                    Check(f.Journal.Data.Contains(id), "記録より操作が先");
                    f.Hardware.Set(id, DeviceState.Disabled); throw new IOException("操作後に異常終了");
                };
                f.Do("disable");
                Check(f.Journal.Data.Count == 2, "例外で記録紛失");
                // 新しい engine に同じ永続記録を渡し、前回の表示状態には依存しない。
                f.Hardware.Hook = null;
                using (var restarted = new Engine(f.Hardware, f.Journal, new Configuration { Value = new Settings() }, new FakeScheduler(), (s, i) => { }))
                {
                    restarted.Start(); Until(() => restarted.Read("").Active != "startup");
                    Check(f.Journal.Data.Count == 0 && f.Hardware.Query("HID\\A") == DeviceState.Enabled, "異常終了後復旧");
                }
            }
        }
        private static void ProtocolChecks()
        {
            using (var f = new Fixture())
            {
                f.Start(); string boot = f.Engine.Read("").Boot;
                Check(Protocol.Reply(f.Engine, "1\tx\t\tstatus\t\n").Contains("VersionMismatch"), "version");
                Check(Protocol.Reply(f.Engine, "2\tx\told\tdisable\t\n").Contains("Restarted"), "boot");
                Check(Protocol.Reply(f.Engine, "2\tx\t" + boot + "\tshell\t\n").Contains("Rejected"), "任意コマンド");
                f.Engine.Submit("disable", "once"); Until(() => f.Engine.Read("once").Operation.Result != "Pending");
                int calls = f.Hardware.Calls.Count; f.Engine.Submit("disable", "once");
                Check(f.Hardware.Calls.Count == calls, "重複実行");
                Check(f.Engine.Submit("enable", "once") == "Rejected", "同じ ID の別操作");
            }
        }
        private static void FileJournal()
        {
            string dir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "__journal_" + Guid.NewGuid().ToString("N"));
            var file = new RecoveryFile(dir, () => Directory.CreateDirectory(dir)); file.Load();
            file.Save(Ids("HID\\A", "HID\\B"));
            string path = Path.Combine(dir, "recovery.v1"); DateTime before = File.GetLastWriteTimeUtc(path);
            file.Save(Ids("HID\\B", "HID\\A")); Check(File.GetLastWriteTimeUtc(path) == before, "同一内容を書き込み");
            file.Save(Ids()); Check(new RecoveryFile(dir, () => { }).Load().Count == 0, "atomic replacement");
            File.WriteAllText(path, "MWS-RECOVERY-1\nHID\\A\n");
            bool failed = false; try { new RecoveryFile(dir, () => { }).Load(); } catch (InvalidDataException) { failed = true; }
            Check(failed && File.ReadAllText(path).Contains("HID\\A"), "破損記録を変更");
        }
        private static void Processes()
        {
            Execution missing = ProcessRunner.Run(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "__missing.exe"), "", 100, () => false);
            Check(missing.ExitCode == null && missing.Error != "", "開始失敗");
            // cmd の内部ループだけを使い、孫プロセスや実デバイス操作を作らない。
            Execution timeout = ProcessRunner.Run(Environment.GetEnvironmentVariable("ComSpec"), "/d /c for /L %i in (1,0,2) do @rem wait", 100, () => false);
            Check(timeout.TimedOut && timeout.ExitCode.HasValue, "timeout 後に回収されない");
        }
        private static string Exchange(string name, string request)
        {
            using (var pipe = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous))
            {
                pipe.Connect(1000);
                byte[] bytes = Encoding.UTF8.GetBytes(request); pipe.Write(bytes, 0, bytes.Length);
                var reader = new StreamReader(pipe, Encoding.UTF8); return reader.ReadLine();
            }
        }
        private static void Pipes()
        {
            using (var f = new Fixture())
            {
                f.Start(); string name = "MwsTest-" + Guid.NewGuid().ToString("N");
                using (var server = TestServer(f.Engine, name))
                {
                    Check(Exchange(name, "2\tx\t\tstatus\t\n").StartsWith("2\tx\t"), "pipe 応答");
                    using (var stalled = new NamedPipeClientStream(".", name, PipeDirection.InOut)) { stalled.Connect(1000); Thread.Sleep(650); }
                    Check(Exchange(name, "2\ty\t\tstatus\t\n").Contains("Read"), "切断後復帰");
                }
            }
        }
        private static int Mock(string name)
        {
            using (var f = new Fixture())
            {
                f.Start();
                f.Hardware.Hook = (id, enable, cancel) => {
                    if (id == "HID\\B" && !enable) return new Execution { ExitCode = 1 };
                    f.Hardware.Set(id, enable ? DeviceState.Enabled : DeviceState.Disabled);
                    return new Execution { ExitCode = 0 };
                };
                // 応答停止と途中切断のサーバーはテスト専用の別 endpoint に隔離する。
                foreach (string suffix in new[] { "-slow", "-drop" })
                {
                    string endpoint = name + suffix;
                    new Thread(() => {
                        using (var pipe = new NamedPipeServerStream(endpoint, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous))
                        {
                            pipe.WaitForConnection();
                            try
                            {
                                byte[] buffer = new byte[4096]; pipe.Read(buffer, 0, buffer.Length);
                                if (endpoint.EndsWith("-slow")) Thread.Sleep(1500);
                                else { byte[] partial = Encoding.UTF8.GetBytes("2\tincomplete"); pipe.Write(partial, 0, partial.Length); }
                            }
                            catch (IOException) { }
                        }
                    }) { IsBackground = true }.Start();
                }
                using (var server = TestServer(f.Engine, name)) Thread.Sleep(12000);
            }
            return 0;
        }
        private static PipeServer TestServer(Engine engine, string name)
        {
            // 一般ユーザーのテスト実行用。製品 endpoint の ACL は変更しない。
            string sid = System.Security.Principal.WindowsIdentity.GetCurrent().User.Value;
            return new PipeServer(engine, name, "D:P(A;;GA;;;" + sid + ")");
        }
    }
}
