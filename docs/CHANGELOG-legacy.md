# Changelog — earlier development rounds (condensed)

The full  logs of these rounds live in the development tree. This is the English summary
of how the project got from "two ships do not agree where they are" to 0.1.

## run #21–#23 — making the two sides agree on *what* exists

* **Name as key.** Everything shared across machines is addressed by object **name**:
  `X4MP Ghost`, `X4MP NPC <lid>`, `X4MP STN <idx>`, `X4MP STN <idx>#<k>`.
  Object ids are local, so they cannot be sent.
* **Lane separation.** `hero` (the other player's ship = the ghost replica) and `NPC` (puppets)
  became two independent pipelines with separate containers and separate packets.
* **Station lane.** Container values plus **per-module** hull/shield/state rows, sent on change
  and in full when the peer becomes ready.
* **Veto discipline.** The non-authoritative side never decides; it reports and is corrected.

## run #24–#25 — damage authority and the first cross-machine session

* **Player ships**: resolved by the local engine on both sides; the other side only mirrors.
* **Client hits**: the client uploads its own hits (`PeerDamagePacket`), the host applies them
  and **never raises** a value.
* **First cross-machine test** (2026-09-27) failed for a mundane reason: the two players picked
  different New Game entries. The host reported `sectors=3`, the client `sectors=2`, and
  `host sync alive=0 mapped=0` — connected, clock-synced, nothing to sync.
  Lesson: the mod has to *say* when the worlds differ.

## run #26 — world fingerprint, single-player fallback, mission level

* **World fingerprint** (`kSyncWorldSig`): each side sends an FNV-1a hash of its sorted sector
  keys plus the sector count every 2 s. A mismatch prints
  `[WORLD MISMATCH] ... local sig=... sectors=... vs peer sig=...` and adds
  ` [X4MP WORLD MISMATCH]` to the window title. No new packet size — it reuses the 8-byte
  sync message.
* **Single-player fallback**: if no peer signal arrives within 30 s the level builds anyway
  (`X4MP LEVEL: no peer signal within 30 s => continuing in single-player mode`), and the ghost is skipped
  (`not $X4MPLevelSolo`).
* **Re-announce on reload**: `X4MP_Level_PeerStateReset` runs on every `event_game_started`,
  because `event_game_started` also fires when loading a save — previously a reload inherited
  "peer already ready" and spawned a ghost with a stale macro (the reported "extra ghost /
  S fighter").
* **Mission level** `x4mp_level_boron`: protective objective, three waves, a Xenon carrier,
  win/lose cues — all gated on the shared clock so the client cannot start the waves first.

## 0.1 — the first published pack

* one-click install/uninstall, role config in `%TEMP%\X4MP\config.txt`, firewall helper,
  manifest verification, `x4mp_savecheck.ps1` for save-file forensics;
* the mission level, the station world and the blank test universe;
* documented limitations: no weapon-fire visuals on the peer, no turret lane, module rows may
  land incompletely.

## Between 0.1 and 0.1.1

* **run #26v** — client ship becomes the Terran Osaka; ghost fallback and the DLL whitelist follow.
* **run #26w / #26x** — the NPC "zero-hull remnant" work and the NPC authority write-back
  (the veto). Both are in 0.1.1; the short-lived `destroy_object` variant is not.
* Everything from **run #26x-fx1 … fx26** (effect research: `add_effect` probes, `aim_turret` /
  `fire_turret`, turret census, arm/mode assertions) is **excluded** from 0.1.1 by design.
