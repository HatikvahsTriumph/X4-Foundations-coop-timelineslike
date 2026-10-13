# Third-party components

This package ships other people's work as well as our own.

## Shipped, unmodified

| Component | Where | Owner / terms |
|---|---|---|
| **X4Native** framework | `files/extensions/x4native/` (`x4native_core.dll`, `x4native_64.dll`, SDK headers, `version_db/`) | Created by **eg3r**. Redistributed unmodified as a runtime requirement; all rights remain with him. |
| **X4: Foundations** game data | accessed at runtime only (no game assets are redistributed here) | Egosoft. All rights reserved. |
| X4 event/function identifiers, MD schema names, ship/station macro names | inside our own scripts | Egosoft (used as the public modding interface) |

## Original work of this project (MIT, see `LICENSE`)

The MIT licence above covers **only** these original parts. Third-party components (in
particular the X4Native framework) keep their own terms.


* `files/extensions/x4mp_native/` — the network layer (DLL + `ui/x4mp_bridge.lua`)
* `files/extensions/x4mp_test/` — the test/mission extension (`md/*.xml`, gamestart, map, texts)
* `tools/*.ps1`, `*.bat`, and everything under `docs/`

## Thanks

* **eg3r** — X4Native, and the Porthole tunnel integration.
* **Egosoft** — X4: Foundations.
* **The anonymous testers** — for the sessions and log files.

If you are one of these authors and want a change to how your work is credited or shipped,
open an issue and it will be handled.
