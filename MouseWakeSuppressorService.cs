using System;
using System.ComponentModel;
using System.Configuration.Install;
using System.Diagnostics;
using System.Reflection;
using System.ServiceProcess;

namespace MouseWakeSuppressor
{
    /// <summary>Windows の通知を直列 worker に中継するサービスです。</summary>
    public sealed class MouseWakeSuppressorService : ServiceBase
    {
        private Engine engine;
        private PipeServer pipe;
        private LockDisplayHost lockDisplay;
        /// <summary>SCM から受け取る通知を設定します。</summary>
        public MouseWakeSuppressorService()
        {
            ServiceName = "MouseWakeSuppressor";
            CanHandleSessionChangeEvent = true;
            CanShutdown = true;
            AutoLog = false;
        }
        protected override void OnStart(string[] args)
        {
            engine = new Engine(new WindowsDevices(), new RecoveryFile(), new IniConfig(AppDomain.CurrentDomain.BaseDirectory), new Scheduler(), Log);
            engine.Start();
            try
            {
                lockDisplay = new LockDisplayHost(new IniConfig(AppDomain.CurrentDomain.BaseDirectory), Log);
                engine.LockStatus = lockDisplay.Read;
                engine.LockProbe = lockDisplay.Probe;
                engine.Keyboards = () => new WindowsDevices(true).Enumerate();
                pipe = new PipeServer(engine);
            }
            catch { if (lockDisplay != null) lockDisplay.Dispose(); engine.Stop(); throw; }
        }
        protected override void OnStop()
        { StopEngine(true); }
        private void StopEngine(bool notifyScm)
        {
            if (engine == null) return;
            if (lockDisplay != null) { lockDisplay.Dispose(); lockDisplay = null; }
            engine.BeginStop();
            if (pipe != null) pipe.Dispose();
            // 復旧中に SCM へ停止完了を返さない。
            while (!engine.Join(1000)) if (notifyScm) RequestAdditionalTime(10000);
            engine.Dispose();
            engine = null;
        }
        protected override void OnShutdown() { StopEngine(false); }
        protected override void OnSessionChange(SessionChangeDescription change)
        {
            if (lockDisplay != null) lockDisplay.SessionChanged(change.SessionId, change.Reason == SessionChangeReason.SessionLock);
            if (engine == null) return;
            if (change.Reason == SessionChangeReason.SessionLock) engine.Schedule();
            else if (change.Reason == SessionChangeReason.SessionUnlock || change.Reason == SessionChangeReason.SessionLogoff)
                engine.Submit("enable", Guid.NewGuid().ToString("N"));
        }
        protected override void OnCustomCommand(int command)
        {
            string[] commands = { "toggle", "enable", "disable", "reload", "schedule" };
            if (command >= 128 && command <= 132) engine.Submit(commands[command - 128], Guid.NewGuid().ToString("N"));
        }
        private static void Log(string message, LogLevel level)
        {
            try { EventLog.WriteEntry("MouseWakeSuppressor", message, level == LogLevel.Information ? EventLogEntryType.Information : level == LogLevel.Error ? EventLogEntryType.Error : EventLogEntryType.Warning); }
            catch (Exception ex) { Trace.WriteLine("EventLog: " + ex.Message); }
        }
    }
    /// <summary>LocalSystem のサービスを登録します。</summary>
    [RunInstaller(true)]
    public sealed class ProjectInstaller : Installer
    {
        /// <summary>サービスのアカウントと起動設定を定義します。</summary>
        public ProjectInstaller()
        {
            Installers.Add(new ServiceProcessInstaller { Account = ServiceAccount.LocalSystem });
            Installers.Add(new ServiceInstaller {
                ServiceName = "MouseWakeSuppressor", DisplayName = "Mouse Wake Suppressor Service",
                Description = "消灯時のマウス無効化と永続記録に基づく復旧を行います。",
                StartType = ServiceStartMode.Automatic, DelayedAutoStart = true
            });
        }
    }
    internal static class Program
    {
        private static int Main(string[] args)
        {
            if (args.Length > 0 && args[0] == "--lock-helper") return LockInputHelper.Run(args);
            // 対話 CLI と SCM 起動を区別する。
            if (args.Length == 0 && !Environment.UserInteractive) { ServiceBase.Run(new MouseWakeSuppressorService()); return 0; }
            if (args.Length != 1 || args[0] == "--help")
            {
                Console.WriteLine("マウスの復旧を管理する Windows サービスです。\n使い方: MouseWakeSuppressorService.exe -install|-uninstall|-start|-stop|-restart\n管理者権限が必要です。引数なしではこのヘルプを表示します。");
                return args.Length == 1 ? 0 : 64;
            }
            try
            {
                string command = args[0].ToLowerInvariant();
                if (command == "-install" || command == "/i")
                {
                    ManagedInstallerClass.InstallHelper(new[] { Assembly.GetExecutingAssembly().Location });
                    ServiceSecurity.Configure(); Start();
                }
                else if (command == "-uninstall" || command == "/u")
                {
                    Stop();
                    // 復旧未完了のまま次回の復旧手段を削除しない。
                    if (new RecoveryFile().Load().Count != 0) throw new InvalidOperationException("復旧対象が残っています。再接続後にサービスを開始し、復旧を再試行してください。");
                    ManagedInstallerClass.InstallHelper(new[] { "/u", Assembly.GetExecutingAssembly().Location });
                }
                else if (command == "-start") Start();
                else if (command == "-stop") Stop();
                else if (command == "-restart") { Stop(); Start(); }
                else { Console.Error.WriteLine("不明な引数です。--help を参照してください。"); return 64; }
                Console.WriteLine("操作が完了しました。"); return 0;
            }
            catch (UnauthorizedAccessException ex) { Console.Error.WriteLine(ex.Message); return 77; }
            catch (Exception ex) { Console.Error.WriteLine("操作に失敗しました: " + ex.Message); return 74; }
        }
        private static void Start()
        {
            using (var sc = new ServiceController("MouseWakeSuppressor"))
            {
                if (sc.Status == ServiceControllerStatus.Stopped) sc.Start();
                sc.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(30));
            }
        }
        private static void Stop()
        {
            using (var sc = new ServiceController("MouseWakeSuppressor"))
            {
                if (sc.Status != ServiceControllerStatus.Stopped && sc.Status != ServiceControllerStatus.StopPending) sc.Stop();
                sc.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromMinutes(10));
            }
        }
    }
}
