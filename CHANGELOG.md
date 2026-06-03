# ItemPass Changelog

## v1.7.2
**Speed Mode pipeline refactor, debug logging, update check, and bugfixes**

### New Features
- **GitHub auto-update check** - on load, fetches `ItemPass.lua` from GitHub and parses `SCRIPT_VERSION` directly. Notifies if a newer version is available. No separate `version.txt` required.
- **Debug logging mode** - UI checkbox writes all status messages and verbose FSM state transitions to `itempass_debug.txt`. Fully gated behind a flag so the render loop is never affected when logging is off.

### Speed Mode Refactor
- Speed Mode now uses a pre-built flat pipeline of `{delay, fn}` steps built once at chain start (`buildSpeedPipeline`).
- Uses `os.clock()` for sub-second precision (was `os.time()` = 1s granularity).
- Dedicated `speedTick()` replaces inline speed branches in `scmTick()`.
- `chainTick()` routes to `speedTick` vs `scmTick` based on `EXP_speedMode`.
- New phases: `SPEED_PIPELINE` (stepping) and `SPEED_WAIT_RETURN` (polling).
- 10s timeout on final return with auto-retry pull.

### Bugfixes
- Fixed: driver was excluded from rotation due to `m.name ~= me` filter in `buildSCMList()`; checked in UI but never actually in the chain.
- Fixed: Chain Preview showed `[driver]`/`[end]` bookends regardless of actual inclusion; now shows `[click]` at real position and `[return]` when not in rotation.
- Fixed: Speed Mode - driver-first self-transfer wasted full `SPEED_GIVE_DELAY`; give step is now skipped and `/useitem` fires immediately.
- Fixed: Speed Mode - driver-last `useDelay` was 0 (item not yet transferred); now uses `SPEED_GIVE_DELAY` for all non-first positions.
- Fixed: Speed Mode - `SPEED_WAIT_RETURN` hung forever when driver was last (item consumed/used, `countItemByName` always 0); completion is now timer-based via `speedDriverIsLast` flag (castTime + 1.5s buffer).

### Housekeeping
- Renamed "controller" to "driver" throughout (all strings, variable names, comments, and UI labels).
- Removed `(EMU)` tag from loading message.
- Removed `[DBG]` prefix from status panel messages.

---

## v1.6.0
**Experimental additions**

- **Speed Mode** - new checkbox in Experimental UI section.
  Uses fixed short delays instead of adaptive polling: give=2.5s, use=castTime+1.5s, return max=3.0s.
  ~2x faster than adaptive mode on stable servers. Routes through driver same as normal mode.
  Not recommended for unstable servers - errors may be silently skipped.

- **Auto-resume after /fic locate** - paired checkbox alongside Auto-locate.
  When enabled: after the item is pulled to driver, chain starts automatically once item is confirmed in inventory.
  Previously required manual Start press after pull.

---

## v1.5.1
**Experimental bugfixes**

- Fixed: `/fic` only accepts a single word. Added `getFicKeyword()` to extract the longest
  non-filler word from the item name. e.g. `"Nimbus of Midnight"` -> `/fic Midnight`.
  Filler words: `of`, `the`, `a`, `an`, `and`.

- Fixed: event parser now matches E3's actual `/fic` output format:
  `<Name> [Pack] Item Name - bag(N) slot(N) count(N)`
  Old pattern (`has item`) never matched real E3 output, causing empty results.

---

## v1.5.0
**Experimental layer: Auto-locate item**

- Added `EXP_autoLocate` toggle (UI checkbox under Experimental section).
  When ON: if driver doesn't have the item at chain start, fires `/fic` to locate it.
- `/fic` output captured via `mq.event`; 2-second silence window collects all results.
- Pulls matching item to driver via `requestItemTransfer` (pull-only, safe).
- Chain does NOT auto-resume after pull - user hits Start again (fixed in v1.6.0).
- `ficTick()` runs in `chainTick()` gate; yields `scmTick` until resolved.
- Zero impact when OFF - all EXP code is fully isolated from core FSM.

---

## v1.4.2
**UI / UX improvements**

- Window now opens expanded at 500x700 on first use.
- Latency section rewritten with plain language:
  - "Last chain took" - total elapsed time for completed chain, resets on next start.
  - "Avg swap time" - explains what the learned value means and sample count.
  - Override label clarified to "Override swap time (s, 0=auto)".

---

## v1.4.1
**Bugfix: window collapse**

- Fixed: collapsing window to title bar permanently hid the UI.
  `ImGui.Begin` returns `false` on collapse; old code set `showUI=false`, unregistering the window.
  Fix: leave `showUI` alone on collapse, just call `ImGui.End()`. Window re-expands on click.
  `/itempassui` still toggles full hide/show.

---

## v1.4.0
**Performance update**

- `BASE_TRADE_TIMEOUT` reduced from 20s to 5s (server latency is much lower).
- Adaptive latency seeded at 1.5s baseline - no longer starts blind on first chain.
- Dynamic cast time detection via local inventory scan at chain start.
- `MEMBER_USE` delay = detected cast time + adaptive network buffer (not flat 3s).
- Fixed: `mq.imgui.init` used for correct ImGui registration.
- Fixed: `pcall` wrapper on entire GUI to prevent crashes from killing the script.
