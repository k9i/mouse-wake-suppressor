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
using System.Windows.Forms;

namespace MouseWakeSuppressor
{
    public class MouseWakeSuppressorService : ServiceBase
    {
        private List<string> devices = new List<string>();
        private volatile bool mouseDisabled = false;
        private readonly object _stateLock = new object();
        private bool _eventSourceCreated = false;
        private Thread windowThread = null;
        private PowerNotificationWindow powerWindow = null;
        private CancellationTokenSource _startupCts = null;

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

            int delaySec = LoadStartupDelay();
            if (delaySec > 0)
            {
                WriteLog(string.Format("電源監視を {0} 秒後に開始します (StartupDelaySec={0})。", delaySec));
                _startupCts = new CancellationTokenSource();
                CancellationToken token = _startupCts.Token;
                Thread t = new Thread(() =>
                {
                    for (int i = 0; i < delaySec && !token.IsCancellationRequested; i++)
                        Thread.Sleep(1000);
                    if (!token.IsCancellationRequested)
                        StartMonitoring();
                });
                t.IsBackground = true;
                t.Start();
            }
            else
            {
                StartMonitoring();
            }
        }

        private void StartMonitoring()
        {
            windowThread = new Thread(() =>
            {
                powerWindow = new PowerNotificationWindow(
                    OnDisplayStateChanged,
                    msg => WriteLog(msg, EventLogEntryType.Error));
                Application.Run(powerWindow);
            });
            windowThread.SetApartmentState(ApartmentState.STA);
            windowThread.Start();
        }

        protected override void OnStop()
        {
            // 起動遅延中の場合はキャンセル
            if (_startupCts != null)
            {
                _startupCts.Cancel();
                _startupCts = null;
            }

            if (powerWindow != null)
            {
                try
                {
                    powerWindow.Invoke(new Action(() => powerWindow.CloseWindow()));
                }
                catch { }
            }
            if (windowThread != null)
            {
                windowThread.Join(2000);
            }

            ForceEnableMouse("サービス停止");
            SaveState(true);
        }

        private void OnDisplayStateChanged(int displayState)
        {
            if (displayState == 0 || displayState == 2) // Display OFF or Dimmed
            {
                DisableMouse("ディスプレイ消灯 (状態=" + displayState + ")");
            }
            else if (displayState == 1) // Display ON
            {
                EnableMouse("ディスプレイ点灯");
            }
        }

        protected override void OnSessionChange(SessionChangeDescription changeDescription)
        {
            if (changeDescription.Reason == SessionChangeReason.SessionUnlock)
            {
                EnableMouse("セッションアンロック");
            }
            else if (changeDescription.Reason == SessionChangeReason.SessionLock)
            {
                DisableMouse("セッションロック");
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
                if (mouseDisabled)
                    EnableMouse("手動トグル (コマンド128)");
                else
                    DisableMouse("手動トグル (コマンド128)");
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
                LoadConfig();
            }
        }

        private void LoadConfig()
        {
            devices.Clear();
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
            }
            catch (Exception ex)
            {
                WriteLog("Error loading configuration: " + ex.Message, EventLogEntryType.Error);
            }
        }

        // [Service] StartupDelaySec の値を読む。未設定または 0 以下なら 0 を返す。
        private int LoadStartupDelay()
        {
            try
            {
                string exeDir = AppDomain.CurrentDomain.BaseDirectory;
                string iniPath = Path.Combine(exeDir, "mws_config.ini");
                if (!File.Exists(iniPath)) return 0;

                StringBuilder sb = new StringBuilder(64);
                GetPrivateProfileString("Service", "StartupDelaySec", "0", sb, (uint)sb.Capacity, iniPath);
                int result;
                if (int.TryParse(sb.ToString().Trim(), out result) && result > 0)
                    return result;
            }
            catch { }
            return 0;
        }

        private void RecoverDevicesOnStartup()
        {
            ForceEnableMouse("サービス起動時の復旧");
        }

        private void DisableMouse(string reason = "")
        {
            lock (_stateLock)
            {
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

    public class PowerNotificationWindow : Form
    {
        private static Guid GUID_CONSOLE_DISPLAY_STATE = new Guid("6fe69556-704a-47a0-8f24-c2c28d936fda");
        private const uint DEVICE_NOTIFY_WINDOW_HANDLE = 0x00000000;
        private const int WM_POWERBROADCAST = 0x218;
        private const int PBT_POWERSETTINGCHANGE = 0x8013;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr RegisterPowerSettingNotification(
            IntPtr hRecipient,
            ref Guid PowerSettingGuid,
            uint Flags);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnregisterPowerSettingNotification(IntPtr handle);

        private IntPtr powerNotifyHandle = IntPtr.Zero;
        private Action<int> onDisplayStateChanged = null;
        private Action<string> onError = null;

        public PowerNotificationWindow(Action<int> callback, Action<string> errorCallback = null)
        {
            this.onDisplayStateChanged = callback;
            this.onError = errorCallback;
            this.FormBorderStyle = FormBorderStyle.None;
            this.ShowInTaskbar = false;
            this.WindowState = FormWindowState.Minimized;
            this.Load += (s, e) => { this.Hide(); };
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            try
            {
                var guid = GUID_CONSOLE_DISPLAY_STATE;
                powerNotifyHandle = RegisterPowerSettingNotification(
                    this.Handle,
                    ref guid,
                    DEVICE_NOTIFY_WINDOW_HANDLE);

                if (powerNotifyHandle == IntPtr.Zero)
                {
                    int error = Marshal.GetLastWin32Error();
                    if (onError != null)
                        onError("RegisterPowerSettingNotification failed. Win32 error: " + error);
                }
            }
            catch { }
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_POWERBROADCAST && (int)m.WParam == PBT_POWERSETTINGCHANGE)
            {
                try
                {
                    // POWERBROADCAST_SETTING: GUID(16B) + DataLength(4B) + Data(4B)
                    int displayState = Marshal.ReadInt32(m.LParam, 20);
                    if (onDisplayStateChanged != null)
                    {
                        onDisplayStateChanged(displayState);
                    }
                }
                catch { }
            }
            base.WndProc(ref m);
        }

        public void CloseWindow()
        {
            if (powerNotifyHandle != IntPtr.Zero)
            {
                UnregisterPowerSettingNotification(powerNotifyHandle);
                powerNotifyHandle = IntPtr.Zero;
            }
            this.Close();
        }
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
        // mws_config.ini の [Service] StartupDelaySec と組み合わせてさらに遅延可能。
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
