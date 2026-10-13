#requires -version 5
<#
    x4mp_tag_windows.ps1 - write the X4MP ROLE onto each X4 window title.

    Why: two instances of the same game carry the same window title ("X4"), so
    "am I looking at the host or at the client?" could not be answered at a
    glance. This script puts " [HOST]" / " [CLIENT]" on the title bar of each
    running instance, so the answer is one alt-tab away.

    Where the role comes from (in this order, all evidence - nothing is guessed):
      1. the instance's own log: ...\Documents\Egosoft\X4\<profile>\x4native\
         x4mp_native\x4mp_native.log, last "mode=host|client" line (the DLL writes
         it on every load; <profile> is read from the process's -personalfolderid),
      2. %TEMP%\X4MP\instance_host.lock - the PID that claimed the host slot
         (autosplit mode only),
      3. the launcher convention: X4.exe = host, X4_2.exe = client.

    Usage
      powershell -ExecutionPolicy Bypass -File x4mp_tag_windows.ps1          # tag once
      powershell -ExecutionPolicy Bypass -File x4mp_tag_windows.ps1 -Watch   # keep it tagged
                                                                             # (until both exit)

    Note: the deployed x4mp_native.dll (>= 2026-09-21) does the same thing from
    inside the game, every 2 s, so this script is a convenience for sessions that
    run an older DLL - and a cross-check of the DLL's own reading of its role.
#>
param(
    [switch]$Watch,
    [int]$IntervalSeconds = 3,
    [switch]$Quiet,
    # 2026-09-21: window layout for local dual-instance testing.
    #   leftright (default) - host fills the left half, client the right half
    #   topbottom           - host on top, client below
    #   none                - tag the titles only, never move a window
    [ValidateSet('leftright','topbottom','none')] [string]$Layout = 'none'
)

# NOTE 2026-09-21: RECT and the Win32 wrappers must be defined in ONE Add-Type call.
# Two separate Add-Type calls land in two dynamic assemblies that do not reference
# each other, so `out X4MP.RECT` in the second one fails to compile ("type or
# namespace name 'RECT' does not exist") - found the hard way while testing the
# left/right layout. One -TypeDefinition, one assembly, no surprise.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace X4MP {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    public static class Win {
        [DllImport("user32.dll", CharSet=CharSet.Ansi, SetLastError=true)]
        public static extern bool SetWindowTextA(IntPtr hWnd, string lpString);
        [DllImport("user32.dll", CharSet=CharSet.Ansi)]
        public static extern int GetWindowTextA(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
        [DllImport("user32.dll", SetLastError=true)]
        public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
        [DllImport("user32.dll")]
        public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, out RECT pvParam, uint fWinIni);
    }
}
'@

# The usable desktop area (taskbar excluded) via SystemParametersInfo(SPI_GETWORKAREA) -
# no WinForms dependency, works in a non-interactive PowerShell too.
function Get-WorkArea {
    $rc = New-Object X4MP.RECT
    if ([X4MP.Win]::SystemParametersInfo(0x0030, 0, [ref]$rc, 0)) {
        return @{ X = $rc.Left; Y = $rc.Top; W = ($rc.Right - $rc.Left); H = ($rc.Bottom - $rc.Top) }
    }
    return @{ X = 0; Y = 0; W = 1920; H = 1080 }
}

function Get-X4Instances {
    $list = @()
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^X4' }
    foreach ($p in $procs) {
        $profileDir = $null
        try {
            $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction Stop).CommandLine
            if ($cmd -match '-personalfolderid\s+(\d+)') { $profileDir = $matches[1] }
        } catch { }

        $role = $null
        if ($profileDir) {
            $log = Join-Path $env:USERPROFILE "Documents\Egosoft\X4\$profileDir\x4native\x4mp_native\x4mp_native.log"
            if (Test-Path -LiteralPath $log) {
                $hit = Select-String -Path $log -Pattern 'mode=(host|client)' | Select-Object -Last 1
                if ($hit -and $hit.Line -match 'mode=(host|client)') { $role = $matches[1] }
            }
        }
        if (-not $role) {
            $lock = Join-Path $env:TEMP 'X4MP\instance_host.lock'
            if (Test-Path -LiteralPath $lock) {
                if (((Get-Content -LiteralPath $lock -Raw).Trim()) -eq "$($p.Id)") { $role = 'host' }
            }
        }
        if (-not $role) { $role = if ($p.ProcessName -eq 'X4') { 'host' } else { 'client' } }

        $list += [pscustomobject]@{
            Id      = $p.Id
            Name    = $p.ProcessName
            Profile = $profileDir
            Role    = $role
        }
    }
    return $list
}

function Set-X4WindowTags {
    $tagged = 0
    $placed = @()
    foreach ($inst in Get-X4Instances) {
        try { (Get-Process -Id $inst.Id).Refresh() } catch { continue }
        $p = Get-Process -Id $inst.Id -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        $h = $p.MainWindowHandle
        if (-not $h -or $h -eq [IntPtr]::Zero) { continue }

        $sb = New-Object Text.StringBuilder 256
        [void][X4MP.Win]::GetWindowTextA($h, $sb, 256)
        $cur  = $sb.ToString()
        $base = ($cur -replace '\s*\[(HOST|CLIENT)\]$', '')
        if ([string]::IsNullOrWhiteSpace($base)) { $base = 'X4: Foundations' }
        $want = "$base [$($inst.Role.ToUpper())]"
        if ($cur -ne $want) {
            [void][X4MP.Win]::SetWindowTextA($h, $want)
            if (-not $Quiet) {
                Write-Host ("[X4MP] pid {0,-6} {1,-8} profile {2,-6} -> {3}" -f $inst.Id, $inst.Name, $inst.Profile, $want)
            }
        }
        $placed += [pscustomobject]@{ Handle = $h; Role = $inst.Role; Id = $inst.Id; Name = $inst.Name }
        $tagged++
    }
    if (-not $Quiet -and $tagged -eq 0) { Write-Host '[X4MP] no X4 window found (game not running, or still loading).' }

    # ---- layout (only with 2+ instances: a solo run keeps its own window size) ----
    if ($Layout -ne 'none' -and $placed.Count -ge 2) {
        $wa = Get-WorkArea
        $w2 = [int]($wa.W / 2); $h2 = [int]($wa.H / 2)
        # host first, client second - the role decides, not the start order
        $order = @($placed | Sort-Object { if ($_.Role -eq 'host') { 0 } else { 1 } })
        for ($i = 0; $i -lt $order.Count; $i++) {
            $item = $order[$i]
            if ($i -gt 1) { break }   # more than two X4 windows: only place the first two
            if ($Layout -eq 'leftright') {
                $x = $wa.X + $i * $w2; $y = $wa.Y; $w = $w2; $hh = $wa.H
            } else {
                $x = $wa.X; $y = $wa.Y + $i * $h2; $w = $wa.W; $hh = $h2
            }
            $rc = New-Object X4MP.RECT
            [void][X4MP.Win]::GetWindowRect($item.Handle, [ref]$rc)
            $dx = [Math]::Abs($rc.Left - $x); $dy = [Math]::Abs($rc.Top - $y)
            $dw = [Math]::Abs(($rc.Right - $rc.Left) - $w); $dh = [Math]::Abs(($rc.Bottom - $rc.Top) - $hh)
            if ($dx -gt 4 -or $dy -gt 4 -or $dw -gt 4 -or $dh -gt 4) {
                [void][X4MP.Win]::MoveWindow($item.Handle, $x, $y, $w, $hh, $true)
                if (-not $Quiet) {
                    Write-Host ("[X4MP] pid {0,-6} {1,-8} -> window {2},{3} {4}x{5} ({6})" -f $item.Id, $item.Name, $x, $y, $w, $hh, $Layout)
                }
            }
        }
    }
    return $tagged
}

if ($Watch) {
    if (-not $Quiet) { Write-Host '[X4MP] watching for X4 windows (Ctrl+C or closing both games stops this).' }
    while ($true) {
        $any = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^X4' }
        if (-not $any) { break }
        [void](Set-X4WindowTags)
        Start-Sleep -Seconds $IntervalSeconds
    }
    if (-not $Quiet) { Write-Host '[X4MP] both instances are gone - watcher stops.' }
} else {
    [void](Set-X4WindowTags)
}
