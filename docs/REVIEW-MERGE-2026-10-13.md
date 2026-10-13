# Review merge - 2026-10-13

Source: an external code review of the separate "Porthole" novice bundle (v1.1) together with
its v1.2 fix set. That bundle is a different distribution, but the reviewed files share this
package lineage, so every finding that touches game content or the installer was ported here.

## Ported - game content

| File | Item | Change |
|---|---|---|
| md/x4mp_stations.xml | P0-2 | module key `$k` is 1-based in `X4MP_StationModuleRegistry`, matching the 1-based names written by `X4MP_EquipStationsSeq`. Before: names 1-based, table 0-based, so every lookup was off by one and `k=N` read nil - the classic `PEER DAMAGE VERIFY ... -> WRITE LOST`. |
| md/x4mp_stations.xml | P0-2 | removed `global.$X4MPStationMods.{idx} = $stnmods` (a full-list assignment into a global table does not enter save state; the registry builds the table one key at a time). |
| md/x4mp_stations.xml | P0-3 | both module counters now increment *before* the null / sequence guards, so a destroyed station (a deliberate null hole) or a save loaded without `plannedconstruction` no longer shifts every later station idx. |
| md/x4mp_stations.xml | P2 | `X4MP_StationEvacHero`: `player.ship?` / `player.ship.parent?` null guards. |
| md/x4mp_level_boron.xml | P1-5 | `X4MP_Level_Init` initialises `$X4MPLevelK`, `$X4MPLevelGhost`, `$X4MPLevelGhostTries`, `$X4MPLevelClientShip`, `$X4MPLevelClientShipTry`, `$X4MPLevelClientOldShip`. |
| md/x4mp_level_boron.xml | P1-6 | `X4MP_Level_Freeze` checkinterval 100 ms -> 200 ms (its own comment always said 200 ms). |
| md/x4mp_testworld.xml | P1-8 | `X4MP_GhostDestroy` gets the double null guard. `explosion="false"` is kept on purpose: this project removes the mirror ship silently. |

Already present here before the merge (no action needed): the `?` guards in `X4MP_Level_KDown`
and `X4MP_Level_Win`, `instantiate="true"` on `X4MP_GhostDestroy`, removal of the 16 `X4MP_P2Fx`
probes, and the client-ship / ghost-try guards.

## Ported - tools

| File | Item | Change |
|---|---|---|
| tools/x4mp_install.ps1 | P2 | strict 0-255 IPv4 regex (`$script:IPv4Re`) for both `-HostIp` and the interactive prompt. |
| tools/x4mp_install.ps1 | P1 | `Ask-HostIp`: `q` or an empty line exits instead of spinning in `while ($true)` forever. |
| tools/x4mp_savecheck.ps1 | P2-10 | the `<hull>` owner lookup no longer copies the rest of the save file (O(n^2) -> a 64 / 256 character window). |
| ui/x4mp_bridge.lua | P2-1 | new `nums()` (non-numeric field = drop the row + `DebugError`, instead of silently handing nil to MD) and `safe()` (pcall around every handler). All 22 `RegisterEvent` calls now go through `safe()`, 14 payload tables through `nums()`. |

## Deliberately not ported

* The Porthole tunnel itself (`x4mp_porthole.ps1`, the `-HostIp 127.0.0.1` fix, tunnel cleanup,
  invite-code handling): this package has no tunnel, guests connect to the host IP directly.
* `x4mp_native.dll` / `content.xml` / the x4native extension: the review bundle ships an older DLL
  (527 KB, `6d344e3c...`) while this package ships `run26x-npcveto` (554 KB, `39d81971...`).
  Never mix the two.
* Uninstalling still removes a third-party `x4native` copy (review P1-9) - left as-is on purpose.
* The `hull / hullpercentage` conversion factors and the `X4MP_Level_TurretCount` approximation
  stay open: both need an in-game measurement, not a code reading.

## Verification performed here

* XML: all three MD files parse; cue counts 26 (level) / 11 (stations) / 15 (testworld).
* Lua: `luaparse` (Lua 5.1 grammar) parses `x4mp_bridge.lua` after the rewrite.
* PowerShell: `Parser::ParseFile` reports 0 errors for every shipped `.ps1`; all carry a UTF-8 BOM.
* `tools/manifest.txt` regenerated and re-verified: 0 missing, 0 mismatched.

Still needs one in-game pass - the review flagged these two as unverified assumptions:

1. hit a single station module and confirm the DLL log `module=` and the MD table index name the
   same module (this pins down that `<do_all counter>` is 1-based);
2. destroy one station, then confirm the *next* station modules still sync.