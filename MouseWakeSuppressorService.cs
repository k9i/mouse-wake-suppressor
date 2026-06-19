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
        private bool mouseDisabled = false;
        private Thread windowThread = null;
        private PowerNotificationWindow powerWindow = null;

        public MouseWakeSuppressorService()
        {
            this.ServiceName = "MouseWakeSuppressor";
            this.CanHandleSessionChangeEvent = true;
        }

        protected override void OnStart(string[] args)
        {
            LoadConfig();
            RecoverDevicesOnStartup();
            SaveState(true);

            windowThread = new Thread(() =>
            {
                powerWindow = new PowerNotificationWindow(OnDisplayStateChanged);
                Application.Run(powerWindow);
            });
            windowThread.SetApartmentState(ApartmentState.STA);
            windowThread.Start();
        }

        protected override void OnStop()
        {
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

            ForceEnableMouse();
            SaveState(true);
        }

        private void OnDisplayStateChanged(int displayState)
        {
            if (displayState == 0) // Display OFF
            {
                DisableMouse();
            }
            else if (displayState == 1) // Display ON
            {
                EnableMouse();
            }
        }

        protected override void OnSessionChange(SessionChangeDescription changeDescription)
        {
            if (changeDescription.Reason == SessionChangeReason.SessionUnlock)
            {
                EnableMouse();
            }
            else if (changeDescription.Reason == SessionChangeReason.SessionLogoff)
            {
                ForceEnableMouse();
            }
        }

        protected override void OnCustomCommand(int command)
        {
            if (command == 128) // Toggle
            {
                if (mouseDisabled)
                    EnableMouse();
                else
                    DisableMouse();
            }
            else if (command == 129) // Enable
            {
                EnableMouse();
            }
            else if (command == 130) // Disable
            {
                DisableMouse();
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

                StringBuilder sb = new StringBuilder(4096);
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

        private void RecoverDevicesOnStartup()
        {
            ForceEnableMouse();
        }

        private void DisableMouse()
        {
            if (mouseDisabled) return;

            LoadConfig();
            if (devices.Count == 0) return;

            foreach (var id in devices)
            {
                RunPnpUtil("/disable-device \"" + id + "\"");
            }
            mouseDisabled = true;
            SaveState(false);
        }

        private void EnableMouse()
        {
            if (!mouseDisabled) return;

            LoadConfig();
            foreach (var id in devices)
            {
                RunPnpUtil("/enable-device \"" + id + "\"");
            }
            mouseDisabled = false;
            SaveState(true);
        }

        private void ForceEnableMouse()
        {
            LoadConfig();
            foreach (var id in devices)
            {
                RunPnpUtil("/enable-device \"" + id + "\"");
            }
            mouseDisabled = false;
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

        private void WriteLog(string message, EventLogEntryType type = EventLogEntryType.Information)
        {
            try
            {
                if (!EventLog.SourceExists("MouseWakeSuppressor"))
                {
                    EventLog.CreateEventSource("MouseWakeSuppressor", "Application");
                }
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

        public PowerNotificationWindow(Action<int> callback)
        {
            this.onDisplayStateChanged = callback;
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
                powerNotifyHandle = RegisterPowerSettingNotification(
                    this.Handle,
                    ref GUID_CONSOLE_DISPLAY_STATE,
                    DEVICE_NOTIFY_WINDOW_HANDLE);
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
                    }
                    return;
                }
                else if (cmd == "-uninstall" || cmd == "/u")
                {
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
    }
}
