# Changelog — 0.1.1 (2026-10-13)

## What this release is

**The 0.1 feature set + the client ship swap + the "dead NPC still visible" fix — and nothing
from the weapon-effect research.** It freezes the released 0.1 capability into a reproducible,
publishable baseline. The effect work (the 0.2 line) and all experimental builds stay in the
development tree and are **not** part of this package.

## What changed versus 0.1

### 1) Client ship: Argon Behemoth → Terran *Osaka*

* Macro `ship_ter_l_destroyer_01_a_macro` (verified present in `ego_dlc_terran\ext_01.cat`),
  loadout faction `faction.terran`, ship name `X4MP LVL Client Osaka`.
* The ghost fallback values `$ghostWant` / `$ghostOther` were updated to the same macro.
* No `ship_arg_l_destroyer_02_a_macro` reference and no `X4MP LVL Client Behemoth` string
  remain in the package.

### 2) The NPC hull/shield synchronisation bug

* Reported symptom: the client log ends with
  `puppet id=39 is a hull-0.0 remnant - not mapped` — a zero-hull wreck stays alive and the two
  sides diverge.
* Shipped fix: the **host's authority is written absolutely** (only `hull/shield >= 0` are
  applied) and the client **writes back** local damage through the NPC veto path
  (`station_note_damage()` hook + a 1 Hz `npc_veto_sweep()`; log line `NPC veto applied ...`).
* **Deliberately excluded:** the intermediate rule `hull <= 0 ⇒ destroy_object` from the same
  round. It was later shown to destroy client-side NPCs permanently
  (`client sync mapped=0`) and has been reverted.
* MD side needed no change: 0.1's `X4MP_NpcVitals` already writes absolute values only and the
  0.1 `x4mp_bridge.lua` already handles `on_npc_vitals`.

### 3) All effect probes removed (review item P1-7)

* The 16 cues `X4MP_P2Fx0 … X4MP_P2FxEnd` in `md/x4mp_testworld.xml` are **deleted**.
* Only a comment remains, keeping the conclusion: **`add_effect` does not render on this
  project's path**; the fire *data* relay is fine on its own (watch the DLL's
  `P2 relay ... fires(sent/recv)` line).
* `X4MP_Level_NpcFireFx` (effect landing), `X4MP_Level_FxDiag` (effect self-check) and the
  `aim_turret` / `fire_turret` real-fire implementation are **not** in this package.

## Also fixed from the code review

* **P1-8** — `X4MP_GhostDestroy`, `X4MP_SpawnNpc`, `X4MP_UniverseGo` now carry
  `instantiate="true"` like every other lane cue.
* **P1-4** — the two comparisons `event.object == global.$X4MPLevelK` /
  `$X4MPLevelXenonStn` in the level MD are now guarded with `?`.
* Everything else: either intentionally untouched with a concrete test recipe, or part of the
  Porthole pack — see `QA-REVIEW-CHECKLIST.md`.

## File inventory

| File | Size / count | Note |
|---|---|---|
| `x4mp_native/native/x4mp_native.dll` | 567,296 B | build id `run26x-npcveto` (last build before the effect work) |
| `x4mp_native/ui/x4mp_bridge.lua` | 21,274 B | identical to 0.1 |
| `x4mp_test/md/x4mp_level_boron.xml` | 26 cues | 0.1 + Syn + P1-4 guards |
| `x4mp_test/md/x4mp_testworld.xml` | 15 cues | 0.1 minus 16 probes, plus P1-8 |
| `x4mp_test/md/x4mp_stations.xml` | 11 cues | byte-identical to 0.1 |
| `content.xml` (both extensions) | — | `version="0.1.1"` |

Per-file SHA-256: `CHECKSUMS.txt`. All three MD files pass an XML parse self-check.

## Post-release: external review merge (2026-10-13)

After the 0.1.1 tag, an external review of the separate "Porthole" novice bundle (v1.1 + its v1.2
fix set) was ported wherever it applies to this package - the files share this package lineage, so
the station-module and level findings hit us too. Per-item mapping: `docs/REVIEW-MERGE-2026-10-13.md`.

* **Station module sync (the `WRITE LOST` class):** module keys are 1-based everywhere, the
  ineffective full-list table assignment is gone, and both module counters increment before the
  null / sequence guards, so a destroyed station no longer shifts every later station index.
* **Level:** `X4MP_Level_Init` initialises six globals that were previously only ever read;
  `X4MP_Level_Freeze` is back to 200 ms as its own comment always claimed.
* **Ghost destroy:** double null guard, silent removal (`explosion="false"`) kept.
* **Tools:** strict 0-255 IPv4 regex, `q` / empty exit in the host-IP prompt, O(n^2) fix in
  `x4mp_savecheck.ps1`, and `nums()` / `safe()` hardening in `x4mp_bridge.lua` (all 22
  registrations wrapped, 14 payload tables validated).
* Unchanged on purpose: no Porthole tunnel code, the DLL is untouched, uninstall behaviour
  (including the third-party `x4native` removal) is unchanged.
## Post-release: installer backup policy (2026-10-14)

Reported: every time the co-op pack was started the game folder gained another
`_x4mp_backup_<timestamp>` folder - Porthole-style launchers re-run this installer on every launch.

* A backup is now **skipped entirely when the installed build already matches the pack** (the normal
  re-run case): the game folder is not touched at all.
* When something else really is being replaced, exactly **one** backup is kept:
  `<X4>\_x4mp_backup\<ext>\` (written over, never appended). Uninstall uses `<X4>\_x4mp_removed\`,
  stale-copy handling uses `<X4>\_x4mp_stale\`.
* Per-run backup folders left by earlier installers are folded into `<X4>\_x4mp_backup\_legacy\`
  (moved, never deleted) on the next install.
* Verified in a sandbox: first run (foreign content) creates the single backup, second run with the
  same build prints `no backup needed` and adds nothing.
## Post-release: missing Chinese text page (2026-10-14)

Reported: the level header showed `readtext100002-1` in a Chinese-language game.

* The review merge build had dropped `t\0001-l086.xml` when the English pack was assembled, so the
  Chinese client had no strings for text page 100002 (level/mission name).
* The English package now ships **both** text pages: `t\0001-l044.xml` (English) and `t\0001-l086.xml`
  (Chinese), like the reference package does. A full audit of the pack found all 16 `{1000xx,N}`
  references defined in both pages (0 missing).