using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

namespace MouseWakeSuppressor
{
    internal static class LockNative
    {
        internal static long Now { get { return (long)GetTickCount64(); } }
        internal static int ConsoleSession { get { return unchecked((int)WTSGetActiveConsoleSessionId()); } }
        internal static bool Locked(int session)
        {
            if (session < 0 || ConsoleSession != session) return false;
            IntPtr data; int size;
            if (!WTSQuerySessionInformation(IntPtr.Zero, session, 25, out data, out size)) throw new Win32Exception();
            try
            {
                // WTSINFOEX の union は LARGE_INTEGER により 8 byte alignment。
                if (size < 20 || Marshal.ReadInt32(data) != 1) throw new InvalidOperationException("WTSINFOEX が不正です。");
                int id = Marshal.ReadInt32(data, 8), state = Marshal.ReadInt32(data, 12), flags = Marshal.ReadInt32(data, 16);
                if (id != session || (flags != 0 && flags != 1)) throw new InvalidOperationException("ロック状態を確認できません。");
                if (state != 0 || flags != 0) return false;
            }
            finally { WTSFreeMemory(data); }
            // ログオン前の Winlogon desktop を既存ユーザーのロックと取り違えない。
            if (!WTSQuerySessionInformation(IntPtr.Zero, session, 5, out data, out size)) throw new Win32Exception();
            try { return size > 2 && !String.IsNullOrEmpty(Marshal.PtrToStringUni(data)); }
            finally { WTSFreeMemory(data); }
        }
        internal static string DesktopName(IntPtr desktop)
        {
            var name = new StringBuilder(256); int needed;
            if (!GetUserObjectInformation(desktop, 2, name, name.Capacity * 2, out needed)) throw new Win32Exception();
            return name.ToString();
        }
        internal static Process Launch(int session, string pipe, string generation)
        {
            IntPtr source = IntPtr.Zero, token = IntPtr.Zero;
            try
            {
                if (!OpenProcessToken(GetCurrentProcess(), 0x000B, out source) ||
                    !DuplicateTokenEx(source, 0xF01FF, IntPtr.Zero, 2, 1, out token) ||
                    !SetTokenInformation(token, 12, ref session, 4)) throw new Win32Exception();
                var startup = new Startup { Size = Marshal.SizeOf(typeof(Startup)), Desktop = @"winsta0\default" };
                ProcessInfo process;
                string exe = System.Reflection.Assembly.GetExecutingAssembly().Location;
                var command = new StringBuilder("\"" + exe + "\" --lock-helper " + pipe + " " + session + " " + generation + " " + Process.GetCurrentProcess().Id);
                if (!CreateProcessAsUser(token, exe, command, IntPtr.Zero, IntPtr.Zero, false, 0x08000000, IntPtr.Zero,
                    AppDomain.CurrentDomain.BaseDirectory, ref startup, out process)) throw new Win32Exception();
                try { return Process.GetProcessById(process.Id); }
                finally { CloseHandle(process.Thread); CloseHandle(process.Process); }
            }
            finally { if (token != IntPtr.Zero) CloseHandle(token); if (source != IntPtr.Zero) CloseHandle(source); }
        }
        internal static bool SystemIdentity { get { using (var id = WindowsIdentity.GetCurrent()) return id.IsSystem; } }
        internal static bool SystemProcess(int pid)
        {
            using (var process = Process.GetProcessById(pid))
            {
                IntPtr token;
                if (!OpenProcessToken(process.Handle, 8, out token)) throw new Win32Exception();
                try { using (var identity = new WindowsIdentity(token)) return identity.IsSystem; }
                finally { CloseHandle(token); }
            }
        }
        internal static string InstanceId(string path)
        {
            IntPtr set = SetupDiCreateDeviceInfoList(IntPtr.Zero, IntPtr.Zero);
            if (set == new IntPtr(-1)) throw new Win32Exception();
            try
            {
                var face = new InterfaceInfo { Size = (uint)Marshal.SizeOf(typeof(InterfaceInfo)) };
                if (!SetupDiOpenDeviceInterface(set, path, 0, ref face)) throw new Win32Exception();
                uint needed;
                var info = new DeviceInfo { Size = (uint)Marshal.SizeOf(typeof(DeviceInfo)) };
                SetupDiGetDeviceInterfaceDetail(set, ref face, IntPtr.Zero, 0, out needed, ref info);
                if (needed < 6 || needed > 65536) throw new Win32Exception();
                IntPtr buffer = Marshal.AllocHGlobal((int)needed);
                try
                {
                    Marshal.WriteInt32(buffer, IntPtr.Size == 8 ? 8 : 6);
                    if (!SetupDiGetDeviceInterfaceDetail(set, ref face, buffer, needed, out needed, ref info)) throw new Win32Exception();
                    var id = new StringBuilder(512);
                    if (!SetupDiGetDeviceInstanceId(set, ref info, id, id.Capacity, out needed)) throw new Win32Exception();
                    return id.ToString();
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
            finally { SetupDiDestroyDeviceInfoList(set); }
        }
        [StructLayout(LayoutKind.Sequential)] internal struct RawDevice { internal IntPtr Handle; internal uint Type; }
        [StructLayout(LayoutKind.Sequential)] internal struct RawRegistration { internal ushort Page, Usage; internal uint Flags; internal IntPtr Window; }
        [StructLayout(LayoutKind.Sequential)] internal struct Message { internal IntPtr Window; internal uint Id; internal UIntPtr WParam; internal IntPtr LParam; internal uint Time; internal int X, Y; internal uint Private; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct WindowClass { internal uint Style; internal WndProc Proc; internal int ClassExtra, WindowExtra; internal IntPtr Instance, Icon, Cursor, Background; internal string Menu, Name; }
        internal delegate IntPtr WndProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct Startup
        { internal int Size; internal string Reserved, Desktop, Title; internal int X, Y, Width, Height, CountX, CountY, Fill, Flags; internal short Show, ReservedSize; internal IntPtr ReservedData, Input, Output, Error; }
        [StructLayout(LayoutKind.Sequential)] private struct ProcessInfo { internal IntPtr Process, Thread; internal int Id, ThreadId; }
        [StructLayout(LayoutKind.Sequential)] private struct InterfaceInfo { internal uint Size; internal Guid Class; internal uint Flags; internal IntPtr Reserved; }
        [StructLayout(LayoutKind.Sequential)] private struct DeviceInfo { internal uint Size; internal Guid Class; internal uint Instance; internal IntPtr Reserved; }
        [DllImport("kernel32.dll")] private static extern ulong GetTickCount64();
        [DllImport("kernel32.dll")] private static extern uint WTSGetActiveConsoleSessionId();
        [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool WTSQuerySessionInformation(IntPtr server, int session, int info, out IntPtr data, out int size);
        [DllImport("wtsapi32.dll")] private static extern void WTSFreeMemory(IntPtr data);
        [DllImport("user32.dll", SetLastError = true)] internal static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
        [DllImport("user32.dll", SetLastError = true)] internal static extern bool SetThreadDesktop(IntPtr desktop);
        [DllImport("user32.dll", SetLastError = true)] internal static extern bool CloseDesktop(IntPtr desktop);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder data, int size, out int needed);
        [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] internal static extern IntPtr GetModuleHandle(string module);
        [DllImport("kernel32.dll")] internal static extern bool CloseHandle(IntPtr handle);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern bool DuplicateTokenEx(IntPtr source, uint access, IntPtr attributes, int level, int type, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern bool SetTokenInformation(IntPtr token, int info, ref int data, int length);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CreateProcessAsUser(IntPtr token, string app, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory, ref Startup startup, out ProcessInfo process);
        [DllImport("user32.dll", SetLastError = true)] internal static extern uint GetRawInputDeviceList([In, Out] RawDevice[] devices, ref uint count, uint size);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern uint GetRawInputDeviceInfo(IntPtr device, uint command, StringBuilder data, ref uint size);
        [DllImport("user32.dll", SetLastError = true)] internal static extern uint GetRawInputData(IntPtr input, uint command, IntPtr data, ref uint size, uint header);
        [DllImport("user32.dll", SetLastError = true)] internal static extern bool RegisterRawInputDevices(RawRegistration[] devices, uint count, uint size);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern ushort RegisterClass(ref WindowClass windowClass);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern IntPtr CreateWindowEx(uint extended, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
        [DllImport("user32.dll", SetLastError = true)] internal static extern bool DestroyWindow(IntPtr window);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern IntPtr DefWindowProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] internal static extern bool PeekMessage(out Message message, IntPtr window, uint min, uint max, uint remove);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern IntPtr DispatchMessage(ref Message message);
        [DllImport("user32.dll", SetLastError = true)] internal static extern IntPtr RegisterPowerSettingNotification(IntPtr window, ref Guid setting, uint flags);
        [DllImport("user32.dll", SetLastError = true)] internal static extern bool UnregisterPowerSettingNotification(IntPtr handle);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out UIntPtr result);
        [DllImport("setupapi.dll", SetLastError = true)] private static extern IntPtr SetupDiCreateDeviceInfoList(IntPtr cls, IntPtr window);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool SetupDiOpenDeviceInterface(IntPtr set, string path, uint flags, ref InterfaceInfo info);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref InterfaceInfo face, IntPtr detail, uint size, out uint needed, ref DeviceInfo info);
        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool SetupDiGetDeviceInstanceId(IntPtr set, ref DeviceInfo info, StringBuilder id, int size, out uint needed);
        [DllImport("setupapi.dll")] private static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    }
}
