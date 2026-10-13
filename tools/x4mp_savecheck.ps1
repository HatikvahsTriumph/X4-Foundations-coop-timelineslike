#requires -version 5
<#
    x4mp_savecheck.ps1 - offline health check of an X4 save (built for X4MP station / fleet acceptance)

    为什么要它：本工程的每次重要验收都靠存档取证（doc 4 §8.1 的判据就是"两端
    `class="turret"` = 0"），而手工解压 + 数 class 每次都要花十几分钟。这个脚本
    把那份工作变成一条命令。

    用法（在 F5 存完档之后）：
        powershell -ExecutionPolicy Bypass -File x4mp_savecheck.ps1
            自动找最新的一份 quicksave/autosave/save_*.xml.gz

        powershell -ExecutionPolicy Bypass -File x4mp_savecheck.ps1 -Save "<路径>"
            指定存档

        powershell -ExecutionPolicy Bypass -File x4mp_savecheck.ps1 -Full
            额外打印"受损对象"的上下文（默认只打计数与命中行）

    读什么：
      1. class 计数：station / defencemodule / dockarea / pier / turret /
         shieldgenerator / engine / buildstorage / production / storage / cargobay
      2. 炮塔按宏分类计数（S3 补装是否真的插上了炮塔，看这一节）
      3. 所有名字里带 X4MP 的对象（我们的站：X4MP STN 1/2/3）
      4. 有 <hull> 记录的对象（受损 = 真的掉血；满血不写 hull）
#>
param(
    [string]$Save = '',
    [switch]$Full
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression

function Find-Save {
    if ($Save) { return $Save }
    $roots = @()
    $base = Join-Path $env:USERPROFILE 'Documents\Egosoft\X4'
    if (Test-Path -LiteralPath $base) {
        foreach ($d in Get-ChildItem -LiteralPath $base -Directory) {
            $s = Join-Path $d.FullName 'save'
            if (Test-Path -LiteralPath $s) { $roots += $s }
        }
    }
    $all = @()
    foreach ($r in $roots) {
        foreach ($f in Get-ChildItem -LiteralPath $r -File -ErrorAction SilentlyContinue) {
            if ($f.Name -notmatch '\.xml(\.gz)?$') { continue }
            if ($f.Name -match 'steam_autocloud') { continue }
            $all += $f
        }
    }
    if (-not $all.Count) { throw 'No save file found. Press F5 in game once, or pass -Save <path>.' }
    # X4MP 的测试世界存档很小（几百 KB），正常宇宙存档几十 MB ⇒ 自动挑"最新的小档"，
    # 这样在测试世界的流程里直接跑本脚本就是想要的那一份。
    $small = $all | Where-Object { $_.Length -lt 5MB } | Sort-Object LastWriteTime -Descending
    $best  = if ($small.Count) { $small[0] } else { ($all | Sort-Object LastWriteTime -Descending)[0] }
    return $best.FullName
}

function Read-SaveText([string]$path) {
    if ($path -match '\.gz$') {
        $fs = [IO.File]::OpenRead($path)
        $gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Decompress)
        $sr = New-Object IO.StreamReader($gz, [Text.Encoding]::UTF8)
        $t  = $sr.ReadToEnd()
        $sr.Dispose(); $gz.Dispose(); $fs.Dispose()
        return $t
    }
    return [IO.File]::ReadAllText($path)
}

$path = Find-Save
$info = Get-Item -LiteralPath $path
Write-Host ''
Write-Host ('=' * 74) -ForegroundColor DarkCyan
Write-Host ("  Save health check: {0}" -f $info.FullName) -ForegroundColor Cyan
Write-Host ("  Size {0:N0} KB   time {1}" -f ($info.Length / 1KB), $info.LastWriteTime) -ForegroundColor DarkGray
Write-Host ('=' * 74) -ForegroundColor DarkCyan

$t = Read-SaveText $path
Write-Host ("  Uncompressed length: {0:N0} characters" -f $t.Length) -ForegroundColor DarkGray

# ---- 1) class 计数 -----------------------------------------------------------
$classes = 'station','defencemodule','dockarea','pier','turret','shieldgenerator','engine',
           'buildstorage','buildmodule','production','storage','cargobay','dockingbay','module',
           'signalleak','ship_s','ship_m','ship_l','ship_xl'
Write-Host ''
Write-Host '  [1] class counts' -ForegroundColor White
foreach ($c in $classes) {
    $n = ([regex]::Matches($t, ('class="' + [regex]::Escape($c) + '"'))).Count
    if ($n -gt 0) {
        $color = if ($c -eq 'turret') { 'Yellow' } else { 'Gray' }
        Write-Host ("      {0,-16} {1,7}" -f $c, $n) -ForegroundColor $color
    }
}

# ---- 2) 炮塔按宏分类（S3 验收核心）------------------------------------------
Write-Host ''
Write-Host '  [2] turrets by macro (S3: after refitting a directly-built station this MUST be > 0)' -ForegroundColor White
$turrets = @{}
foreach ($m in [regex]::Matches($t, '<component[^>]*class="turret"[^>]*>')) {
    $mac = if ($m.Value -match 'macro="([^"]+)"') { $matches[1] } else { '?' }
    if (-not $turrets.ContainsKey($mac)) { $turrets[$mac] = 0 }
    $turrets[$mac]++
}
if ($turrets.Count -eq 0) {
    Write-Host '      (no turrets at all => the station refit did not take effect)' -ForegroundColor Red
} else {
    foreach ($k in ($turrets.Keys | Sort-Object { -$turrets[$_] })) {
        Write-Host ("      {0,5} × {1}" -f $turrets[$k], $k) -ForegroundColor Gray
    }
}

# ---- 3) 名字里带 X4MP 的对象 -------------------------------------------------
Write-Host ''
Write-Host '  [3] X4MP objects (our stations / fleets)' -ForegroundColor White
$hits = [regex]::Matches($t, '"X4MP [^"]*"')
if ($hits.Count -eq 0) {
    Write-Host '      (no X4MP objects in this save)' -ForegroundColor Yellow
} else {
    $names = @{}
    foreach ($h in $hits) { $names[$h.Value] = 1 + ($names[$h.Value] -as [int]) }
    foreach ($k in ($names.Keys | Sort-Object)) {
        Write-Host ("      {0,-34} × {1}" -f $k, $names[$k]) -ForegroundColor Gray
    }
}

# ---- 4) 受损对象（<hull> 只对受损/施工中的对象写）----------------------------
Write-Host ''
Write-Host '  [4] damaged objects (an undamaged object writes no <hull>)' -ForegroundColor White
$hull = [regex]::Matches($t, '<hull[^>]*value="[^"]+"[^>]*/?>')
Write-Host ("      <hull> records: {0}" -f $hull.Count) -ForegroundColor Gray
$shown = 0
$seen = @{}
foreach ($h in $hull) {
    # 归属：往前找最近的 class=" / macro="（存档里属性在 <hull> 之前），窗口放宽到 4 KB
    $cls = '?'; $mac = '?'
    $ci = $t.LastIndexOf('class="', $h.Index)
    if ($ci -ge 0 -and ($h.Index - $ci) -lt 4000) {
        $seg = $t.Substring($ci)
        if ($seg -match '^class="([a-z_]+)"') { $cls = $matches[1] }
    }
    $mi = $t.LastIndexOf('macro="', $h.Index)
    if ($mi -ge 0 -and ($h.Index - $mi) -lt 4000) {
        $seg2 = $t.Substring($mi)
        if ($seg2 -match '^macro="([^"]+)"') { $mac = $matches[1] }
    }
    $val = if ($h.Value -match 'value="([^"]+)"') { $matches[1] } else { '?' }
    $key = "$cls|$mac|$val"
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = 1
    if ($Full -or $shown -lt 12) {
        Write-Host ("      value={0,-8} class={1,-16} macro={2}" -f $val, $cls, $mac) -ForegroundColor Gray
    }
    $shown++
}
if ($shown -gt 12 -and -not $Full) {
    Write-Host ("      ({0} classes in total; use -Full for all)" -f $shown) -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  [5] X4MP global variables (MD-side evidence: refit chain counters etc.)' -ForegroundColor White
$gv = [regex]::Matches($t, 'name="[\$]?(X4MP[A-Za-z0-9_]*)"[^>]*?value="([^"]*)"')
if ($gv.Count -eq 0) {
    Write-Host '      (no X4MP global variables in this save)' -ForegroundColor Yellow
} else {
    $rows = @{}
    foreach ($m in $gv) { $rows[$m.Groups[1].Value] = $m.Groups[2].Value }
    foreach ($k in ($rows.Keys | Sort-Object)) {
        $color = if ($k -match '^X4MPEq') { 'Yellow' } else { 'Gray' }
        Write-Host ("      {0,-26} = {1}" -f $k, $rows[$k]) -ForegroundColor $color
    }
}

Write-Host ''
Write-Host '  [6] turret lastshottime: did the station really fire back' -ForegroundColor White
$lt = @()
foreach ($m in [regex]::Matches($t, '<component class="turret"[^>]*>')) {
    if ($m.Value -match 'lastshottime="([0-9.]+)"') { $lt += [double]$matches[1] }
}
if ($lt.Count -eq 0) {
    Write-Host '      (no turret carries a lastshottime)' -ForegroundColor Yellow
} else {
    $u = $lt | Select-Object -Unique
    Write-Host ("      turrets with lastshottime: {0}; distinct values: {1}; min={2} max={3}" -f $lt.Count, $u.Count, ($lt | Measure-Object -Minimum).Minimum, ($lt | Measure-Object -Maximum).Maximum) -ForegroundColor Gray
    Write-Host '      · all equal to one value (about the refit moment) => a build artefact, not fire' -ForegroundColor DarkGray
    Write-Host '      · a value later than the refit (e.g. t=99 when you attacked) => the station fired back' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  [7] drone ownership (route B acceptance: every station should be 0)' -ForegroundColor White
$droneMacros = [ordered]@{
    'fightingdrone' = 'fight / defence'
    'cargodrone'    = 'cargo'
    'repairdrone'   = 'repair'
    'buildingdrone' = 'construction'
    'miningdrone'   = 'mining'
    'transdrone'    = 'transport'
}
$anyDrone = $false

# (a) 按站归属：只有把无人机挂到"哪座站"上，才回答得了"为什么还有一座站有无人机"。
#     存档里站是 <component class="station">，无人机是它机库(dockingbay)下面的
#     <component class="ship_s">（2026-09-21 实抓：第一架紧跟 dock_gen_xs_ship_01_macro）。
try {
    $xd = New-Object System.Xml.XmlDocument
    $xd.LoadXml($t)
    $stations = $xd.SelectNodes('//component[@class="station"]')
    if ($stations.Count -eq 0) {
        Write-Host '      (no station components in this save)' -ForegroundColor Yellow
    } else {
        foreach ($st in $stations) {
            # The name is an ATTRIBUTE of the component (实抓:
            #   <component class="station" macro="…" connection="space" name="X4MP STN 2" code="TIY-216" …>)
            # - which is why it never showed up in InnerXml.
            $nm = $st.GetAttribute('name')
            if (-not $nm) {
                $hit = [regex]::Match($st.OuterXml, 'X4MP STN \d+')
                if ($hit.Success) { $nm = $hit.Value } else { $nm = $st.GetAttribute('macro') }
            }
            $ids = if ($st.GetAttribute('id')) { $st.GetAttribute('id') } else { '?' }
            $kids = $st.SelectNodes('.//component[@class="ship_s" or @class="ship_xs" or @class="ship_m" or @class="ship_l"]')
            $per = @{}
            foreach ($c in $kids) {
                $mac = $c.GetAttribute('macro')
                foreach ($k in $droneMacros.Keys) {
                    if ($mac -like "*$k*") { $per[$k] = 1 + ($per[$k] -as [int]); $anyDrone = $true }
                }
            }
            $txt = if ($per.Count -eq 0) { '0 drones' } else {
                (($per.Keys | Sort-Object) | ForEach-Object { "$_=$($per[$_])" }) -join ' '
            }
            $col = if ($per.Count -eq 0) { 'Gray' } else { 'Yellow' }
            Write-Host ("      {0,-16} uid={1,-10} drones in hangars {2}" -f $nm, $ids, $txt) -ForegroundColor $col

            # 2026-09-21: 船厂/装备厂的"装备库存"（<ammunition><available>）是**站类型自带**的，
            # 不走 loadout ⇒ B 路线原先漏了它（X4MP STN 3 曾实抓 fightingdrone×87 +
            # cargodrone×24 + repairdrone×46，而 STN 1/2 为空）。修法 = MD 里
            # set_equipment_wares_excluded。这里直接读出来验收。
            $stockItems = $st.SelectNodes('./ammunition/available/item')
            if ($stockItems.Count -gt 0) {
                $sTxt = @()
                foreach ($si in $stockItems) {
                    $sm = $si.GetAttribute('macro') -replace '_macro$', ''
                    $sTxt += ('{0} × {1}' -f $sm, $si.GetAttribute('amount'))
                }
                $scol = if (($sTxt -join ' ') -match 'drone') { 'Yellow' } else { 'Gray' }
                Write-Host ('                       equipment stock: {0}' -f (($sTxt -join '   '))) -ForegroundColor $scol
            }
        }
    }
} catch {
    Write-Host ('      (failed to resolve by station ownership: {0})' -f $_.Exception.Message) -ForegroundColor DarkYellow
}

# (b) 全局计数：loadout 单元条目 / 库存条目也要为 0（那是"能再放飞"的资本）
foreach ($k in $droneMacros.Keys) {
    $ms = [regex]::Matches($t, ('<component[^>]*macro="ship_gen_[a-z0-9_]*' + $k + '[a-z0-9_]*"[^>]*>'))
    $us = [regex]::Matches($t, ('<unit[^>]*macro="ship_gen_[a-z0-9_]*' + $k + '[a-z0-9_]*"'))
    $is = [regex]::Matches($t, ('<item[^>]*macro="ship_gen_[a-z0-9_]*' + $k + '[a-z0-9_]*"'))
    if ($ms.Count -eq 0 -and $us.Count -eq 0 -and $is.Count -eq 0) { continue }
    $anyDrone = $true
    $col = if ($k -eq 'fightingdrone') { 'Yellow' } else { 'Gray' }
    Write-Host ("      total {0,-14} live {1,5}   unit rows {2,4}   item rows {3,4}   {4}" -f $k, $ms.Count, $us.Count, $is.Count, $droneMacros[$k]) -ForegroundColor $col
}
if (-not $anyDrone) {
    Write-Host '      ✔ no drones in the save => route B works (the loadout excludes units/drones)' -ForegroundColor Green
} else {
    Write-Host '      ⇒ drones present: check the per-station line above to see which station route B missed' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  How to read this:' -ForegroundColor White
Write-Host '    · station should be 3 (X4MP STN 1/2/3) and defencemodule 18 (station 1 = 3, station 2 = 4, station 3 = 11)' -ForegroundColor DarkGray
Write-Host '    · turret > 0 => the S3 refit worked; [5] $X4MPEqSeqOfficer should be 3 (a defence officer on every station)' -ForegroundColor DarkGray
Write-Host '    · save again after attacking: [4] should show <hull> for class=defencemodule and [6] max(lastshottime) should be about your attack time' -ForegroundColor DarkGray
Write-Host '    · [7] fightingdrone should be 0 (route B: stations carry no drones; $X4MPEqSeqNoDrones=1 confirms)' -ForegroundColor DarkGray
Write-Host '    · [7] 的"装备库存"（船厂/装备厂特有）也应为空：修前 STN 3 有 fightingdrone×87 —— 那是站类型自带、不走 loadout，靠 MD 的 set_equipment_wares_excluded 清掉' -ForegroundColor DarkGray
Write-Host ''
