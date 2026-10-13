# X4MP — unofficial co-op multiplayer for X4: Foundations

**Version 0.1.1** · Windows · X4: Foundations (Steam / GOG, current release branch)

X4MP lets two players play **together in the same X4 universe**: one machine acts as the
**host** (the world is created there) and the other joins as a **client**. Today that means a
shared mission level with a mirror of the other player's ship, synchronised NPC fleets and
station damage, and an authoritative host for damage resolution.

> This is a fan project. It is **not** affiliated with, endorsed by or supported by Egosoft.
> Expect rough edges — see [Known limitations](#known-limitations). Please use a **new
> gamestart** for multiplayer; save compatibility between versions is not guaranteed.

**Requirements**

* X4: Foundations (Steam / GOG, current release branch) on both machines, **same version**.
* The **Boron DLC** (*X4: Kingdom End*) — the co-op scenario is a Boron level
  (`x4mp_level_boron`, the real Boron sector *Ocean of Fantasy*).
* The **Terran DLC** (*X4: Cradle of Humanity*) — the client's ship is the Terran destroyer.
* Both players must own the same DLCs; otherwise the two sides load different content.

---

## Quick start

1. **Both players install the same pack** (keep the folders together; the installer looks for
   `files\extensions\` next to itself).
2. Put the pack **outside** the game folder, then double-click **`1-INSTALL.bat`**
   (or follow `docs/MANUAL-INSTALL.md` to copy the folders by hand).
3. Pick a role when asked:
   * **Host** — the world is created on this machine.
   * **Client** — you will be asked for the host's **VPN address** (Radmin/ZeroTier).
4. Both players start X4 with the role passed by the installer, then click **New Game** and
   choose the **same entry** (the co-op gamestart).
5. Double-click **`2-PLAY.bat`** to launch the game through Steam if you prefer.

Full details: **`docs/INSTALL.md`** · first-run checklist: **`docs/TEST-PLAN.txt`**.

## What works in 0.1.1

| Area | Behaviour |
|---|---|
| Ghost replica | The other player's ship is recreated locally, follows position + rotation, and mirrors hull/shield |
| NPC lane | Host samples ~10 Hz and broadcasts; the client follows. NPC deaths, orders and fire events are relayed |
| NPC authority | The host's hull/shield values win; client-side local damage is written back (no more "my NPC died first") |
| Station lane | Container **and per-module** hull/shield/state rows, with veto on the non-authoritative side |
| Damage authority | The host applies client hits (**only ever downwards**); your own ship is resolved by your own engine |
| World handshake | Clock packet gates the scene; the client freezes instead of drifting when the host leaves |
| Mission flow | Objective stations, three waves, carrier spawn, win/lose — driven by the shared world state |
| Fail-safe | Single-player fallback after 30 s without a peer signal; world fingerprint mismatch is surfaced in the window title |

## Known limitations (0.1.1)

* **Client ship** is the Terran *Osaka* (`ship_ter_l_destroyer_01_a_macro`) — this needs the
  **Terran DLC**; the Argon Behemoth of 0.1 is no longer used.
* The co-op scenario is a **Boron** level, so the **Boron DLC** is required on *both* machines
  (the level places you in the real Boron sector *Ocean of Fantasy* and gives the host the
  Boron Ray).
* **Weapon fire effects are not shown on the peer.** Fire *data* is relayed in both directions,
  but the rendering path is still being researched; this release deliberately ships **no**
  effect probes.
* **Turret destruction is not synced yet.** If the host loses a turret, the client's copy may
  keep firing.
* **Station module rows** may report fewer `applied` than `sent` (module-level landing).
* Module naming vs. table base (1-based vs 0-based) is still under investigation — see
  `docs/QA-REVIEW-CHECKLIST.md`.
* No voice/menu integration yet; there is no matchmaking — you provide the VPN/tunnel yourself.

## Repository layout

```
1-INSTALL.bat / 2-PLAY.bat / 3-UNINSTALL.bat   one-click helpers (English console output)
files/extensions/x4mp_native                   the network layer (DLL + Lua bridge)
files/extensions/x4mp_test                     the test/mission extension (MD scripts)
files/extensions/x4native                      third-party framework, shipped as required
tools/                                         installer + diagnostics PowerShell scripts
docs/                                          install, changelog, QA checklist, test plan, technical reference
CHECKSUMS.txt                                  SHA-256 of every shipped file
```

## Credits

* **eg3r** — thank you. eg3r created **X4Native**, the framework this mod is built on, and also
  built the Porthole tunnel integration that lets players connect without port-forwarding.
* **Egosoft** — for X4: Foundations and its modding interface.
* **Everyone who tested** — the anonymous testers whose sessions and log files made this
  release possible.

## Third-party components

`files/extensions/x4native` is **eg3r's** X4Native framework, redistributed unmodified; all
rights remain with him. X4: Foundations and all game assets belong to Egosoft. Only the
`x4mp_native` / `x4mp_test` extensions and the `tools/` scripts are original work of this
project. See `docs/THIRD-PARTY.md`.

## Licence

The original parts of this project (the `x4mp_*` extensions and `tools/`) are released under the
**MIT licence** — see `LICENSE`. Third-party components keep their own terms.

X4MP is an unofficial, **non-commercial fan project**: please do not sell it, its builds, or any
modified version of it. Code reuse is welcome under the MIT terms — please just keep it free.

## Changelog

* `docs/CHANGELOG-0.1.1.md` — what changed in this release, and what it deliberately excludes.
* `docs/CHANGELOG-legacy.md` — condensed history of the earlier development rounds.
* `docs/TECHNICAL-REFERENCE.md` — framework and code reference (English).
