#requires -version 5
<#
    x4mp_fit_halfscreen.ps1 - give two local X4 instances half the screen each (no overlap)

    Why: in windowed mode X4 FORCES its own window width (measured: res_width=960 with 135% display scaling
    显示缩放 135% ⇒ 窗口物理宽度 1296 px，被人为改成 960 后游戏会立刻抢回 1296)。
    so side-by-side placement depends on res_width/res_height in config.xml, not on MoveWindow.
    This script derives a 16:9 render resolution from half the work area and writes it into both profiles
    config.xml (keeping .pre_halfres.bak backups) and prints the placement command that
    x4mp_tag_windows.ps1 can run.

    Usage:
      powershell -ExecutionPolicy Bypass -File x4mp_fit_halfscreen.ps1 -DryRun
          show what would be written, change nothing
      powershell -ExecutionPolicy Bypass -File x4mp_fit_halfscreen.ps1
          actually write (close the game first; effective on next start)
      powershell -ExecutionPolicy Bypass -File x4mp_fit_halfscreen.ps1 -Restore
          restore the resolution from the backup
      powershell -ExecutionPolicy Bypass -File x4mp_fit_halfscreen.ps1 -Scale 1.35
          set display scaling manually (default: auto-detect from the running X4 window, then registry/DPR, then cache)
#>
param(
    [string[]]$Profiles = @('1001','1002'),
    [double]$Scale = 0,
    [switch]$Restore,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$cfgDir = Join-Path $env:USERPROFILE 'Documents\Egosoft\X4'
$cache  = Join-Path $env:TEMP 'X4MP\dpi_factor.txt'

# 16:9 候选(从大到小)，只取 ≤ 半屏的那些
$candidates = @(
    @{W=1920;H=1080}, @{W=1600;H=900}, @{W=1366;H=768}, @{W=1280;H=720},
    @{W=1152;H=648}, @{W=1024;H=576}, @{W=960;H=540}, @{W=854;H=480},
    @{W=800;H=450}, @{W=720;H=405}, @{W=640;H=360}, @{W=512;H=288}
)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace X4MPF { [StructLayout(LayoutKind.Sequential)] public struct R { public int Left, Top, Right, Bottom; }
  public static class W { [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
                         [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint u, out R r, uint f);
                         [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd); } }
'@

function Get-WorkArea {
    $rc = New-Object X4MPF.R
    if ([X4MPF.W]::SystemParametersInfo(0x0030, 0, [ref]$rc, 0)) {
        return @{ X = $rc.Left; Y = $rc.Top; W = ($rc.Right - $rc.Left); H = ($rc.Bottom - $rc.Top) }
    }
    return @{ X = 0; Y = 0; W = 1920; H = 1080 }
}

function Get-CurrentRes([string]$profile) {
    $f = Join-Path $cfgDir "$profile\config.xml"
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $t = [IO.File]::ReadAllText($f)
    $w = [regex]::Match($t, '<res_width>(\d+)</res_width>')
    $h = [regex]::Match($t, '<res_height>(\d+)</res_height>')
    if ($w.Success -and $h.Success) { return @{ W = [int]$w.Groups[1].Value; H = [int]$h.Groups[1].Value; File = $f } }
    return $null
}

function Get-ScaleFactor {
    if ($Scale -gt 0) { return $Scale }
    # 1) 正在运行的 X4 窗口: 物理宽 / 它的 res_width —— 最直接、也最可靠
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^X4' })) {
        try { $p.Refresh() } catch { continue }
        $h = $p.MainWindowHandle
        if (-not $h -or $h -eq [IntPtr]::Zero) { continue }
        $rc = New-Object X4MPF.R
        [void][X4MPF.W]::GetWindowRect($h, [ref]$rc)
        $phys = $rc.Right - $rc.Left
        foreach ($prof in $Profiles) {
            $res = Get-CurrentRes $prof
            if ($res -and $res.W -gt 0 -and $phys -gt 0) {
                $f = [Math]::Round($phys / $res.W, 2)
                if ($f -gt 0.5 -and $f -lt 4) {
                    try { [IO.File]::WriteAllText($cache, "$f", (New-Object Text.ASCIIEncoding)) } catch { }
                    Write-Host ("[X4MP] measured scale factor: {0} (window {1}px / res_width {2})" -f $f, $phys, $res.W)
                    return $f
                }
            }
        }
    }
    # 2) 缓存
    if (Test-Path -LiteralPath $cache) {
        $c = (Get-Content -LiteralPath $cache -Raw).Trim()
        if ($c -match '^\d+(\.\d+)?$') { Write-Host ("[X4MP] using cached scale factor: {0}" -f $c); return [double]$c }
    }
    Write-Host '[X4MP] could not detect the scale factor, assuming 1.0 (pass -Scale 1.35 if the window is still too wide)'
    return 1.0
}


# ---------------------------------------------------------------- 主流程
$wa     = Get-WorkArea
$halfW  = [int]($wa.W / 2)

if ($Restore) {
    foreach ($prof in $Profiles) {
        $f   = Join-Path $cfgDir "$prof\config.xml"
        $bak = "$f.pre_halfres.bak"
        if (Test-Path -LiteralPath $bak) {
            Copy-Item -LiteralPath $bak -Destination $f -Force
            Write-Host ("[X4MP] {0} restored (from .pre_halfres.bak)" -f $f) -ForegroundColor Green
        } else {
            Write-Host ("[X4MP] {0} has no backup, skipped" -f $prof) -ForegroundColor Yellow
        }
    }
    exit 0
}

$factor = Get-ScaleFactor
$pick = $null
foreach ($c in $candidates) {
    $pw = [int]($c.W * $factor); $ph = [int]($c.H * $factor)
    if ($pw -le $halfW -and $ph -le $wa.H) { $pick = $c; break }
}
if (-not $pick) { Write-Host '[X4MP] work area too small, no suitable resolution found' -ForegroundColor Red; exit 1 }
$physW = [int]($pick.W * $factor); $physH = [int]($pick.H * $factor)

Write-Host ("[X4MP] work area {0}x{1} (half width {2}px), scale factor {3}" -f $wa.W, $wa.H, $halfW, $factor)
Write-Host ("[X4MP] target render resolution {0}x{1} => about {2}x{3}px per window, {4}px side by side" -f $pick.W, $pick.H, $physW, $physH, ($physW * 2))

foreach ($prof in $Profiles) {
    $res = Get-CurrentRes $prof
    if (-not $res) { Write-Host ("[X4MP] no config.xml for profile {0}, skipped" -f $prof) -ForegroundColor Yellow; continue }
    if ($res.W -eq $pick.W -and $res.H -eq $pick.H) {
        Write-Host ("[X4MP] profile {0} is already {1}x{2}, nothing to do" -f $prof, $pick.W, $pick.H)
        continue
    }
    if ($DryRun) {
        Write-Host ("[X4MP] (DryRun) would change profile {0} from {1}x{2} to {3}x{4}" -f $prof, $res.W, $res.H, $pick.W, $pick.H) -ForegroundColor Cyan
        continue
    }
    $bak = "$($res.File).pre_halfres.bak"
    if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $res.File -Destination $bak -Force }
    $t = [IO.File]::ReadAllText($res.File)
    $t = [regex]::Replace($t, '<res_width>\d+</res_width>',   "<res_width>$($pick.W)</res_width>")
    $t = [regex]::Replace($t, '<res_height>\d+</res_height>', "<res_height>$($pick.H)</res_height>")
    [IO.File]::WriteAllText($res.File, $t, (New-Object Text.UTF8Encoding($false)))
    Write-Host ("[X4MP] profile {0}: {1}x{2} -> {3}x{4} (backup .pre_halfres.bak)" -f $prof, $res.W, $res.H, $pick.W, $pick.H) -ForegroundColor Green
}

Write-Host ''
Write-Host 'Next: close the game and start both instances again;'
Write-Host '        x4mp_tag_windows.ps1 -Layout leftright places the windows left (host) / right (client).'
Write-Host '(X4 window width = res_width x display scaling, so it must be changed in config.xml; MoveWindow gets reverted by the game.)'
