using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace MouseWakeSuppressor
{
    internal sealed class IniConfig : IConfig
    {
        private readonly string path;
        internal IniConfig(string directory) { path = Path.Combine(directory, "mws_config.ini"); }
        private string Read(string section, string key, string fallback)
        {
            var buffer = new StringBuilder(32768);
            uint count = GetPrivateProfileString(section, key, fallback, buffer, (uint)buffer.Capacity, path);
            if (count >= buffer.Capacity - 1) throw new IOException("設定が長すぎます。");
            return buffer.ToString();
        }
        private int Number(string key, int fallback, int minimum)
        {
            int value;
            string text = Read("Service", key, fallback.ToString());
            if (!int.TryParse(text, out value) || value < minimum || value > 600000)
                throw new InvalidDataException(key + " は " + minimum + " から 600000 の整数で指定してください。");
            return value;
        }
        internal LockSettings LoadLock()
        {
            string enabled = Read("LockDisplay", "Enabled", "0");
            int idle, retry;
            if ((enabled != "0" && enabled != "1") ||
                !int.TryParse(Read("LockDisplay", "IdleTimeoutSeconds", "30"), out idle) ||
                !int.TryParse(Read("LockDisplay", "RetryIntervalMs", "1000"), out retry))
                throw new InvalidDataException("LockDisplay の設定値が不正です。");
            var result = new LockSettings { Enabled = enabled == "1", IdleSeconds = idle, RetryMs = retry,
                Keyboards = Read("LockDisplay", "KeyboardInstanceIds", "").Split('|').Select(s => s.Trim()).Where(s => s != "").Distinct(StringComparer.OrdinalIgnoreCase).ToList() };
            result.Validate(); return result;
        }
        /// <summary>設定の不正を検出し、安全な操作だけに使用します。</summary>
        public Settings Load()
        {
            var ids = Read("Devices", "InstanceIds", "").Split('|').Select(s => s.Trim()).Where(s => s != "").Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            foreach (string id in ids) ValidateId(id);
            return new Settings { Ids = ids, Delay = Number("AutomaticDisableDelayMs", 5000, 0),
                Timeout = Number("OperationTimeoutMs", 5000, 100), Information = Read("Service", "InformationLog", "0") == "1" };
        }
        /// <summary>復旧後に Devices section だけを削除します。</summary>
        public void Reset()
        {
            if (Read("Devices", "InstanceIds", "") == "" && Read("Devices", "Names", "") == "") return;
            if (!WritePrivateProfileString("Devices", null, null, path)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        internal static void ValidateId(string id)
        {
            if (String.IsNullOrWhiteSpace(id) || id.Length > 200 || !id.Contains("\\") || id.EndsWith("\\") ||
                id.Any(c => c < 32 || c == '"' || c == '|' || c == '*' || c == '?'))
                throw new InvalidDataException("不正な device instance ID です。");
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern uint GetPrivateProfileString(string section, string key, string fallback, StringBuilder value, uint size, string path);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool WritePrivateProfileString(string section, string key, string value, string path);
    }

    internal sealed class RecoveryFile : IRecovery
    {
        private readonly string directory, path;
        private readonly Action prepare;
        private string previous;
        internal RecoveryFile() : this(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "MouseWakeSuppressor")) { }
        internal RecoveryFile(string directory) : this(directory, null) { }
        internal RecoveryFile(string directory, Action prepare) { this.directory = directory; path = Path.Combine(directory, "recovery.v1"); this.prepare = prepare; }
        /// <summary>初回移行と通常起動を区別します。</summary>
        public bool Exists { get { return File.Exists(path); } }
        private void Secure()
        {
            // 継承を切り、一般ユーザーによる復旧先の差し替えを防ぐ。
            var acl = new DirectorySecurity();
            acl.SetAccessRuleProtection(true, false);
            acl.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
            foreach (WellKnownSidType sid in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
                acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid, null), FileSystemRights.FullControl,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            if (!Directory.Exists(directory)) Directory.CreateDirectory(directory, acl);
            if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) throw new IOException("復旧ディレクトリに reparse point は使用できません。");
            Directory.SetAccessControl(directory, acl);
            if (File.Exists(path))
            {
                if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("復旧記録に reparse point は使用できません。");
                var fileAcl = new FileSecurity();
                fileAcl.SetAccessRuleProtection(true, false);
                fileAcl.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
                foreach (WellKnownSidType sid in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
                    fileAcl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid, null), FileSystemRights.FullControl, AccessControlType.Allow));
                File.SetAccessControl(path, fileAcl);
            }
        }
        /// <summary>version と全 ID を検証し、破損時は書き込みを許可しません。</summary>
        public HashSet<string> Load()
        {
            if (prepare == null) Secure(); else prepare();
            var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (!Exists) return ids;
            if (new FileInfo(path).Length > 1024 * 1024) throw new InvalidDataException("復旧記録が大きすぎます。");
            string text = File.ReadAllText(path, new UTF8Encoding(false, true));
            string[] lines = text.Split('\n');
            if (lines.Length < 3 || lines[0] != "MWS-RECOVERY-1" || lines[lines.Length - 1] != "")
                throw new InvalidDataException("復旧記録が破損しています。上書きせず新規無効化を禁止します。");
            string body = String.Join("\n", lines.Take(lines.Length - 2).ToArray()) + "\n";
            if (lines[lines.Length - 2] != "SHA256=" + Digest(body)) throw new InvalidDataException("復旧記録の checksum が一致しません。");
            foreach (string id in lines.Skip(1).Take(lines.Length - 3))
            {
                IniConfig.ValidateId(id);
                if (!ids.Add(id)) throw new InvalidDataException("復旧記録に重複があります。");
            }
            previous = Serialize(ids);
            return ids;
        }
        private static string Digest(string text)
        {
            using (var sha = SHA256.Create()) return Convert.ToBase64String(sha.ComputeHash(Encoding.UTF8.GetBytes(text)));
        }
        private static string Serialize(HashSet<string> ids)
        {
            string body = "MWS-RECOVERY-1\n" + String.Concat(ids.OrderBy(s => s, StringComparer.OrdinalIgnoreCase).Select(s => s + "\n"));
            return body + "SHA256=" + Digest(body) + "\n";
        }
        /// <summary>write-through と flush の後、同一 volume 内で原子的に置き換えます。</summary>
        public void Save(HashSet<string> ids)
        {
            foreach (string id in ids) IniConfig.ValidateId(id);
            string content = Serialize(ids);
            if (content == previous) return;
            string temporary = Path.Combine(directory, "__recovery_" + Guid.NewGuid().ToString("N") + ".tmp");
            // 失敗した一時ファイルは証跡として残し、既存の正式記録を維持する。
            byte[] bytes = new UTF8Encoding(false).GetBytes(content);
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            { stream.Write(bytes, 0, bytes.Length); stream.Flush(true); }
            if (File.Exists(path)) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
            previous = content;
        }
    }

    internal sealed class WindowsDevices : IDevices
    {
        private static readonly Guid MouseClass = new Guid("4d36e96f-e325-11ce-bfc1-08002be10318");
        private readonly Guid deviceClass;
        internal WindowsDevices() : this(false) { }
        internal WindowsDevices(bool keyboards) { deviceClass = keyboards ? new Guid("4d36e96b-e325-11ce-bfc1-08002be10318") : MouseClass; }
        [StructLayout(LayoutKind.Sequential)] private struct DeviceInfo { internal uint Size; internal Guid Class; internal uint Instance; internal IntPtr Reserved; }
        /// <summary>SetupAPI で Mouse クラスのデバイスを列挙します。</summary>
        public List<Device> Enumerate()
        {
            Guid guid = deviceClass;
            // 未接続も含めることで初回移行の復旧対象を失わない。
            IntPtr set = SetupDiGetClassDevs(ref guid, null, IntPtr.Zero, 0);
            if (set == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
            var result = new List<Device>();
            try
            {
                for (uint index = 0; ; index++)
                {
                    var info = new DeviceInfo { Size = (uint)Marshal.SizeOf(typeof(DeviceInfo)) };
                    if (!SetupDiEnumDeviceInfo(set, index, ref info))
                    {
                        int code = Marshal.GetLastWin32Error();
                        if (code == 259) break;
                        throw new Win32Exception(code);
                    }
                    var id = new StringBuilder(512); uint required;
                    if (!SetupDiGetDeviceInstanceId(set, ref info, id, id.Capacity, out required)) throw new Win32Exception(Marshal.GetLastWin32Error());
                    string name = Property(set, ref info, 12);
                    if (name == "") name = Property(set, ref info, 0);
                    result.Add(new Device { Id = id.ToString(), Name = name, Manufacturer = Property(set, ref info, 11), State = Query(id.ToString()) });
                }
            }
            finally { SetupDiDestroyDeviceInfoList(set); }
            return result;
        }
        private static string Property(IntPtr set, ref DeviceInfo info, uint property)
        {
            byte[] bytes = new byte[4096]; uint type, needed;
            if (!SetupDiGetDeviceRegistryProperty(set, ref info, property, out type, bytes, (uint)bytes.Length, out needed)) return "";
            return Encoding.Unicode.GetString(bytes, 0, (int)Math.Min(needed, bytes.Length)).TrimEnd('\0');
        }
        /// <summary>未接続と API 失敗を Unknown とし、正常起動を確認します。</summary>
        public DeviceState Query(string id)
        {
            uint instance, status, problem;
            if (CM_Locate_DevNode(out instance, id, 0) != 0 || CM_Get_DevNode_Status(out status, out problem, instance, 0) != 0) return DeviceState.Unknown;
            if ((status & 0x400) != 0) return problem == 22 ? DeviceState.Disabled : DeviceState.Unknown;
            return (status & 8) != 0 ? DeviceState.Enabled : DeviceState.Unknown;
        }
        /// <summary>終了コードと両出力を回収し、期限切れの子プロセスを残しません。</summary>
        public Execution Run(string id, bool enable, int timeout, Func<bool> cancel)
        {
            if (deviceClass != MouseClass) throw new InvalidOperationException("キーボードの状態変更は禁止しています。");
            IniConfig.ValidateId(id);
            if (!Enumerate().Any(d => String.Equals(d.Id, id, StringComparison.OrdinalIgnoreCase)))
                return new Execution { Error = "Mouse クラスに見つかりません。復旧対象を保持します。" };
            return ProcessRunner.Run(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "pnputil.exe"),
                (enable ? "/enable-device \"" : "/disable-device \"") + id + "\"", timeout, cancel);
        }
        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] private static extern uint CM_Locate_DevNode(out uint instance, string id, uint flags);
        [DllImport("cfgmgr32.dll")] private static extern uint CM_Get_DevNode_Status(out uint status, out uint problem, uint instance, uint flags);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr SetupDiGetClassDevs(ref Guid guid, string enumerator, IntPtr hwnd, uint flags);
        [DllImport("setupapi.dll", SetLastError = true)] private static extern bool SetupDiEnumDeviceInfo(IntPtr set, uint index, ref DeviceInfo info);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool SetupDiGetDeviceInstanceId(IntPtr set, ref DeviceInfo info, StringBuilder id, int size, out uint needed);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool SetupDiGetDeviceRegistryProperty(IntPtr set, ref DeviceInfo info, uint property, out uint type, byte[] data, uint size, out uint needed);
        [DllImport("setupapi.dll")] private static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    }

    internal static class ProcessRunner
    {
        internal static Execution Run(string executable, string arguments, int timeout, Func<bool> cancel)
        {
            var result = new Execution();
            var output = new StringBuilder(); var error = new StringBuilder();
            using (var process = new Process())
            {
                process.StartInfo = new ProcessStartInfo(executable, arguments) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
                // 両 stream を同時に drain し、pipe buffer の満杯による deadlock を防ぐ。
                process.OutputDataReceived += (s, e) => { if (e.Data != null) lock (output) { if (output.Length < 16384) output.AppendLine(e.Data); } };
                process.ErrorDataReceived += (s, e) => { if (e.Data != null) lock (error) { if (error.Length < 16384) error.AppendLine(e.Data); } };
                bool started = false;
                try
                {
                    started = process.Start();
                    process.BeginOutputReadLine(); process.BeginErrorReadLine();
                    var watch = Stopwatch.StartNew();
                    while (!process.WaitForExit(25))
                    {
                        if (watch.ElapsedMilliseconds >= timeout || cancel())
                        {
                            result.TimedOut = watch.ElapsedMilliseconds >= timeout;
                            if (!result.TimedOut) result.Error = "停止要求により中断しました。";
                            process.Kill(); break;
                        }
                    }
                    process.WaitForExit();
                    result.ExitCode = process.ExitCode;
                }
                catch (Exception ex) { result.Error += ex.Message; }
                finally
                {
                    // 例外経路でも子を回収する。回収失敗は隠さず上位へ伝える。
                    if (started && !process.HasExited) { process.Kill(); process.WaitForExit(); }
                }
            }
            result.Output = output.ToString().Trim(); result.Error += error.ToString().Trim();
            return result;
        }
    }

    internal static class ServiceSecurity
    {
        internal static void Configure()
        {
            IntPtr scm = OpenSCManager(null, null, 1);
            if (scm == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr service = IntPtr.Zero, descriptor = IntPtr.Zero;
            try
            {
                service = OpenService(scm, "MouseWakeSuppressor", 0x40000);
                if (service == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                uint size;
                // 一般ユーザーは照会と既存 custom command のみ。開始・停止は管理者に限定。
                if (!ConvertStringSecurityDescriptorToSecurityDescriptor("D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;CCLCSWLOCRRC;;;BU)", 1, out descriptor, out size) ||
                    !SetServiceObjectSecurity(service, 4, descriptor)) throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            finally { if (descriptor != IntPtr.Zero) LocalFree(descriptor); if (service != IntPtr.Zero) CloseServiceHandle(service); CloseServiceHandle(scm); }
        }
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr OpenSCManager(string machine, string database, uint access);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr OpenService(IntPtr scm, string name, uint access);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string sddl, uint revision, out IntPtr descriptor, out uint size);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern bool SetServiceObjectSecurity(IntPtr service, uint information, IntPtr descriptor);
        [DllImport("advapi32.dll")] private static extern bool CloseServiceHandle(IntPtr handle);
        [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    }
}
