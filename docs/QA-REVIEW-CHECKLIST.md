# QA review checklist — how 0.1.1 answers the independent code review

Source: an independent review of the Porthole pack (3 × P0, 12 × P1, 16 × P2), produced by
**eg3r**. This file records, item by item, what 0.1.1 does about it: **fixed**, **needs a live
test first**, or **not part of this pack**.

## 1. Fixed in 0.1.1

| Item | What was done |
|---|---|
| **P1-7** — 16 effect probes (`X4MP_P2Fx0 … P2FxEnd`) shipped in the test world | **Deleted.** Only a comment remains, keeping the conclusion: `add_effect` does not render on this project's path |
| **P1-8 (mechanism)** — `X4MP_GhostDestroy`, `X4MP_SpawnNpc`, `X4MP_UniverseGo` had neither `instantiate` nor `reset_cue` | All three now carry `instantiate="true"`, matching every other lane cue |
| **P1-4** — `event.object == global.$X4MPLevelK` / `$X4MPLevelXenonStn` without a `?` guard | Both comparisons are guarded, so a not-yet-spawned K / Xenon station cannot fail the whole action block |

## 2. Deliberately NOT changed — needs one live (or mutation) test first

| Item | Why not changed blindly | How to test |
|---|---|---|
| **P0-2** — station module "name as key": names 1-based, table 0-based | The review itself calls this a "strong inference". Getting it wrong breaks module sync **for every module** | Run one session and check whether `PEER DAMAGE VERIFY … WRITE LOST` is off by exactly one (`k=1` hits the second module). Only then unify the base |
| **P0-3** — holes in the station list shift the index/name mapping | Same class of structural assumption | Use a save where a middle station was destroyed; compare `X4MP STN <idx>` names against the registry keys |
| **P1-5** — `X4MP_Level_Init` does not initialise 6 globals | Initialising object globals to `null` makes `not global.$X?` **false**, which can break the existing "not created yet" guards | Test together with P1-4: only add them once an undefined-variable error is actually observed |
| **P1-6** — `instantiate` with `checkinterval="100ms"` creates instances on every check | Changing it alters freeze timing (a behaviour change) | Kill the host for two minutes and watch the client's log volume and frame rate |
| **P1-8 (semantics)** — does a second peer death really work? | The attribute is fixed, but the behaviour needs a real session | Let the peer die twice; the ghost must be destroyed and rebuilt twice |
| **P2-4 / P2-5** — `hull / hullpercentage` divides by zero | Only fires in the instant `hullpercentage == 0` | Watch the log for a divide-by-zero |
| **P2-6** — `X4MP_Level_TurretCount` advances the objective for *any* faction's turret | A mission-design trade-off, not a pure bug | If the objective jumps unexpectedly in a session, filter by faction |
| P2-19 / P2-20 — hard-coded scene anchor, inconsistent indentation | Cosmetic / known coupling, no functional impact | Not scheduled |

## 3. Part of this pack's tools (same files as the Porthole pack, byte-identical)

| Script | Status |
|---|---|
| `tools/x4mp_savecheck.ps1` | Byte-identical to the reviewed copy ⇒ **P2-10/11/12 apply here too** (O(n²) substring, full-DOM parse, auto-picking a save under 5 MB). Console output is English in 0.1.1; the algorithm is unchanged |
| `tools/x4mp_fit_halfscreen.ps1`, `tools/x4mp_tag_windows.ps1` | Byte-identical ⇒ **P2-21 applies** (these are single-machine dual-instance helpers; with a tunnel both sides bind 127.0.0.1:42069, so one machine cannot be host *and* guest — README wording matters) |
| `tools/x4mp_install.ps1` | A different generation from the reviewed copy (23,604 B vs 18,311 B) ⇒ the **P0-1 class of bug (passing `-HostIp` explicitly)** needs a separate check in the Porthole flow |
| `tools/x4mp_porthole.ps1` | **Not present in this pack** ⇒ P0-1, P1-1/2/3/9/10/11/12, P2-13/14 do not apply here; they belong to the Porthole pack |

## 4. Not part of this pack (Porthole-side items)

P0-1, P1-1, P1-2, P1-3, P1-9, P1-10, P1-11, P1-12 and P2-8/9/13/14 live in
`x4mp_porthole.ps1` and the interactive `*.bat` files of the Porthole pack. eg3r reports them
fixed in the v1.2 pack; the v1.2 archive is not on this machine, so they were not re-verified
here.

## 5. How the review's items were reproduced here

* hash comparison against the changelog's declared values;
* a two-way diff of the Lua ↔ MD event contract (`AddUITriggeredEvent` vs `event_ui_triggered`);
* XML validity plus an AST check of every `do_if` block (to catch lying indentation);
* a scan for this project's known anti-patterns (`<wait>` in the wrong place,
  `GetOwnerDetails`, `raise_lua_event`, `find_ship` without `space=`).
* **Not** done by the reviewer: DLL binary analysis (closed source) and live multiplayer runs —
  which is exactly why section 2 above exists.
