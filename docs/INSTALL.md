# Installation

Two ways: the **installer** (recommended) or **by hand** (`MANUAL-INSTALL.md`). Both end up in
the same place: the three extension folders copied into

```
<X4 Foundations>\extensions\{x4native, x4mp_native, x4mp_test}
```

and one small role config file for the game to read.

## 1. Before you start

* **DLCs.** Both players need the **Boron DLC** (*X4: Kingdom End*): the co-op scenario is a
  Boron level (`x4mp_level_boron`, the real Boron sector *Ocean of Fantasy*, host flies the
  Boron Ray). The **Terran DLC** (*X4: Cradle of Humanity*) is also needed — the client's ship
  is the Terran **Osaka** (`ship_ter_l_destroyer_01_a_macro`). Mixed DLC ownership means the
  two sides load different content and will not line up.
* **Close X4 completely** on both machines (a running game locks the DLL and the copy fails).
* Keep the pack **outside** the game folder. The installer refuses to run if it finds itself
  inside `<X4>\extensions\`.
* Both players must run the **same X4 version** and the **same pack version**.

## 2. Run the installer

Double-click **`1-INSTALL.bat`** in the pack folder. It will:

1. locate your X4 Foundations folder (registry → `libraryfolders.vdf` → common paths → ask you);
2. copy `files\extensions\{x4native,x4mp_native,x4mp_test}` into the game, moving any old
   same-named folder out to `<X4>\_x4mp_backup_<timestamp>\` first
   (a stale copy of our extensions inside `extensions\` is loaded as a *second* extension and
   makes the two players end up in different worlds — that is why this matters);
3. write the role config to `%TEMP%\X4MP\config.txt`:

   ```
   mode=host        (or mode=client)
   address=127.0.0.1   (client: the host's VPN address, e.g. 26.0.0.5)
   port=42069
   ```

4. **host only:** add an inbound UDP 42069 firewall rule (needs an elevated prompt; if that is
   refused it prints the manual steps);
5. verify every shipped file against `tools\manifest.txt` (SHA-256).

Non-interactive usage, if you prefer a console:

```powershell
powershell -ExecutionPolicy Bypass -File tools\x4mp_install.ps1 -Role host
powershell -ExecutionPolicy Bypass -File tools\x4mp_install.ps1 -Role client -HostIp 26.0.0.5
powershell -ExecutionPolicy Bypass -File tools\x4mp_install.ps1 -DryRun   # check only
```

## 3. Pick your worlds (both players!)

Start the game (or double-click `2-PLAY.bat`), then **New Game** and pick the **same entry** on
both machines:

* **X4MP Blank Universe** — 20 Argon M ships + 1 Xenon K, the lightest sync test.
* **X4MP Station World** — 3 stations with station attack synchronisation.
* **X4MP Ocean Guard** — the mission level (protective objective, waves, carrier).

If the two sides pick different worlds they will connect, sync clocks, and never see each
other's ships. 0.1.1 detects this: the window title gains
` [X4MP WORLD MISMATCH]` and the log prints `local ... vs peer sig=...`.

## 4. Verify the link

* window title shows `[HOST]` / `[CLIENT]`;
* log (`Documents\Egosoft\X4\<profile>\x4native\x4mp_native\x4mp_native.log`) shows
  `hosting on port 42069` then `peer connected`;
* a ghost replica of the other player exists and follows them.

## 5. Uninstall

`3-UNINSTALL.bat` removes the extensions (moving them to `extensions\_x4mp_removed_*`), deletes
`%TEMP%\X4MP\config.txt` and the firewall rule.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Installer says the pack is incomplete | The ZIP was only partly extracted — extract the whole archive into an empty folder |
| Installer says you extracted inside the game folder | Move the pack outside `<X4>` and run it there |
| `Cannot find path ...\files\extensions\x4native` during copy | Same as above, or antivirus quarantined a file — see `ANTIVIRUS-NOTES.md` |
| Client never sees `peer connected` | Host firewall (UDP 42069), VPN not connected on both sides, or a wrong address |
| Both connect but see nothing of each other | Different worlds/gamestarts (see step 3) |
| Client ship is missing a loadout / empty hull | It was created without a faction loadout; re-enter the level |
| "Property lookup failed" spam in the log | Please report it with the log lines — see `docs/QA-REVIEW-CHECKLIST.md` (P1-4) |
