<#
.SYNOPSIS
  ClaudeManager - Task-Manager-style viewer for every Claude process and script on this PC.

.DESCRIPTION
  Scans the whole Windows process table (not just the current folder or session) and lists:
    * Claude Code agents   - claude.exe / node running claude-code, from the terminal,
                             the VS Code extension, the Claude desktop app, or the SDK
    * Scripts              - everything those agents spawned (python, node, powershell, cmd, git, MCP servers...)
                             at any depth in the process tree
    * Claude Desktop       - the Electron app and its helper processes
    * Orphans              - processes whose parent has exited but whose command line points at Claude
                             (optionally also any python/node/powershell/... whose parent has exited)
  For each one it shows CPU %, memory, disk I/O, threads, uptime and the full command line,
  and lets you End Task / End Process Tree.

  Every agent and script row has an "Open chat" button that jumps to the chat running it:
    * VS Code extension  -> vscode://anthropic.claude-code/open?session=<id>   (the extension's own link)
    * Claude desktop app -> raises the app and clicks that chat in the sidebar (Windows UI Automation);
                            if the sidebar entry can't be found it just raises the app
    * Terminal / CLI     -> raises the terminal window hosting the agent
  Scripts open the chat of the agent that started them. Desktop helper processes and orphans have no chat.

  Light / dark theme: the "Dark mode" checkbox; the choice is remembered in %APPDATA%\ClaudeManager\settings.json
  (first run follows the Windows app theme).

  -List        print the table to the console and exit (no window)
  -Screenshot  save a PNG of the window and exit (for testing)
  -Theme       Light|Dark: force the theme for this run (not saved)
  -TestToggle  with -Screenshot: also flip the theme and save a second PNG (for testing)
#>
[CmdletBinding()]
param(
    [switch]$List,
    [string]$Screenshot,
    [ValidateSet('Light', 'Dark')][string]$Theme,
    [switch]$TestToggle,
    [int]$RefreshSeconds = 3
)

$ErrorActionPreference = 'Stop'
$script:OptShot    = $Screenshot
$script:OptTheme   = $Theme
$script:OptToggle  = [bool]$TestToggle
$script:OptRefresh = $RefreshSeconds

# ---------------------------------------------------------------- shared state
$script:SelfPid       = $PID
$script:Cores         = [Environment]::ProcessorCount
$script:DesktopRx     = '\\WindowsApps\\Claude_|\\AnthropicClaude\\|\\app(-[\d.]+)?\\claude\.exe$'
$script:DesktopArgRx  = '\s--type=(renderer|gpu-process|utility|crashpad-handler|zygote)'
$script:AgentNodeRx   = 'claude-code|@anthropic-ai[\\/]+claude'
$script:OrphanHintRx  = 'claude-code|@anthropic-ai|[\\/]\.claude[\\/]|Claude-Data|anthropic\.claude'
$script:InterpRx      = '^(python[\d.]*|pythonw|py|node|npm|npx|bun|deno|powershell|pwsh|bash|sh|cmd|ruby|java|javaw|uv|uvx)\.exe$'
$script:Prev          = @{}
$script:ChildMap      = @{}
$script:NameByPid     = @{}
$script:SelfAncestors = New-Object 'System.Collections.Generic.HashSet[int]'
$script:EnvCache      = @{}
$script:SessionFiles  = @{}
$script:SessionIndex  = $null
$script:SessionIndexAt = [datetime]::MinValue
$script:SettingsDir   = Join-Path $env:APPDATA 'ClaudeManager'
$script:SettingsPath  = Join-Path $script:SettingsDir 'settings.json'
$script:Dark          = $false
$script:Pal         = $null
$script:Scale         = 1.0
$script:AppIcon       = $null

# Our own source text: the background runspaces re-load it. (ClaudeManager.exe hands it over in a variable;
# running the .ps1 directly, we read the file.)
$script:SourceText = $null
if ($global:ClaudeManagerSource) { $script:SourceText = [string]$global:ClaudeManagerSource }
elseif ($PSCommandPath)          { $script:SourceText = [IO.File]::ReadAllText($PSCommandPath) }

# ---------------------------------------------------------------- native helpers (C#)
# Compiled into ClaudeManager.exe by build\Build.ps1; when running the .ps1 directly it is compiled once on first
# launch and cached in %LOCALAPPDATA%\ClaudeManager\cache. Plain C# 5 only.
$script:UiSource = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace ClaudeManager.UI
{
    public static class Native
    {
        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
        private static extern int SetWindowTheme(IntPtr hWnd, string pszSubAppName, string pszSubIdList);
        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
        [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int cmd);
        [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
        [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
        [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();

        // Dark scrollbars / selection for native controls (Windows 10 1809+; harmless elsewhere).
        public static void ThemeControl(Control c, bool dark)
        {
            if (c == null || !c.IsHandleCreated) return;
            if (dark) SetWindowTheme(c.Handle, "DarkMode_Explorer", null);
            else SetWindowTheme(c.Handle, null, null);
        }

        // Themes a control and its child controls with a named visual-style class (null = back to the default look).
        public static void ThemeAs(Control c, string app, string idList)
        {
            if (c == null || !c.IsHandleCreated) return;
            SetWindowTheme(c.Handle, app, idList);
            foreach (Control ch in c.Controls) ThemeAs(ch, app, idList);
        }

        // Dark title bar (attribute 20 on current Windows 10/11, 19 on early 20H1 builds).
        public static void TitleBar(IntPtr hwnd, bool dark)
        {
            if (hwnd == IntPtr.Zero) return;
            int v = dark ? 1 : 0;
            if (DwmSetWindowAttribute(hwnd, 20, ref v, 4) != 0) DwmSetWindowAttribute(hwnd, 19, ref v, 4);
            SetWindowPos(hwnd, IntPtr.Zero, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0004 | 0x0010 | 0x0020);
        }

        // Restore if minimised and bring a window to the front.
        public static void Focus(IntPtr h)
        {
            if (h == IntPtr.Zero) return;
            ShowWindow(h, IsIconic(h) ? 9 : 5);
            IntPtr fg = GetForegroundWindow();
            uint fgThread = GetWindowThreadProcessId(fg, IntPtr.Zero);
            uint me = GetCurrentThreadId();
            bool attached = fgThread != 0 && fgThread != me && AttachThreadInput(me, fgThread, true);
            BringWindowToTop(h);
            SetForegroundWindow(h);
            if (attached) AttachThreadInput(me, fgThread, false);
        }
    }

    // Reads a few named variables from another process's environment block (same user, 64-bit).
    // Everything else in the block is discarded immediately - only the names asked for are returned.
    public static class ProcInfo
    {
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
        [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, ref PBI info, int size, out int ret);
        [StructLayout(LayoutKind.Sequential)]
        struct PBI { public IntPtr a; public IntPtr Peb; public IntPtr b; public IntPtr c; public IntPtr d; public IntPtr e; }

        static IntPtr ReadPtr(IntPtr h, IntPtr addr)
        {
            byte[] b = new byte[8]; IntPtr n;
            if (!ReadProcessMemory(h, addr, b, (IntPtr)8, out n)) return IntPtr.Zero;
            return (IntPtr)BitConverter.ToInt64(b, 0);
        }

        public static Dictionary<string, string> ReadEnv(int pid, string[] wanted)
        {
            Dictionary<string, string> res = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (!Environment.Is64BitProcess) return res;
            IntPtr h = OpenProcess(0x0400 | 0x0010, false, pid);
            if (h == IntPtr.Zero) return res;
            try
            {
                PBI pbi = new PBI(); int ret;
                if (NtQueryInformationProcess(h, 0, ref pbi, Marshal.SizeOf(pbi), out ret) != 0) return res;
                IntPtr parms = ReadPtr(h, (IntPtr)(pbi.Peb.ToInt64() + 0x20));
                if (parms == IntPtr.Zero) return res;
                IntPtr env = ReadPtr(h, (IntPtr)(parms.ToInt64() + 0x80));
                byte[] sz = new byte[8]; IntPtr n;
                ReadProcessMemory(h, (IntPtr)(parms.ToInt64() + 0x3F0), sz, (IntPtr)8, out n);
                long size = BitConverter.ToInt64(sz, 0);
                if (env == IntPtr.Zero || size <= 0 || size > 4 * 1024 * 1024) return res;
                byte[] buf = new byte[size];
                if (!ReadProcessMemory(h, env, buf, (IntPtr)size, out n)) return res;
                string all = Encoding.Unicode.GetString(buf);
                foreach (string kv in all.Split('\0'))
                {
                    if (kv.Length < 2) continue;
                    int eq = kv.IndexOf('=', 1);
                    if (eq <= 0) continue;
                    string name = kv.Substring(0, eq);
                    foreach (string w in wanted)
                        if (string.Equals(w, name, StringComparison.OrdinalIgnoreCase)) res[name] = kv.Substring(eq + 1);
                }
                return res;
            }
            finally { CloseHandle(h); }
        }
    }

    // Menu / status-strip colours for dark mode.
    public class ThemedColorTable : ProfessionalColorTable
    {
        private readonly bool dark;
        public ThemedColorTable(bool dark) { this.dark = dark; }
        static Color C(int r, int g, int b) { return Color.FromArgb(r, g, b); }
        public override Color ToolStripDropDownBackground { get { return dark ? C(43, 43, 43) : base.ToolStripDropDownBackground; } }
        public override Color ImageMarginGradientBegin { get { return dark ? C(43, 43, 43) : base.ImageMarginGradientBegin; } }
        public override Color ImageMarginGradientMiddle { get { return dark ? C(43, 43, 43) : base.ImageMarginGradientMiddle; } }
        public override Color ImageMarginGradientEnd { get { return dark ? C(43, 43, 43) : base.ImageMarginGradientEnd; } }
        public override Color MenuBorder { get { return dark ? C(84, 84, 84) : base.MenuBorder; } }
        public override Color MenuItemBorder { get { return dark ? C(96, 96, 96) : base.MenuItemBorder; } }
        public override Color MenuItemSelected { get { return dark ? C(72, 72, 72) : base.MenuItemSelected; } }
        public override Color MenuItemSelectedGradientBegin { get { return dark ? C(72, 72, 72) : base.MenuItemSelectedGradientBegin; } }
        public override Color MenuItemSelectedGradientEnd { get { return dark ? C(72, 72, 72) : base.MenuItemSelectedGradientEnd; } }
        public override Color MenuItemPressedGradientBegin { get { return dark ? C(60, 60, 60) : base.MenuItemPressedGradientBegin; } }
        public override Color MenuItemPressedGradientMiddle { get { return dark ? C(60, 60, 60) : base.MenuItemPressedGradientMiddle; } }
        public override Color MenuItemPressedGradientEnd { get { return dark ? C(60, 60, 60) : base.MenuItemPressedGradientEnd; } }
        public override Color SeparatorDark { get { return dark ? C(84, 84, 84) : base.SeparatorDark; } }
        public override Color SeparatorLight { get { return dark ? C(84, 84, 84) : base.SeparatorLight; } }
        public override Color StatusStripGradientBegin { get { return dark ? C(32, 32, 32) : base.StatusStripGradientBegin; } }
        public override Color StatusStripGradientEnd { get { return dark ? C(32, 32, 32) : base.StatusStripGradientEnd; } }
        public override Color ToolStripBorder { get { return dark ? C(32, 32, 32) : base.ToolStripBorder; } }
    }

    public class ThemedRenderer : ToolStripProfessionalRenderer
    {
        public ThemedRenderer(bool dark) : base(new ThemedColorTable(dark)) { RoundedEdges = false; }
    }

    public class ItemEventArgs : EventArgs
    {
        public ListViewItem Item;
        public ItemEventArgs(ListViewItem item) { Item = item; }
    }

    // Owner-drawn details ListView: themeable header, rows and grid, plus one column of clickable buttons.
    public class ThemedListView : ListView
    {
        public bool Dark;
        public Color HeaderBack = Color.FromArgb(250, 250, 250);
        public Color HeaderFore = Color.FromArgb(40, 40, 40);
        public Color HeaderLine = Color.FromArgb(222, 222, 222);
        public Color GridColor = Color.FromArgb(236, 236, 236);
        public Color SelBack = Color.FromArgb(204, 228, 247);
        public Color SelBackInactive = Color.FromArgb(230, 230, 230);
        public Color SelFore = Color.Black;
        public int ButtonColumn = -1;
        public Color ButtonBack = Color.FromArgb(237, 231, 250);
        public Color ButtonHover = Color.FromArgb(222, 210, 246);
        public Color ButtonPressed = Color.FromArgb(205, 190, 240);
        public Color ButtonFore = Color.FromArgb(84, 48, 150);
        public Color ButtonBorder = Color.FromArgb(190, 170, 235);
        public event EventHandler<ItemEventArgs> ButtonClicked;

        private ListViewItem hotItem;
        private ListViewItem downItem;
        private int pad = -1;

        public ThemedListView()
        {
            OwnerDraw = true;
            DoubleBuffered = true;
            View = View.Details;
            FullRowSelect = true;
            HideSelection = false;
        }

        private int Pad()
        {
            if (pad < 0) { using (Graphics g = CreateGraphics()) { pad = (int)Math.Round(6 * g.DpiX / 96f); } }
            return pad;
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            Native.ThemeControl(this, Dark);
        }

        public void ApplyTheme()
        {
            Native.ThemeControl(this, Dark);
            Invalidate(true);
        }

        protected override void OnDrawColumnHeader(DrawListViewColumnHeaderEventArgs e)
        {
            using (SolidBrush b = new SolidBrush(HeaderBack)) e.Graphics.FillRectangle(b, e.Bounds);
            using (Pen p = new Pen(HeaderLine))
            {
                e.Graphics.DrawLine(p, e.Bounds.Left, e.Bounds.Bottom - 1, e.Bounds.Right, e.Bounds.Bottom - 1);
                e.Graphics.DrawLine(p, e.Bounds.Right - 1, e.Bounds.Top + 4, e.Bounds.Right - 1, e.Bounds.Bottom - 5);
            }
            TextFormatFlags f = TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.NoPadding;
            f |= (e.Header.TextAlign == HorizontalAlignment.Right) ? TextFormatFlags.Right : TextFormatFlags.Left;
            int pd = Pad();
            Rectangle r = new Rectangle(e.Bounds.X + pd, e.Bounds.Y, Math.Max(1, e.Bounds.Width - 2 * pd), e.Bounds.Height);
            TextRenderer.DrawText(e.Graphics, e.Header.Text, Font, r, HeaderFore, f);
        }

        protected override void OnDrawItem(DrawListViewItemEventArgs e) { /* each cell is painted in OnDrawSubItem */ }

        protected override void OnDrawSubItem(DrawListViewSubItemEventArgs e)
        {
            bool sel = e.Item.Selected;
            Color back = sel ? (Focused ? SelBack : SelBackInactive) : e.Item.BackColor;
            Color fore = sel ? SelFore : e.Item.ForeColor;
            using (SolidBrush b = new SolidBrush(back)) e.Graphics.FillRectangle(b, e.Bounds);
            using (Pen p = new Pen(GridColor))
            {
                e.Graphics.DrawLine(p, e.Bounds.Left, e.Bounds.Bottom - 1, e.Bounds.Right, e.Bounds.Bottom - 1);
                e.Graphics.DrawLine(p, e.Bounds.Right - 1, e.Bounds.Top, e.Bounds.Right - 1, e.Bounds.Bottom);
            }
            string text = e.SubItem.Text;
            if (e.ColumnIndex == ButtonColumn)
            {
                if (text.Length > 0) DrawButton(e, text);
                return;
            }
            TextFormatFlags f = TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine | TextFormatFlags.NoPadding;
            if (Columns[e.ColumnIndex].TextAlign == HorizontalAlignment.Right) f |= TextFormatFlags.Right;
            int pd = Pad();
            Rectangle r = new Rectangle(e.Bounds.X + pd, e.Bounds.Y, Math.Max(1, e.Bounds.Width - 2 * pd), e.Bounds.Height);
            TextRenderer.DrawText(e.Graphics, text, Font, r, fore, f);
        }

        private void DrawButton(DrawListViewSubItemEventArgs e, string text)
        {
            int pd = Pad();
            Rectangle br = new Rectangle(e.Bounds.X + pd, e.Bounds.Y + 2, Math.Max(8, e.Bounds.Width - 2 * pd - 1), Math.Max(8, e.Bounds.Height - 5));
            Color bb = ButtonBack;
            if (e.Item == hotItem) bb = (e.Item == downItem) ? ButtonPressed : ButtonHover;
            SmoothingMode old = e.Graphics.SmoothingMode;
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath gp = RoundRect(br, 4))
            using (SolidBrush fill = new SolidBrush(bb))
            using (Pen border = new Pen(ButtonBorder))
            {
                e.Graphics.FillPath(fill, gp);
                e.Graphics.DrawPath(border, gp);
            }
            e.Graphics.SmoothingMode = old;
            TextRenderer.DrawText(e.Graphics, text, Font, br, ButtonFore,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding);
        }

        private static GraphicsPath RoundRect(Rectangle r, int rad)
        {
            int d = rad * 2;
            GraphicsPath p = new GraphicsPath();
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d - 1, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d - 1, r.Bottom - d - 1, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d - 1, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        // ---- button hit-testing
        private ListViewItem ButtonItemAt(Point pt)
        {
            if (ButtonColumn < 0) return null;
            ListViewHitTestInfo hi = HitTest(pt);
            if (hi.Item == null || hi.SubItem == null) return null;
            if (hi.Item.SubItems.IndexOf(hi.SubItem) != ButtonColumn) return null;
            return hi.SubItem.Text.Length > 0 ? hi.Item : null;
        }

        private void Redraw(ListViewItem it)
        {
            if (it != null && it.ListView == this) RedrawItems(it.Index, it.Index, false);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            ListViewItem over = ButtonItemAt(e.Location);
            if (over != hotItem)
            {
                ListViewItem old = hotItem;
                hotItem = over;
                Redraw(old); Redraw(over);
                Cursor = over != null ? Cursors.Hand : Cursors.Default;
            }
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            base.OnMouseLeave(e);
            ListViewItem old = hotItem;
            hotItem = null; downItem = null;
            Redraw(old);
            Cursor = Cursors.Default;
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            downItem = (e.Button == MouseButtons.Left) ? ButtonItemAt(e.Location) : null;
            Redraw(downItem);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            ListViewItem it = downItem;
            downItem = null;
            Redraw(it);
            if (e.Button == MouseButtons.Left && it != null && it == ButtonItemAt(e.Location) && ButtonClicked != null)
                ButtonClicked(this, new ItemEventArgs(it));
        }
    }
}
'@

function Initialize-UiTypes {
    if ($script:UiReady) { return }
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    if ('ClaudeManager.UI.ThemedListView' -as [type]) { $script:UiReady = $true; return }
    $sha  = [System.Security.Cryptography.SHA1]::Create()
    $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:UiSource))) -replace '-', '').Substring(0, 12).ToLower()
    $dir  = Join-Path $env:LOCALAPPDATA 'ClaudeManager\cache'
    $dll  = Join-Path $dir "ui-$hash.dll"
    if (-not (Test-Path -LiteralPath $dll)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Add-Type -TypeDefinition $script:UiSource -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -OutputAssembly $dll -OutputType Library
        foreach ($old in Get-ChildItem -LiteralPath $dir -Filter 'ui-*.dll' -ErrorAction SilentlyContinue) {
            if ($old.FullName -ne $dll) { try { Remove-Item -LiteralPath $old.FullName -Force } catch { } }
        }
    }
    if (-not ('ClaudeManager.UI.ThemedListView' -as [type])) { Add-Type -Path $dll }
    $script:UiReady = $true
}

# ---------------------------------------------------------------- theme + settings
function Get-Theme {
    param([bool]$Dark)
    Add-Type -AssemblyName System.Drawing
    function C([int]$r, [int]$g, [int]$b) { [System.Drawing.Color]::FromArgb($r, $g, $b) }
    if ($Dark) {
        return [pscustomobject]@{
            Dark = $true
            Back = (C 32 32 32);          Fore = (C 232 232 232)
            ListBack = (C 24 24 24);      ListFore = (C 232 232 232)
            HeaderBack = (C 45 45 45);    HeaderFore = (C 222 222 222);  HeaderLine = (C 72 72 72)
            Grid = (C 44 44 44)
            SelBack = (C 58 76 120);      SelBackInactive = (C 56 56 56); SelFore = (C 255 255 255)
            InputBack = (C 48 48 48);     InputFore = (C 232 232 232)
            ButtonBack = (C 58 58 58);    ButtonFore = (C 232 232 232);  ButtonBorder = (C 96 96 96)
            LBack = (C 60 48 92);         LFore = (C 214 196 255);       LBorder = (C 110 84 170)
            LHover = (C 78 62 120);       LPressed = (C 96 76 146)
            RowDesktop = (C 140 140 140); RowOrphan = (C 255 115 115);   RowLong = (C 255 176 80)
            RowBusyBack = (C 70 64 28)
        }
    }
    return [pscustomobject]@{
        Dark = $false
        Back = (C 240 240 240);           Fore = (C 30 30 30)
        ListBack = (C 255 255 255);       ListFore = (C 20 20 20)
        HeaderBack = (C 250 250 250);     HeaderFore = (C 40 40 40);     HeaderLine = (C 222 222 222)
        Grid = (C 236 236 236)
        SelBack = (C 204 228 247);        SelBackInactive = (C 230 230 230); SelFore = (C 0 0 0)
        InputBack = (C 255 255 255);      InputFore = (C 20 20 20)
        ButtonBack = (C 253 253 253);     ButtonFore = (C 30 30 30);     ButtonBorder = (C 173 173 173)
        LBack = (C 237 231 250);          LFore = (C 84 48 150);         LBorder = (C 190 170 235)
        LHover = (C 222 210 246);         LPressed = (C 205 190 240)
        RowDesktop = (C 100 100 100);     RowOrphan = (C 176 32 32);     RowLong = (C 180 90 0)
        RowBusyBack = (C 255 244 200)
    }
}

# First run follows the Windows "app mode"; after that the saved choice wins.
function Get-InitialDarkMode {
    try {
        if (Test-Path -LiteralPath $script:SettingsPath) {
            $j = [IO.File]::ReadAllText($script:SettingsPath) | ConvertFrom-Json
            if ($null -ne $j -and $j.PSObject.Properties['darkMode']) { return [bool]$j.darkMode }
        }
    } catch { }
    try {
        $v = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme
        return ($v -eq 0)
    } catch { return $false }
}

function Save-DarkMode {
    param([bool]$Dark)
    try {
        $o = [ordered]@{}
        if (Test-Path -LiteralPath $script:SettingsPath) {
            try {
                $old = [IO.File]::ReadAllText($script:SettingsPath) | ConvertFrom-Json
                foreach ($p in $old.PSObject.Properties) { $o[$p.Name] = $p.Value }
            } catch { }
        }
        $o['darkMode'] = $Dark
        New-Item -ItemType Directory -Force -Path $script:SettingsDir | Out-Null
        [IO.File]::WriteAllText($script:SettingsPath, ($o | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# ---------------------------------------------------------------- scanning
function Format-Span {
    param([TimeSpan]$T)
    if ($T.TotalDays  -ge 1) { return ('{0}d {1}h'    -f [int][math]::Floor($T.TotalDays),  $T.Hours) }
    if ($T.TotalHours -ge 1) { return ('{0}h {1:00}m' -f [int][math]::Floor($T.TotalHours), $T.Minutes) }
    return ('{0}m {1:00}s' -f [int][math]::Floor($T.TotalMinutes), $T.Seconds)
}

# Desktop chat titles, from the app's own session store (local_<id>.json). Only four fields are read from each file.
function Get-DesktopSessionIndex {
    if ($script:SessionIndex -and ((Get-Date) - $script:SessionIndexAt).TotalSeconds -lt 8) { return $script:SessionIndex }
    $roots = New-Object System.Collections.Generic.List[string]
    $roots.Add((Join-Path $env:APPDATA 'Claude\claude-code-sessions'))
    foreach ($d in @(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Claude-Data\*\claude-code-sessions') -Directory -ErrorAction SilentlyContinue)) { $roots.Add($d.FullName) }
    foreach ($d in @(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Packages\Claude_*\LocalCache\Roaming\Claude\claude-code-sessions') -Directory -ErrorAction SilentlyContinue)) { $roots.Add($d.FullName) }
    $idx = @{}
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $r -Recurse -File -Filter 'local_*.json' -ErrorAction SilentlyContinue)) {
            $c = $script:SessionFiles[$f.FullName]
            if (-not $c -or $c.Stamp -ne $f.LastWriteTimeUtc.Ticks) {
                try {
                    $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
                    try { $text = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
                    $title = [regex]::Match($text, '"title"\s*:\s*"((?:[^"\\]|\\.)*)"').Groups[1].Value
                    $c = @{
                        Stamp    = $f.LastWriteTimeUtc.Ticks
                        Id       = [regex]::Match($text, '"sessionId"\s*:\s*"(local_[^"]+)"').Groups[1].Value
                        Cli      = [regex]::Match($text, '"cliSessionId"\s*:\s*"([^"]+)"').Groups[1].Value
                        Title    = [regex]::Unescape($title)
                        Archived = ([regex]::Match($text, '"isArchived"\s*:\s*(true|false)').Groups[1].Value -eq 'true')
                    }
                    $script:SessionFiles[$f.FullName] = $c
                } catch { continue }
            }
            if ($c.Id) { $idx[$c.Id] = $c }
        }
    }
    $script:SessionIndex = $idx
    $script:SessionIndexAt = Get-Date
    return $idx
}

# Which chat is this agent running? Kind: vscode | desktop | terminal.
function Resolve-AgentChat {
    param($Proc, $ParentProc)
    $id  = [int]$Proc.ProcessId
    $key = '{0}|{1}' -f $id, $(if ($Proc.CreationDate) { $Proc.CreationDate.Ticks } else { 0 })
    $e = $script:EnvCache[$key]
    if (-not $e) {
        $e = @{ Entry = ''; Host = '' }
        try {
            $env = [ClaudeManager.UI.ProcInfo]::ReadEnv($id, [string[]]@('CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_HOST_SESSION_ID'))
            if ($env.ContainsKey('CLAUDE_CODE_ENTRYPOINT'))       { $e.Entry = [string]$env['CLAUDE_CODE_ENTRYPOINT'] }
            if ($env.ContainsKey('CLAUDE_CODE_HOST_SESSION_ID'))  { $e.Host  = [string]$env['CLAUDE_CODE_HOST_SESSION_ID'] }
        } catch { }
        $script:EnvCache[$key] = $e
    }
    $cmd  = [string]$Proc.CommandLine
    $path = [string]$Proc.ExecutablePath
    $resume = [regex]::Match($cmd, '--(?:resume|session-id)(?:\s+|=)"?([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})').Groups[1].Value
    $parentIsDesktop = $ParentProc -and ([string]$ParentProc.Name) -ieq 'claude.exe' -and
        (([string]$ParentProc.ExecutablePath) -match $script:DesktopRx -or ([string]$ParentProc.CommandLine) -match $script:DesktopArgRx)

    if ($e.Entry -match 'vscode' -or $path -match 'extensions[\\/]anthropic\.claude-code') {
        $short = if ($resume) { $resume.Substring(0, 8) } else { '' }
        return [pscustomobject]@{ Kind = 'vscode'; Id = $resume; Label = 'VS Code extension'; Title = $(if ($short) { "VS Code chat $short" } else { 'VS Code chat' }) }
    }
    if ($e.Entry -match 'desktop' -or $e.Host -or $parentIsDesktop) {
        $title = ''
        if ($e.Host) {
            $rec = (Get-DesktopSessionIndex)[$e.Host]
            if ($rec) { $title = $rec.Title }
        }
        if (-not $title) { $title = 'Claude Desktop chat' }
        return [pscustomobject]@{ Kind = 'desktop'; Id = $e.Host; Label = 'Claude Desktop app'; Title = $title }
    }
    $label = 'Terminal / CLI'
    if ($e.Entry -match '^sdk' -or $cmd -match '--output-format\s+stream-json') { $label = 'SDK / headless' }
    return [pscustomobject]@{ Kind = 'terminal'; Id = ''; Label = $label; Title = 'Terminal session' }
}

# One system-wide scan. Returns rows for every Claude-related process.
function Get-Scan {
    param([bool]$InterpOrphans = $false)

    Initialize-UiTypes
    $now = Get-Date
    $all = @(Get-CimInstance -ClassName Win32_Process)
    $byPid = @{}
    foreach ($p in $all) { $byPid[[int]$p.ProcessId] = $p }

    # Parent links. A "parent" that is newer than its child is a recycled PID, i.e. the real parent is gone.
    $parentOf = @{}
    $childMap = @{}
    foreach ($p in $all) {
        $id   = [int]$p.ProcessId
        $ppid = [int]$p.ParentProcessId
        $par  = $null
        if ($ppid -ne 0 -and $ppid -ne $id -and $byPid.ContainsKey($ppid)) {
            $cand = $byPid[$ppid]
            if (-not ($cand.CreationDate -and $p.CreationDate -and $cand.CreationDate -gt $p.CreationDate)) { $par = $cand }
        }
        $parentOf[$id] = $par
        if ($par) {
            $pk = [int]$par.ProcessId
            if (-not $childMap.ContainsKey($pk)) { $childMap[$pk] = New-Object 'System.Collections.Generic.List[int]' }
            $childMap[$pk].Add($id)
        }
    }

    # Flag roots
    $isDesktop = @{}; $isAgent = @{}; $orphanRoot = @{}
    foreach ($p in $all) {
        $id   = [int]$p.ProcessId
        $name = [string]$p.Name
        $cmd  = [string]$p.CommandLine
        $path = [string]$p.ExecutablePath
        $desk = $false; $agent = $false
        if ($name -ieq 'claude.exe') {
            if ($path -match $script:DesktopRx -or $cmd -match $script:DesktopArgRx) { $desk = $true } else { $agent = $true }
        } elseif ($name -match '^node(\.exe)?$' -and $cmd -match $script:AgentNodeRx) {
            $agent = $true
        }
        $isDesktop[$id] = $desk
        $isAgent[$id]   = $agent
        if (-not $desk -and -not $agent -and $null -eq $parentOf[$id] -and $cmd) {
            if ($cmd -match $script:OrphanHintRx)                          { $orphanRoot[$id] = 'Claude path in command line' }
            elseif ($InterpOrphans -and $name -match $script:InterpRx)     { $orphanRoot[$id] = 'origin unknown' }
        }
    }

    # This tool and its ancestors (so we can warn before the user kills the thing that launched us)
    $selfAnc = New-Object 'System.Collections.Generic.HashSet[int]'
    $cur = $byPid[$script:SelfPid]; $g = 0
    while ($cur -and $g -lt 64) {
        $cid = [int]$cur.ProcessId
        if ($cid -ne $script:SelfPid) { [void]$selfAnc.Add($cid) }
        $cur = $parentOf[$cid]; $g++
    }

    # Classify
    $rows    = New-Object 'System.Collections.Generic.List[object]'
    $newPrev = @{}
    $rowPids = @{}
    $liveKeys = @{}
    foreach ($p in $all) {
        $id = [int]$p.ProcessId
        $chain = New-Object 'System.Collections.Generic.List[object]'
        $agentIdx = -1; $deskIdx = -1; $orphIdx = -1; $isSelfTree = $false
        $cur = $p; $i = 0
        while ($cur -and $i -lt 64) {
            $cid = [int]$cur.ProcessId
            if ($cid -eq $script:SelfPid) { $isSelfTree = $true; break }
            $chain.Add($cur)
            if ($agentIdx -lt 0 -and $isAgent[$cid])        { $agentIdx = $i }
            if ($deskIdx  -lt 0 -and $isDesktop[$cid])      { $deskIdx  = $i }
            if ($orphIdx  -lt 0 -and $orphanRoot.ContainsKey($cid)) { $orphIdx = $i }
            $cur = $parentOf[$cid]; $i++
        }
        if ($isSelfTree) { continue }

        $kind = $null; $origin = ''; $chat = $null; $anc = @(); $rootPid = 0
        if ($agentIdx -ge 0) {
            $rootProc = $chain[$agentIdx]
            $rootPid  = [int]$rootProc.ProcessId
            $chat     = Resolve-AgentChat $rootProc $parentOf[$rootPid]
            $anc      = @(for ($k = $agentIdx + 1; $k -lt $chain.Count; $k++) { [int]$chain[$k].ProcessId })
            if ($agentIdx -eq 0) { $kind = 'Claude Code'; $origin = $chat.Label }
            else                 { $kind = 'Script'; $origin = 'PID {0} - {1}' -f $rootPid, $chat.Label }
        } elseif ($deskIdx -ge 0) {
            $kind = 'Claude Desktop'
            if ($deskIdx -eq 0) {
                if ([string]$p.CommandLine -match '--type=([\w-]+)') { $origin = 'app ' + $Matches[1] } else { $origin = 'app main process' }
            } else { $origin = 'app child process' }
        } elseif ($orphIdx -ge 0) {
            $kind = 'Orphan'
            $origin = 'parent exited - ' + $orphanRoot[[int]$chain[$orphIdx].ProcessId]
        }
        if (-not $kind) { continue }
        if (([string]$p.Name) -ieq 'conhost.exe') { continue }   # console-window helpers: noise, and they die with their tree

        $created = $p.CreationDate
        $uptime  = if ($created) { $now - $created } else { [TimeSpan]::Zero }
        $ticks   = [double]$p.KernelModeTime + [double]$p.UserModeTime
        $io      = [double]$p.ReadTransferCount + [double]$p.WriteTransferCount
        $key     = '{0}|{1}' -f $id, $(if ($created) { $created.Ticks } else { 0 })

        $cpu = 0.0; $disk = 0.0
        $pv = $script:Prev[$key]
        if ($pv) {
            $dt = ($now - $pv.T).TotalSeconds
            if ($dt -ge 0.25) {
                $cpu  = [math]::Max(0.0, $ticks - $pv.Ticks) / ($dt * 1e7 * $script:Cores) * 100
                $disk = [math]::Max(0.0, $io - $pv.Io) / $dt / 1MB
                $newPrev[$key] = @{ T = $now; Ticks = $ticks; Io = $io; Cpu = $cpu; Disk = $disk }
            } else {
                $cpu = $pv.Cpu; $disk = $pv.Disk
                $newPrev[$key] = $pv
            }
        } else {
            $newPrev[$key] = @{ T = $now; Ticks = $ticks; Io = $io; Cpu = 0.0; Disk = 0.0 }
        }

        $priv = [double]$p.PrivatePageCount
        if ($priv -le 0) { $priv = [double]$p.PageFileUsage * 1KB }

        $rowPids[$id] = $true
        $rows.Add([pscustomobject]@{
            Pid        = $id
            Name       = [string]$p.Name
            Kind       = $kind
            Origin     = $origin
            ParentPid  = [int]$p.ParentProcessId
            Created    = $created
            Uptime     = $uptime
            UptimeText = (Format-Span $uptime)
            Cpu        = $cpu
            Disk       = $disk
            WorkingMB  = [double]$p.WorkingSetSize / 1MB
            PrivateMB  = $priv / 1MB
            Threads    = [int]$p.ThreadCount
            Handles    = [int]$p.HandleCount
            Cmd        = [string]$p.CommandLine
            Path       = [string]$p.ExecutablePath
            Key        = $key
            CanOpen    = [bool]($null -ne $chat)
            ChatKind   = $(if ($chat) { $chat.Kind } else { '' })
            ChatId     = $(if ($chat) { $chat.Id } else { '' })
            ChatTitle  = $(if ($chat) { $chat.Title } else { '' })
            RootPid    = $rootPid
            Anc        = $anc
            Up         = @()
            Depth      = 0
        })
    }

    # forget cached env reads of processes that are gone
    foreach ($r in $rows) { $liveKeys[$r.Key] = $true }
    foreach ($k in @($script:EnvCache.Keys)) { if (-not $byPid.ContainsKey([int]($k -split '\|')[0])) { $script:EnvCache.Remove($k) } }

    # nearest-first list of listed ancestors, used to build the tree view
    foreach ($r in $rows) {
        $up = New-Object 'System.Collections.Generic.List[int]'
        $cur = $parentOf[$r.Pid]; $g = 0
        while ($cur -and $g -lt 64) {
            $cid = [int]$cur.ProcessId
            if ($rowPids.ContainsKey($cid)) { $up.Add($cid) }
            $cur = $parentOf[$cid]; $g++
        }
        $r.Up = $up.ToArray()
    }

    $script:Prev          = $newPrev
    $script:ChildMap      = $childMap
    $script:SelfAncestors = $selfAnc
    $nameByPid = @{}
    foreach ($p in $all) { $nameByPid[[int]$p.ProcessId] = [string]$p.Name }
    $script:NameByPid = $nameByPid

    return [pscustomobject]@{ Rows = $rows.ToArray(); Total = $all.Count; At = $now }
}

# Depth-first order: agents first (with their scripts nested underneath), then orphans, then the desktop app.
function Get-TreeOrder {
    param($Rows)
    $rows = @($Rows)
    $set = @{}
    foreach ($r in $rows) { $set[$r.Pid] = $r }
    $kids = @{}
    $roots = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $rows) {
        $par = $null
        # agents are always top-level rows, even when the desktop app spawned them
        if ($r.Kind -ne 'Claude Code') {
            foreach ($u in $r.Up) { if ($set.ContainsKey($u)) { $par = $u; break } }
        }
        if ($null -ne $par) {
            if (-not $kids.ContainsKey($par)) { $kids[$par] = New-Object 'System.Collections.Generic.List[object]' }
            $kids[$par].Add($r)
        } else { $roots.Add($r) }
    }
    $rank = @{ 'Claude Code' = 0; 'Orphan' = 1; 'Claude Desktop' = 2; 'Script' = 3 }
    $ordered = New-Object 'System.Collections.Generic.List[object]'
    function Add-Node($Node, [int]$Depth) {
        $Node.Depth = $Depth
        $ordered.Add($Node)
        if ($kids.ContainsKey($Node.Pid)) {
            foreach ($k in @($kids[$Node.Pid] | Sort-Object Created)) { Add-Node $k ($Depth + 1) }
        }
    }
    foreach ($r in @($roots | Sort-Object @{ Expression = { $rank[$_.Kind] } }, Created)) { Add-Node $r 0 }
    return $ordered.ToArray()
}

function Get-DescendantPids {
    param([int]$RootPid)
    $res = New-Object 'System.Collections.Generic.List[int]'
    $stack = New-Object 'System.Collections.Generic.Stack[int]'
    $stack.Push($RootPid)
    while ($stack.Count -gt 0) {
        $c = $stack.Pop()
        if ($script:ChildMap.ContainsKey($c)) {
            foreach ($k in $script:ChildMap[$c]) { $res.Add($k); $stack.Push($k) }
        }
    }
    return $res.ToArray()
}

# Ends one process (or its whole tree). Checks the start time first so a recycled PID is never killed by mistake.
function Stop-ProcessRow {
    param($Row, [bool]$Tree)
    try { $proc = [System.Diagnostics.Process]::GetProcessById([int]$Row.Pid) }
    catch { return [pscustomobject]@{ Ok = $true; Msg = 'already exited' } }
    try {
        $st = $proc.StartTime
        if ($Row.Created -and [math]::Abs(($st - $Row.Created).TotalSeconds) -gt 2) {
            return [pscustomobject]@{ Ok = $false; Msg = 'PID now belongs to a different process - skipped' }
        }
    } catch { }
    try {
        if ($Tree) {
            $tk = Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', [string]$Row.Pid, '/T', '/F') -WindowStyle Hidden -Wait -PassThru
            if ($tk.ExitCode -ne 0) { return [pscustomobject]@{ Ok = $false; Msg = "taskkill exit code $($tk.ExitCode) (access denied?)" } }
        } else {
            $proc.Kill()
            [void]$proc.WaitForExit(3000)
        }
        return [pscustomobject]@{ Ok = $true; Msg = 'ended' }
    } catch {
        return [pscustomobject]@{ Ok = $false; Msg = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------- open the chat behind a process
# These run in a background (MTA) runspace: UI Automation must not be driven from the window's own UI thread.
function Get-DesktopWindowHandle {
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'")) {
        if ([string]$p.CommandLine -match '--type=') { continue }
        if ([string]$p.ExecutablePath -notmatch $script:DesktopRx) { continue }
        $gp = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if ($gp -and $gp.MainWindowHandle -ne [IntPtr]::Zero) { return $gp.MainWindowHandle }
    }
    return [IntPtr]::Zero
}

# Clicks the chat's row in the desktop app's sidebar. The row is a Button named exactly like the chat title; the
# folder-group header with the same name has an ExpandCollapse pattern and the page-header buttons have longer names,
# so "exact name + Invoke, no ExpandCollapse, in the left part of the window" picks the sidebar row.
function Invoke-SidebarSession {
    param([IntPtr]$Hwnd, [string]$Title)
    if (-not $Title) { return $false }
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $AE   = [System.Windows.Automation.AutomationElement]
    $root = $AE::FromHandle($Hwnd)
    $win  = $root.Current.BoundingRectangle
    $cond = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $Title)),
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)))
    for ($try = 0; $try -lt 4; $try++) {   # the app builds its accessibility tree lazily on first contact
        foreach ($el in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
            $o = $null
            if ($el.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$o)) { continue }
            if (-not $el.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$o)) { continue }
            $r = $el.Current.BoundingRectangle
            if (($r.X - $win.X) -gt ($win.Width * 0.45) -or $r.Width -lt 120) { continue }
            $o.Invoke()
            return $true
        }
        Start-Sleep -Milliseconds 600
    }
    return $false
}

# The terminal an agent runs in is the nearest ancestor that owns a window (Windows Terminal, VS Code, ...). A classic
# console window is owned by a conhost.exe *child* of the shell instead, so those are checked per ancestor too.
function Show-TerminalFor {
    param([int[]]$Anc)
    foreach ($id in $Anc) {
        $gp = Get-Process -Id $id -ErrorAction SilentlyContinue
        if (-not $gp -or $gp.ProcessName -match '^(explorer|ClaudeManager)$') { continue }
        $h = $gp.MainWindowHandle; $owner = $gp.ProcessName
        if ($h -eq [IntPtr]::Zero) {
            foreach ($c in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$id AND Name='conhost.exe'" -ErrorAction SilentlyContinue)) {
                $cp = Get-Process -Id $c.ProcessId -ErrorAction SilentlyContinue
                if ($cp -and $cp.MainWindowHandle -ne [IntPtr]::Zero) { $h = $cp.MainWindowHandle; $owner = 'console'; break }
            }
        }
        if ($h -ne [IntPtr]::Zero) {
            [ClaudeManager.UI.Native]::Focus($h)
            return "Brought the $owner window forward - the agent runs in it."
        }
    }
    return "Couldn't find a window for this agent (it may be running without a visible terminal)."
}

function Open-ChatTarget {
    param($Target)
    Initialize-UiTypes
    switch ([string]$Target.Kind) {
        'vscode' {
            $uri = 'vscode://anthropic.claude-code/open'
            if ($Target.ChatId) { $uri += '?session=' + [uri]::EscapeDataString([string]$Target.ChatId) }
            Start-Process $uri
            return "Asked VS Code to open: $($Target.Title)"
        }
        'desktop' {
            $h = Get-DesktopWindowHandle
            if ($h -eq [IntPtr]::Zero) { return 'The Claude desktop app has no open window right now (is it minimised to the tray?).' }
            [ClaudeManager.UI.Native]::Focus($h)
            if (Invoke-SidebarSession $h ([string]$Target.Title)) { return "Opened '$($Target.Title)' in Claude Desktop." }
            return "Brought Claude Desktop forward, but couldn't find '$($Target.Title)' in its sidebar - click it there (its folder may be collapsed)."
        }
        'terminal' { return (Show-TerminalFor ([int[]]@($Target.Anc))) }
        default    { return 'No chat to open for this process.' }
    }
}

# Fresh runspace with this script's functions loaded (entry point skipped), for background scans/actions.
function New-LibraryShell {
    if (-not $script:SourceText) { throw 'ClaudeManager cannot find its own source text.' }
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('ClaudeManagerLibraryOnly', $true)
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:SourceText).Invoke()
    $ps.Commands.Clear()
    return $ps
}

# ---------------------------------------------------------------- themed dialogs
function New-ThemedDialog {
    param([string]$Title, [string]$Message, $Buttons, [string]$Icon = 'None', [int]$DefaultIndex = 0)
    $t = $script:Pal; $s = $script:Scale
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title; $f.FormBorderStyle = 'FixedDialog'; $f.StartPosition = 'CenterParent'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false; $f.ShowIcon = $false
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $f.BackColor = $t.Back; $f.ForeColor = $t.Fore
    $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'
    $pad = [int][math]::Round(14 * $s)
    $f.Padding = New-Object System.Windows.Forms.Padding($pad)

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.AutoSize = $true; $root.ColumnCount = 1; $root.RowCount = 2; $root.BackColor = $t.Back

    $top = New-Object System.Windows.Forms.FlowLayoutPanel
    $top.AutoSize = $true; $top.WrapContents = $false; $top.FlowDirection = 'LeftToRight'
    $top.Margin = New-Object System.Windows.Forms.Padding(0); $top.BackColor = $t.Back
    if ($Icon -ne 'None') {
        $pb = New-Object System.Windows.Forms.PictureBox
        $pb.SizeMode = 'AutoSize'
        $pb.Image = $(if ($Icon -eq 'Warning') { [System.Drawing.SystemIcons]::Warning.ToBitmap() } else { [System.Drawing.SystemIcons]::Question.ToBitmap() })
        $pb.Margin = New-Object System.Windows.Forms.Padding(0, 0, $pad, 0)
        $top.Controls.Add($pb)
    }
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.AutoSize = $true; $lbl.Text = $Message; $lbl.ForeColor = $t.Fore; $lbl.BackColor = $t.Back
    $lbl.MaximumSize = New-Object System.Drawing.Size([int][math]::Round(560 * $s), 0)
    $lbl.MinimumSize = New-Object System.Drawing.Size([int][math]::Round(300 * $s), 0)
    $lbl.Margin = New-Object System.Windows.Forms.Padding(0)
    $top.Controls.Add($lbl)

    $row = New-Object System.Windows.Forms.FlowLayoutPanel
    $row.AutoSize = $true; $row.WrapContents = $false; $row.FlowDirection = 'RightToLeft'; $row.Anchor = 'Right'
    $row.Margin = New-Object System.Windows.Forms.Padding(0, $pad, 0, 0); $row.BackColor = $t.Back
    for ($i = $Buttons.Count - 1; $i -ge 0; $i--) {        # right-to-left: last button is added first
        $b = New-Object System.Windows.Forms.Button
        $b.Text = [string]$Buttons[$i][0]; $b.AutoSize = $true
        $b.Padding = New-Object System.Windows.Forms.Padding(10, 2, 10, 2)
        $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderColor = $t.ButtonBorder
        $b.BackColor = $t.ButtonBack; $b.ForeColor = $t.ButtonFore
        $b.Tag = [System.Windows.Forms.DialogResult]([string]$Buttons[$i][1])
        $b.Add_Click({ param($sender, $e) $sender.FindForm().DialogResult = $sender.Tag })
        if ($i -eq $DefaultIndex) { $f.AcceptButton = $b; $b.FlatAppearance.BorderColor = $t.LBorder; $b.FlatAppearance.BorderSize = 2 }
        if ([string]$Buttons[$i][1] -match '^(No|Cancel|OK)$' -and -not $f.CancelButton) { $f.CancelButton = $b }
        $row.Controls.Add($b)
    }
    $f.Add_HandleCreated({ param($sender, $e) [ClaudeManager.UI.Native]::TitleBar($sender.Handle, $script:Dark) })
    $root.Controls.Add($top, 0, 0)
    $root.Controls.Add($row, 0, 1)
    $f.Controls.Add($root)
    return $f
}

function Show-ThemedDialog {
    param($Owner, [string]$Title, [string]$Message, $Buttons, [string]$Icon = 'None', [int]$DefaultIndex = 0)
    $f = New-ThemedDialog -Title $Title -Message $Message -Buttons $Buttons -Icon $Icon -DefaultIndex $DefaultIndex
    try { return $f.ShowDialog($Owner) } finally { $f.Dispose() }
}

# ---------------------------------------------------------------- console mode
function Show-List {
    [void](Get-Scan -InterpOrphans $false)
    Start-Sleep -Milliseconds 1000
    $scan = Get-Scan -InterpOrphans $false
    $rows = @(Get-TreeOrder $scan.Rows)
    $rows | ForEach-Object {
        $ind = if ($_.Depth -gt 0) { ('    ' * ($_.Depth - 1)) + '+- ' } else { '' }
        [pscustomobject]@{
            Kind    = $_.Kind
            PID     = $_.Pid
            Name    = $ind + $_.Name
            'CPU%'  = '{0:N1}' -f $_.Cpu
            'MemMB' = '{0:N0}' -f $_.WorkingMB
            Uptime  = $_.UptimeText
            Origin  = $_.Origin
            Chat    = $(if ($_.CanOpen) { '{0}: {1}' -f $_.ChatKind, $_.ChatTitle } else { '' })
            Command = if ($_.Cmd.Length -gt 70) { $_.Cmd.Substring(0, 70) + '...' } else { $_.Cmd }
        }
    } | Format-Table -AutoSize | Out-String -Width 300 | Write-Host
    Write-Host ("{0} Claude-related processes of {1} on this PC. Memory total {2:N0} MB." -f $rows.Count, $scan.Total, (($rows | Measure-Object WorkingMB -Sum).Sum))
}

# ---------------------------------------------------------------- GUI
function Start-Gui {
    Initialize-UiTypes
    if (-not ('Native.Dpi' -as [type])) {
        Add-Type -Namespace Native -Name Dpi -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    }
    [void][Native.Dpi]::SetProcessDPIAware()
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    # An unexpected UI error must never pop a modal crash dialog (a paint error would loop): log it, show it in the status bar.
    [System.Windows.Forms.Application]::add_ThreadException({
        param($sender, $e)
        try {
            $dir = Join-Path $env:LOCALAPPDATA 'ClaudeManager'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Add-Content -LiteralPath (Join-Path $dir 'error.log') -Value ("[{0:s}] {1}" -f (Get-Date), $e.Exception.ToString())
            $script:LastUiError = $e.Exception.Message
        } catch { }
    })

    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $s = $g.DpiX / 96.0; $g.Dispose()
    $script:Scale = $s
    function Px([double]$v) { return [int][math]::Round($v * $s) }

    $script:TreeMode   = $true
    $script:SortCol    = 6
    $script:SortDesc   = $true
    $script:LastScan   = $null
    $script:RowByKey   = @{}
    $script:ScanPs     = $null
    $script:ScanAsync  = $null
    $script:ScanQueued = $false
    $script:ActPs      = $null
    $script:ActAsync   = $null

    $initialDark = $false
    if ($script:OptTheme) { $initialDark = ($script:OptTheme -eq 'Dark') } else { $initialDark = Get-InitialDarkMode }
    $script:Dark  = $initialDark
    $script:Pal = Get-Theme $initialDark

    # icon (ClaudeManager.exe embeds it; next to the .ps1 we pick up ClaudeManager.ico)
    $iconBytes = $null
    if ($global:ClaudeManagerIcon) { $iconBytes = [byte[]]$global:ClaudeManagerIcon }
    elseif ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'ClaudeManager.ico'))) { $iconBytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'ClaudeManager.ico')) }
    if ($iconBytes) { try { $script:AppIcon = New-Object System.Drawing.Icon((New-Object System.IO.MemoryStream(, $iconBytes))) } catch { } }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'ClaudeManager'
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.ClientSize = New-Object System.Drawing.Size((Px 1400), (Px 700))
    $form.KeyPreview = $true
    if ($script:AppIcon) { $form.Icon = $script:AppIcon }

    # ---- list
    $lv = New-Object ClaudeManager.UI.ThemedListView
    $lv.MultiSelect = $true; $lv.Dock = 'Fill'; $lv.UseCompatibleStateImageBehavior = $false
    $lv.ButtonColumn = 1
    $cols = @(
        @('Name', 200, 'Left'), @('Open', 92, 'Left'), @('Chat', 165, 'Left'), @('PID', 58, 'Right'), @('Type', 100, 'Left'),
        @('Started by', 175, 'Left'), @('CPU %', 60, 'Right'), @('Memory MB', 80, 'Right'), @('Private MB', 80, 'Right'),
        @('Disk MB/s', 72, 'Right'), @('Threads', 60, 'Right'), @('Running for', 84, 'Right'), @('Started', 122, 'Left'),
        @('Command line', 3000, 'Left')
    )
    foreach ($c in $cols) {
        $h = $lv.Columns.Add($c[0], (Px $c[1]))
        $h.TextAlign = $c[2]
    }

    # ---- toolbar
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Top'; $bar.AutoSize = $true; $bar.WrapContents = $true
    $bar.Padding = New-Object System.Windows.Forms.Padding(6, 6, 6, 4)

    function New-Button($text) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text; $b.AutoSize = $true
        $b.Padding = New-Object System.Windows.Forms.Padding(8, 2, 8, 2)
        $b.FlatStyle = 'Flat'
        return $b
    }
    function New-Check($text, $checked) {
        $c = New-Object System.Windows.Forms.CheckBox
        $c.Text = $text; $c.AutoSize = $true; $c.Checked = $checked; $c.Anchor = 'Left'
        return $c
    }
    function New-Label($text) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.AutoSize = $true; $l.Anchor = 'Left'
        $l.Margin = New-Object System.Windows.Forms.Padding(8, 0, 2, 0)
        return $l
    }

    $btnEnd = New-Button 'End Task'
    $btnEnd.BackColor = [System.Drawing.Color]::FromArgb(196, 43, 28); $btnEnd.ForeColor = [System.Drawing.Color]::White
    $btnEnd.FlatAppearance.BorderSize = 0
    $btnTree = New-Button 'End Process Tree'
    $btnRefresh = New-Button 'Refresh'
    $chkAuto = New-Check 'Auto-refresh every' $true
    $chkAuto.Margin = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
    $nud = New-Object System.Windows.Forms.NumericUpDown
    $nud.Minimum = 1; $nud.Maximum = 60; $nud.Value = [math]::Max(1, [math]::Min(60, $script:OptRefresh)); $nud.Width = Px 48; $nud.Anchor = 'Left'
    $lblSec = New-Label 's'; $lblSec.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $lblShow = New-Label 'Show:'
    $cboShow = New-Object System.Windows.Forms.ComboBox
    $cboShow.DropDownStyle = 'DropDownList'; $cboShow.Width = Px 230; $cboShow.Anchor = 'Left'
    [void]$cboShow.Items.AddRange(@('All Claude processes', 'Agents + their scripts (hide desktop app UI)', 'Scripts and orphans only', 'Running for more than 1 hour'))
    $cboShow.SelectedIndex = 0
    $lblFind = New-Label 'Find:'
    $txtFind = New-Object System.Windows.Forms.TextBox
    $txtFind.Width = Px 150; $txtFind.Anchor = 'Left'
    $chkTree = New-Check 'Group as tree' $true
    $chkTree.Margin = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
    $chkDark = New-Check 'Dark mode' $initialDark
    $chkDark.Margin = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
    $chkOrph = New-Check 'Also list orphaned python/node/shell processes (parent exited, origin unknown)' $false
    $bar.Controls.AddRange(@($btnEnd, $btnTree, $btnRefresh, $chkAuto, $nud, $lblSec, $lblShow, $cboShow, $lblFind, $txtFind, $chkTree, $chkDark, $chkOrph))

    # ---- status bar
    $status = New-Object System.Windows.Forms.StatusStrip
    $stLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $stLabel.Spring = $true; $stLabel.TextAlign = 'MiddleLeft'; $stLabel.Text = 'Scanning...'
    [void]$status.Items.Add($stLabel)

    # ---- context menu
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miOpen = $menu.Items.Add('Open chat')
    [void]$menu.Items.Add('-')
    $miEnd  = $menu.Items.Add('End task')
    $miTree = $menu.Items.Add('End process tree')
    [void]$menu.Items.Add('-')
    $miCmd  = $menu.Items.Add('Copy command line')
    $miPid  = $menu.Items.Add('Copy PID')
    $lv.ContextMenuStrip = $menu

    $form.Controls.Add($lv)
    $form.Controls.Add($status)
    $form.Controls.Add($bar)

    # ---------------- theme
    function Set-AppTheme([bool]$dark) {
        $script:Dark = $dark
        $t = Get-Theme $dark
        $script:Pal = $t
        $form.BackColor = $t.Back; $form.ForeColor = $t.Fore
        $bar.BackColor = $t.Back; $bar.ForeColor = $t.Fore
        foreach ($c in @($chkAuto, $chkTree, $chkOrph, $chkDark, $lblSec, $lblShow, $lblFind)) { $c.BackColor = $t.Back; $c.ForeColor = $t.Fore }
        foreach ($b in @($btnTree, $btnRefresh)) {
            $b.FlatAppearance.BorderColor = $t.ButtonBorder; $b.FlatAppearance.BorderSize = 1
            $b.BackColor = $t.ButtonBack; $b.ForeColor = $t.ButtonFore
        }
        foreach ($c in @($cboShow, $txtFind, $nud)) { $c.BackColor = $t.InputBack; $c.ForeColor = $t.InputFore }
        if ($dark) { $txtFind.BorderStyle = 'FixedSingle' } else { $txtFind.BorderStyle = 'Fixed3D' }
        # native dark look for the dropdown (needs its window handle, so also re-applied once shown).
        # NOT applied to the NumericUpDown: a foreign visual-style class makes its own paint code throw.
        [ClaudeManager.UI.Native]::ThemeAs($cboShow, $(if ($dark) { 'DarkMode_CFD' } else { $null }), $(if ($dark) { 'Combobox' } else { $null }))

        $lv.Dark = $dark
        $lv.BackColor = $t.ListBack; $lv.ForeColor = $t.ListFore
        $lv.HeaderBack = $t.HeaderBack; $lv.HeaderFore = $t.HeaderFore; $lv.HeaderLine = $t.HeaderLine
        $lv.GridColor = $t.Grid; $lv.SelBack = $t.SelBack; $lv.SelBackInactive = $t.SelBackInactive; $lv.SelFore = $t.SelFore
        $lv.ButtonBack = $t.LBack; $lv.ButtonFore = $t.LFore; $lv.ButtonBorder = $t.LBorder
        $lv.ButtonHover = $t.LHover; $lv.ButtonPressed = $t.LPressed

        $status.BackColor = $t.Back; $stLabel.ForeColor = $t.Fore
        $status.Renderer = New-Object ClaudeManager.UI.ThemedRenderer($dark)
        $menu.Renderer = New-Object ClaudeManager.UI.ThemedRenderer($dark)
        $menu.BackColor = $(if ($dark) { [System.Drawing.Color]::FromArgb(43, 43, 43) } else { [System.Drawing.SystemColors]::Menu })
        foreach ($it in $menu.Items) { $it.ForeColor = $t.Fore }

        if ($form.IsHandleCreated) { [ClaudeManager.UI.Native]::TitleBar($form.Handle, $dark) }
        $lv.ApplyTheme()
        if ($script:LastScan) { Show-View }
        $form.Invalidate($true)
    }

    # ---------------- helpers
    function Get-RowTexts($r) {
        $indent = ''
        if ($script:TreeMode -and $r.Depth -gt 0) { $indent = ('    ' * ($r.Depth - 1)) + [string][char]0x2514 + ' ' }
        $disk = '0'
        if ($r.Disk -ge 0.005) { $disk = '{0:N2}' -f $r.Disk }
        $started = ''
        if ($r.Created) { $started = $r.Created.ToString('yyyy-MM-dd HH:mm') }
        $open = ''; $chat = ''
        if ($r.CanOpen) { $open = 'Open chat'; $chat = $r.ChatTitle }
        return [string[]]@(
            ($indent + $r.Name), $open, $chat, [string]$r.Pid, $r.Kind, $r.Origin,
            ('{0:N1}' -f $r.Cpu), ('{0:N0}' -f $r.WorkingMB), ('{0:N0}' -f $r.PrivateMB), $disk,
            [string]$r.Threads, $r.UptimeText, $started, $r.Cmd
        )
    }

    function Set-RowColors($item, $r) {
        $t = $script:Pal
        $fore = $t.ListFore
        $back = $t.ListBack
        if     ($r.Kind -eq 'Claude Desktop') { $fore = $t.RowDesktop }
        elseif ($r.Kind -eq 'Orphan')         { $fore = $t.RowOrphan }
        elseif ($r.Kind -eq 'Script' -and $r.Uptime.TotalHours -ge 24) { $fore = $t.RowLong }
        if ($r.Cpu -ge 25) { $back = $t.RowBusyBack }
        $item.ForeColor = $fore; $item.BackColor = $back
    }

    function Get-VisibleRows {
        $rows = @($script:LastScan.Rows)
        switch ($cboShow.SelectedIndex) {
            1 { $rows = @($rows | Where-Object { $_.Kind -ne 'Claude Desktop' }) }
            2 { $rows = @($rows | Where-Object { $_.Kind -eq 'Script' -or $_.Kind -eq 'Orphan' }) }
            3 { $rows = @($rows | Where-Object { $_.Uptime.TotalHours -ge 1 }) }
        }
        $q = $txtFind.Text.Trim()
        if ($q) {
            $rows = @($rows | Where-Object {
                ($_.Name + ' ' + $_.Pid + ' ' + $_.Kind + ' ' + $_.Origin + ' ' + $_.ChatTitle + ' ' + $_.Cmd).IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0
            })
        }
        if ($script:TreeMode) { return @(Get-TreeOrder $rows) }
        $props = 'Name', 'CanOpen', 'ChatTitle', 'Pid', 'Kind', 'Origin', 'Cpu', 'WorkingMB', 'PrivateMB', 'Disk', 'Threads', 'Uptime', 'Created', 'Cmd'
        return @($rows | Sort-Object -Property $props[$script:SortCol] -Descending:$script:SortDesc)
    }

    function Update-Headers {
        for ($i = 0; $i -lt $lv.Columns.Count; $i++) {
            $t = $cols[$i][0]
            if (-not $script:TreeMode -and $i -eq $script:SortCol) {
                if ($script:SortDesc) { $t += '  v' } else { $t += '  ^' }
            }
            $lv.Columns[$i].Text = $t
        }
    }

    function Show-View {
        if (-not $script:LastScan) { return }
        $rows = @(Get-VisibleRows)

        $selKeys = @{}
        foreach ($it in $lv.SelectedItems) { $selKeys[[string]$it.Tag] = $true }
        $topKey = $null
        if ($lv.TopItem) { $topKey = [string]$lv.TopItem.Tag }

        $map = @{}
        foreach ($r in $script:LastScan.Rows) { $map[$r.Key] = $r }
        $script:RowByKey = $map

        $lv.BeginUpdate()
        try {
            $same = ($lv.Items.Count -eq $rows.Count)
            if ($same) {
                for ($i = 0; $i -lt $rows.Count; $i++) {
                    if ([string]$lv.Items[$i].Tag -ne $rows[$i].Key) { $same = $false; break }
                }
            }
            if ($same) {
                for ($i = 0; $i -lt $rows.Count; $i++) {
                    $texts = Get-RowTexts $rows[$i]
                    $item = $lv.Items[$i]
                    if ($item.Text -ne $texts[0]) { $item.Text = $texts[0] }
                    for ($k = 1; $k -lt $texts.Length; $k++) {
                        if ($item.SubItems[$k].Text -ne $texts[$k]) { $item.SubItems[$k].Text = $texts[$k] }
                    }
                    Set-RowColors $item $rows[$i]
                }
            } else {
                $lv.Items.Clear()
                $topIdx = -1; $idx = 0
                foreach ($r in $rows) {
                    $item = [System.Windows.Forms.ListViewItem]::new([string[]](Get-RowTexts $r))
                    $item.Tag = $r.Key
                    Set-RowColors $item $r
                    [void]$lv.Items.Add($item)
                    if ($selKeys.ContainsKey($r.Key)) { $item.Selected = $true }
                    if ($topKey -and $r.Key -eq $topKey) { $topIdx = $idx }
                    $idx++
                }
                if ($topIdx -ge 0 -and $topIdx -lt $lv.Items.Count) { $lv.TopItem = $lv.Items[$topIdx] }
            }
        } finally { $lv.EndUpdate() }
        $lv.Invalidate()

        Update-Headers

        $cpuSum = ($rows | Measure-Object Cpu -Sum).Sum
        $memSum = ($rows | Measure-Object WorkingMB -Sum).Sum
        $old = @($rows | Where-Object { $_.Kind -ne 'Claude Desktop' -and $_.Uptime.TotalHours -ge 24 }).Count
        $stLabel.Text = '{0} shown of {1} Claude-related processes   |   CPU {2:N1}%   |   Memory {3:N0} MB   |   {4} agent/script processes running over 24 h   |   updated {5:HH:mm:ss}' -f `
            $rows.Count, $script:LastScan.Rows.Count, $cpuSum, $memSum, $old, $script:LastScan.At
    }

    # Scans run in their own runspace: the WMI query + classification take ~0.5 s and must not freeze the window.
    # Update-View only *requests* a scan; Complete-Scan (polled by a fast timer) picks up the result.
    function Update-View {
        if ($script:ScanAsync) { $script:ScanQueued = $true; return }
        $script:ScanQueued = $false
        $ps = $script:ScanPs
        $ps.Commands.Clear()
        [void]$ps.AddScript('param($o) $s = Get-Scan -InterpOrphans $o; [pscustomobject]@{ Scan = $s; ChildMap = $script:ChildMap; NameByPid = $script:NameByPid; SelfAnc = $script:SelfAncestors }').AddArgument([bool]$chkOrph.Checked)
        $script:ScanAsync = $ps.BeginInvoke()
    }

    function Complete-Scan {
        if (-not $script:ScanAsync -or -not $script:ScanAsync.IsCompleted) { return }
        $async = $script:ScanAsync
        $script:ScanAsync = $null
        try {
            $out = $script:ScanPs.EndInvoke($async)
            $res = $out[0]
            $script:ChildMap      = $res.ChildMap
            $script:NameByPid     = $res.NameByPid
            $script:SelfAncestors = $res.SelfAnc
            $script:LastScan      = $res.Scan
            Show-View
        } catch {
            $stLabel.Text = 'Scan error: ' + $_.Exception.Message
        }
        if ($script:ScanQueued) { Update-View }
    }

    function Wait-Scan {
        if ($script:ScanAsync) { [void]$script:ScanAsync.AsyncWaitHandle.WaitOne(30000) }
        Complete-Scan
    }

    # "Open chat": runs in a second background runspace (UI Automation must not run on the window's UI thread).
    function Start-OpenChat($row) {
        if (-not $row -or -not $row.CanOpen) { $stLabel.Text = 'That process has no chat to open.'; return }
        if ($script:ActAsync) { $stLabel.Text = 'Still opening the previous chat...'; return }
        $target = @{ Kind = $row.ChatKind; ChatId = $row.ChatId; Title = $row.ChatTitle; Anc = @($row.Anc) }
        $ps = $script:ActPs
        $ps.Commands.Clear()
        [void]$ps.AddScript('param($t) Open-ChatTarget $t').AddArgument($target)
        $stLabel.Text = 'Opening chat...'
        $script:ActAsync = $ps.BeginInvoke()
    }

    function Complete-Action {
        if (-not $script:ActAsync -or -not $script:ActAsync.IsCompleted) { return }
        $a = $script:ActAsync
        $script:ActAsync = $null
        $msg = ''
        try {
            $out = $script:ActPs.EndInvoke($a)
            if ($out.Count -gt 0) { $msg = [string]$out[$out.Count - 1] }
        } catch { $msg = 'Could not open the chat: ' + $_.Exception.Message }
        if (-not $msg) { $msg = 'Done.' }
        $stLabel.Text = $msg
    }

    function Get-SelectedRows {
        $out = @()
        foreach ($it in $lv.SelectedItems) {
            $r = $script:RowByKey[[string]$it.Tag]
            if ($r) { $out += $r }
        }
        return $out
    }

    function Invoke-EndTask([bool]$Tree) {
        $targets = @(Get-SelectedRows)
        if ($targets.Count -eq 0) { $stLabel.Text = 'Select one or more processes first.'; return }

        $lines = New-Object System.Collections.Generic.List[string]
        $warn  = New-Object System.Collections.Generic.List[string]
        $shown = 0
        foreach ($t in $targets) {
            if ($shown -lt 8) { $lines.Add(('  {0}  (PID {1}, {2}, running {3})' -f $t.Name, $t.Pid, $t.Kind, $t.UptimeText)); $shown++ }
            if ($script:SelfAncestors.Contains([int]$t.Pid)) {
                $warn.Add("PID $($t.Pid) is what launched this window - ending it will also close ClaudeManager.")
            }
            if ($t.Kind -eq 'Claude Desktop') {
                $warn.Add('Ending part of the Claude desktop app can close the app and every session running inside it.')
            }
            if ($t.Kind -eq 'Claude Code') {
                $warn.Add('Ending a Claude Code agent stops that session; anything it was doing is lost.')
            }
        }
        if ($targets.Count -gt 8) { $lines.Add(('  ... and {0} more' -f ($targets.Count - 8))) }

        $kidInfo = ''
        if ($Tree) {
            $desc = New-Object 'System.Collections.Generic.HashSet[int]'
            foreach ($t in $targets) { foreach ($d in (Get-DescendantPids ([int]$t.Pid))) { [void]$desc.Add($d) } }
            foreach ($t in $targets) { [void]$desc.Remove([int]$t.Pid) }
            if ($desc.Count -gt 0) {
                $names = @($desc | ForEach-Object { $script:NameByPid[$_] } | Group-Object | Sort-Object Count -Descending | Select-Object -First 6 |
                    ForEach-Object { if ($_.Count -gt 1) { '{0} x{1}' -f $_.Name, $_.Count } else { $_.Name } })
                $kidInfo = "`r`n`r`nAlso ends {0} child process(es): {1}" -f $desc.Count, ($names -join ', ')
            }
        }

        $what = 'End task'; if ($Tree) { $what = 'End process tree' }
        $msg = "$what for:`r`n`r`n" + ($lines -join "`r`n") + $kidInfo
        $uw = @($warn | Select-Object -Unique)
        if ($uw.Count -gt 0) { $msg += "`r`n`r`nWARNING:`r`n- " + ($uw -join "`r`n- ") }
        $msg += "`r`n`r`nThis cannot be undone."

        $icon = 'Question'; if ($uw.Count -gt 0) { $icon = 'Warning' }
        $buttons = @(@($what, 'Yes'), @('Cancel', 'No'))
        $ans = Show-ThemedDialog $form $what $msg $buttons $icon 1
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $ok = 0; $fail = New-Object System.Collections.Generic.List[string]
        foreach ($t in $targets) {
            $res = Stop-ProcessRow $t $Tree
            if ($res.Ok) { $ok++ } else { $fail.Add(('{0} (PID {1}): {2}' -f $t.Name, $t.Pid, $res.Msg)) }
        }
        Start-Sleep -Milliseconds 300
        Update-View
        if ($fail.Count -gt 0) {
            [void](Show-ThemedDialog $form 'ClaudeManager' (("Ended {0}, failed {1}:`r`n`r`n" -f $ok, $fail.Count) + ($fail -join "`r`n")) @(, @('OK', 'OK')) 'Warning' 0)
        } else {
            $stLabel.Text = "Ended $ok process(es)."
        }
    }

    function Save-WindowShot([string]$Path) {
        $form.TopMost = $true
        $form.Activate()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 600
        [System.Windows.Forms.Application]::DoEvents()
        $r = $form.Bounds
        $bmp = New-Object System.Drawing.Bitmap($r.Width, $r.Height)
        $gr = [System.Drawing.Graphics]::FromImage($bmp)
        $gr.CopyFromScreen($r.Location, [System.Drawing.Point]::Empty, $r.Size)
        $gr.Dispose()
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $form.TopMost = $false
    }

    # ---------------- events
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [int]($nud.Value * 1000)
    $timer.Add_Tick({
        $want = [int]($nud.Value * 1000)
        if ($timer.Interval -ne $want) { $timer.Interval = $want }
        if ($chkAuto.Checked) { Update-View }
    })
    $poll = New-Object System.Windows.Forms.Timer
    $poll.Interval = 120
    $poll.Add_Tick({
        Complete-Scan; Complete-Action
        if ($script:LastUiError) { $stLabel.Text = 'Internal UI error (logged to %LOCALAPPDATA%\ClaudeManager\error.log): ' + $script:LastUiError; $script:LastUiError = $null }
    })
    $nud.Add_ValueChanged({ $timer.Interval = [int]($nud.Value * 1000) })

    $btnEnd.Add_Click({ Invoke-EndTask $false })
    $btnTree.Add_Click({ Invoke-EndTask $true })
    $btnRefresh.Add_Click({ Update-View })
    $miEnd.Add_Click({ Invoke-EndTask $false })
    $miTree.Add_Click({ Invoke-EndTask $true })
    $miOpen.Add_Click({ $t = @(Get-SelectedRows); if ($t.Count -gt 0) { Start-OpenChat $t[0] } })
    $menu.Add_Opening({
        $t = @(Get-SelectedRows)
        $miOpen.Enabled = ($t.Count -eq 1 -and $t[0].CanOpen)
    })
    $miCmd.Add_Click({
        $t = @(Get-SelectedRows)
        if ($t.Count -gt 0) { [System.Windows.Forms.Clipboard]::SetText((($t | ForEach-Object { $_.Cmd }) -join "`r`n")) }
    })
    $miPid.Add_Click({
        $t = @(Get-SelectedRows)
        if ($t.Count -gt 0) { [System.Windows.Forms.Clipboard]::SetText((($t | ForEach-Object { [string]$_.Pid }) -join "`r`n")) }
    })
    $lv.add_ButtonClicked({ param($sender, $e) Start-OpenChat $script:RowByKey[[string]$e.Item.Tag] })
    $cboShow.Add_SelectedIndexChanged({ Show-View })
    $txtFind.Add_TextChanged({ Show-View })
    $chkOrph.Add_CheckedChanged({ Update-View })
    $chkTree.Add_CheckedChanged({ $script:TreeMode = $chkTree.Checked; Show-View })
    $chkDark.Add_CheckedChanged({
        Set-AppTheme $chkDark.Checked
        if (-not $script:OptTheme) { Save-DarkMode $chkDark.Checked }
    })
    $lv.Add_ColumnClick({
        param($sender, $e)
        if ($e.Column -eq 1) { return }                 # the button column is not sortable
        if ($script:TreeMode) {
            $script:SortCol = $e.Column
            $script:SortDesc = ($e.Column -ge 6 -and $e.Column -le 11)
            $chkTree.Checked = $false                   # re-renders via CheckedChanged
        } else {
            if ($script:SortCol -eq $e.Column) { $script:SortDesc = -not $script:SortDesc }
            else { $script:SortCol = $e.Column; $script:SortDesc = ($e.Column -ge 6 -and $e.Column -le 11) }
            Show-View
        }
    })
    $form.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq 'F5') { Update-View; $e.Handled = $true }
        elseif ($e.KeyCode -eq 'Delete' -and $lv.Focused) { Invoke-EndTask $false; $e.Handled = $true }
        elseif ($e.KeyCode -eq 'A' -and $e.Control -and $lv.Focused) { foreach ($it in $lv.Items) { $it.Selected = $true }; $e.Handled = $true }
    })
    $form.Add_HandleCreated({ param($sender, $e) [ClaudeManager.UI.Native]::TitleBar($sender.Handle, $script:Dark) })

    $form.Add_Shown({
        Set-AppTheme $script:Dark        # now that every control has a window handle, apply the native dark styles too
        Update-View; Wait-Scan           # first sample
        if ($global:ClaudeManagerTestHook) {      # lets a test script drive the real window (not used in normal runs)
            Start-Sleep -Milliseconds 900
            Update-View; Wait-Scan
            $poll.Start()
            try { & $global:ClaudeManagerTestHook $form $lv } catch { [Console]::Error.WriteLine('test hook failed: ' + $_) }
            $form.Close()
        } elseif ($script:OptShot) {
            Start-Sleep -Milliseconds 900
            Update-View; Wait-Scan       # second sample so CPU % has a baseline
            foreach ($it in $lv.Items) { if ($it.SubItems[4].Text -eq 'Script') { $it.Selected = $true; break } }   # show the selection styling
            Save-WindowShot $script:OptShot
            if ($script:OptToggle) {
                $chkDark.Checked = -not $chkDark.Checked
                [System.Windows.Forms.Application]::DoEvents()
                Save-WindowShot ([IO.Path]::Combine([IO.Path]::GetDirectoryName($script:OptShot), [IO.Path]::GetFileNameWithoutExtension($script:OptShot) + '-toggled.png'))
            }
            $form.Close()
        } else {
            $timer.Interval = 1000       # quick second sample so CPU % shows up, then the normal interval
            $timer.Start()
            $poll.Start()
        }
    })
    $form.Add_FormClosed({
        $timer.Stop(); $poll.Stop()
        foreach ($x in @($script:ScanPs, $script:ActPs)) { try { $x.Stop(); $x.Runspace.Close() } catch { } }
    })

    $script:ScanPs = New-LibraryShell
    $script:ActPs  = New-LibraryShell
    Set-AppTheme $initialDark
    try { [void]$form.ShowDialog() }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show("ClaudeManager crashed:`r`n`r`n$($_.Exception.Message)", 'ClaudeManager', 'OK', 'Error')
    }
}

# ---------------------------------------------------------------- entry point
# (skipped when the file is dot-sourced or loaded as a library, so the functions above can be reused and tested)
if (-not $global:ClaudeManagerLibraryOnly -and $MyInvocation.InvocationName -ne '.') {
    if ($List) { Show-List } else { Start-Gui }
}
