# Changelog

All notable changes to ItemPass are documented in this file.

The format follows [Semantic Versioning](https://semver.org/).

---

## [1.3.0] – 2026-05-01

### Added
- Adaptive latency tracking that learns actual transfer times and adjusts timeouts automatically.
- Manual Transfer Timeout override in the GUI (enter seconds to force a fixed timeout).
- GUI Transfer Timing panel showing measured transfers and rolling average transfer time.

### Changed
- Trade and remote-use timeouts now use adaptive calculations when enough samples are collected:
  - Trade timeout: `BASE_TRADE_TIMEOUT + (avgTransferTime * 3)` (safety buffer)
  - Remote use delay: `BASE_REMOTE_USE_DELAY + (avgTransferTime * 1.5)`
- Default behavior remains the same until the script has collected transfer samples.

### Fixed
- Do not record latency samples while a manual override is set.

### Internal
- Added rolling-sample history and status logging for transfer timing diagnostics.

---

## [1.2.4] – 2026-01-19

### Fixed
- Corrected `requestItemTransfer` command order  
  (reverted to original `/e3bct <to> /giveme <from> "<item>"` to restore proper pull logic)

### Internal
- Added detailed logging to `requestItemTransfer` for improved debugging and traceability

---

## [1.2.3] – 2026-01-19

### Fixed
- Restored original `requestItemTransfer` execution order  
  (`/e3bct <from> /giveme "%s" <to>`) to ensure correct giver-side execution
- Ensured **One-Way Trade** completes as a true one-way handoff  
  (no `/useitem`, no return pass)

---

## [1.2.2] – 2026-01-19

### Fixed
- Corrected `/e3bct` command order in `requestItemTransfer`  
  (swapped `from` / `to` to fix giver vs recipient logic)

### Changed
- **One-Way Trade** now hands items directly to the target only  
  (skips chain execution and does not invoke `/useitem`)

### Internal
- Improved logging to confirm successful one-way handoff completion

---

## [1.2.1] – 2026-01-19

### Changed
- Removed `<Any Member>` option from **One-Way Target**  
  (explicit target selection now required)
- Default **One-Way Target** to the first enabled non-controller member if unset

### Fixed
- Status logging now occurs **only** when the target actually changes, preventing log spam

---

## [1.2.0] – 2026-01-19

### Added
- **One-Way Trade** option  
  - Passes items through the chain (with `/useitem`)  
  - Does **not** return from the final (or specified) target
- **One-Way Target** dropdown  
  - Supports `<Any Member>` and live group member list
- Full profile persistence for all ItemPass settings

---

## [1.1.4] – 2026-01-19

### Changed
- Added advanced autocomplete ranking  
  (prefix → substring → fuzzy match)
- Limited autocomplete results to top 10 entries
- Improved UI selection behavior to prevent spam and flicker

---

## [1.1.3] – 2026-01-02

### Fixed
- Controller no longer participates in trade chains
- Eliminated `/giveme self` and NULL trade target failures
- Controller now clicks items locally **after** the trade chain completes
- Chain execution is fully deterministic regardless of controller state

### Changed
- Controller checkbox now controls **end-of-chain local usage**
- Trade logic and controller logic are explicitly separated

### Internal
- Added durable FSM phase for controller-only actions
- Enforced controller exclusion from trade-based FSM states
- Improved chain-order correctness when `(Start)` is used

---

## [1.1.2]

### Fixed
- Controller checkbox not triggering local item usage
- Missing FSM state causing controller `/useitem` to be skipped

> Superseded by v1.1.3 due to remaining self-trade edge cases.

---

## [1.1.1]

### Fixed
- `(Start)` marker not consistently honored
- Chain ordering inconsistencies

---

## [1.1.0]

### Initial Public Release
- Deterministic item pass chain
- Profile support
- ImGui UI
- EMU-safe inventory handling
