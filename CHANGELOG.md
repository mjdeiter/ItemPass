# ItemPass — Changelog

All notable changes to ItemPass are documented here.

---

## [1.6.0] — 2026-01-xx

### Experimental additions
- **Speed Mode / Fire and Forget** — new UI toggle under the Experimental section.
  Bypasses all adaptive waits and inventory polling. Uses fixed delays calibrated
  against hotpotato timing (give: 3.0s, use: castTime + 2.0s, return max: 4.0s).
  Approximately 2x faster than adaptive mode on a stable chain. Item loss is possible
  if the server lags — use only when the chain is reliable.
- **Auto-resume after /fic locate** — paired checkbox next to Auto-locate.
  When enabled, the chain starts automatically the moment the item arrives at the
  controller after a `/fic` pull. No need to hit Start a second time.

---

## [1.5.1] — 2026-01-xx

### Experimental bugfixes
- **Fixed: `/fic` keyword extraction** — `/fic` only accepts a single word.
  `getFicKeyword()` now extracts the longest non-filler word from the item name.
  Example: "Nimbus of Midnight" → `/fic Midnight`. Filler words: of, the, a, an, and.
- **Fixed: `/fic` output parser** — previous regex `"(%a+) has item (.+)"` never
  matched E3's actual output format. New pattern correctly matches:
  `<Name> [Pack] Item Name - bag(N) slot(N) count(N)`

---

## [1.5.0] — 2026-01-xx

### Experimental layer (safe, isolated from core FSM)
- **Auto-locate item** — new UI toggle. If the controller does not have the item when
  Start is pressed, the script fires `/fic <keyword>` to locate it and pull it to the
  controller. Chain does not auto-start (manual Start required — see v1.6.0 for auto-resume).
- `ficTick()` runs in the `chainTick()` gate loop; `scmTick` is fully suspended while
  a locate is in progress. Zero impact when the toggle is OFF.

---

## [1.4.2] — 2025-xx-xx

### UI / UX
- Window opens expanded at 500×700 on first use (was collapsed/tiny).
- Latency section rewritten with plain-language labels:
  - "Last chain took" — total elapsed time for the completed chain (resets on next start).
  - "Avg swap time" — learned value with sample count explanation.
  - Override field label clarified to "Override swap time (s, 0=auto)".

---

## [1.4.1] — 2025-xx-xx

### Bugfix
- Fixed: collapsing the window to its title bar permanently hid the UI.
  `ImGui.Begin` returns `false` on collapse (not just on close). The old code set
  `showUI = false` in that path, unregistering the window entirely. Fix: leave
  `showUI` alone on collapse; just call `ImGui.End()` and return.

---

## [1.4.0] — 2025-xx-xx

### Performance
- `BASE_TRADE_TIMEOUT` reduced from 20s to 5s.
- Adaptive latency seeded at 1.5s baseline (no longer blind on first chain).
- Dynamic cast time detection via local inventory scan at chain start.
- `MEMBER_USE` delay = detected cast time + adaptive network buffer (not flat 3s).
- Fixed: `mq.imgui.init` used for correct ImGui registration.
- Fixed: `pcall` wrapper on entire GUI to prevent crashes killing the script.
