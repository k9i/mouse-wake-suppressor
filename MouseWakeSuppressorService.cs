using System;
using System.Collections.Generic;
using System.ServiceProcess;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.ComponentModel;
using System.Configuration.Install;
using System.Reflection;
using System.Threading;

namespace MouseWakeSuppressor
{
    public class MouseWakeSuppressorService : ServiceBase
    {
        private List<string> devices = new List<string>();
        private volatile bool mouseDisabled = false;
        private readonly object _stateLock = new object();
        private bool _eventSourceCreated = false;
        private const int DefaultAutomaticDisableDelayMilliseconds = 5000;
        private int _automaticDisableDelayMilliseconds = DefaultAutomaticDisableDelayMilliseconds;
        private Timer _automaticDisableTimer = null;
        private long _automaticDisableGeneration = 0;

        /// <summary>サービスの基本属性を初期化します。</summary>
        public MouseWakeSuppressorService()
        {
            this.ServiceName = "MouseWakeSuppressor";
            this.CanHandleSessionChangeEvent = true;
        }

        protected override void OnStart(string[] args)
        {
            InitEventSource();
            LoadConfig();
            // 起動直後にマウスを有効に戻し状態ファイルを更新
            RecoverDevicesOnStartup();
            SaveState(true);
        }

        protected override void OnStop()
        {
            ForceEnableMouse("サービス停止");
            SaveState(true);
        }

        protected override void OnSessionChange(SessionChangeDescription changeDescription)
        {
            if (changeDescription.Reason == SessionChangeReason.SessionUnlock)
            {
                EnableMouse("セッションアンロック");
            }
            else if (changeDescription.Reason == SessionChangeReason.SessionLock)
            {
                ScheduleAutomaticDisable("セッションロック");
            }
            else if (changeDescription.Reason == SessionChangeReason.SessionLogoff)
            {
                ForceEnableMouse("セッションログオフ");
                SaveState(true);
            }
        }

        protected override void OnCustomCommand(int command)
        {
            if (command == 128) // Toggle
            {
                ToggleMouse();
            }
            else if (command == 129) // Enable
            {
                EnableMouse("手動有効化 (コマンド129)");
            }
            else if (command == 130) // Disable
            {
                DisableMouse("手動無効化 (コマンド130)");
            }
            else if (command == 131) // Reload Config
            {
                lock (_stateLock)
                {
                    LoadConfig();
                }
            }
            else if (command == 132) // 自動無効化を予約
            {
                ScheduleAutomaticDisable("ディスプレイ消灯");
            }
        }

        private void LoadConfig()
        {
            devices.Clear();
            _automaticDisableDelayMilliseconds = DefaultAutomaticDisableDelayMilliseconds;
            try
            {
                string exeDir = AppDomain.CurrentDomain.BaseDirectory;
                string iniPath = Path.Combine(exeDir, "mws_config.ini");

                if (!File.Exists(iniPath))
                {
                    return;
                }

                StringBuilder sb = new StringBuilder(16384);
                GetPrivateProfileString("Devices", "InstanceIds", "", sb, (uint)sb.Capacity, iniPath);
                string savedIds = sb.ToString();

                if (!string.IsNullOrEmpty(savedIds))
                {
                    string[] ids = savedIds.Split('|');
                    foreach (var id in ids)
                    {
                        string trimmed = id.Trim();
                        if (!string.IsNullOrEmpty(trimmed))
                        {
                            devices.Add(trimmed);
                        }
                    }
                }

                // 不正値で安全機構が意図せず無効にならないよう、既定値へ戻す。
                sb.Clear();
                GetPrivateProfileString(
                    "Service",
                    "AutomaticDisableDelayMs",
                    DefaultAutomaticDisableDelayMilliseconds.ToString(),
                    sb,
                    (uint)sb.Capacity,
                    iniPath);
                int configuredDelay;
                if (int.TryParse(sb.ToString().Trim(), out configuredDelay) && configuredDelay >= 0)
                {
                    _automaticDisableDelayMilliseconds = configuredDelay;
                }
                else
                {
                    WriteLog(
                        "AutomaticDisableDelayMs が不正なため、既定値 5000 ms を使用します。",
                        EventLogEntryType.Warning);
                }
            }
            catch (Exception ex)
            {
                WriteLog("Error loading configuration: " + ex.Message, EventLogEntryType.Error);
            }
        }

        private void ToggleMouse()
        {
            lock (_stateLock)
            {
                if (mouseDisabled)
                    EnableMouse("手動トグル (コマンド128)");
                else
                    DisableMouse("手動トグル (コマンド128)");
            }
        }

        private void ScheduleAutomaticDisable(string reason)
        {
            lock (_stateLock)
            {
                // 同じ状態の通知が重なっても、最初の通知からの猶予を延長しない。
                if (mouseDisabled || _automaticDisableTimer != null) return;

                long generation = ++_automaticDisableGeneration;
                int delayMilliseconds = _automaticDisableDelayMilliseconds;
                _automaticDisableTimer = new Timer(
                    state => CompleteAutomaticDisable(generation, reason, delayMilliseconds),
                    null,
                    delayMilliseconds,
                    Timeout.Infinite);
            }
        }

        private void CompleteAutomaticDisable(long generation, string reason, int delayMilliseconds)
        {
            lock (_stateLock)
            {
                // Dispose と callback の競合時も、取消済み世代には状態を変更させない。
                if (_automaticDisableTimer == null || generation != _automaticDisableGeneration) return;

                _automaticDisableTimer.Dispose();
                _automaticDisableTimer = null;
                DisableMouse(string.Format("{0}から {1} ms 経過", reason, delayMilliseconds));
            }
        }

        private void CancelAutomaticDisableLocked()
        {
            // 世代を進めることで、既に queue 済みの stale callback も無効化する。
            _automaticDisableGeneration++;
            if (_automaticDisableTimer == null) return;

            _automaticDisableTimer.Dispose();
            _automaticDisableTimer = null;
        }

        private void RecoverDevicesOnStartup()
        {
            ForceEnableMouse("サービス起動時の復旧");
        }

        private void DisableMouse(string reason = "")
        {
            lock (_stateLock)
            {
                // 手動無効化後に不要な自動 callback を残さない。
                CancelAutomaticDisableLocked();
                if (mouseDisabled) return;

                LoadConfig();
                if (devices.Count == 0) return;

                WriteLog("マウス無効化: " + (string.IsNullOrEmpty(reason) ? "不明" : reason));
                foreach (var id in devices)
                {
                    RunPnpUtil("/disable-device \"" + id + "\"");
                }
                mouseDisabled = true;
                SaveState(false);
            }
        }

        private void EnableMouse(string reason = "")
        {
            lock (_stateLock)
            {
                CancelAutomaticDisableLocked();
                if (!mouseDisabled) return;

                LoadConfig();
                WriteLog("マウス有効化: " + (string.IsNullOrEmpty(reason) ? "不明" : reason));
                foreach (var id in devices)
                {
                    RunPnpUtil("/enable-device \"" + id + "\"");
                }
                mouseDisabled = false;
                SaveState(true);
            }
        }

        private void ForceEnableMouse(string reason = "")
        {
            lock (_stateLock)
            {
                CancelAutomaticDisableLocked();
                LoadConfig();
                WriteLog("マウス強制有効化: " + (string.IsNullOrEmpty(reason) ? "不明" : reason));
                foreach (var id in devices)
                {
                    RunPnpUtil("/enable-device \"" + id + "\"");
                }
                mouseDisabled = false;
            }
        }

        private void RunPnpUtil(string argument)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = "pnputil.exe";
                psi.Arguments = argument;
                psi.CreateNoWindow = true;
                psi.UseShellExecute = false;
                psi.WindowStyle = ProcessWindowStyle.Hidden;

                using (Process p = Process.Start(psi))
                {
                    p.WaitForExit(5000);
                    if (p.ExitCode != 0)
                    {
                        if (p.ExitCode == 50 && argument.StartsWith("/enable-device")) // exit code 50 は already enabled
                        {
                            WriteLog(string.Format("pnputil {0} exited with code 50 (already enabled).", argument), EventLogEntryType.Information);
                        }
                        else
                        {
                            WriteLog(string.Format("pnputil {0} exited with code {1}.", argument, p.ExitCode), EventLogEntryType.Warning);
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                WriteLog("pnputil execution error: " + ex.Message, EventLogEntryType.Error);
            }
        }

        private void SaveState(bool enabled)
        {
            try
            {
                string exeDir = AppDomain.CurrentDomain.BaseDirectory;
                string stateFile = Path.Combine(exeDir, "mws_state.txt");
                File.WriteAllText(stateFile, enabled ? "1" : "0");
            }
            catch { }
        }

        private void InitEventSource()
        {
            try
            {
                if (!EventLog.SourceExists("MouseWakeSuppressor"))
                {
                    EventLog.CreateEventSource("MouseWakeSuppressor", "Application");
                }
                _eventSourceCreated = true;
            }
            catch { }
        }

        private void WriteLog(string message, EventLogEntryType type = EventLogEntryType.Information)
        {
            if (!_eventSourceCreated) return;
            try
            {
                EventLog.WriteEntry("MouseWakeSuppressor", message, type);
            }
            catch { }
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern uint GetPrivateProfileString(
            string lpAppName,
            string lpKeyName,
            string lpDefault,
            StringBuilder lpReturnedString,
            uint nSize,
            string lpFileName);
    }

    [RunInstaller(true)]
    public class ProjectInstaller : Installer
    {
        private ServiceProcessInstaller processInstaller;
        private ServiceInstaller serviceInstaller;

        public ProjectInstaller()
        {
            processInstaller = new ServiceProcessInstaller();
            serviceInstaller = new ServiceInstaller();

            processInstaller.Account = ServiceAccount.LocalSystem;
            processInstaller.Username = null;
            processInstaller.Password = null;

            serviceInstaller.StartType = ServiceStartMode.Automatic;
            serviceInstaller.ServiceName = "MouseWakeSuppressor";
            serviceInstaller.DisplayName = "Mouse Wake Suppressor Service";
            serviceInstaller.Description = "モニター消灯時に、指定したマウスを一時的に無効化して不意のスリープ解除を防ぎます。";

            Installers.Add(processInstaller);
            Installers.Add(serviceInstaller);
        }
    }

    static class Program
    {
        static void Main(string[] args)
        {
            if (args.Length > 0)
            {
                string cmd = args[0].ToLower();
                if (cmd == "-install" || cmd == "/i")
                {
                    try
                    {
                        ManagedInstallerClass.InstallHelper(new string[] { Assembly.GetExecutingAssembly().Location });
                        Console.WriteLine("Service installed successfully.");
                    }
                    catch (Exception ex)
                    {
                        Console.WriteLine("Installation error: " + ex.Message);
                        return;
                    }
                    // 一般ユーザーが sc control でカスタムコマンドを送れるよう DACL を設定
                    SetServiceDacl();
                    // OS起動時の遅延自動起動を有効化 (Automatic Delayed Start)
                    SetDelayedAutoStart();
                    // サービスを起動
                    StartService();
                    return;
                }
                else if (cmd == "-uninstall" || cmd == "/u")
                {
                    // アンインストール前にサービスを停止
                    StopService();
                    try
                    {
                        ManagedInstallerClass.InstallHelper(new string[] { "/u", Assembly.GetExecutingAssembly().Location });
                        Console.WriteLine("Service uninstalled successfully.");
                    }
                    catch (Exception ex)
                    {
                        Console.WriteLine("Uninstallation error: " + ex.Message);
                    }
                    return;
                }
            }

            ServiceBase.Run(new MouseWakeSuppressorService());
        }

        // 一般ユーザー (Users グループ) がサービスの状態照会とカスタムコマンドを
        // 送信できるよう DACL を設定する。管理者でのインストール時に一度だけ実行。
        private static void SetServiceDacl()
        {
            try
            {
                // BU (Builtin Users) に CC+LC+SW+LO+CR+RC を付与:
                //   CC = SERVICE_QUERY_CONFIG
                //   LC = SERVICE_QUERY_STATUS
                //   SW = SERVICE_ENUMERATE_DEPENDENTS
                //   LO = SERVICE_INTERROGATE
                //   CR = SERVICE_USER_DEFINED_CONTROL  ← sc control に必要
                //   RC = READ_CONTROL
                const string dacl =
                    "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)" +
                    "(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)" +
                    "(A;;CCLCSWLOCRRC;;;IU)" +
                    "(A;;CCLCSWLOCRRC;;;SU)" +
                    "(A;;CCLCSWLOCRRC;;;BU)";

                ProcessStartInfo psi = new ProcessStartInfo("sc",
                    "sdset MouseWakeSuppressor " + dacl);
                psi.CreateNoWindow = true;
                psi.UseShellExecute = false;
                using (Process p = Process.Start(psi))
                {
                    p.WaitForExit(5000);
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("DACL setting error: " + ex.Message);
            }
        }

        // OS起動時に Automatic (Delayed Start) として登録する。
        // これにより他の自動起動サービスが落ち着いた後に起動される。
        private static void SetDelayedAutoStart()
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo("sc",
                    "config MouseWakeSuppressor start= delayed-auto");
                psi.CreateNoWindow = true;
                psi.UseShellExecute = false;
                using (Process p = Process.Start(psi))
                {
                    p.WaitForExit(5000);
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("Delayed auto start config error: " + ex.Message);
            }
        }

        private static void StartService()
        {
            try
            {
                using (System.ServiceProcess.ServiceController sc =
                    new System.ServiceProcess.ServiceController("MouseWakeSuppressor"))
                {
                    if (sc.Status != System.ServiceProcess.ServiceControllerStatus.Running)
                    {
                        sc.Start();
                        sc.WaitForStatus(
                            System.ServiceProcess.ServiceControllerStatus.Running,
                            TimeSpan.FromSeconds(10));
                        Console.WriteLine("Service started.");
                    }
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("Service start error: " + ex.Message);
            }
        }

        private static void StopService()
        {
            try
            {
                using (System.ServiceProcess.ServiceController sc =
                    new System.ServiceProcess.ServiceController("MouseWakeSuppressor"))
                {
                    if (sc.Status == System.ServiceProcess.ServiceControllerStatus.Running)
                    {
                        sc.Stop();
                        sc.WaitForStatus(
                            System.ServiceProcess.ServiceControllerStatus.Stopped,
                            TimeSpan.FromSeconds(10));
                    }
                }
            }
            catch { }
        }
    }
}
