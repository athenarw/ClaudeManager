<#
.SYNOPSIS
  Task-Manager-style viewer for every Claude process and script on this PC.

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

  -List        print the table to the console and exit (no window)
  -Screenshot  save a PNG of the window and exit (for testing)
#>
[CmdletBinding()]
param(
    [switch]$List,
    [string]$Screenshot,
    [int]$RefreshSeconds = 3
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- classification
$script:SelfPid      = $PID
$script:ScriptPath   = $PSCommandPath
$script:Cores       = [Environment]::ProcessorCount
$script:DesktopRx    = '\\WindowsApps\\Claude_|\\AnthropicClaude\\|\\app(-[\d.]+)?\\claude\.exe$'
$script:DesktopArgRx = '\s--type=(renderer|gpu-process|utility|crashpad-handler|zygote)'
$script:AgentNodeRx  = 'claude-code|@anthropic-ai[\\/]+claude'
$script:OrphanHintRx = 'claude-code|@anthropic-ai|[\\/]\.claude[\\/]|Claude-Data|anthropic\.claude'
$script:InterpRx     = '^(python[\d.]*|pythonw|py|node|npm|npx|bun|deno|powershell|pwsh|bash|sh|cmd|ruby|java|javaw|uv|uvx)\.exe$'
$script:Prev         = @{}
$script:ChildMap     = @{}
$script:NameByPid    = @{}
$script:SelfAncestors = New-Object 'System.Collections.Generic.HashSet[int]'

function Format-Span {
    param([TimeSpan]$T)
    if ($T.TotalDays  -ge 1) { return ('{0}d {1}h'    -f [int][math]::Floor($T.TotalDays),  $T.Hours) }
    if ($T.TotalHours -ge 1) { return ('{0}h {1:00}m' -f [int][math]::Floor($T.TotalHours), $T.Minutes) }
    return ('{0}m {1:00}s' -f [int][math]::Floor($T.TotalMinutes), $T.Seconds)
}

function Get-AgentOrigin {
    param($Proc, $Parent)
    $path = [string]$Proc.ExecutablePath
    $cmd  = [string]$Proc.CommandLine
    if ($path -match 'extensions[\\/]anthropic\.claude-code') { return 'VS Code extension' }
    if ($Parent -and ([string]$Parent.Name) -ieq 'claude.exe' -and
        (([string]$Parent.ExecutablePath) -match $script:DesktopRx -or ([string]$Parent.CommandLine) -match $script:DesktopArgRx)) {
        return 'Claude Desktop app'
    }
    if ($cmd -match '--output-format\s+stream-json') { return 'SDK / headless' }
    return 'Terminal / CLI'
}

# One system-wide scan. Returns rows for every Claude-related process.
function Get-Scan {
    param([bool]$InterpOrphans = $false)

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
    $rows   = New-Object 'System.Collections.Generic.List[object]'
    $newPrev = @{}
    $rowPids = @{}
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

        $kind = $null; $origin = ''
        if ($agentIdx -eq 0) {
            $kind = 'Claude Code'
            $origin = Get-AgentOrigin $p $parentOf[$id]
        } elseif ($agentIdx -gt 0) {
            $kind = 'Script'
            $root = $chain[$agentIdx]
            $origin = 'PID {0} - {1}' -f $root.ProcessId, (Get-AgentOrigin $root $parentOf[[int]$root.ProcessId])
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
            Up         = @()
            Depth      = 0
        })
    }

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
            Command = if ($_.Cmd.Length -gt 90) { $_.Cmd.Substring(0, 90) + '...' } else { $_.Cmd }
        }
    } | Format-Table -AutoSize | Out-String -Width 300 | Write-Host
    Write-Host ("{0} Claude-related processes of {1} on this PC. Memory total {2:N0} MB." -f $rows.Count, $scan.Total, (($rows | Measure-Object WorkingMB -Sum).Sum))
}

# ---------------------------------------------------------------- GUI
function Start-Gui {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    if (-not ('Native.Dpi' -as [type])) {
        Add-Type -Namespace Native -Name Dpi -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    }
    [void][Native.Dpi]::SetProcessDPIAware()
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)

    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $s = $g.DpiX / 96.0; $g.Dispose()
    function Px([double]$v) { return [int][math]::Round($v * $s) }

    $script:TreeMode  = $true
    $script:SortCol   = 4
    $script:SortDesc  = $true
    $script:LastScan  = $null
    $script:RowByKey  = @{}
    $script:ScanPs    = $null
    $script:ScanAsync = $null
    $script:ScanQueued = $false

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'ClaudeManager'
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.ClientSize = New-Object System.Drawing.Size((Px 1320), (Px 700))
    $form.KeyPreview = $true

    # ---- list
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $true; $lv.MultiSelect = $true
    $lv.HideSelection = $false; $lv.Dock = 'Fill'; $lv.UseCompatibleStateImageBehavior = $false
    [void]$lv.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($lv, $true, $null)
    $cols = @(
        @('Name', 210, 'Left'), @('PID', 60, 'Right'), @('Type', 100, 'Left'), @('Started by', 200, 'Left'),
        @('CPU %', 62, 'Right'), @('Memory MB', 82, 'Right'), @('Private MB', 82, 'Right'), @('Disk MB/s', 74, 'Right'),
        @('Threads', 62, 'Right'), @('Running for', 86, 'Right'), @('Started', 125, 'Left'), @('Command line', 900, 'Left')
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
    $btnEnd.FlatStyle = 'Flat'; $btnEnd.BackColor = [System.Drawing.Color]::FromArgb(196, 43, 28); $btnEnd.ForeColor = [System.Drawing.Color]::White
    $btnTree = New-Button 'End Process Tree'
    $btnRefresh = New-Button 'Refresh'
    $chkAuto = New-Check 'Auto-refresh every' $true
    $chkAuto.Margin = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
    $nud = New-Object System.Windows.Forms.NumericUpDown
    $nud.Minimum = 1; $nud.Maximum = 60; $nud.Value = [math]::Max(1, [math]::Min(60, $RefreshSeconds)); $nud.Width = Px 48; $nud.Anchor = 'Left'
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
    $chkOrph = New-Check 'Also list orphaned python/node/shell processes (parent exited, origin unknown)' $false
    $bar.Controls.AddRange(@($btnEnd, $btnTree, $btnRefresh, $chkAuto, $nud, $lblSec, $lblShow, $cboShow, $lblFind, $txtFind, $chkTree, $chkOrph))

    # ---- status bar
    $status = New-Object System.Windows.Forms.StatusStrip
    $stLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $stLabel.Spring = $true; $stLabel.TextAlign = 'MiddleLeft'; $stLabel.Text = 'Scanning...'
    [void]$status.Items.Add($stLabel)

    # ---- context menu
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miEnd  = $menu.Items.Add('End task')
    $miTree = $menu.Items.Add('End process tree')
    [void]$menu.Items.Add('-')
    $miCmd  = $menu.Items.Add('Copy command line')
    $miPid  = $menu.Items.Add('Copy PID')
    $lv.ContextMenuStrip = $menu

    $form.Controls.Add($lv)
    $form.Controls.Add($status)
    $form.Controls.Add($bar)

    # ---------------- helpers
    function Get-RowTexts($r) {
        $indent = ''
        if ($script:TreeMode -and $r.Depth -gt 0) { $indent = ('    ' * ($r.Depth - 1)) + [string][char]0x2514 + ' ' }
        $disk = '0'
        if ($r.Disk -ge 0.005) { $disk = '{0:N2}' -f $r.Disk }
        $started = ''
        if ($r.Created) { $started = $r.Created.ToString('yyyy-MM-dd HH:mm') }
        return [string[]]@(
            ($indent + $r.Name), [string]$r.Pid, $r.Kind, $r.Origin,
            ('{0:N1}' -f $r.Cpu), ('{0:N0}' -f $r.WorkingMB), ('{0:N0}' -f $r.PrivateMB), $disk,
            [string]$r.Threads, $r.UptimeText, $started, $r.Cmd
        )
    }

    function Set-RowColors($item, $r) {
        $fore = [System.Drawing.SystemColors]::WindowText
        $back = [System.Drawing.SystemColors]::Window
        if     ($r.Kind -eq 'Claude Desktop') { $fore = [System.Drawing.Color]::FromArgb(100, 100, 100) }
        elseif ($r.Kind -eq 'Orphan')         { $fore = [System.Drawing.Color]::FromArgb(176, 32, 32) }
        elseif ($r.Kind -eq 'Script' -and $r.Uptime.TotalHours -ge 24) { $fore = [System.Drawing.Color]::FromArgb(180, 90, 0) }
        if ($r.Cpu -ge 25) { $back = [System.Drawing.Color]::FromArgb(255, 244, 200) }
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
                ($_.Name + ' ' + $_.Pid + ' ' + $_.Kind + ' ' + $_.Origin + ' ' + $_.Cmd).IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0
            })
        }
        if ($script:TreeMode) { return @(Get-TreeOrder $rows) }
        $props = 'Name', 'Pid', 'Kind', 'Origin', 'Cpu', 'WorkingMB', 'PrivateMB', 'Disk', 'Threads', 'Uptime', 'Created', 'Cmd'
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

        Update-Headers

        $cpuSum = ($rows | Measure-Object Cpu -Sum).Sum
        $memSum = ($rows | Measure-Object WorkingMB -Sum).Sum
        $old = @($rows | Where-Object { $_.Kind -ne 'Claude Desktop' -and $_.Uptime.TotalHours -ge 24 }).Count
        $txt = '{0} shown of {1} Claude-related processes   |   CPU {2:N1}%   |   Memory {3:N0} MB   |   {4} agent/script processes running over 24 h   |   updated {5:HH:mm:ss}' -f `
            $rows.Count, $script:LastScan.Rows.Count, $cpuSum, $memSum, $old, $script:LastScan.At
        $stLabel.Text = $txt
    }

    # The WMI query + classification takes ~0.5 s, so scans run in their own runspace and never freeze the window.
    # Update-View only *requests* a scan; Complete-Scan (polled by a fast timer) picks up the result.
    function Initialize-Scanner {
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        $self = $script:ScriptPath.Replace("'", "''")
        [void]$ps.AddScript(". '$self'").Invoke()      # loads the scan functions (entry point is skipped when dot-sourced)
        $ps.Commands.Clear()
        $script:ScanPs = $ps
    }

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
        if ($script:ScanAsync) { [void]$script:ScanAsync.AsyncWaitHandle.WaitOne(20000) }
        Complete-Scan
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

        $icon = [System.Windows.Forms.MessageBoxIcon]::Question
        if ($uw.Count -gt 0) { $icon = [System.Windows.Forms.MessageBoxIcon]::Warning }
        $ans = [System.Windows.Forms.MessageBox]::Show($form, $msg, 'ClaudeManager', [System.Windows.Forms.MessageBoxButtons]::YesNo, $icon, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $ok = 0; $fail = New-Object System.Collections.Generic.List[string]
        foreach ($t in $targets) {
            $res = Stop-ProcessRow $t $Tree
            if ($res.Ok) { $ok++ } else { $fail.Add(('{0} (PID {1}): {2}' -f $t.Name, $t.Pid, $res.Msg)) }
        }
        Start-Sleep -Milliseconds 300
        Update-View
        if ($fail.Count -gt 0) {
            [void][System.Windows.Forms.MessageBox]::Show($form, ("Ended {0}, failed {1}:`r`n`r`n" -f $ok, $fail.Count) + ($fail -join "`r`n"), 'ClaudeManager', 'OK', 'Warning')
        } else {
            $stLabel.Text = "Ended $ok process(es)."
        }
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
    $poll.Add_Tick({ Complete-Scan })
    $nud.Add_ValueChanged({ $timer.Interval = [int]($nud.Value * 1000) })

    $btnEnd.Add_Click({ Invoke-EndTask $false })
    $btnTree.Add_Click({ Invoke-EndTask $true })
    $btnRefresh.Add_Click({ Update-View })
    $miEnd.Add_Click({ Invoke-EndTask $false })
    $miTree.Add_Click({ Invoke-EndTask $true })
    $miCmd.Add_Click({
        $t = @(Get-SelectedRows)
        if ($t.Count -gt 0) { [System.Windows.Forms.Clipboard]::SetText((($t | ForEach-Object { $_.Cmd }) -join "`r`n")) }
    })
    $miPid.Add_Click({
        $t = @(Get-SelectedRows)
        if ($t.Count -gt 0) { [System.Windows.Forms.Clipboard]::SetText((($t | ForEach-Object { [string]$_.Pid }) -join "`r`n")) }
    })
    $cboShow.Add_SelectedIndexChanged({ Show-View })
    $txtFind.Add_TextChanged({ Show-View })
    $chkOrph.Add_CheckedChanged({ Update-View })
    $chkTree.Add_CheckedChanged({ $script:TreeMode = $chkTree.Checked; Show-View })
    $lv.Add_ColumnClick({
        param($sender, $e)
        if ($script:TreeMode) {
            $script:SortCol = $e.Column
            $script:SortDesc = ($e.Column -ge 4 -and $e.Column -le 9)
            $chkTree.Checked = $false      # re-renders via CheckedChanged
        } else {
            if ($script:SortCol -eq $e.Column) { $script:SortDesc = -not $script:SortDesc }
            else { $script:SortCol = $e.Column; $script:SortDesc = ($e.Column -ge 4 -and $e.Column -le 9) }
            Show-View
        }
    })
    $form.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq 'F5') { Update-View; $e.Handled = $true }
        elseif ($e.KeyCode -eq 'Delete' -and $lv.Focused) { Invoke-EndTask $false; $e.Handled = $true }
        elseif ($e.KeyCode -eq 'A' -and $e.Control -and $lv.Focused) { foreach ($it in $lv.Items) { $it.Selected = $true }; $e.Handled = $true }
    })

    $form.Add_Shown({
        Update-View; Wait-Scan           # first sample
        if ($Screenshot) {
            Start-Sleep -Milliseconds 900
            Update-View; Wait-Scan       # second sample so CPU % has a baseline
            $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
            $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
            $bmp.Save($Screenshot, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            $form.Close()
        } else {
            $timer.Interval = 1000       # quick second sample so CPU % shows up, then the normal interval
            $timer.Start()
            $poll.Start()
        }
    })
    $form.Add_FormClosed({
        $timer.Stop(); $poll.Stop()
        try { $script:ScanPs.Stop(); $script:ScanPs.Runspace.Close() } catch { }
    })

    Initialize-Scanner
    try { [void]$form.ShowDialog() }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show("ClaudeManager crashed:`r`n`r`n$($_.Exception.Message)", 'ClaudeManager', 'OK', 'Error')
    }
}

# ---------------------------------------------------------------- entry point
# (skipped when the file is dot-sourced, so the functions above can be tested on their own)
if ($MyInvocation.InvocationName -ne '.') {
    if ($List) { Show-List } else { Start-Gui }
}
