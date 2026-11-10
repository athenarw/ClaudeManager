// ClaudeManager.exe - a tiny native host for ClaudeManager.ps1.
//
// It runs the app's PowerShell engine *inside this process* (so the taskbar button, pinning and the icon all belong to
// ClaudeManager.exe instead of a generic powershell.exe), with the script and icon embedded as resources.
// Built by build\Build.ps1 together with the UI helper classes that are extracted from ClaudeManager.ps1.
// Plain C# 5 (the compiler that ships with Windows).

using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("ClaudeManager")]
[assembly: AssemblyProduct("ClaudeManager")]
[assembly: AssemblyDescription("Task-Manager-style viewer for Claude processes and scripts")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]

namespace ClaudeManager
{
    internal static class Program
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindow(string cls, string title);
        [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr h);

        private static byte[] ReadResource(string name)
        {
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
            {
                if (s == null) throw new InvalidOperationException("Missing embedded resource: " + name);
                using (MemoryStream ms = new MemoryStream())
                {
                    s.CopyTo(ms);
                    return ms.ToArray();
                }
            }
        }

        [STAThread]
        private static int Main(string[] args)
        {
            // One window only: launching again just brings the existing one forward.
            // (Launches with arguments, e.g. -Screenshot for testing, are exempt.)
            Mutex mutex = null;
            bool owned = false;
            if (args.Length == 0)
            {
                bool created;
                mutex = new Mutex(true, @"Local\ClaudeManager.SingleInstance", out created);
                owned = created;
                if (!created)
                {
                    IntPtr h = FindWindow(null, "ClaudeManager");
                    if (h != IntPtr.Zero)
                    {
                        ShowWindow(h, IsIconic(h) ? 9 : 5);
                        SetForegroundWindow(h);
                    }
                    mutex.Dispose();
                    return 0;
                }
            }

            try { return Run(args); }
            catch (Exception ex)
            {
                MessageBox.Show("ClaudeManager could not start:\r\n\r\n" + ex.Message, "ClaudeManager", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            finally
            {
                if (mutex != null)
                {
                    if (owned) mutex.ReleaseMutex();
                    mutex.Dispose();
                }
            }
        }

        private static int Run(string[] args)
        {
            string script = Encoding.UTF8.GetString(ReadResource("ClaudeManager.ps1"));
            if (script.Length > 0 && script[0] == '﻿') script = script.Substring(1);
            byte[] icon = ReadResource("ClaudeManager.ico");

            InitialSessionState iss = InitialSessionState.CreateDefault();
            using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
            {
                rs.ApartmentState = ApartmentState.STA;
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();
                // the script's background runspaces re-load the same source text, and the window uses the icon
                rs.SessionStateProxy.SetVariable("ClaudeManagerSource", script);
                rs.SessionStateProxy.SetVariable("ClaudeManagerIcon", icon);

                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddScript(script);
                    for (int i = 0; i < args.Length; i++)       // -Name value  /  -Switch  ->  script parameters
                    {
                        if (!args[i].StartsWith("-")) continue;
                        string name = args[i].TrimStart('-');
                        if (i + 1 < args.Length && !args[i + 1].StartsWith("-")) { ps.AddParameter(name, args[i + 1]); i++; }
                        else ps.AddParameter(name);
                    }
                    ps.Invoke();
                    if (ps.Streams.Error.Count > 0)
                    {
                        MessageBox.Show("ClaudeManager reported an error:\r\n\r\n" + ps.Streams.Error[0].ToString(), "ClaudeManager", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return 1;
                    }
                }
            }
            return 0;
        }
    }
}
