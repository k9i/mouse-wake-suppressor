using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace MouseWakeSuppressor
{
    internal static class Protocol
    {
        internal const int Limit = 262144;
        internal static string Encode(string value) { return Convert.ToBase64String(Encoding.UTF8.GetBytes(value ?? "")); }
        internal static string Reply(Engine engine, string request)
        {
            string[] fields = request.TrimEnd('\n').Split('\t');
            string id = fields.Length > 1 ? fields[1] : "";
            Snapshot state = engine.Read(fields.Length == 5 ? fields[4] : "");
            string accepted = "Rejected";
            if (fields.Length == 5 && fields[0] == "1" && ValidId(id))
            {
                if (fields[3] == "status" || fields[3] == "enumerate") accepted = "Read";
                else if (fields[2] == state.Boot)
                {
                    accepted = engine.Submit(fields[3], id);
                    state = engine.Read(id);
                }
                else accepted = "Restarted";
            }
            else if (fields.Length > 0 && fields[0] != "1") accepted = "VersionMismatch";
            Operation op = state.Operation;
            var devices = fields.Length == 5 && fields[3] == "enumerate" ? state.Available : state.Devices;
            string rows = String.Join(";", devices.Select(d => String.Join(",", new[] {
                Encode(d.Id), Encode(d.Name), Encode(d.Manufacturer), d.State.ToString(), d.Recovery ? "1" : "0", Encode(d.Result) })).ToArray());
            // 受付と実行結果を別フィールドにして、受付だけで成功通知させない。
            string response = String.Join("\t", new[] { "1", id, state.Boot, accepted, state.State,
                state.Active, state.Scheduled ? "1" : "0", state.Stopping ? "1" : "0", Encode(state.Error),
                op == null ? "" : op.Id, op == null ? "Missing" : op.Result, Encode(op == null ? "" : op.Message), rows }) + "\n";
            if (Encoding.UTF8.GetByteCount(response) > Limit) throw new IOException("IPC 応答が上限を超えています。");
            return response;
        }
        private static bool ValidId(string id) { return id.Length > 0 && id.Length <= 64 && id.All(c => Char.IsLetterOrDigit(c) || c == '-'); }
    }

    internal sealed class PipeServer : IDisposable
    {
        private readonly Engine engine;
        private readonly string name;
        private readonly string sddl;
        private readonly object gate = new object();
        private readonly List<NamedPipeServerStream> streams = new List<NamedPipeServerStream>();
        private readonly List<Thread> threads = new List<Thread>();
        private volatile bool stopping;
        internal Action<string> Diagnostic = null;
        internal PipeServer(Engine engine) : this(engine, "MouseWakeSuppressor-v1") { }
        internal PipeServer(Engine engine, string name) : this(engine, name, "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x00120183;;;BU)") { }
        internal PipeServer(Engine engine, string name, string sddl)
        {
            this.engine = engine; this.name = name; this.sddl = sddl;
            // 最初の instance を排他的に作成し、既存の偽サーバーとの共存を拒否する。
            try
            {
                for (int i = 0; i < 4; i++) streams.Add(Create(i == 0));
                foreach (NamedPipeServerStream stream in streams.ToArray())
                {
                    NamedPipeServerStream initial = stream;
                    var thread = new Thread(() => Serve(initial)) { IsBackground = true, Name = "ipc" };
                    threads.Add(thread); thread.Start();
                }
            }
            catch { Dispose(); throw; }
        }
        private NamedPipeServerStream Create(bool first)
        {
            IntPtr descriptor; uint size;
            // BU に FILE_CREATE_PIPE_INSTANCE を与えず、remote は pipe mode で拒否する。
            if (!ConvertStringSecurityDescriptorToSecurityDescriptor(sddl, 1, out descriptor, out size))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                var security = new SecurityAttributes { Length = Marshal.SizeOf(typeof(SecurityAttributes)), Descriptor = descriptor };
                SafePipeHandle handle = CreateNamedPipe("\\\\.\\pipe\\" + name, 3u | 0x40000000u | (first ? 0x80000u : 0), 8, 4, Protocol.Limit, 4096, 500, ref security);
                if (handle.IsInvalid) { handle.Dispose(); throw new Win32Exception(Marshal.GetLastWin32Error()); }
                return new NamedPipeServerStream(PipeDirection.InOut, true, false, handle);
            }
            finally { LocalFree(descriptor); }
        }
        private void Serve(NamedPipeServerStream stream)
        {
            while (!stopping)
            {
                try
                {
                    stream.WaitForConnection();
                    var clock = System.Diagnostics.Stopwatch.StartNew();
                    var input = new MemoryStream();
                    var buffer = new byte[1024];
                    while (true)
                    {
                        IAsyncResult read = stream.BeginRead(buffer, 0, buffer.Length, null, null);
                        int count = Complete(stream, read, () => stream.EndRead(read), clock);
                        if (count == 0 || input.Length + count > 4096) throw new IOException("IPC 要求が不正です。");
                        input.Write(buffer, 0, count);
                        if (buffer[count - 1] == 10) break;
                    }
                    string request = new UTF8Encoding(false, true).GetString(input.ToArray());
                    if (request.IndexOf('\n') != request.Length - 1) throw new IOException("複数の要求は受け付けません。");
                    byte[] response = Encoding.UTF8.GetBytes(Protocol.Reply(engine, request));
                    IAsyncResult write = stream.BeginWrite(response, 0, response.Length, null, null);
                    Complete(stream, write, () => { stream.EndWrite(write); return 0; }, clock);
                    // EndWrite は相手の受信完了ではない。相手の close を期限内だけ待ち、
                    // buffer を未読のまま破棄する競合と WaitForPipeDrain の無期限待機を避ける。
                    IAsyncResult closed = stream.BeginRead(buffer, 0, 1, null, null);
                    Complete(stream, closed, () => stream.EndRead(closed), clock);
                }
                catch (IOException ex) { if (Diagnostic != null) Diagnostic(ex.ToString()); }
                catch (ObjectDisposedException) { /* 停止との競合でも listener を正常終了する。 */ }
                catch (OperationCanceledException) { /* CancelIoEx による通常の取消として扱う。 */ }
                catch (ArgumentException ex) { if (Diagnostic != null) Diagnostic(ex.ToString()); }
                finally { lock (gate) { streams.Remove(stream); stream.Dispose(); } }
                lock (gate)
                {
                    if (stopping) return;
                    try { stream = Create(streams.Count == 0); streams.Add(stream); }
                    catch (Win32Exception) { return; }
                }
            }
        }
        private static int Complete(NamedPipeServerStream stream, IAsyncResult operation, Func<int> end, System.Diagnostics.Stopwatch clock)
        {
            // event の所有者は .NET。End が callback 完了後に解放するため、
            // 呼出側で Dispose してはいけない (timeout と停止の競合でも同様)。
            if (operation.AsyncWaitHandle.WaitOne(Math.Max(0, 500 - (int)clock.ElapsedMilliseconds))) return end();
            try { CancelIoEx(stream.SafePipeHandle, IntPtr.Zero); }
            catch (ObjectDisposedException) { /* 停止側による close が既に取消を行っている。 */ }
            try { end(); }
            catch (IOException) { }
            catch (ObjectDisposedException) { }
            catch (OperationCanceledException) { }
            throw new IOException("IPC の全体期限を超えました。");
        }
        /// <summary>接続待ちと保留 I/O を閉じ、全 listener を回収します。</summary>
        public void Dispose()
        {
            lock (gate)
            {
                stopping = true;
                foreach (var stream in streams.ToArray()) { CancelIoEx(stream.SafePipeHandle, IntPtr.Zero); stream.Dispose(); }
            }
            foreach (var thread in threads) thread.Join();
        }
        [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes { internal int Length; internal IntPtr Descriptor; internal int Inherit; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafePipeHandle CreateNamedPipe(string name, uint openMode, uint pipeMode, int instances, int outSize, int inSize, uint timeout, ref SecurityAttributes security);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string sddl, uint revision, out IntPtr descriptor, out uint size);
        [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CancelIoEx(SafePipeHandle pipe, IntPtr overlapped);
    }
}
