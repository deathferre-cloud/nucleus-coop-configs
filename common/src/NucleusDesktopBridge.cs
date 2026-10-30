// SPDX-License-Identifier: GPL-3.0-or-later
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;
using Nucleus.Gaming;
using Nucleus.Gaming.Coop;
using Nucleus.Gaming.Coop.InputManagement;
using Nucleus.Gaming.Coop.ProtoInput;
using Nucleus.Gaming.Tools;
using Nucleus.Gaming.Tools.AudioReroute;
using Nucleus.Gaming.Tools.GlobalWindowMethods;

namespace NucleusLocalTools
{
    // Loaded by the handler inside Nucleus. Input unlocking must run in the
    // process that owns ProtoInput and can resume its suspended Explorer.
    public static class DesktopBridge
    {
        [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
        [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out Rect rect);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr window, int command);
        [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int w, int h, uint flags);
        [DllImport("user32.dll")] private static extern bool ClipCursor(IntPtr rect);
        [DllImport("user32.dll")] private static extern IntPtr GetShellWindow();
        [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll", SetLastError=true)] private static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
        [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr window, int id);
        [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);

        private static readonly Dictionary<IntPtr, Rect> positions = new Dictionary<IntPtr, Rect>();
        private static readonly Dictionary<string, bool> routed = new Dictionary<string, bool>();
        private static System.Threading.Thread audioThread;
        private static readonly Dictionary<string, string> audioRoutes = new Dictionary<string, string>();
        private static DateTime lastAudioStatus;
        private static int checkingAudio;
        private static bool fullSizePending;
        private static Thread hotkeyThread;
        private static IntPtr sizeHotkeyWindow;
        private const int SizeHotkeyId = 0x4E43;
        private const uint RegisterSizeMessage = 0x8001, UnregisterSizeMessage = 0x8002, ToggleSizeMessage = 0x8003;
        private static readonly string logPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "setup", "desktop-bridge.log");

        private static void Log(string message)
        {
            try { File.AppendAllText(logPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + message + Environment.NewLine); } catch { }
        }

        public static void Begin()
        {
            lock (positions) positions.Clear();
            fullSizePending = true;
            StartSizeHotkey();
            lock (routed) routed.Clear();
            lock (audioRoutes) { audioRoutes.Clear(); foreach (var pair in GameProfile.AudioInstances) audioRoutes[pair.Key] = pair.Value; }
            if (audioThread == null)
            {
                audioThread = new System.Threading.Thread(delegate() { while(true) { System.Threading.Thread.Sleep(4000); CheckAudio(null); } });
                audioThread.IsBackground = true;
                audioThread.Name = "Nucleus local audio reconnect";
                audioThread.Start();
            }
            Log("Session integration v5 initialized; full-size start; captured audio routes=" + audioRoutes.Count + " " + String.Join("; ", audioRoutes.Select(p=>p.Key+"="+p.Value).ToArray()));
        }

        public static void Toggle() { SetVisible(!GlobalWindowMethods.TopMostToggle); }
        public static void Show() { SetVisible(true); }
        public static void Hide() { SetVisible(false); }

        // Nucleus 2.4.2 has only three custom handler slots. Keep those IDs
        // unchanged and register the additional shortcut in our own message loop.
        private sealed class SizeHotkeyReceiver : NativeWindow
        {
            private bool registered;
            public SizeHotkeyReceiver()
            {
                CreateHandle(new CreateParams { Caption = "NucleusPlayer2SizeHotkey" });
                sizeHotkeyWindow = Handle;
                Register();
            }
            private void Register()
            {
                if (registered) return;
                registered = RegisterHotKey(Handle, SizeHotkeyId, 0x4002, 0x76); // Ctrl+F7, no repeat
                Log(registered ? "Ctrl+F7 registered" : "Ctrl+F7 registration failed: " + Marshal.GetLastWin32Error());
            }
            protected override void WndProc(ref Message message)
            {
                if (message.Msg == 0x0312 && message.WParam.ToInt32() == SizeHotkeyId || message.Msg == ToggleSizeMessage)
                    ToggleSecondWindow();
                else if (message.Msg == RegisterSizeMessage) Register();
                else if (message.Msg == UnregisterSizeMessage && registered)
                {
                    UnregisterHotKey(Handle, SizeHotkeyId);
                    registered = false;
                }
                base.WndProc(ref message);
            }
        }

        private static void StartSizeHotkey()
        {
            if (hotkeyThread == null)
            {
                var ready = new ManualResetEvent(false);
                hotkeyThread = new Thread(delegate()
                {
                    var receiver = new SizeHotkeyReceiver();
                    ready.Set();
                    Application.Run();
                    GC.KeepAlive(receiver);
                });
                hotkeyThread.IsBackground = true;
                hotkeyThread.Name = "Nucleus player two window size";
                hotkeyThread.SetApartmentState(ApartmentState.STA);
                hotkeyThread.Start();
                ready.WaitOne(3000);
            }
            else if (sizeHotkeyWindow != IntPtr.Zero)
                PostMessage(sizeHotkeyWindow, RegisterSizeMessage, IntPtr.Zero, IntPtr.Zero);
        }

        public static void ToggleSecondWindow() { ResizeSecondWindow(false); }
        public static void FullSecondWindow() { ResizeSecondWindow(true); }

        private static void ResizeSecondWindow(bool forceFull)
        {
            lock (positions)
            try
            {
                var handler = GenericGameHandler.Instance;
                if (handler == null || handler.hasEnded) return;
                var players = handler.profile.DevicesList.ToArray();
                var player = players.FirstOrDefault(p=>p.PlayerID == 1);
                if (player == null || player.ProcessData == null || player.ProcessData.HWnd == null) return;
                IntPtr window = player.ProcessData.HWnd.NativePtr;
                uint sizePid;
                if (window == IntPtr.Zero || GetWindowThreadProcessId(window, out sizePid) == 0 || sizePid != player.ProcessID) return;
                var bounds = player.MonitorBounds;
                if (bounds.Width <= 0 || bounds.Height <= 0) return;
                int smallWidth = Math.Max(1, (int)Math.Round(bounds.Width * 0.75));
                int smallHeight = Math.Max(1, (int)Math.Round(bounds.Height * 0.75));
                Rect current;
                bool visible = IsWindowVisible(window) && !player.IsMinimized;
                if (!visible && positions.TryGetValue(window, out current)) { }
                else if (!GetWindowRect(window, out current)) return;
                bool isSmall = Math.Abs(current.Right-current.Left-smallWidth) <= 2 && Math.Abs(current.Bottom-current.Top-smallHeight) <= 2;
                bool useSmall = !forceFull && !isSmall;
                var target = new Rect { Left=bounds.X, Top=bounds.Y,
                    Right=bounds.X+(useSmall ? smallWidth : bounds.Width), Bottom=bounds.Y+(useSmall ? smallHeight : bounds.Height) };
                positions[window] = target;
                var game = handler.CurrentGameInfo;
                if (!forceFull)
                {
                    LockInputRuntime.Unlock(game.ProtoInput.FreezeExternalInputWhenInputNotLocked, game.ProtoInput);
                    ClipCursor(IntPtr.Zero);
                }
                if (visible)
                    SetWindowPos(window, new IntPtr(game.NotTopMost ? -2 : -1), target.Left, target.Top,
                        target.Right-target.Left, target.Bottom-target.Top, 0x0010 | 0x4000);
                Log("PLAYER2 SIZE " + (useSmall ? "COMPACT " : "FULL ") + (target.Right-target.Left) + "x" + (target.Bottom-target.Top) + " visible=" + visible + " startup=" + forceFull);
            }
            catch (Exception error) { Log("Player2 size failed: " + error); }
        }

        private static void SetVisible(bool visible)
        {
            lock (positions)
            try
            {
                var handler = GenericGameHandler.Instance;
                if (handler == null || handler.hasEnded) return;
                var game = handler.CurrentGameInfo;
                bool wasLocked = LockInputRuntime.IsLocked;
                LockInputRuntime.Unlock(game.ProtoInput.FreezeExternalInputWhenInputNotLocked, game.ProtoInput);
                ClipCursor(IntPtr.Zero);
                int count = 0;
                foreach (var player in handler.profile.DevicesList.ToArray())
                {
                    if (player.ProcessData == null || player.ProcessData.HWnd == null) continue;
                    IntPtr window = player.ProcessData.HWnd.NativePtr;
                    uint visiblePid;
                    if (window == IntPtr.Zero || GetWindowThreadProcessId(window, out visiblePid) == 0 || visiblePid != player.ProcessID) continue;
                    if (player.ProtoInputInstanceHandle != 0)
                        ProtoInput.protoInput.SetDrawFakeCursor(player.ProtoInputInstanceHandle, visible && (int)game.ProtoInput.DrawFakeCursor != 0);
                    Rect rect;
                    if (!visible)
                    {
                        if (GetWindowRect(window, out rect) && rect.Left > -30000 && rect.Top > -30000 && rect.Right-rect.Left > 100 && rect.Bottom-rect.Top > 100)
                            positions[window] = rect;
                        ShowWindowAsync(window, 0);
                    }
                    else
                    {
                        if (!positions.TryGetValue(window, out rect))
                        {
                            var bounds = player.MonitorBounds;
                            rect = new Rect { Left = bounds.X, Top = bounds.Y, Right = bounds.Right, Bottom = bounds.Bottom };
                        }
                        ShowWindowAsync(window, 9);
                        SetWindowPos(window, new IntPtr(game.NotTopMost ? -2 : -1), rect.Left, rect.Top, rect.Right-rect.Left, rect.Bottom-rect.Top, 0x0010 | 0x0040 | 0x4000);
                    }
                    player.IsMinimized = !visible;
                    count++;
                }
                GlobalWindowMethods.TopMostToggle = visible;
                if (!visible)
                {
                    TaskbarState.Show.Invoke();
                    SetForegroundWindow(GetShellWindow());
                }
                Log((visible ? "SHOW" : "HIDE") + " windows=" + count + " wasLocked=" + wasLocked + " nowLocked=" + LockInputRuntime.IsLocked);
            }
            catch (Exception error) { Log("Desktop action failed: " + error); }
        }

        private static void CheckAudio(object state)
        {
            if (System.Threading.Interlocked.Exchange(ref checkingAudio, 1) != 0) return;
            try
            {
                var handler = GenericGameHandler.Instance;
                if (handler == null || handler.hasEnded)
                {
                    if (sizeHotkeyWindow != IntPtr.Zero) PostMessage(sizeHotkeyWindow, UnregisterSizeMessage, IntPtr.Zero, IntPtr.Zero);
                    return;
                }
                var players = handler.profile.DevicesList.ToArray();
                if ((DateTime.Now-lastAudioStatus).TotalSeconds > 60)
                {
                    lastAudioStatus = DateTime.Now;
                    Log("Audio watcher active; players="+players.Length+" captured routes="+audioRoutes.Count);
                }
                if (fullSizePending && players.Length >= 2 && players.All(p=>p.ProcessData != null && p.ProcessData.HWnd != null && p.ProcessData.Status == 2))
                {
                    FullSecondWindow();
                    fullSizePending = false;
                }
                for (int i = 0; i < players.Length; i++)
                {
                    var player = players[i];
                    if (player.ProcessData == null || player.ProcessData.HWnd == null || player.ProcessData.Status != 2) continue;
                    uint windowPid;
                    GetWindowThreadProcessId(player.ProcessData.HWnd.NativePtr, out windowPid);
                    // A stale/reused HWND during shutdown may now belong to another player.
                    // Never persist another player's endpoint against that process.
                    if (windowPid == 0 || windowPid != player.ProcessID || player.ProcessData.Process == null || player.ProcessData.Process.HasExited || windowPid != player.ProcessData.Process.Id) continue;
                    int playerNumber = player.PlayerID + 1;
                    string endpoint;
                    lock (audioRoutes) { if (!audioRoutes.TryGetValue("AudioInstance" + playerNumber, out endpoint) || endpoint == "Default") continue; }
                    string endpointGuid = endpoint.Substring(endpoint.LastIndexOf('{'));
                    bool active;
                    using (RegistryKey root = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
                    using (RegistryKey key = root.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\" + endpointGuid))
                        active = key != null && (Convert.ToInt32(key.GetValue("DeviceState", 0)) & 1) != 0;
                    int pid = (int)windowPid;
                    string routeKey;
                    using (var process = Process.GetProcessById(pid)) routeKey = pid + "_" + process.StartTime.Ticks + "_" + endpoint;
                    lock (routed)
                    {
                        bool wasRouted;
                        if (!active) { routed[routeKey] = false; continue; }
                        if (routed.TryGetValue(routeKey, out wasRouted) && wasRouted) continue;
                        Log("Audio route requested for player="+playerNumber+" pid="+pid);
                        AudioReroute.SwitchProcessTo(endpoint, AudioReroute.ERole.ERole_enum_count, AudioReroute.EDataFlow.eRender, (uint)pid);
                        routed[routeKey] = true;
                        Log("Audio player=" + playerNumber + " pid=" + pid + " endpoint=" + endpoint);
                    }
                }
            }
            catch (Exception error) { Log("Audio reconnect check: " + error.Message); }
            finally { System.Threading.Interlocked.Exchange(ref checkingAudio, 0); }
        }
    }
}
