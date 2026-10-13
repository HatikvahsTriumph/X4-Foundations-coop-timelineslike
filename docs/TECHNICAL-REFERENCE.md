# X4MP Technical Doc 10 — Framework & Code Reference

> **What this document is**: a *reference manual*. It answers exactly two questions —
> ① **Framework**: what the system is made of, how data flows, who owns what;
> ② **Code ↔ function**: which function / cue / event / packet is responsible for which job.
> It deliberately contains **no development history, no debugging narratives and no changelog**
> (those live in the project's Chinese docs 6/7/8/9).
> Line numbers are those of the current revision and drift as the code changes —
> **search by function name / cue name**, not by line number.

---

## 1. Framework overview

### 1.1 The three extensions

| Extension | Role | Contents |
|---|---|---|
| `x4native` | **Native-extension host (SDK)** | Loads C++ DLLs into the X4 process; provides the game function table, event hooks, the Lua bridge and logging. Upstream third-party project (MIT). |
| `x4mp_native` | **Network sync layer** | `native\x4mp_native.dll` (all sync logic, one C++ file) + `ui\x4mp_bridge.lua` (the DLL ↔ MD bridge) + `content.xml` / `x4native.json` (role and parameters). |
| `x4mp_test` | **World content layer** | Level and test worlds: `libraries\gamestarts.xml`, `maps\x4mp_galaxy_macro.xml`, `md\*.xml` (all MD scripts), `t\*.xml` (text pages), `index\macros.xml`. |

### 1.2 Runtime structure (inside one process)

```
                    ┌────────────────────────── X4.exe / X4_2.exe ──────────────────────────┐
                    │                                                                       │
 engine events ──▶  │  x4native_core.dll                                                      │
 (damage / killed / │      │  function table (2065 entries) + hooks (MD before/after,         │
  weapon fired /    │      │  native frame, radar)                                            │
  sector changed /  │      ▼                                                                  │
  dock / undock)    │  x4mp_native.dll  ── UI thread (inside the game frame) ──────────────┐  │
                    │      │  on_frame(): sample → drain/fill queues → write engine → raise  │  │
                    │      │  on_game_loaded(): build tables / reset / announce             │  │
                    │      │                                                              │  │
                    │      ├─ shared containers (guarded by std::mutex, UI ↔ net thread)    │  │
                    │      │     s_outXxx (UI fills, net drains)                           │  │
                    │      │     s_inXxx  (net fills, UI drains)                           │  │
                    │      │                                                              │  │
                    │      └─ network thread (own std::thread; heap-allocated, stopped at   │  │
                    │            exit via atexit)                                          │  │
                    │             eNet UDP ── port 42069 ──▶ peer                          │  │
                    │                                                                      │  │
                    │  raise_lua("x4mp_*")  ──▶  ui\x4mp_bridge.lua (UI Lua)              │  │
                    │                                   │                                  │  │
                    │                                   ▼                                  │  │
                    │                          AddUITriggeredEvent('X4MP_*','ctrl',{…})    │  │
                    └───────────────────────────────────┼──────────────────────────────────┘
                                                        ▼
                                            <event_ui_triggered> cue in md\*.xml
                                                        │
                                                        ▼
                                            engine operators (create_ship / warp /
                                            set_object_hull / destroy_object / …)
```

**Key points**

- **Two independent pipelines**: `hero` (the peer player's ship = the ghost replica) and `NPC` (puppets: pose / vitals / orders / fire / sector transit). They share no containers.
- **Exactly one crossing direction between threads**: the UI thread and the network thread exchange data only through queues guarded by `s_mutex`; **the network thread never touches the engine**.
- **The only DLL → MD channel is a Lua event**: DLL `raise_lua(name, payload)` → bridge parses it → `AddUITriggeredEvent(screen, control, table)` → an MD `event_ui_triggered` cue.
- **The only MD → DLL channel is an object name** (see §1.5); there is no direct MD → native call.

### 1.3 Threads and ownership (must be respected when writing code)

| Data | Owner | Note |
|---|---|---|
| Engine reads/writes (`x4n::entity`, `game()`, …) | **UI thread** | the net thread only parses bytes and fills queues |
| `s_out*` / `s_in*` queues | shared (`s_mutex`) | UI fills `s_out` and drains `s_in`; the net thread does the opposite |
| `s_*Map` tables (`s_npcMap`, `s_stationMap`, `s_sectorByKey`, …) | **UI thread** | rebuilt in `on_game_loaded()` and inside the frame |
| Window title, speed readout | UI thread | through Win32 `SetWindowTextA` (ASCII only) |
| Network context (eNet host/peer) | **network thread** | reconnects happen on that thread too |

### 1.4 Role split (host = authority / client = mirror)

| Lane | Host | Client |
|---|---|---|
| NPC pose (P1) | samples and broadcasts | **freezes puppet AI**, then writes back interpolated snapshots |
| NPC vitals (P0) | **sole authority**, sends absolute values | applies whatever arrives (mirror), **never reports back** |
| NPC orders / fire (P2) | records events and relays them | executes / plays effects on arrival |
| Station vitals / modules | **sole authority** (container percentage + per-module rows) | applies on arrival; a local-hit veto protects its own mirror |
| Station damage uplink | receives it (**decrease only**, never heals, never destroys) | attributes local player hits and reports them |
| World handshake | announces the world size, releases the world | sends CLIENT_READY / WORLD_READY |
| Player hero (ghost) | both directions: each side broadcasts its own pose | same |
| Host clock | broadcasts every 2 s | receives, computes the offset, uses it as the time base |

### 1.5 Invariants (read once, apply everywhere)

1. **Name as key**: every cross-machine key travels as an object name (`X4MP Ghost`, `X4MP NPC <lid>`, `X4MP STN <idx>`, `X4MP STN <idx>#<k>`, `X4MP TUR <idx>#<k>#<c>`), because runtime uids differ between peers.
2. **Length is the type tag**: the receive chain dispatches on `len == sizeof(struct)` ⇒ **every new packet struct must have a unique length** (enforced by a `size_differs_from_all<…>` static assert).
3. **The ghost pose has exactly one slot**: `global.$X4MPGhostShip`. MD must write that slot when it creates the ghost, or the pose lane cannot find the object.
4. **A throwing MD operator skips the rest of that turn's actions** ⇒ write critical globals first, put error-prone operations (renames, etc.) last.
5. **Only proven MD constructs are used** (`libraries\md.xsd` validates the outer envelope only; action elements are not covered by it).
6. **Cross-machine comparisons use fingerprints / names / counts only** — never uids, never absolute time.
7. **The first line of every session log is the build identity** (`build id …`), so "which build produced this log" is answerable from the log alone.

---

## 2. Wire protocol (UDP 42069)

### 2.1 Dispatch rule

The receive side **types packets by length**: whichever branch's `len == sizeof(struct)` matches is how the bytes are interpreted.
⇒ **Length is the type tag.** A new packet must satisfy:

- a **unique** struct length (enforced by `size_differs_from_all<every existing packet…>(sizeof(new_packet))`);
- fixed alignment/padding (`#pragma pack` plus `static_assert(sizeof(...) == N)`);
- placement in the receive chain: exact-length branches first, the `len >= sizeof(MovePacket)` fallback last.

Lengths already taken (**a new packet must not reuse any**): `4 · 8 · 12 · 13 · 16 · 20 · 24 · 28 · 29 · 32 · 36 · 40 · 44 · 48 · 56 · 64 · 68 · 102`.

### 2.2 Packet list

| Packet | Size | Direction | Delivery | Purpose |
|---|---|---|---|---|
| `MovePacket` | 40 | both | unreliable | Hero pose (position + yaw/pitch/roll + sector key + seq) |
| `DamagePacket` | 13 | both | unreliable | Damage dealt to the **hero** (paired with the mirrored ghost vitals) |
| `SpawnPacket` | 102 | host→client | reliable | Puppet spawn row (logical id, macro, faction, position, name-flag bits) |
| `DespawnPacket` | 4 | host→client | reliable | Puppet despawn row (logical id) |
| `NpcVitalsPacket` | 16 | host→client | reliable | Puppet **absolute** hull/shield (`flags & 0x01` = this puppet is dead) |
| `NpcStatePacket` (record 48) | 56 | host→client | unreliable | Puppet pose snapshot (10 Hz; the client interpolates) |
| `NpcOrderPacket` | 20 | both | reliable | Order relay (op / order / target / targetKind) |
| `NpcFirePacket` | 24 | host→client | unreliable | Firing behaviour (the client plays an effect) |
| `NpcTransitPacket` | 32 | host→client | reliable | Puppet sector transit (from/to sector keys + arrival point) |
| `NpcDamagePacket` | 12 | — | — | **Retired**; receiving one only logs a warning (absolute vitals replaced deltas) |
| `StationVitalsPacket` | 29 | host→client | reliable | Station hull/shield/state/flags (`magic 0x53 'S'`) |
| `StationModulePacket` | 28 | host→client | unreliable | Single module hull (`magic 0x4D 'M'`; located by the `idx#k` key) |
| `PeerDamagePacket` | 64 | client→host | reliable | Client player hit report (`magic 0x44 'D'`; kind 0=station / 1=NPC / 2=unmapped) |
| `PeerEventPacket` | 36 | both | unreliable | Peer player's personal actions (dock / undock, …) |
| `TimeSyncPacket` | 44 | host→client | unreliable | Host clock (host time / offset / stage); the client derives its time base from it |
| `HeroMacroPacket` | 68 | both | unreliable | Peer **hero macro name** (the ghost replica is built from it) |
| `SyncMsgPacket` | 8 | both | reliable | Handshake and world fingerprint (`magic 0x5A`; see §2.3) |

### 2.3 Handshake (`SyncMsgPacket`)

| kind | Name | Direction | Payload | Meaning |
|---|---|---|---|---|
| 1 | `kSyncClientReady` | client→host | 1 | "my game is loaded" (re-sent every 500 ms until the world starts) |
| 2 | `kSyncWorldSize` | host→client | puppet rows | announces the world size; the client uses it to decide "is everything standing" |
| 3 | `kSyncWorldReady` | client→host | standing count | the client reports "N puppets stand here" |
| 4 | `kSyncWorldGo` | host→client | 0 | release the world (both sides start AI / driving together) |
| 5 | `kSyncWorldSig` | both | `a`=signature, `flags`=sector count | **world fingerprint**: "are we in the same world" |

**World fingerprint** (`world_signature()`): a sorted FNV-1a over all local sector keys, mixed with the sector count. A mismatch ⇒ log `[WORLD MISMATCH]` and append ` [X4MP WORLD MISMATCH]` to the window title.

### 2.4 Tick and threshold constants

| Constant | Value | Meaning |
|---|---|---|
| `kStateSampleMs` | 100 | host puppet pose sampling (10 Hz) |
| `kStateInterpSec` | 0.20 | client render lag (about two samples) |
| `kStateMaxExtra` | 0.30 | longest extrapolation allowed beyond the last sample |
| `kStateHistMax` | 5 | snapshots kept per puppet |
| `kReconcileMs` | 2000 | host spawn/despawn + vitals backstop period |
| `kVitalsPollMs` / `kVitalsFullScanMs` | 1000 / 250 | own and ghost damage polling / full rescan after an unmappable event |
| `kSyncAskMs` / `kSyncResendMs` | 500 / 2000 | CLIENT_READY repeat / WORLD_SIZE repeat |
| `kSyncSizeWaitMs` / `kSyncReleaseHoldMs` | 5000 / 30000 | client's size-fallback window / host's limit on holding the world |
| `kStationReconcileMs` / `kStationPollMs` / `kStationDeepPollMs` | 2000 / 500 / 1000 | station table re-resolve / station scan / module-inclusive scan |
| `kStationFullPushMs` / `kStationDriftPct` | 10000 / 0.5 | station full re-push period / changes below this are not news |
| `kStationKillResend` / `kStationKillResendMs` | 3 / 500 | station destroy-row re-sends, count and interval |
| `kStationVetoMs` / `kStationVetoPanicPct` / `kStationGhostVetoMs` | 200 / 20.0 / 1200 | client local-hit veto rate limit / low-hull protection threshold / window in which ghost damage is not reported |
| `kPlayerAttackWindowMs` | 15000 | window for "this local player is attacking this target" |
| `kStationNeighbourMs` / `kStationNeighbourKm` | 5000 / 10.0 | station neighbourhood scan period / radius |
| `kMaxPuppetWrites` / `kMaxPuppetWritesHard` | 12 / 64 | per-frame puppet pose write budget (soft / hard) |
| `kGoneStableMs` | 3000 | how long a puppet must read "unreadable / hull ≈ 0" before it counts as dead |
| `kMoveDeadband` / `kMoveKeepAliveMs` | 0.02 / 40 | pose-raise deadband (m/deg) and keep-alive period for the ghost lane |
| `kGhostNudgeRadius` / `kGhostNudgeLift` | 200 / 700 | distance at which the ghost display ladder starts, and the lift applied at zero distance |

---

## 3. DLL code reference (`x4mp_native.cpp`)

> Look-up by function name. About 150 file-level `static` functions, grouped by functional domain below.

### 3.1 Initialisation, configuration, lifecycle

| Function / symbol | Purpose |
|---|---|
| `parse_cmdline()` | parse `-x4mp host\|client <address>` from the command line |
| `read_config()` / `temp_config_dir()` | read `%TEMP%\X4MP\config.txt` (`mode=` / `address=` / `port=`) |
| `autosplit_is_host()` | role auto-detection for the dual-instance case (`X4.exe` / `X4_2.exe`) |
| `process_alive()` | is a given pid still running (single-instance mutex helper) |
| `on_game_loaded()` | **reset entry point for every load/reload**: build the sector-key table, clear all tables and caches, reset handshake / fingerprint / clock state, write the build id as the first log line |
| `on_frame()` | **per-frame main loop**: calls every flush / apply / sync below (wrapped in try/catch) |
| `x4mp_signal_net_thread_stop()` + `atexit` registration | stop and release the network thread before process exit |
| `tag_window_title()` | maintain the window title: `… [HOST]\|[CLIENT] | <own speed> m/s | peer <peer speed> m/s`, plus a marker when the worlds differ |
| `s_ownSpeedMps` / `s_peerSpeedMps` | speed readouts derived from consecutive poses (shown in the title) |

### 3.2 Network thread and transport

| Function / symbol | Purpose |
|---|---|
| `net_thread(bool asHost, address)` | network thread body: create the eNet host/peer, loop on `enet_host_service`, move queues, reconnect on failure |
| receive dispatch chain | **types every packet by `len == sizeof(...)`** into the `s_inXxx` queues (see §2) |
| `queue_sync(kind, a, b)` | queue one 8-byte handshake / fingerprint row |
| `s_outXxx` / `s_inXxx` queue family | the only interface between UI and network thread (`s_mutex`); naming rule: `s_out*` filled by UI, `s_in*` filled by the network thread |
| `release_universe(why)` | host releases the world: send `kSyncWorldGo` and raise `x4mp_universe_go` locally |

### 3.3 Sector keys and shared helpers

| Function | Purpose |
|---|---|
| `sector_key_hash(macro)` | 32-bit FNV-1a of a sector macro name (0 is reserved for "no sector") |
| `build_sector_keys()` | enumerate every sector of the local galaxy, build `key → local UniverseID` (rebuilt per load; detects hash collisions) |
| `sector_of_entity(uid)` / `sector_key_of_entity(uid)` | the sector id an entity lives in / its sector key |
| `sector_id_of_key(key)` | incoming key → local sector id (unresolvable ⇒ the object is parked) |
| `world_signature(&sectors)` | world fingerprint (sorted FNV-1a + sector count) |
| `read_vitals(id, hp, sp)` | read a component's hull/shield percentages (false on failure) |
| `read_own(out[6])` | read the local player ship's pose (position + angles) |
| `read_lua_num(id, field, out)` | fetch any component field through Lua (`GetComponentData` path) |
| `find_ship_named(...)` / `s_ghostUidCached` | locate a ship by object name (how the ghost pose/vitals lane finds its object) |
| `is_ghost_uid(uid)` | is this uid the local ghost replica |

### 3.4 Player hero lane (the ghost replica)

| Function / symbol | Purpose |
|---|---|
| `update_display()` (incl. the nudge block) | interpolate the peer pose into the local display pose; **lift it smoothly when it gets too close to our own ship**; writes `s_display` |
| `raise_lua("x4mp_move", "x,y,z,yaw,pitch,roll")` | hand six numbers to the bridge every frame → MD `<warp>` (position + orientation) |
| `s_remoteSectorKey` / `s_remoteTransit` | the peer hero's sector key / transit notice (decides "park" versus "re-place") |
| `ghost_mirror_vitals(immediate)` | mirror the peer hero's hull/shield onto the local ghost (the ghost cannot die first) |
| `flush_peer_macro()` | broadcast the local hero macro once per second; on receipt sets `s_remoteMacroDirty` so MD can rebuild the ghost |
| `queue_peer_event(kind, keyType, id, modIdx)` | report / relay the peer player's personal actions (dock, undock) |
| `dock_event_is_player(source)` | filter: was this dock event produced by the player (the hero) |

### 3.5 NPC puppet lane

**Registration and diffing (host)**

| Function | Purpose |
|---|---|
| `sync_npcs()` | host entry point: enumerate ships carrying the `X4MP NPC` marker → assign/reuse a logical id → emit spawn/despawn rows → maintain `s_npcMap`; "unreadable / hull ≈ 0" must persist for `kGoneStableMs` before it counts as dead |
| `npc_lid_of(uid, &lid)` | parse the logical id out of an object name |
| `parse_npc_tag(name)` | same, for the enumeration path |
| `s_npcGoneSince` | uid → the time it was first seen as "apparently gone" (the death-decision stable window) |
| `sync_client_npcs()` | client side: claim puppets by name, count `s_clientMapped`, report leftovers |
| `flush_spawns()` / `find_local_ship_for_row()` | the client builds a ship from a spawn row (macro/faction/position come from the row) |
| `flush_despawns()` | the client removes a puppet per despawn row (with an idempotent tombstone guard) |
| `s_despawnTombstones` | lid → time the despawn arrived; prevents "destroy received before spawn" from resurrecting a ship |

**Vitals (P0, host-authoritative)**

| Function | Purpose |
|---|---|
| `mark_npc_dirty(uid)` | mark dirty from engine events (hull change / killed) |
| `flush_npc_vitals_out()` | the host reads dirty ids and reports **absolute** values; `hp ≤ 1%` counts as dead and sends `flags 0x01` |
| `flush_incoming_vitals_in()` | the client applies the host's values (the host drops peer rows, keeping a single authority) |
| `md_on_hull_damaged()` / `md_on_shield_damaged()` / `md_on_killed()` | three engine event callbacks: mark dirty, record attribution (did the local player do it), route into the station / puppet paths |

**Pose (P1, 10 Hz snapshots + client interpolation)**

| Function | Purpose |
|---|---|
| `apply_npc_states()` | **client-side core**: freeze puppet AI (`order_wait`) and write back interpolated poses along the arrival-time axis; includes staleness detection and "strict follow" self-healing |
| `s_npcSnap` / `s_npcFreezeState` / `s_npcSector` | per-puppet snapshot history / freeze state / last known sector |
| write budget (`kMaxPuppetWrites` …) | cap on how many puppets are written back per frame, protecting frame time |

**Orders and fire (P2)**

| Function | Purpose |
|---|---|
| `queue_npc_order(lid, op, orderIdx, target, kind)` | the host records a puppet order change and relays it (op=1 apply / op=2 remove, …) |
| `classify_target(uid, &lid)` | translate a target uid into a peer-recognisable category + logical id |
| `md_on_attack_started()` / `md_on_attack_stopped()` | engine attack events → begin/end a behaviour row |
| `md_on_weapon_fired()` / `resolve_firer(weapon, bullet)` | firing event → work back to the firer (so the client can play an effect) |
| `flush_npc_fires_out()` | settle and emit fire rows |

**Sector transit (T2)**

| Function | Purpose |
|---|---|
| `md_on_changed_sector()` | puppet sector-change event → queue an `NpcTransitPacket` (destination sector key + arrival point) |
| `queue_npc_transit(...)` / `apply_npc_transits()` | queue / apply transits (puppets whose sector could not be resolved are parked first) |
| `s_npcTransitPending` / `s_npcSectorKey` | pending set / last known sector key per puppet |

### 3.6 Station lane (doc 4)

**Registration and mapping**

| Function | Purpose |
|---|---|
| `parse_station_tag(name)` | `"X4MP STN <idx>"` → idx |
| `parse_module_tag(name, &idx, &k)` | `"X4MP STN <idx>#<k>"` → (station index, module index) |
| `station_idx_of(uid, &idx)` | resolve a **station or one of its modules** up the ancestor chain to the station index |
| `sync_stations()` | re-resolve the local station table every 2 s (per-faction listing + name filter), maintaining `s_stationMap` |
| `station_census()` | count stations at startup (`kStationExpect`) and print each mapping |
| `station_scan_modules(idx, uid)` | enumerate modules: register `idx#k → uid`, and queue a `StationModulePacket` whenever a module hull moves |
| `station_poll_modules_client()` | client side: complete the module uid table (so the veto can restore exactly the module that was hit) |
| `station_probe_components(idx, uid)` | diagnostic: print the module composition, to verify the name keys are complete |
| `station_scan_neighbours()` | diagnostic: print ships within `kStationNeighbourKm` of a station (macro / faction / distance) |

**Vitals and state**

| Function | Purpose |
|---|---|
| `station_worst_hull_pct(uid, &shield)` | station + module sweep: worst **surviving** module percentage and worst shield (with alive/destroyed module counts) |
| `flush_station_vitals_out()` | host authority egress: full re-push / change rows / destroy rows (×`kStationKillResend`); also drives the station and module sweeps |
| `flush_incoming_station_vitals_in()` | the client applies host rows (destroy rows are idempotent; local baselines are updated) |
| `flush_incoming_station_modules()` | the client applies per-module hull (`station module row applied idx=… k=… hull=…`) |
| `station_module_uid(idx, k)` | resolve the local module uid from `idx#k` |
| `station_mark_destroyed(idx, why)` | emit a destroy row (only the **station itself** reaching zero counts as a station loss; a module reaching zero does not) |

**Local damage and the uplink (client → host)**

| Function | Purpose |
|---|---|
| `station_note_damage(source, damaged)` | the client records "the local player hit this", for later attribution |
| a block inside `md_on_hull_damaged()` | a hit is only recorded as pending when the target is in the hit set (strict attribution) |
| `player_ship_uid()` / `is_local_player_attacker()` / `client_note_player_attack()` / `player_attacks()` / `player_was_last_attacker()` | attribution family: **only targets attacked by the local player** count (window `kPlayerAttackWindowMs`) |
| `flush_client_attack_reports()` | the client turns hits into uplink rows (station idx / NPC lid / unmapped + macro and position) |
| `flush_incoming_peer_damage()` | host-side application: **decrease only**, and deliberately without a destroy flag (death is always decided by the host's engine) |
| `station_veto_raise(idx)` / `flush_station_veto()` | client local-hit veto: write the host's authoritative value back, so local combat cannot rewrite the authority |

### 3.7 Handshake, clock and readiness

| Function / symbol | Purpose |
|---|---|
| host-side handshake block (inside the frame) | keeps the world held back until CLIENT_READY arrives (log `world held back …`), then calls `release_universe()` |
| `s_clientReady` / `s_worldReady` / `s_worldReadyCount` / `s_worldExpected` | handshake state: client loaded / client built everything / count reported / rows expected |
| `s_worldAnnounced` / `s_worldAnnouncedAtMs` / `s_worldSizeSentAtMs` | announced size and its re-send timing |
| world-fingerprint block (inside the frame) | sends `kSyncWorldSig` both ways every 2 s; a mismatch ⇒ `[WORLD MISMATCH]` log line and a title marker |
| `TimeSyncPacket` egress / ingress | the host broadcasts the game time every 2 s; the client computes `offset` and raises `x4mp_host_time` (MD stores `global.$X4MPHostTimeOffset`) |
| client-side `[BOTH]` branch | in a world without spawn rows (each side builds its own NPCs) the client reports "my standing puppet count" as the world size |

### 3.8 Diagnostics and observability (read-only; never changes sync behaviour)

| Function / symbol | Purpose |
|---|---|
| `DIAG` line | every 3 s: own/peer pose, sector keys, park flag, `remoteAge`, `ghostUid` |
| `P1 SUMMARY` line | client side: `steered`, `pktIn`, `err avg/max`, `dyawMax`, `applyMs`/`frameMs`, `skipped*` counters |
| `station lane rows(...)` line | station lane summary: `sent/recv/applied`, `veto(mirror/ghost)`, `unmappedEvents`, `mapped=x/y`, `peerDmg(...)`, `modRows(...)`, `attackHits` |
| `module sweep` line | printed whenever the number of **destroyed modules** changes (`station idx=N module sweep: X of Y …`) |
| `npc vitals queued N (from M dirty ids)` | how many puppet vitals rows were emitted this round |
| `ghost diag (replica missing)` | locating information when the ghost object is missing (names, macros, ships scanned) |
| `meter_self_frame()` / `fps` / `frameMs` / `applyMs` | per-frame cost measurements (is sync work dragging the frame) |
| unknown-length warning | printed for a packet that matches no registered length and is not `>= MovePacket` (a version-mismatch signal) |

**Log conventions**: the first line of every session is `build id …`; timestamps are **UTC**; the role is written on the second line (`mode=host|client`).

---

## 4. Lua bridge (`ui\x4mp_bridge.lua`)

The bridge has exactly one job: **translate a DLL Lua event into an MD UI trigger**. Convention: string payloads carry numbers or macro names only ("numbers only in the table"), and every event name corresponds to one `event_ui_triggered` in MD.

| DLL event (`RegisterEvent` name) | Payload | MD trigger `screen / control` | Purpose |
|---|---|---|---|
| `x4mp_move` | `x,y,z,yaw,pitch,roll` | `X4MP_GhostSync / move` | Ghost pose (position + orientation) |
| `x4mp_damage` | `shield,hull,targetType` | `X4MP_SelfSync / damage` | Local hero taking damage |
| `x4mp_destroy` | — | `X4MP_GhostSync / destroy` | Remove the local ghost replica |
| `x4mp_spawn_npc` | — | `X4MP_NpcSync / spawn` | Host builds puppets locally (MD does the ship creation) |
| `x4mp_spawn_remote` | `macro` / `lid,…,x,y,z,faction…` | `X4MP_RemoteSync / spawnmacro` + `/ spawn` | Client builds puppets from rows |
| `x4mp_despawn_remote` | `lid,silent` | `X4MP_DespawnSync / despawn` | Client removes a puppet (`silent=1` = no explosion) |
| `x4mp_npc_damage` | `lid,hull,shield` | `X4MP_NpcDamageSync / damage` | Puppet damage presentation |
| `x4mp_npc_vitals` | `lid,hull,shield,…` | `X4MP_NpcVitalsSync / vitals` | Client writes **absolute** puppet hull |
| `x4mp_npc_order` | `lid,op,order,target,targetKind` | `X4MP_NpcOrderSync / order` | Puppet order relay |
| `x4mp_npc_fire` | `lid,…` | `X4MP_NpcFireSync / fire` | Puppet firing effect |
| `x4mp_universe_go` | — | `X4MP_NpcSync / go` | World released (both sides start together) |
| `x4mp_station_vitals` | `idx,hull,shield,state` | `X4MP_StationVitalsSync / vitals` | Station hull / shield / state |
| `x4mp_ghost_vitals` | `hull,shield` | `X4MP_GhostSync / vit` | Ghost vitals mirror |
| `x4mp_station_module_hull` | `idx,k,hull` | `X4MP_StationModuleSync / mod` | Single module hull |
| `x4mp_peer_event` | `kind,key,id,mod` | `X4MP_PeerEventSync / ev` | Peer player actions (`21` = docked, `22` = undocked) |
| `x4mp_host_time` | `hostTime,offset,stage` | `X4MP_HostTimeSync / clock` | Host clock → MD time base |
| `x4mp_station_module_damage` | `idx,k,…` | `X4MP_StationModuleDamageSync / dmg` | Client module-damage uplink hint |
| `x4mp_peer_hero` | macro name | `X4MP_PeerHeroSync / macro` | Peer hero macro (the ghost is built from it) |
| `x4mp_ghost_dock` | `idx` | `X4MP_PeerEventSync / ev` (kind 21) | **Alias**: equivalent to `x4mp_peer_event` docked |
| `x4mp_ghost_undock` | — | `X4MP_PeerEventSync / ev` (kind 22) | **Alias**: undocked |
| `x4mp_respawn` | — | logs one line only (the local ghost self-heals in MD) | **Alias**, no corresponding behaviour |
| `x4mp_puppet_reclaim` | keep count | `DebugError` (explicit warning) | **Alias**, not implemented here (list index may drift) |

> The alias layer exists so that mixing this build with the other implementation (`X4MP_v0.2-RC`) cannot silently lose a lane when event names differ. **Reverse gap**: `x4mp_host_time`, `x4mp_peer_hero`, `x4mp_station_module_hull` and `x4mp_station_module_damage` are not registered in that other bridge ⇒ **the DLL and the bridge must always be shipped together**.

---

## 5. MD script reference

### 5.1 Level: `md\x4mp_level_boron.xml` (cues in file order)

| Cue | Purpose |
|---|---|
| `X4MP_Level_Init` | new-game initialisation: anchor coordinates and level globals |
| `X4MP_Level_PeerSeen_Spawn` | "peer joined" signal (the DLL's `spawn`) ⇒ `PeerSeen=1` and clear the solo fallback |
| `X4MP_Level_PeerSeen_WorldGo` | `go` signal (the client's scene is standing) ⇒ `PeerScene=1`, also clears the solo fallback |
| `X4MP_Level_ReadyLatch` | **readiness master gate**: `PeerSeen ∧ ClockOk` ⇒ `Ready=1` (the single release point; re-checked every second) |
| `X4MP_Level_PeerStateReset` | **runs on every load/reload**: resets peer-derived state and silently sweeps a leftover ghost replica |
| `X4MP_Level_PeerReadyTimeout` | if no peer signal arrives within 30 s, fill in `ClockOk+PeerSeen` and set `Solo` (playable alone) |
| `X4MP_Level_PeerHeroMacro` | receives `x4mp_peer_hero` ⇒ stores `$X4MPPeerHeroMacro` (the ghost is built from it) |
| `X4MP_Level_Ghost` | ghost replica maintenance: create/rebuild per peer macro, write `$X4MPGhostShip`, macro fallback ladder and failure counting (not built while `Solo`) |
| `X4MP_Level_Mission` | mission host cue (`create_mission` attach point, objective updates) |
| `X4MP_Level_Setup` | staging: protected trade station + Xenon station + friendly fleet (gated by readiness / clock / time) |
| `X4MP_Level_TurretBase` / `TurretBase2` | delayed turret baseline count on the Xenon station (45 s, retry at 90 s) |
| `X4MP_Level_ClientXenonShip` | prepares and registers the client's own ship |
| `X4MP_Level_ClientShipSwap` | client ship swap (build the Argon Behemoth → move the player in → destroy the old ship), periodic re-check and retries |
| `X4MP_Level_PeerWatch` | client heartbeat: host clock packets timing out ⇒ `PeerDown` |
| `X4MP_Level_Freeze` | freezes the client when the host is offline (pins the ship; puppets stand still anyway without snapshots) |
| `X4MP_Level_HostShip` | host ship state and the host clock self-set |
| `X4MP_Level_Wave1/2/3` | three Xenon waves (20 S / 10 M / 1 K) |
| `X4MP_Level_KDown` | stage advance after the Xenon K is destroyed |
| `X4MP_Level_TurretCount` | graviton turret-cleared check (stage advance condition) |
| `X4MP_Level_Win` | completion check and mission completion |
| `X4MP_Level_ModuleNaming` | names the **modules** of both stations `X4MP STN <idx>#<k>` (45 s self-restarting ticker; modules appear later than the station) |

### 5.2 Shared world: `md\x4mp_testworld.xml`

| Cue | Purpose |
|---|---|
| `X4MP_SpawnScriptShip` | probe ship creation (test scaffolding) |
| `X4MP_NetworkSync` | **ghost position**: `<warp>` to the `x,y,z` sent by the bridge |
| `X4MP_GhostRotate` | **ghost orientation**: `<warp>` with `<rotation yaw/pitch/roll>` (a separate cue from the position warp, so neither blocks the other) |
| `X4MP_GhostDestroy` | silently removes the local ghost (`explosion="false"`) |
| `X4MP_SelfDamage` | self-damage correction (attributes player-entity damage to the ship) |
| `X4MP_SpawnNpc` | host builds puppets locally in batches |
| `X4MP_UniverseGo` | world released → the probe driver starts |
| `X4MP_NpcDriveStep` | probe driver ticker (0.1 s; advances several ships along a track and rotates them) |
| `X4MP_RemoteMacro` | peer macro broadcast (used when the client picks a hull) |
| `X4MP_SpawnRemote` | client builds a puppet from a spawn row (macro / faction / position / name) |
| `X4MP_DespawnRemote` | client removes a puppet per despawn row (optionally silent) |
| `X4MP_NpcDamage` / `X4MP_NpcOrder` / `X4MP_NpcFire` / `X4MP_NpcVitals` | puppet damage presentation / orders / firing / absolute vitals |
| `X4MP_P2Fx0 … P2Fx9` / `P2FxEnd` | firing effect family (one is chosen per weapon/target class) |

### 5.3 Station world: `md\x4mp_stations.xml`

| Cue | Purpose |
|---|---|
| `X4MP_SpawnNetworkCarriers` | creates the network carriers of the station world |
| `X4MP_SpawnStations` | creates the three stations and names them `X4MP STN 1/2/3` |
| `X4MP_StationMarkers` | station markers / known status |
| `X4MP_EquipStationsSeq` | **three-step loadout**: equipment fill + finalisation + defence officer; includes the drone policy (loadout filter / stock exclusion / `set_drone_armed false`) |
| `X4MP_StationVitals` | applies station hull/shield (runs on both peers; the host's authoritative value arrives through the DLL) |
| `X4MP_StationGhostVitals` | station damage caused by the ghost (the peer player) is not reported |
| `X4MP_StationModuleHull` | applies a single module hull |
| `X4MP_PeerEvent` | peer player actions (dock / undock) presentation |
| `X4MP_HostTime` | stores the host clock offset `global.$X4MPHostTimeOffset` |
| `X4MP_StationModuleRegistry` | module registry (`idx#k` → object) |
| `X4MP_StationModuleDamage` | client module-damage uplink |

### 5.4 Key global variables (`global.$X4MP*`)

| Variable | Writer | Reader | Meaning |
|---|---|---|---|
| `$X4MPGhostShip` | ghost cue | `X4MP_NetworkSync` / `GhostRotate` / `GhostDestroy` | **the single slot for the ghost pose** |
| `$X4MPPeerHeroMacro` | `PeerHeroMacro` | `Ghost` | peer hero macro name |
| `$X4MPHostTimeOffset` | `HostTime` | level gates | host time base offset |
| `$X4MPLevelPeerSeen` / `ClockOk` / `Ready` / `ReadyAt` | handshake cues | staging / ghost / waves | readiness gates |
| `$X4MPLevelPeerScene` | `PeerSeen_WorldGo` | host staging | "the client's scene is standing" |
| `$X4MPLevelSolo` | fallback / real signals | ghost cue | solo mode (no peer) |
| `$X4MPLevelIsClient` | clock cue | ship swap / freeze | is this end the client |
| `$X4MPLevelPeerDown` / `ClockAge` | `PeerWatch` | `Freeze` | host-offline detection |
| `$X4MPLevelActive` / `Wave` / `StationDown` / `TurretLeft` | `Setup` / wave cues | advance conditions | level progress |
| `$X4MPLevelTradeStn` / `XenonStn` | `Setup` | objectives / naming | the two stations |
| `$X4MPLevelClientShip` / `ClientOldShip` / `ClientShipDone` / `ClientShipPlace` | `ClientShipSwap` | swap re-check | client ship state |
| `$X4MPLevelGhost` / `GhostWant` / `GhostTries` | `Ghost` | ghost cue | ghost object and fallback counter |
| `$X4MPNpcList` / `LevelNpcNext` | level spawn blocks | name/lid computation | level roster (list index = logical id) |
| `$X4MPStationMods.{idx}` | `EquipStationsSeq` | module lane | station module list |
| `$X4MPLevelAnchorX/Y/Z` | `Init` | staging / waves | level anchor coordinates |
| `$X4MPDriveActive` / `Drive{X,Z,Dir}` / `Yaw6…10` | `UniverseGo` / `NpcDriveStep` | probe driver | test probe state |

---

## 6. World content and the project

### 6.1 Gamestarts (`libraries\gamestarts.xml`)

| gamestart id | Display name (zh) | Player ship macro | Use |
|---|---|---|---|
| `x4mp_blank` | X4MP Blank Universe | `ship_arg_s_fighter_01_a_macro` | fleet / puppet / ghost test world |
| `x4mp_stations` | X4MP Station World | `ship_arg_s_fighter_01_a_macro` | station-sync test world (three stations) |
| `x4mp_level_boron` | X4MP: Ocean Guard | `ship_bor_l_destroyer_01_a_macro` | the level: protect the trade station, three Xenon waves, destroy the Xenon station |

All three share the custom galaxy `maps\x4mp_galaxy_macro.xml`: `x4mp_cluster_01` (one sector) plus the borrowed Boron `cluster_604` ⇒ **three sectors** (one of the world-fingerprint inputs).

Text pages: `t\0001-l044.xml` (English) / `t\0001-l086.xml` (Chinese), page ids `100000` (Blank) / `100001` (Station) / `100002` (level).

### 6.2 Directory layout

```
<X4>\extensions\
├─ x4native\                      native-extension host (SDK, MIT)
│   ├─ native\x4native_core.dll   function table / hooks / Lua bridge
│   └─ sdk\                       headers (needed to build x4mp_native)
├─ x4mp_native\                   network sync layer
│   ├─ native\x4mp_native.dll     all sync logic (one C++ file)
│   ├─ ui\x4mp_bridge.lua         DLL → MD bridge
│   ├─ content.xml / ui.xml / x4native.json
└─ x4mp_test\                     world content layer
    ├─ libraries\gamestarts.xml   the three gamestart entries
    ├─ maps\x4mp_galaxy_macro.xml custom galaxy
    ├─ md\x4mp_level_boron.xml    the level
    ├─ md\x4mp_testworld.xml      shared world (ghost / NPC lanes)
    ├─ md\x4mp_stations.xml       station world (stations / modules / uplink)
    ├─ index\macros.xml · t\*.xml · content.xml
```

Development source tree (shipped in `the development source pack`): `source\examples\x4mp_native\` (DLL source + CMake), `source\extensions\` (the three extensions), `source\sdk\` / `source\x4native_sdk\`, `source\deps\{enet,minhook}`, `tools\`, `docs\`.

### 6.3 Build and deployment

| Stage | Content |
|---|---|
| Build | CMake + VS2022 BuildTools, `--config Release`; depends on eNet and the X4Native SDK headers |
| Artefact | `x4mp_native.dll` (optionally with `/MAP` for a symbol map) |
| Deployed files | `extensions\x4mp_native\native\x4mp_native.dll`, `extensions\x4mp_native\ui\x4mp_bridge.lua`, `extensions\x4mp_test\md\*.xml` |
| Role configuration (any one of three) | ① `%TEMP%\X4MP\config.txt` (`mode=` / `address=` / `port=`) ② Steam launch option `host:<addr>` / `client:<addr>` ③ command line `-x4mp host\|client <addr>` |
| Network | UDP `42069`; the **host needs an inbound allow rule**, the client does not |
| Version self-check | `build id …` as the first log line; the extension `content.xml` `version` (both ends must match to share a world) |
| Integrity self-check | `tools\manifest.txt` inside the package (per-file SHA256); `CHECKSUMS.txt` (full listing) |

### 6.4 Glossary

| Term | Meaning |
|---|---|
| **ghost** | The replica ship in this world that represents the **peer player**; always named `X4MP Ghost`; its pose is driven by the peer's broadcast |
| **puppet** | The replica ship representing a **host-world NPC**; named `X4MP NPC <lid>`; the client freezes its AI and writes snapshots into it |
| **logical id (lid)** | The id shared by both peers for one puppet, carried inside the object name |
| **sector key** | A 32-bit hash of a sector's macro name, replacing the non-portable uid |
| **world fingerprint** | A hash over the sector-key set plus its size, used to decide "same world" |
| **authority** | The single source of truth for a lane (here: NPC and station vitals = host; hero pose = each side broadcasts its own) |
| **veto** | The client writing the host's authoritative value back during a local hit, so local combat cannot rewrite the authority |
| **handshake** | The four-step readiness flow CLIENT_READY → WORLD_SIZE → WORLD_READY → WORLD_GO |
| **lane** | One end-to-end sync path (pose / vitals / orders / fire / station / module / …) |
| **solo fallback** | Degrading to a playable single-player state when no peer signal arrives |

### 6.5 Reading guide (where to look for what)

| Goal | Read |
|---|---|
| Add a new network message | §2.1 (unique length) + §3.2 (queues) + §4 (bridge) + §5 (MD trigger) |
| Change NPC sync behaviour | §3.5 + §5.2 (`X4MP_SpawnRemote` / `DespawnRemote` / `NpcVitals` / `NpcOrder` / `NpcFire`) |
| Change player ghost behaviour | §3.4 + §5.2 (`X4MP_NetworkSync` / `GhostRotate` / `GhostDestroy`) |
| Change station / turret sync | §3.6 + §5.3; **modules must be named `X4MP STN <idx>#<k>` or the module lane does not work** |
| Change the level flow | §5.1 (cue order is the flow order) + §5.4 (globals) |
| Diagnose "the two ends disagree" | §2.3 world fingerprint + the §3.8 log lines `station lane rows` / `DIAG` / `P1 SUMMARY` |
| Tell which build produced a log | the first line, `build id …` |

---

## 7. Post-merge additions (runs #26d … #26o)

> This section records everything added after §§1–6 were written (the merge with the `X4MP_v0.2-RC`
> branch plus the fixes it drove). All of it describes **the current code**; search by name.

### 7.1 Two corrections to the packet table

| Packet | Update |
|---|---|
| `DamagePacket` (13 B) | **Received but deliberately NOT applied**: damage to a player ship is now settled **only by that player's own engine** (applying it counted the same loss twice, and the MD side writes hull values directly, bypassing the engine's "shields first, then hull" pipeline). The row is still received and logged (5 s throttle): `incoming hero damage ignored (shield=… hull=… type=…)`. Peer health is shown through the **ghost vitals mirror** only ✓ |
| `NpcFirePacket` (24 B) | `logicalID = 0` is a **reserved convention**: "the peer hero" (not an NPC). From §7.9 on, **only the main weapon** is relayed (turrets get no effect yet); the peer plays a muzzle flash **on the ghost** ✓ |

### 7.2 New constants (P1 stability guards)

| Constant | Value | Meaning |
|---|---|---|
| `kStateMaxSpeed` | 2000 m/s | anything faster than this is not a velocity: drop the velocity field, keep the position (missiles/drones sit near 1500 and stay inside the cap ✓) |
| `kStateMinStepSec` | 0.05 s | two snapshots closer than this make any velocity derived from them noise |
| `kStateJumpConfirmM` | 5000 m | jump-distance threshold; only together with "implied speed over the cap" does it enter the **jump-confirmation** flow |

### 7.3 New / changed DLL behaviour

| Site | Behaviour |
|---|---|
| `apply_npc_states()` (client, snapshot ingest) | every snapshot passes `x4mp_pure::judge_sample()` first: ① velocity field over the cap ⇒ drop the velocity; ② sample spacing below the floor ⇒ drop the velocity; ③ implied speed over the cap **and** distance over the threshold ⇒ record a **jump candidate** and keep the sample **out of the history** (the puppet keeps its previous pose); a following sample near the candidate confirms the jump (candidate + current sample are both enqueued), otherwise the candidate is replaced and the wait continues ⇒ a bad coordinate can never enter the history ✓ Logs (5 s throttle): `sample jump HELD (waiting for confirmation)` / `sample jump CONFIRMED (candidate accepted)` |
| Host sampling loop (`s_npcMap` egress) | **Source-side validation** (the dual): implied speed over the cap and distance over the threshold ⇒ this frame's row is **not sent** and the velocity baseline is **not updated**; log `host sample dropped lid=N (implied … m/s over … s, dist … m)` |
| `md_on_weapon_fired()` | **Hero fire relay**: `is_local_player_attacker(e.source_id)` (walks a turret/weapon up the context chain to its Controllable and compares with the local player ship) ⇒ aggregated under `lid = 0`; NPC rows stay host-only ✓ |
| `flush_incoming()` | no longer raises `x4mp_damage` (see 7.1) ✓ |
| `flush_client_attack_reports()` | targets where `is_ghost_uid()` is true are **never reported** (a mirror object must not be reported; player ships are settled by their own engine) ✓ |
| `station_note_damage()` (client) | records **which module** was hit: parses the object name `X4MP STN <idx>#<k>` and stores the uid in `s_stationVetoModPending[idx][uid]` ✓ |
| `flush_station_veto()` (client) | ① new **module-level write-back**: resolve uid→k, take the host's last authoritative value (`s_stationModHull[idx][k]`) and raise `x4mp_station_module_hull`; log `MODULE veto applied idx=… k=… host=… n=…` ② new **recency rule**: when the host's row is newer than this local hit, the veto **no longer writes back** (`station veto skipped … (authority already landed)`); the timestamp tables are `s_stationNoteAtMs` / `s_stationHostRowAtMs` ✓ |
| `on_game_loaded()` | ① **C1** NPC registry reset (maps, history, freeze state, `s_npcPrev`, `s_fireAgg`, `s_uidLid`, tombstones, `s_nextLogicalID`, `g_npc_stage`, …) plus the marker line `npc registry reset (game loaded)` ② station-side clears as before, plus `s_npcJumpCand` and the veto timestamp tables ✓ |
| In-frame handshake block | **C2 reconnect re-announce**: `s_peerReconnected` (set by the network thread on `ENET_EVENT_TYPE_CONNECT`) is consumed ⇒ logs `reconnect - re-announcing state (idempotent re-push)`; the host resets the size announcement and the release state and forces a full station push, the client resets CLIENT_READY and the size-wait state ✓ (idempotency is provided by the absolute-vitals, tombstone and full-push lanes) ✓ |

### 7.4 New pure core: `x4mp_pure.h`

- **House rule**: nothing in this file may touch the engine, the wall clock or any global state; every input is a parameter ⇒ its behaviour can be proven **at compile time** ✓
- Exports: `judge_sample(Vec3 prevPos, bool hasPrev, double dt, Vec3 samplePos, Vec3 sampleVel, maxSpeed, minStepSec, jumpConfirmM)` → `{trustVelocity, jump, dist2, dt}`, and `jump_confirms(cand, sample, threshold)` ✓ (all comparisons use squared distances, avoiding `std::sqrt`'s constexpr limits)
- **9 behavioural assertions** (`static_assert`, executed by the build): normal flight / a 1500 m/s missile is still trusted / a 420 km/s garbage velocity only loses its velocity / **a 73 km bad coordinate is judged a jump** / a legitimate slow long-range transit is not misjudged / sub-floor sample spacing / a consistent second suspicious sample confirms / two mutually inconsistent suspicious samples never confirm / the first sample is never a jump ✓
- Why it matters: **a behaviour change now breaks the build** instead of only being caught by text comparison. (This is our adaptation of the same idea as the 0.2-RC `x4mp_pure.h`; they drive a runtime replay, we use constexpr plus compile-time assertions ✓)

### 7.5 New / changed MD and bridge

| File | Content |
|---|---|
| `md\x4mp_level_boron.xml` | ① `X4MP_Level_ModuleNaming` now also **builds the module registry once** (`global.$X4MPLevelMods.{1,2}`, guarded by `$X4MPLevelModsReg1/2`) while continuing to (idempotently) re-name the modules `X4MP STN <idx>#<k>` every 45 s ② new cue **`X4MP_Level_StationModuleHull`**: listens on `X4MP_StationModuleSync/mod` and writes `set_object_hull` through the registry (the **write-back end** of the module-level veto; it coexists with the identically named cue in the station world because each uses its own registry) |
| `md\x4mp_testworld.xml` | ① new cue **`X4MP_GhostRotate`**: position and orientation live in two separate cues, and `<rotation>` multiplies all three angles by `1deg` to make them proper angle values (bare numbers are read as radians, which looks like the ship tumbling around an axis) ② `X4MP_GhostDestroy` now uses `explosion="false"` (the ghost disappears silently) ③ `X4MP_NpcFire` gained a `lid == 0` branch that plays a muzzle flash **on the ghost**: `<add_effect object="global.$X4MPGhostShip" effect="'muzzle_gen_s_laser_01_mk1'"/>` (the idiom is taken from the already-proven `X4MP_P2Fx2` probe in this same file) ✓ |
| `ui\x4mp_bridge.lua` | **Event alias layer** (aligned with 0.2-RC): `x4mp_ghost_dock` / `x4mp_ghost_undock` → `X4MP_PeerEventSync/ev` (kind 21/22); `x4mp_respawn` only logs; `x4mp_puppet_reclaim` raises an explicit error ✓ RegisterEvent went from 18 to 22 |

### 7.6 New globals

| Variable | Writer | Reader | Meaning |
|---|---|---|---|
| `$X4MPLevelMods.{idx}` | `X4MP_Level_ModuleNaming` (once) | `X4MP_Level_StationModuleHull` | module registry of the level's two stations (write-back target of the module-level veto) |
| `$X4MPLevelModsReg1` / `Reg2` | same | same | "registry already built" guard (avoids rebuilding every 45 s) |

### 7.7 Tooling (`tools\`)

| Tool | Purpose |
|---|---|
| `deploy.ps1` | **Deployment gate + ledger**: ① refuse to deploy while `X4`/`X4_2` run ② verify the source's `build id` **inside the binary** before deploying ③ deploy to 5 targets (E:, D:, LAN pack, double-box pack, source pack) with **read-back size+SHA256** ④ write the ledger `D:\x49.0\X4MP\deployed.json` (build id / cpp md5 / dll size+sha256 / per-target records / process snapshot) ⑤ `-DryRun` shows the plan only ✓ |
| `gate.ps1` | **14 static assertions**: wire-length uniqueness (two wire structs sharing a length fails) · bridge↔MD↔DLL consistency (every `AddUITriggeredEvent` needs an MD cue; every `RegisterEvent` needs a DLL `raise_lua`, minus a documented allow-list) · MD structure and preconditions (XML parses; cue open/close balance **after stripping comments**; unique cue names; level module naming/registry; ghost single slot; both pose cues present; the module write-back cue exists) · delivery consistency (`content.xml` version, 59-file manifest hashes) ✓ exit code 0/1 ✓ |

**The routine for every change**: edit the code → bump the `build id` literal → build (the compile-time behaviour assertions run here) → `gate.ps1` all green → close the game → `deploy.ps1` → start the test and check the build id on the log's first line ✓

### 7.8 New log markers (for attribution)

| Line | Meaning |
|---|---|
| `build id run26x-…` | build identity of the session (first line) |
| `npc registry reset (game loaded)` | C1: load/reload reset |
| `reconnect - re-announcing state (idempotent re-push)` | C2: reconnect re-announce |
| `incoming hero damage ignored (…)` | peer hero damage deliberately dropped |
| `sample jump HELD / CONFIRMED` | client guard: jump held / confirmed |
| `host sample dropped lid=…` | host source-side validation dropped a bad sample |
| `MODULE veto applied idx=… k=… host=…` | module-level veto wrote the authority back |
| `station veto skipped … (authority already landed)` | veto recency rule engaged |
| `[WORLD MISMATCH] …` | the two peers are not in the same world |

### 7.9 Main-weapon effects + turret damage synchronization (run #26p)

**A. Only the main weapon's fire is relayed** (`md_on_weapon_fired()`)
- Test: the firer belongs to the local player ✓ **and** the weapon is not under a turret — `x4n::entity::find_ancestor(uid, GameClass::Turret) != 0` (`Turret = 104` in the SDK) ✓
- A fixed-mount main weapon ⇒ its ancestor chain holds only the ship ⇒ aggregated into `s_fireAgg[0]` (lid 0 = peer hero) ⇒ the peer plays a muzzle flash on the ghost ✓
- A turret weapon ⇒ **no effect**, but **its damage is still synchronized** (see B) ✓; both cases `return`, so player fire never enters the NPC lane ✓

**B. Damage dealt by turrets is synchronized to the victim** (`md_on_hull_damaged()`, client side)
- Why it is needed: the puppets in the client's world are **real ships** whose turrets fire from **the client's own engine** ⇒ that damage never happens on the host (the host's copy is "authoritative but not being shot at") ⇒ without an uplink the two ends diverge ✓
- How: in the event, `source_id` is the **attacker** and `damaged_component` the **victim** (the same reading as in `md_on_killed`) ⇒ when "**one of our puppets is the attacker**", the victim's current vitals are recorded in `s_clientAttackPending[victim uid]` ⇒ the existing uplink carries it (stations per module / NPCs by lid / unmapped by macro+position) and the host applies it **decrease-only** ✓
- **No echo**: after the host writes the value back, the locally triggered callback has **no attacker** (`set_object_hull` is not an attack event) ⇒ `npc_lid_of(source)` fails ⇒ nothing is reported again ✓
- Result: **turret damage really lands on the victim on both ends, with no effects needed** ✓











