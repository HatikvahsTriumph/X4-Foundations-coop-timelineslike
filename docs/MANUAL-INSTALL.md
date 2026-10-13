# Manual installation (no scripts)

Use this if you do not want to run the PowerShell installer, or if your antivirus blocks it.

## 1. Copy the extensions

Copy these three folders from `files\extensions\` into your game's `extensions\` folder:

```
x4native      ->  <X4 Foundations>\extensions\x4native
x4mp_native   ->  <X4 Foundations>\extensions\x4mp_native
x4mp_test     ->  <X4 Foundations>\extensions\x4mp_test
```

`<X4 Foundations>` is the folder that contains `X4.exe`. Typical locations:

* `C:\Program Files (x86)\Steam\steamapps\common\X4 Foundations`
* `D:\SteamLibrary\steamapps\common\X4 Foundations`
* GOG: `C:\GOG Games\X4 Foundations`

**Delete any older copy of the same folders first** — do not leave a backup copy inside
`extensions\` (X4 loads every folder it finds there, and two copies of the same extension make
the two players end up in different worlds).

After copying, `<X4>\extensions\` should contain exactly one of each, and nothing else of ours.

## 2. Write the role config

The game reads `%TEMP%\X4MP\config.txt`. Create the folder and the file by hand:

```
mode=host
address=127.0.0.1
port=42069
```

For the **client**, set the host's VPN address instead:

```
mode=client
address=26.0.0.5
port=42069
```

`%TEMP%` is usually `C:\Users\<you>\AppData\Local\Temp`. Save the file as **plain ASCII**,
ANSI or UTF-8 without BOM, with a trailing newline.

If the file is missing the game starts as **host** on `127.0.0.1:42069`.

## 3. Firewall (host only)

The host needs one inbound rule for **UDP 42069**. Easiest: run this in an **administrator**
PowerShell (it can be deleted afterwards with `Remove-NetFirewallRule -DisplayName X4MP`):

```powershell
New-NetFirewallRule -DisplayName X4MP -Direction Inbound -Action Allow `
  -Protocol UDP -LocalPort 42069 -Profile Any
```

Or by hand: Control Panel → Windows Defender Firewall → Advanced settings → Inbound Rules →
New Rule → Port → UDP → specific local port `42069` → Allow → tick all profiles → name it
`X4MP`.

The client needs **no** inbound port.

## 4. Verify the files

Compare the SHA-256 of the shipped files with `CHECKSUMS.txt`:

```powershell
Get-FileHash .\files\extensions\x4mp_native\native\x4mp_native.dll -Algorithm SHA256
```

The DLL must be **567,296 bytes** and report build id `run26x-npcveto`:

```powershell
Select-String -Path .\files\extensions\x4mp_native\native\x4mp_native.dll -Pattern 'build id \S+' |
  Select-Object -First 1
```

## 5. Start the game

Launch X4 normally (or `2-PLAY.bat`). Both players pick the **same** New Game entry. Then check
the log file for `hosting on port 42069` / `peer connected`.

## 6. Uninstall by hand

1. Delete `<X4>\extensions\x4mp_native` and `<X4>\extensions\x4mp_test`.
2. Delete `x4native` **only if** you did not install it for another mod.
3. Delete `%TEMP%\X4MP\config.txt`.
4. Delete the firewall rule named `X4MP` (if you created it).
