using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;

namespace MouseWakeSuppressor
{
    internal sealed class LockInputHelper
    {
        private readonly string pipe, generation;
        private readonly int session, parent;
        private LockSettings settings;
        private LockDeadline deadline;
        private readonly LockKeyboardMap keyboards = new LockKeyboardMap();
        private IntPtr desktop, window, power;
        private string desktopName = "", error = "";
        private bool monitoring;
        private bool allowOff;
        private long nextLease, nextDevices, initialBaseline;
        private int desktopEpoch;
        private LockNative.WndProc procedure;
        private static readonly Guid DisplayGuid = new Guid("6FE69556-704A-47A0-8F24-C28D936FDA47");
        private LockInputHelper(string pipe, int session, string generation, int parent) { this.pipe = pipe; this.session = session; this.generation = generation; this.parent = parent; }
        internal static int Run(string[] args)
        {
            int session, parent; Guid generation;
            if (args.Length != 5 || !LockNative.SystemIdentity || !int.TryParse(args[2], out session) || !int.TryParse(args[4], out parent) ||
                !Guid.TryParseExact(args[3], "N", out generation) || args[1] != "MwsLock-" + args[3] ||
                Process.GetCurrentProcess().SessionId != session) return 77;
            try { new LockInputHelper(args[1], session, args[3], parent).Loop(); return 0; }
            catch (Exception ex) { Trace.WriteLine(ex.Message); return 74; }
        }
        private void Lease()
        {
            string state = deadline == null ? "監視開始中" : !monitoring && error != "" ? "監視停止: " + error :
                (allowOff ? "" : "入力診断 (消灯要求なし): ") + deadline.State + (error == "" ? "" : " / " + error);
            if (desktopName != "") state += " / desktop=" + desktopName + "#" + desktopEpoch;
            if (deadline != null) state += " / OFF 要求=" + deadline.Requests + "@" + deadline.LastRequest +
                " / 表示通知=" + deadline.DisplayValue + "@" + deadline.LastDisplayNotification;
            string health = error != "" || (deadline != null && deadline.Unconfirmed >= 3) ? "ERROR" : "OK";
            string request = "2\t" + generation + "\t" + session + "\t" + (deadline == null ? 0 : deadline.Activity) + "\t" + health + "\t" + Protocol.Encode(state) + "\n";
            // 識別だけを許可し、偽 server が LocalSystem token を impersonate する余地を作らない。
            using (var stream = new NamedPipeClientStream(".", pipe, PipeDirection.InOut, PipeOptions.Asynchronous, TokenImpersonationLevel.Identification))
            {
                stream.Connect(500);
                uint server;
                if (!GetNamedPipeServerProcessId(stream.SafePipeHandle, out server) || server != parent || !LockNative.SystemProcess(parent))
                    throw new IOException("helper lease の server が一致しません。");
                byte[] bytes = Encoding.UTF8.GetBytes(request);
                var clock = Stopwatch.StartNew();
                IAsyncResult write = stream.BeginWrite(bytes, 0, bytes.Length, null, null);
                Finish(stream, write, () => { stream.EndWrite(write); return 0; }, clock);
                var data = new MemoryStream(); var buffer = new byte[4096];
                while (true)
                {
                    IAsyncResult read = stream.BeginRead(buffer, 0, buffer.Length, null, null);
                    int count = Finish(stream, read, () => stream.EndRead(read), clock);
                    if (count == 0 || data.Length + count > 32768) throw new IOException("helper lease が切断されました。");
                    data.Write(buffer, 0, count);
                    if (buffer[count - 1] == 10) break;
                }
                string[] fields = Encoding.UTF8.GetString(data.ToArray()).TrimEnd('\n').Split('\t');
                if (fields.Length != 8 || fields[0] != "2" || fields[1] != generation || fields[2] != session.ToString() || (fields[6] != "0" && fields[6] != "1"))
                    throw new IOException("helper lease が取り消されました。");
                var received = new LockSettings { Enabled = true, IdleSeconds = int.Parse(fields[3]), RetryMs = int.Parse(fields[4]),
                    Keyboards = Encoding.UTF8.GetString(Convert.FromBase64String(fields[5])).Split('|').ToList() };
                received.Validate();
                if (settings != null && (received.Identity != settings.Identity || allowOff != (fields[6] == "1"))) throw new IOException("helper 設定が変更されました。");
                if (settings == null)
                {
                    settings = received; deadline = new LockDeadline(settings);
                    if (!long.TryParse(fields[7], out initialBaseline) || initialBaseline < 0 || initialBaseline > LockNative.Now)
                        throw new IOException("helper の開始時刻が不正です。");
                }
                allowOff = fields[6] == "1";
                nextLease = LockNative.Now + 250;
            }
        }
        private static int Finish(NamedPipeClientStream stream, IAsyncResult operation, Func<int> end, Stopwatch clock)
        {
            if (operation.AsyncWaitHandle.WaitOne(Math.Max(0, 500 - (int)clock.ElapsedMilliseconds))) return end();
            stream.Dispose();
            try { end(); } catch (IOException) { } catch (ObjectDisposedException) { }
            throw new IOException("helper lease が timeout しました。");
        }
        private void Loop()
        {
            Lease();
            procedure = WindowProc;
            var cls = new LockNative.WindowClass { Name = "MwsLockInput", Proc = procedure, Instance = LockNative.GetModuleHandle(null) };
            if (LockNative.RegisterClass(ref cls) == 0) throw new Win32Exception();
            while (true)
            {
                bool again = false;
                Exception failure = null;
                // IME などが作る補助 window も thread 終了で回収する。同じ thread の desktop 再割当は行わない。
                var receiver = new Thread(() =>
                {
                    try { again = DesktopLoop(); }
                    catch (Exception ex) { failure = ex; }
                }) { IsBackground = true, Name = "lock-input-desktop" };
                receiver.Start(); receiver.Join();
                if (desktop != IntPtr.Zero)
                {
                    if (!LockNative.CloseDesktop(desktop)) throw new Win32Exception();
                    desktop = IntPtr.Zero;
                }
                if (failure != null) throw new IOException("desktop 受信 thread が終了しました。", failure);
                if (!again) return;
                if (!monitoring) Thread.Sleep(250);
            }
        }
        private bool DesktopLoop()
        {
            try
            {
                while (true)
                {
                    // 通信断はこの loop を終了させ、単独 helper に制御を残さない。
                    if (LockNative.Now >= nextLease) Lease();
                    try
                    {
                        if (!LockNative.Locked(session)) return false;
                        if (!EnsureDesktop()) return true;
                        if (LockNative.Now >= nextDevices) { RefreshDevices(); nextDevices = LockNative.Now + 1000; }
                        if (!monitoring)
                        {
                            RefreshDevices(); monitoring = true; error = "";
                            deadline.Reset(initialBaseline > 0 ? initialBaseline : LockNative.Now, true); initialBaseline = 0;
                        }
                        Drain();
                        long ticket = deadline.Ticket(LockNative.Now);
                        if (allowOff && ticket >= 0)
                        {
                            Lease();
                            // IPC 待機中に到着した入力と desktop 切替を消灯より先に処理する。
                            if (!EnsureDesktop()) return true;
                            Drain();
                            if (!monitoring || !LockNative.Locked(session)) continue;
                            if (deadline.Commit(ticket, LockNative.Now))
                            {
                                UIntPtr result;
                                // 自分の window の DefWindowProc に同期要求し、古い post を残さない。
                                if (LockNative.SendMessageTimeout(window, 0x112, new IntPtr(0xF170), new IntPtr(2), 2, 200, out result) == IntPtr.Zero)
                                    error = "SC_MONITORPOWER の応答を確認できません。";
                            }
                        }
                    }
                    catch (Exception ex)
                    {
                        error = ex.Message; monitoring = false; initialBaseline = 0; deadline.Reset(LockNative.Now, false);
                        keyboards.Clear(); nextDevices = 0;
                        return true;
                    }
                    Thread.Sleep(20);
                }
            }
            finally { CloseWindow(); }
        }
        private bool EnsureDesktop()
        {
            IntPtr input = LockNative.OpenInputDesktop(0, false, 0x0083);
            if (input == IntPtr.Zero) throw new Win32Exception();
            try
            {
                string name = LockNative.DesktopName(input);
                if (window != IntPtr.Zero) return name == desktopName;
                bool continuous = monitoring;
                if (!LockNative.SetThreadDesktop(input)) throw new Win32Exception();
                desktop = input; input = IntPtr.Zero; desktopName = name;
                window = LockNative.CreateWindowEx(0, "MwsLockInput", "", 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, LockNative.GetModuleHandle(null), IntPtr.Zero);
                if (window == IntPtr.Zero) throw new Win32Exception();
                var registration = new[] { new LockNative.RawRegistration { Page = 1, Usage = 6, Flags = 0x2100, Window = window } };
                if (!LockNative.RegisterRawInputDevices(registration, 1, (uint)Marshal.SizeOf(typeof(LockNative.RawRegistration)))) throw new Win32Exception();
                Guid guid = DisplayGuid;
                power = LockNative.RegisterPowerSettingNotification(window, ref guid, 0);
                if (power == IntPtr.Zero) throw new Win32Exception();
                // 正常な desktop 切替そのものはキーボード入力として数えない。
                monitoring = continuous; error = "";
                if (!continuous) deadline.Reset(LockNative.Now, false);
                // 新 desktop の最初の入力を古い handle の一覧で除外しない。
                RefreshDevices(continuous);
                nextDevices = LockNative.Now + 1000;
                desktopEpoch++;
                return true;
            }
            finally { if (input != IntPtr.Zero) LockNative.CloseDesktop(input); }
        }
        private void CloseWindow()
        {
            int failure = 0;
            if (power != IntPtr.Zero)
            {
                if (!LockNative.UnregisterPowerSettingNotification(power)) failure = Marshal.GetLastWin32Error();
                power = IntPtr.Zero;
            }
            if (window != IntPtr.Zero)
            {
                var remove = new[] { new LockNative.RawRegistration { Page = 1, Usage = 6, Flags = 1 } };
                if (!LockNative.RegisterRawInputDevices(remove, 1, (uint)Marshal.SizeOf(typeof(LockNative.RawRegistration)))) failure = Marshal.GetLastWin32Error();
                if (!LockNative.DestroyWindow(window)) failure = Marshal.GetLastWin32Error();
                window = IntPtr.Zero;
            }
            // desktop handle は、この thread の Join 後に所有元 thread が閉じる。
            if (failure != 0) throw new Win32Exception(failure);
        }
        private void Drain()
        {
            LockNative.Message message;
            while (LockNative.PeekMessage(out message, IntPtr.Zero, 0, 0, 1)) LockNative.DispatchMessage(ref message);
            if (error != "" && !monitoring) throw new IOException(error);
        }
        private void RefreshDevices(bool desktopChanged = false)
        {
            uint count = 0, size = (uint)Marshal.SizeOf(typeof(LockNative.RawDevice));
            if (LockNative.GetRawInputDeviceList(null, ref count, size) == uint.MaxValue || count > 4096) throw new Win32Exception();
            var devices = new LockNative.RawDevice[count];
            uint found = LockNative.GetRawInputDeviceList(devices, ref count, size);
            if (found == uint.MaxValue) throw new Win32Exception();
            var current = new Dictionary<IntPtr, string>();
            for (int i = 0; i < found; i++)
            {
                if (devices[i].Type != 1 || devices[i].Handle == IntPtr.Zero) continue;
                var name = new StringBuilder(4096); uint capacity = (uint)name.Capacity;
                if (LockNative.GetRawInputDeviceInfo(devices[i].Handle, 0x20000007, name, ref capacity) == uint.MaxValue) throw new Win32Exception();
                // RDP の synthetic keyboard は device interface を持たず、選択対象にも含めない。
                if (!name.ToString().StartsWith(@"\\?\", StringComparison.Ordinal)) continue;
                string id = LockNative.InstanceId(name.ToString());
                if (settings.Keyboards.Contains(id, StringComparer.OrdinalIgnoreCase)) current.Add(devices[i].Handle, id);
            }
            if (current.Count == 0) throw new IOException("登録キーボードを Raw Input で確認できません。");
            if (keyboards.Replace(current, desktopChanged))
            {
                // 再接続や device handle の再利用時は不明期間を idle とみなさない。
                deadline.Reset(LockNative.Now, true);
            }
        }
        private IntPtr WindowProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam)
        {
            try
            {
                if (message == 0xFF)
                {
                    // RID_HEADER だけを取得し、キー値を managed memory に取り込まない。
                    uint size = (uint)(8 + IntPtr.Size * 2);
                    IntPtr header = Marshal.AllocHGlobal((int)size);
                    try
                    {
                        uint expected = size;
                        if (LockNative.GetRawInputData(lParam, 0x10000005, header, ref size, expected) != expected) throw new Win32Exception();
                        if (Marshal.ReadInt32(header) == 1)
                            deadline.Input(LockNative.Now, keyboards.Contains(Marshal.ReadIntPtr(header, 8)));
                    }
                    finally { Marshal.FreeHGlobal(header); }
                }
                else if (message == 0xFE)
                {
                    // 未登録デバイスの変更は期限を延長しない。対象の脱落時だけ不明期間を作る。
                    if (wParam.ToInt64() == 2 && keyboards.Contains(lParam))
                    { monitoring = false; deadline.Reset(LockNative.Now, false); }
                    RefreshDevices(); nextDevices = LockNative.Now + 1000;
                }
                else if (message == 0x218 && wParam.ToInt64() == 0x8013 && lParam != IntPtr.Zero && Marshal.ReadInt32(lParam, 16) == 4)
                {
                    Guid guid = (Guid)Marshal.PtrToStructure(lParam, typeof(Guid));
                    int value = Marshal.ReadInt32(lParam, 20);
                    if (guid == DisplayGuid && value >= 0 && value <= 2) { deadline.Display(LockNative.Now, value); if (value == 0) error = ""; }
                }
            }
            catch (Exception ex) { error = ex.Message; monitoring = false; deadline.Reset(LockNative.Now, false); }
            return LockNative.DefWindowProc(hwnd, message, wParam, lParam);
        }
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetNamedPipeServerProcessId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint process);
    }
}
