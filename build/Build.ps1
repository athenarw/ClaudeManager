<#
.SYNOPSIS
  Builds ClaudeManager.exe - a single self-contained launcher (the script and the icon are embedded in it).

.DESCRIPTION
  Uses the C# compiler that ships with Windows (.NET Framework 4.x), so nothing needs to be installed.
  Steps: (re)generate ClaudeManager.ico if it is missing, pull the C# helper classes out of ClaudeManager.ps1,
  compile them together with build\ClaudeManagerHost.cs, and embed ClaudeManager.ps1 + ClaudeManager.ico.
  Re-run this after editing ClaudeManager.ps1 - the .exe contains a copy of the script as it was at build time.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File build\Build.ps1
  powershell -ExecutionPolicy Bypass -File build\Build.ps1 -NewIcon      # also redraw the icon
#>
param(
    [switch]$NewIcon,
    [string]$Out
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$ps1  = Join-Path $root 'ClaudeManager.ps1'
$ico  = Join-Path $root 'ClaudeManager.ico'
$exe  = if ($Out) { $Out } else { Join-Path $root 'ClaudeManager.exe' }

if ($NewIcon -or -not (Test-Path -LiteralPath $ico)) { & (Join-Path $PSScriptRoot 'New-Icon.ps1') -Out $ico }

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw "C# compiler not found at $csc" }

$sma = [System.Management.Automation.PSObject].Assembly.Location          # the PowerShell engine the exe will host
# (csc already references System.Windows.Forms / System.Drawing through its default response file)

# the native UI helper classes live inside ClaudeManager.ps1 ($script:UiSource); compile them into the exe as well
$text = [IO.File]::ReadAllText($ps1)
$m = [regex]::Match($text, '(?s)\$script:UiSource\s*=\s*@''\r?\n(.*?)\r?\n''@')
if (-not $m.Success) { throw 'Could not find $script:UiSource in ClaudeManager.ps1' }
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'ClaudeManagerBuild'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$uiCs = Join-Path $tmp 'UiSource.cs'
[IO.File]::WriteAllText($uiCs, $m.Groups[1].Value, (New-Object System.Text.UTF8Encoding($false)))

$cscArgs = @(
    '/nologo', '/target:winexe', '/platform:x64', '/optimize+',
    "/out:$exe",
    "/win32icon:$ico",
    "/win32manifest:$(Join-Path $PSScriptRoot 'ClaudeManager.manifest')",
    "/resource:$ps1,ClaudeManager.ps1",
    "/resource:$ico,ClaudeManager.ico",
    "/reference:$sma",
    (Join-Path $PSScriptRoot 'ClaudeManagerHost.cs'),
    $uiCs
)
& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
'Built {0} ({1:N0} KB)' -f $exe, ((Get-Item -LiteralPath $exe).Length / 1KB)
