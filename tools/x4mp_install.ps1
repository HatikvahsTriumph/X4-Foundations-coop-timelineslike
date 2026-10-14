#requires -version 5
<#
    x4mp_install.ps1 - X4MP co-op pack: one-click install / uninstall

    You normally never type this by hand: just double-click 1-INSTALL.bat in the pack (it calls this script).

    Manual usage:
      powershell -ExecutionPolicy Bypass -File x4mp_install.ps1                         # interactive menu
      powershell -ExecutionPolicy Bypass -File x4mp_install.ps1 -Role host
      powershell -ExecutionPolicy Bypass -File x4mp_install.ps1 -Role client -HostIp 26.0.0.5
      powershell -ExecutionPolicy Bypass -File x4mp_install.ps1 -Uninstall

    It does four things:
      1. Locate the X4 Foundations install folder (registry -> libraryfolders.vdf -> common paths -> manual input)
      2. Copy files\extensions\{x4native,x4mp_native,x4mp_test} into it (old same-named folders are backed up first)
      3. Write %TEMP%\X4MP\config.txt: mode=host / mode=client plus the host address
      4. Host: add an inbound UDP 42069 firewall rule; both sides: verify file SHA-256 against the manifest
#>
param(
    [ValidateSet('menu','host','client')] [string]$Role = 'menu',
    [string]$HostIp = '',
    [string]$X4Dir = '',          # explicitly set the game folder (fallback when autodetection fails)
    [switch]$DryRun,              # check only (find paths / report state); copy nothing, write no config
    [switch]$Uninstall,
    [switch]$NoFirewall,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$script:Root        = Split-Path -Parent $PSScriptRoot          # pack root folder

# 2026-09-29 (0.1, verified by users) Opening guard: validate the pack and its location BEFORE any file operation
# Why first: the old order copied first and checked the pack later, so an incomplete pack or a wrong
# 报错会出现在拷贝中途(Get-ChildItem: Cannot find path …files\extensions\x4native)，
# that hid the real cause. These two checks turn the common mistakes into one plain sentence.
$script:StageExtChk = Join-Path $script:Root 'files\extensions'
if (-not (Test-Path -LiteralPath $script:StageExtChk)) {
    Write-Host ''
    Write-Host '  [X] This pack is incomplete: files\extensions\ not found' -ForegroundColor Red
    Write-Host ('      Expected location: {0}' -f $script:StageExtChk) -ForegroundColor DarkGray
    Write-Host '      Common cause: the archive was only partly extracted, or its files were dragged out one by one.' -ForegroundColor Yellow
    Write-Host '      Correct: extract the WHOLE X4MP-0.1.1.zip into an empty folder, then run this installer.' -ForegroundColor Yellow
    Write-Host ''
    Read-Host '  Press Enter to exit'
    exit 1
}

# 是否被解压进了Game folder？(本安装在 <X4>\extensions\ 里，或它的上一级有 X4.exe)
$parentOfRoot = Split-Path -Parent $script:Root
$looksInsideGame = ((Split-Path -Leaf $script:Root) -ieq 'extensions') -or
                   (Test-Path -LiteralPath (Join-Path $parentOfRoot 'X4.exe')) -or
                   (Test-Path -LiteralPath (Join-Path (Join-Path $parentOfRoot '..') 'X4.exe'))
if ($looksInsideGame) {
    Write-Host ''
    Write-Host '  [X] You extracted this pack INSIDE the game folder.' -ForegroundColor Red
    Write-Host ('      Current pack root: {0}' -f $script:Root) -ForegroundColor DarkGray
    Write-Host '      The installer would then treat the game''s own extensions\ as the pack folder and can never find the files to install.' -ForegroundColor Yellow
    Write-Host '      Correct procedure (two steps):' -ForegroundColor Yellow
    Write-Host '        1) Extract the archive OUTSIDE the game folder, e.g. D:\X4MP\ or the Desktop;' -ForegroundColor Yellow
    Write-Host '        2) In that folder double-click 1-INSTALL.bat (it locates the game folder itself and asks if it cannot).' -ForegroundColor Yellow
    Write-Host '      Cleanup: delete these items that were put into the game''s extensions\ by mistake:' -ForegroundColor DarkGray
    Write-Host '        1-INSTALL.bat / 2-PLAY.bat / 3-UNINSTALL.bat / files\ / tools\ and the extracted folder itself' -ForegroundColor DarkGray
    Write-Host ''
    Read-Host '  Press Enter to exit'
    exit 1
}

$script:StageExt    = Join-Path $script:Root 'files\extensions'
$script:Port        = 42069
$script:X4DirParam  = $X4Dir
$script:ExtNames    = @('x4native','x4mp_native','x4mp_test')
# 2026-10-13 移植（v1.2 审查 P2）：旧正则 ^\d{1,3}(\.\d{1,3}){3}$ 会把 999.999.999.999
# 当成合法 IP 收下，写进 config.txt 后表现为"地址填了却连不上"。这里收紧到每段 0-255。
$script:IPv4Re      = '^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$'

function Say([string]$msg, [string]$color = 'Gray') {
    if (-not $Quiet) { Write-Host $msg -ForegroundColor $color }
}
function Head([string]$msg) {
    Write-Host ''
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host ('=' * 66) -ForegroundColor DarkCyan
}

# --------------------------------------------------------------- locate the game folder
function Join-Safe([string]$base, [string]$child) {
    # [IO.Path]::Combine is PURELY LEXICAL: unlike Join-Path it never touches the
    # file system, so a drive that is registered but not mounted (a Steam library on
    # an offline disk) cannot make it throw. Join-Path does throw
    # ("Cannot find drive. A drive with the name 'F' does not exist.") and that is
    # exactly how the first host run of this installer died before it could even ask
    # for the path by hand. Every path built during the search goes through here.
    if ([string]::IsNullOrWhiteSpace($base)) { return $null }
    return [IO.Path]::Combine($base.Trim().Trim('"'), $child)
}

function Test-X4Exe([string]$dir) {
    if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
    $p = Join-Safe $dir 'X4.exe'
    if (-not $p) { return $false }
    try { return (Test-Path -LiteralPath $p -ErrorAction Stop) } catch { return $false }
}

function Get-SteamLibraries {
    $libs = New-Object System.Collections.Generic.List[string]
    $steam = $null
    foreach ($k in @('HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $p = Get-ItemProperty -Path $k -ErrorAction Stop
            foreach ($f in @('SteamPath','InstallPath')) {
                if ($p.$f) { $steam = $p.$f; break }
            }
        } catch { }
        if ($steam) { break }
    }
    if ($steam) {
        $libs.Add($steam)
        $vdf = Join-Safe $steam 'steamapps\libraryfolders.vdf'
        try {
            if ($vdf -and (Test-Path -LiteralPath $vdf -ErrorAction Stop)) {
                foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
                    $libs.Add(($m.Groups[1].Value -replace '\\\\', '\'))
                }
            }
        } catch { }
    }
    return ($libs | Where-Object { $_ } | Select-Object -Unique)
}

function Find-X4 {
    if (Test-X4Exe $env:X4DIR) { return $env:X4DIR }
    if (Test-X4Exe $script:X4DirParam) { return $script:X4DirParam }

    $cand = New-Object System.Collections.Generic.List[string]
    foreach ($lib in Get-SteamLibraries) {
        $c = Join-Safe $lib 'steamapps\common\X4 Foundations'
        if ($c) { $cand.Add($c) }
    }
    # Only drives that are actually mounted right now - a missing drive must never be
    # able to stop the search (see Join-Safe above).
    $drives = @()
    try {
        $drives = [IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady } | ForEach-Object { $_.Name.TrimEnd('\') }
    } catch { $drives = @('C:','D:','E:') }
    foreach ($drv in $drives) {
        foreach ($sub in @('SteamLibrary\steamapps\common\X4 Foundations',
                           'Steam\steamapps\common\X4 Foundations',
                           'SteamLibrary\steamapps\common\X4 Foundations',
                           'Program Files (x86)\Steam\steamapps\common\X4 Foundations',
                           'Games\X4 Foundations',
                           'X4 Foundations')) {
            $c = Join-Safe $drv $sub
            if ($c) { $cand.Add($c) }
        }
    }

    foreach ($c in ($cand | Select-Object -Unique)) {
        if (Test-X4Exe $c) { Say ("  found the game folder automatically: {0}" -f $c) 'Gray'; return $c }
    }
    return $null
}

function Ask-X4 {
    while ($true) {
        Write-Host ''
        Write-Host '  X4 Foundations was not found automatically. Paste the game install folder (the level containing X4.exe), e.g.:' -ForegroundColor Yellow
        Write-Host '      D:\SteamLibrary\steamapps\common\X4 Foundations' -ForegroundColor DarkGray
        Write-Host '  (You can copy the path from Explorer''s address bar and paste it here with Ctrl+V.)' -ForegroundColor DarkGray
        $p = (Read-Host '  Game folder').Trim().Trim('"')
        if (Test-X4Exe $p) { return $p }
        Write-Host '  No X4.exe in that folder, please try again.' -ForegroundColor Red
    }
}

function Confirm-GameClosed([string]$x4) {
    $run = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'X4*' }
    if ($run) {
        Write-Host ''
        Write-Host '  [!] X4 is running - close the game before install/uninstall (a locked DLL makes the copy fail).' -ForegroundColor Red
        $ans = Read-Host '  Closed now? type y to continue, any other key to quit'
        if ($ans -notmatch '^[yY]') { exit 1 }
    }
}


# --------------------------------------------------------------- install / uninstall
# 2026-09-28 (run #26): the backup folder MUST live at the <X4> root (next to X4.exe),
# 不能放在 extensions\ 里面。
# 原因(实测踩坑): X4 会扫描 extensions\ 下的**每一个**扩展目录(不认 "_" 前缀)，
# 所以 extensions\_x4mp_backup_* 里的旧副本会被**当成第二个扩展一起加载**: 
# two extensions with the same id - which one wins depends on load order and may differ per machine.
# That is what the 2026-09-27 cross-machine test showed: host 3 sectors, client 2 (two different worlds),
# connected and clock-synced, yet never seeing each other ships.
function Move-StaleExtensionCopies([string]$x4) {
    $extRoot = Join-Path $x4 'extensions'
    if (-not (Test-Path -LiteralPath $extRoot)) { return }
    $mine  = @('x4mp_test', 'x4mp_native', 'x4native')
    $stale = @()
    foreach ($d in (Get-ChildItem -LiteralPath $extRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($script:ExtNames -contains $d.Name) { continue }        # a real install folder, skipped
        $hit = $false
        if ($d.Name -like '_x4mp_backup_*' -or $d.Name -like '_x4mp_removed_*') { $hit = $true }
        else {
            # also catches stale copies that were renamed but still carry our id in content.xml
            $c = Join-Path $d.FullName 'content.xml'
            if (Test-Path -LiteralPath $c) {
                $t = Get-Content -LiteralPath $c -Raw -ErrorAction SilentlyContinue
                foreach ($id in $mine) { if ($t -match ('id\s*=\s*"' + $id + '"')) { $hit = $true; break } }
            }
        }
        if ($hit) { $stale += $d }
    }
    if (-not $stale.Count) { return }
    # ★2026-10-14: 单一固定目录（原来按时间戳新建 ⇒ 每跑一次多一个目录）
    $dst = Join-Path $x4 '_x4mp_stale'
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    foreach ($d in $stale) {
        Move-Item -LiteralPath $d.FullName -Destination (Join-Path $dst $d.Name) -Force -ErrorAction SilentlyContinue
    }
    Say ("  [!] extensions\ 里有 {0} 个会被 X4 一起加载的旧副本/备份，已移出到: {1}" -f $stale.Count, $dst) 'Yellow'
    Say '      (X4 loads every extension folder under extensions\; a stale copy with the same id makes the two worlds disagree)' 'DarkGray'
}

# ★2026-10-14 重做备份策略（用户反馈：开一次联机就多一个 backup 文件夹 ✗）：
#   旧代码每次运行都建 <X4>\_x4mp_backup_<时间戳>\ —— 而 Porthole 式启动器每次开局都会
#   再跑一遍这个安装器 ⇒ 游戏目录里按次堆积一堆内容完全相同的备份。
#   现在的规则只有两条：
#     1) 已装版本与本包**逐文件同构** ⇒ 根本不需要备份（什么都不建）；
#     2) 确实要覆盖别人的旧版本 ⇒ 只保留**唯一一个**固定名备份目录 <X4>\_x4mp_backup\<ext>\
#        （覆盖式，不追加）。想还原就把它拷回 extensions\ 即可。
function Get-DirSignature([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return '' }
    $parts = Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue |
             Sort-Object FullName |
             ForEach-Object { $_.FullName.Substring($dir.Length).TrimStart('\') + '|' + $_.Length }
    return ($parts -join "`n")
}

function Backup-Existing([string]$x4) {
    $extRoot = Join-Path $x4 'extensions'

    # 1) 装的就是这一版 ⇒ 没有“旧东西”值得留
    $same = $true
    $any  = $false
    foreach ($n in $script:ExtNames) {
        $cur = Join-Path $extRoot $n
        if (-not (Test-Path -LiteralPath $cur)) { continue }
        $any = $true
        if ((Get-DirSignature $cur) -ne (Get-DirSignature (Join-Path $script:StageExt $n))) { $same = $false; break }
    }
    if ($any -and $same) {
        Say '  [OK] the installed build is identical to this pack - no backup needed' 'Green'
        return
    }

    # 2) 否则：单一备份目录，覆盖式
    #    ★仍然放在 <X4> 根目录（与 X4.exe 同级），**不在** extensions\ 里面 —— 见 Move-StaleExtensionCopies
    $bkRoot = Join-Path $x4 '_x4mp_backup'
    $moved  = @()
    foreach ($n in $script:ExtNames) {
        $p = Join-Path $extRoot $n
        if (Test-Path -LiteralPath $p) {
            New-Item -ItemType Directory -Force -Path $bkRoot | Out-Null
            $t = Join-Path $bkRoot $n
            if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath $p -Destination $t -Force
            $moved += $n
        }
    }
    if ($moved.Count) {
        Say ("  moved the previous extensions to the single backup folder: {0}" -f $bkRoot) 'Yellow'
        Say ("     (contains: {0} - replaced on the next install, delete it whenever you like)" -f ($moved -join ', ')) 'DarkGray'
    }
}

# ★2026-10-14：把老版本安装器按次留下的备份目录折进一个地方，别再让游戏根目录越开越多。
# 只移动，不删除 —— 确认没用后你可以整个删掉 <X4>\_x4mp_backup\_legacy\。
function Cleanup-LegacyBackups([string]$x4) {
    $legacy = Get-ChildItem -LiteralPath $x4 -Directory -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match '^_x4mp_(backup|removed|backups_moved)_\d{8}_\d{6}$' }
    if (-not $legacy) { return }
    $dst = Join-Path $x4 '_x4mp_backup\_legacy'
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    foreach ($d in $legacy) {
        $t = Join-Path $dst $d.Name
        if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $d.FullName -Destination $t -Force -ErrorAction SilentlyContinue
    }
    Say ("  [!] folded {0} old per-run backup folder(s) from earlier installers into: {1}" -f @($legacy).Count, $dst) 'Yellow'
    Say '      (nothing was deleted - you can remove that whole folder yourself)' 'DarkGray'
}

function Install-Files([string]$x4) {
    $extRoot = Join-Path $x4 'extensions'
    New-Item -ItemType Directory -Force -Path $extRoot | Out-Null
    Move-StaleExtensionCopies $x4      # ★run #26: first move stale copies/backups out of extensions\
    Cleanup-LegacyBackups $x4          # ★2026-10-14: fold old per-run backup folders into one place
    Backup-Existing $x4
    foreach ($n in $script:ExtNames) {
        $src = Join-Path $script:StageExt $n
        $dst = Join-Path $extRoot $n
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Get-ChildItem -Recurse -File -LiteralPath $src | ForEach-Object {
            $rel = $_.FullName.Substring($src.Length).TrimStart('\')
            $t   = Join-Path $dst $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $t) | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $t -Force
        }
        Say ("  [OK] {0}" -f $n) 'Green'
    }
}

function Remove-Files([string]$x4) {
    $extRoot = Join-Path $x4 'extensions'
    # ★run #26: 同样放到 <X4> 根目录，不放 extensions\(见 Move-StaleExtensionCopies)
    # ★2026-10-14: 固定名（原来带时间戳 ⇒ 每次卸载都多一个目录）
    $bkRoot  = Join-Path $x4 '_x4mp_removed'
    Move-StaleExtensionCopies $x4
    Cleanup-LegacyBackups $x4
    foreach ($n in $script:ExtNames) {
        $p = Join-Path $extRoot $n
        if (Test-Path -LiteralPath $p) {
            New-Item -ItemType Directory -Force -Path $bkRoot | Out-Null
            $t = Join-Path $bkRoot $n
            if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath $p -Destination $t -Force
            Say ("  [OK] removed {0}" -f $n) 'Green'
        }
    }
    $cfg = Join-Path $env:TEMP 'X4MP\config.txt'
    if (Test-Path -LiteralPath $cfg) { Remove-Item -LiteralPath $cfg -Force; Say '  [OK] deleted %TEMP%\X4MP\config.txt' 'Green' }
    try {
        Get-NetFirewallRule -DisplayName 'X4MP UDP 42069' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        Say '  [OK] removed the firewall rule (if present)' 'Green'
    } catch { }
    if (Test-Path -LiteralPath $bkRoot) { Say ("  backup is at: {0}" -f $bkRoot) 'DarkGray' }
}

# --------------------------------------------------------------- role and config
function Ask-Role {
    if ($Role -ne 'menu') { return $Role }
    while ($true) {
        Write-Host ''
        Write-Host '  Is this machine the HOST or the CLIENT?' -ForegroundColor White
        Write-Host '    [1] I am the host   - the world is created here, friends connect to me' -ForegroundColor Gray
        Write-Host '    [2] I am the client - I will enter the host''s VPN address' -ForegroundColor Gray
        switch ((Read-Host '  Enter 1 or 2').Trim()) {
            '1' { return 'host' }
            '2' { return 'client' }
            default { Write-Host '  Please enter 1 or 2.' -ForegroundColor Red }
        }
    }
}

function Ask-HostIp {
    # 2026-10-13 移植（v1.2 审查）：原来的 while($true) 没有任何出口 —— 只按回车会一直
    # 空转（脚本卡死，用户以为"装完了"）；现在 q 或空输入明确退出，并提示合法格式。
    if ($HostIp) {
        if ($HostIp -match $script:IPv4Re) { return $HostIp }
        Write-Host ("  The IP given as a parameter looks wrong: {0}" -f $HostIp) -ForegroundColor Red
    }
    while ($true) {
        Write-Host ''
        Write-Host '  Enter the HOST''s IPv4 address inside the virtual LAN (NOT 127.0.0.1)' -ForegroundColor Yellow
        Write-Host '  e.g. Radmin VPN is usually 26.x.x.x, ZeroTier usually 10.147.x.x / 172.x.x.x' -ForegroundColor DarkGray
        Write-Host '  Type q and press Enter to cancel.' -ForegroundColor DarkGray
        $ip = (Read-Host '  Host IP').Trim()
        if ($ip -eq 'q' -or $ip -eq 'Q' -or [string]::IsNullOrWhiteSpace($ip)) {
            Write-Host '  Cancelled - no host IP given.' -ForegroundColor Red
            exit 1
        }
        if ($ip -match $script:IPv4Re) { return $ip }
        Write-Host '  Bad format - expected x.x.x.x, each part 0-255.' -ForegroundColor Red
    }
}

function Write-X4mpConfig([string]$role, [string]$ip) {
    $dir = Join-Path $env:TEMP 'X4MP'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $cfg  = Join-Path $dir 'config.txt'
    $body = @("mode=$role", "address=$ip", "port=$script:Port")
    [IO.File]::WriteAllText($cfg, (($body -join "`r`n") + "`r`n"), (New-Object Text.ASCIIEncoding))
    Say ("  [OK] config written: {0}" -f $cfg) 'Green'
    Say ("      mode={0}  address={1}  port={2}" -f $role, $ip, $script:Port) 'DarkGray'
}

function Add-FwRule {
    if ($NoFirewall) { return }
    $name = 'X4MP UDP 42069'
    try {
        if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol UDP `
                -LocalPort $script:Port -Action Allow -Profile Any -ErrorAction Stop | Out-Null
            Say "  [OK] inbound UDP $($script:Port) allowed (required for the host)" 'Green'
        } else {
            Say "  [OK] firewall rule already present (UDP $($script:Port))" 'Green'
        }
    } catch {
        Say '  [!] Could not add the firewall rule automatically (needs administrator). Add it manually:' 'Yellow'
        Say '     Control Panel -> Windows Defender Firewall -> Advanced settings -> Inbound Rules -> New Rule' 'Yellow'
        Say "     -> Port -> UDP -> Specific local port $($script:Port) -> Allow the connection -> tick all -> name it X4MP" 'Yellow'
        Say '     Or run this in an ADMIN PowerShell:' 'Yellow'
        Say "     netsh advfirewall firewall add rule name=`"X4MP UDP 42069`" dir=in action=allow protocol=UDP localport=$($script:Port)" 'DarkGray'
    }
}


# --------------------------------------------------------------- manifest verification
function Verify-Install([string]$x4) {
    $manifest = Join-Path $script:Root 'tools\manifest.txt'
    if (-not (Test-Path -LiteralPath $manifest)) { Say '  (the pack has no manifest.txt - skipping the check)' 'DarkGray'; return $true }
    $bad = 0; $n = 0
    foreach ($line in Get-Content -LiteralPath $manifest) {
        if ($line -notmatch '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') { continue }
        $want = $Matches[1].ToLower()
        $rel  = $Matches[2].Trim()
        if ($rel -notlike 'files\extensions\*') { continue }
        $target = Join-Path $x4 $rel.Substring('files\'.Length)
        $n++
        if (-not (Test-Path -LiteralPath $target)) { Write-Host ("  [X] missing {0}" -f $rel) -ForegroundColor Red; $bad++; continue }
        $got = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLower()
        if ($got -ne $want) { Write-Host ("  [X] content mismatch {0}" -f $rel) -ForegroundColor Red; $bad++ }
    }
    $color = if ($bad) { 'Red' } else { 'Green' }
    Say ("  verified {0} files, {1} mismatches" -f $n, $bad) $color
    return ($bad -eq 0)
}

# --------------------------------------------------------------- main flow
Head 'X4MP co-op pack - install / uninstall'

if (-not (Test-Path -LiteralPath $script:StageExt)) {
    Write-Host ("  [X] files\extensions not found inside the pack (partly extracted?): {0}" -f $script:StageExt) -ForegroundColor Red
    Write-Host '  Please extract the entire archive before running this.' -ForegroundColor Red
    exit 1
}

$x4 = $null
try { $x4 = Find-X4 } catch { Say ("  [!] Error while autodetecting the game folder, switching to manual input: {0}" -f $_.Exception.Message) 'Yellow' }
if (-not $x4) { $x4 = Ask-X4 }
if (-not (Test-Path -LiteralPath (Join-Path $x4 'X4.exe'))) { Write-Host '  [X] no X4.exe in that folder.' -ForegroundColor Red; exit 1 }

Head ("Game folder: " + $x4)
$exeVer = (Get-Item -LiteralPath (Join-Path $x4 'X4.exe')).VersionInfo.FileVersion
Say ("  X4.exe version detected: {0}" -f $exeVer) 'Gray'
Say '  [!] Requirement: you and your friend must run the same version (Steam updates automatically - keep both sides current)' 'Yellow'

Confirm-GameClosed $x4

if ($DryRun) {
    Head 'check only (DryRun): no copying, no config, no firewall changes'
    Say ("  Game folder: {0}" -f $x4) 'Green'
    foreach ($n in $script:ExtNames) {
        $p = Join-Path (Join-Path $x4 'extensions') $n
        if (Test-Path -LiteralPath $p) {
            $dll = Join-Path $p 'native\x4mp_native.dll'
            if (Test-Path -LiteralPath $dll) {
                Say ("  present: {0} (x4mp_native.dll {1} B, {2})" -f $n, (Get-Item $dll).Length, (Get-Item $dll).LastWriteTime.ToString('yyyy-MM-dd HH:mm')) 'Gray'
            } else {
                Say ("  present: {0}" -f $n) 'Gray'
            }
        } else {
            Say ("  not installed: {0}" -f $n) 'Yellow'
        }
    }
    $cfg = Join-Path $env:TEMP 'X4MP\config.txt'
    if (Test-Path -LiteralPath $cfg) { Say ("  current role config: {0}" -f ((Get-Content -LiteralPath $cfg) -join ' | ')) 'Gray' }
    else { Say '  current role config: none (the game starts as host by default, address 127.0.0.1)' 'Yellow' }
    $okB = Verify-Install $x4
    Say ''
    Say '  This was check mode; nothing changed. To really install, double-click 1-INSTALL.bat (or drop -DryRun).' 'White'
    exit 0
}

if ($Uninstall) {
    Head 'uninstall: move the extensions out + delete the role config'
    Remove-Files $x4
    Say ''
    Say '  Uninstall complete (the old files are under <X4>\_x4mp_removed\; you may delete that folder).' 'Yellow'
    exit 0
}

$role = Ask-Role
$ip   = '127.0.0.1'
if ($role -eq 'client') { $ip = Ask-HostIp }

Head 'Step 1 of 3: copy the extensions'
Install-Files $x4

Head 'Step 2 of 3: write the co-op role config'
Write-X4mpConfig $role $ip
if ($role -eq 'host') { Add-FwRule } else { Say '  (the client does not need an open firewall port)' 'DarkGray' }

Head 'Step 3 of 3: verify against the manifest (SHA-256)'
$ok = Verify-Install $x4

Head 'What to do next'
if ($role -eq 'host') {
    Say '  1) Tell your friend YOUR VPN address (visible in the Radmin VPN / ZeroTier client)' 'White'
    Say '  2) Double-click 2-PLAY.bat to start the game (or launch it from Steam as usual)' 'White'
    Say '  3) Main menu -> New Game -> pick a world; BOTH sides must pick the SAME one:' 'White'
    Say '       · X4MP Blank Universe   blank universe: 20 Argon M ships + 1 Xenon K' 'Gray'
    Say '       · X4MP Station World    station world: 3 stations with attack synchronisation' 'Gray'
    Say '  4) Confirm the link: the window title shows [HOST]; the log shows hosting on port 42069 -> peer connected' 'Gray'
} else {
    Say ("  1) Configured as client: connecting to {0}:42069" -f $ip) 'White'
    Say '  2) Double-click 2-PLAY.bat to start the game (or launch it from Steam as usual)' 'White'
    Say '  3) Main menu -> New Game -> pick a world; both sides must pick the SAME one' 'White'
    Say '  4) Confirm the link: the window title shows [CLIENT]; the log should show connecting to <hostIP>:42069 -> peer connected' 'Gray'
}
Say ''
Say '  Log location (replace <number> with your own profile folder):' 'DarkGray'
Say '     %USERPROFILE%\Documents\Egosoft\X4\<数字>\x4native\x4mp_native\x4mp_native.log' 'DarkGray'
Say '  If peer connected never appears, check in order: 1) the host firewall allows UDP 42069  2) both sides are online on the same virtual LAN and can ping each other  3) the address is wrong' 'DarkGray'
if (-not $ok) {
    Say ''
    Say '  [!] Verification did not fully pass - please send the lines marked [X]. Usual causes: installing while the game was running (files locked), or antivirus interference.' 'Red'
}
Say ''
