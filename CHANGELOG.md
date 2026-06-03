# ItemPass - Changelog

All notable changes to ItemPass are documented here.

---

## [1.7.2] - 2026-06-02

### Bugfixes
- **Fixed: Controller excluded from rotation** - `buildSCMList()` had an explicit
  `m.name ~= me` filter that always stripped the controller from the chain list, even
  when they were checked in the UI. The Chain Preview showed `[controller]` and
  `[end]` bookends regardless of actual inclusion, making it impossible to tell
  whether the controller was actually in the rotation. Both issues are fixed: the
  filter is removed and the preview now shows `[click]` at the controller's real
  position, and `[return]` (instead of `[end]`) when the controller is not in the
  rotation.
- **Fixed: Speed Mode - controller-first self-transfer** - when the controller was
  first in the chain, the pipeline issued a self-giveme (controller -> controller),
  wasting the full `SPEED_GIVE_DELAY` (3s) before issuing `/useitem`. The give
  step is now skipped and `/useitem` fires immediately when the controller is first.
- **Fixed: Speed Mode - controller-last useDelay was 0** - when the controller was
  last in the chain, `useDelay` was incorrectly set to `0` (a shortcut intended
  only for the controller-first case). This caused `/useitem` to fire before the
  item had finished transferring from the previous member. Fixed to use
  `SPEED_GIVE_DELAY` for all non-first positions, including controller-last.
- **Fixed: Speed Mode - SPEED_WAIT_RETURN hung when controller was last** - after
  the controller used the item at the end of a chain, `countItemByName` returned
  `0` indefinitely (item consumed/used), causing the chain to never complete and
  retry in a loop every 10s. Added `speedControllerIsLast` flag; when set,
  completion is timer-based (castTime + 1.5s) instead of polling.

### Added
- **Debug logging mode** - new UI section with an "Enable Debug Log" checkbox. When
  enabled, all status messages and verbose `[DBG]` FSM tracing are written to
  `itempass_debug.txt` in the MQ root. Includes a Clear Log button and a session
  header timestamp. Verbose tracing is gated behind a `verbose` parameter in
  `buildSCMList()` so the render loop never triggers file I/O.

---

## [1.7.1] - 2026-05-21

### Bugfix
- **Group member checkboxes now default to unchecked on load** - previously all group
  members were added to the chain list with `enabled = true`, causing every member to
  be selected automatically when the script loaded or a new member joined. Members are
  now inserted with `enabled = false` so the user explicitly opts each toon in before
  starting a chain. Applies to both group members and the controller toon itself.

---

## [1.7.0] - 2026-05-04

### Speed Mode - Pipeline Refactor
- **Pipeline architecture** - Speed Mode now pre-builds a flat ordered list of
  `{delay, fn}` steps at chain start via `buildSpeedPipeline()`. All commands are
  queued upfront and fired in sequence; no inline branching inside `scmTick()`.
- **Sub-second precision** - timing now uses `os.clock()` instead of `os.time()`,
  eliminating the 1-second granularity floor that caused jitter in tight chains.
- **Dedicated `speedTick()`** - replaces the old inline speed-mode branches inside
  `scmTick()`. `chainTick()` routes to `speedTick` or `scmTick` based on the
  `EXP_speedMode` flag; the two paths are now fully separated.
- **New FSM phases** - `SPEED_PIPELINE` (stepping through the queue) and
  `SPEED_WAIT_RETURN` (polling for item arrival after the final pull command).
- **10s return timeout with auto-retry** - if the item hasn't arrived 10s after the
  last pull request, the pull is automatically re-issued once.
- **`resetSCMState()` now clears pipeline state** - `speedPipeline`,
  `speedPipelineIndex`, and `speedPhaseStart` are reset alongside the core FSM.

---

## [1.6.0] - 2026-01-xx

### Experimental additions
- **Speed Mode / Fire and Forget** - new UI toggle under the Experimental section.
  Bypasses all adaptive waits and inventory polling. Uses fixed delays calibrated
  against hotpotato timing (give: 3.0s, use: castTime + 2.0s, return max: 4.0s).
  Approximately 2x faster than adaptive mode on a stable chain. Item loss is possible
  if the server lags - use only when the chain is reliable.
- **Auto-resume after /fic locate** - paired checkbox next to Auto-locate.
  When enabled, the chain starts automatically the moment the item arrives at the
  controller after a `/fic` pull. No need to hit Start a second time.

---

## [1.5.1] - 2026-01-xx

### Experimental bugfixes
- **Fixed: `/fic` keyword extraction** - `/fic` only accepts a single word.
  `getFicKeyword()` now extracts the longest non-filler word from the item name.
  Example: "Nimbus of Midnight" -> `/fic Midnight`. Filler words: of, the, a, an, and.
- **Fixed: `/fic` output parser** - previous regex never matched E3's actual output
  format. New pattern correctly matches:
  `<Name> [Pack] Item Name - bag(N) slot(N) count(N)`

---

## [1.5.0] - 2026-01-xx

### Experimental layer (safe, isolated from core FSM)
- **Auto-locate item** - new UI toggle. If the controller does not have the item when
  Start is pressed, the script fires `/fic <keyword>` to locate it and pull it to the
  controller. Chain does not auto-start (manual Start required - see v1.6.0 for auto-resume).
- `ficTick()` runs in the `chainTick()` gate loop; `scmTick` is fully suspended
  while a locate is in progress. Zero impact when the toggle is OFF.

---

## [1.4.2] - 2025-xx-xx

### UI / UX
- Window opens expanded at 500x700 on first use (was collapsed/tiny).
- Latency section rewritten with plain-language labels.

---

## [1.4.1] - 2025-xx-xx

### Bugfix
- Fixed: collapsing the window to its title bar permanently hid the UI.

---

## [1.4.0] - 2025-xx-xx

### Performance
- `BASE_TRADE_TIMEOUT` reduced from 20s to 5s.
- Adaptive latency seeded at 1.5s baseline.
- Dynamic cast time detection via local inventory scan at chain start.
- `MEMBER_USE` delay = detected cast time + adaptive network buffer.
- Fixed: `mq.imgui.init` used for correct ImGui registration.
- Fixed: `pcall` wrapper on entire GUI.