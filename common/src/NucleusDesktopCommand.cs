// SPDX-License-Identifier: GPL-3.0-or-later
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

internal static class NucleusDesktopCommand
{
    private delegate bool EnumProc(IntPtr window, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll", SetLastError=true)] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);

    [STAThread]
    private static int Main(string[] args)
    {
        string mode = args.Length == 0 ? "toggle" : args[0];
        int command = mode == "toggle" ? 10 : mode == "show" ? 11 : mode == "hide" ? 12 : 0;
        if (command == 0) return 2;
        string root = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ".."));
        var pids = new HashSet<uint>();
        foreach (Process process in Process.GetProcessesByName("NucleusCoop"))
        {
            using (process)
            {
                try
                {
                    if (String.Equals(process.MainModule.FileName, Path.Combine(root,"NucleusCoop.exe"), StringComparison.OrdinalIgnoreCase)) pids.Add((uint)process.Id);
                }
                catch { }
            }
        }
        int sent = 0;
        EnumWindows(delegate(IntPtr window, IntPtr parameter)
        {
            uint pid;
            GetWindowThreadProcessId(window, out pid);
            if (!pids.Contains(pid)) return true;
            var title = new StringBuilder(256);
            GetWindowText(window, title, title.Capacity);
            if (title.ToString() == "HotkeyListener" && PostMessage(window, 0x0312, new IntPtr(command), IntPtr.Zero)) sent++;
            return true;
        }, IntPtr.Zero);
        if (sent == 0)
        {
            MessageBox.Show("Активный сеанс Nucleus не найден. Сначала запустите игру через настроенный профиль.", "Nucleus: рабочий стол", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 1;
        }
        return 0;
    }
}
