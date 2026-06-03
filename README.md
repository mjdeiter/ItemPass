# ItemPass v1.7.2
**MQNext / E3Next**
*Driver-based item passing script for group buff rotations.*

---

## Overview

ItemPass automates the process of rotating a clickable item through your group:

1. Driver starts with the item.
2. Item is sent to each enabled group member in order.
3. Each member uses the item, then it is returned to the driver.
4. After the last member, the chain stops (or repeats if Auto-Repeat is on).

Safe by design - no `FindItem`, no unsafe TLOs. Inventory access via `Me.Inventory` / `Container` / `Item` only.

---

## Commands

| Command | Description |
|---|---|
| `/itempassui` | Toggle the UI window |
| `/itempassstart` | Start the chain |
| `/itempasspause` | Pause / resume |
| `/itempassreset` | Reset and stop |

---

## Features

### Core
- **Adaptive latency** - learns average swap time from completed transfers; adjusts all wait windows automatically.
- **Dynamic cast time detection** - scans local inventory at chain start; no FindItem.
- **Chain preview** - shows full pass order before you start.
- **Profiles** - save and load item + member configurations.
- **Hidden items** - filter items from dropdowns without removing from saved list.
- **Autocomplete** - fuzzy item name matching with Levenshtein scoring.
- **Auto-update check** - fetches the latest version from GitHub on load and notifies you if a newer version is available.

### Timing / Latency
- Adaptive swap time learned over up to 30 samples.
- Manual override available (set 0 to return to auto).
- "Last chain took" timer displayed after each completed round.

### Debug Logging
- UI checkbox enables verbose FSM tracing to `itempass_debug.txt`.
- All status lines and internal state transitions logged per tick.
- File I/O is fully gated - render loop is never affected when logging is off.

---

## Experimental Features

> These features are isolated from the core FSM. Bugs here will not corrupt chain state.
> All experimental toggles default to **OFF**.

### Auto-locate item
When the driver doesn't have the item at chain start, fires `/fic <keyword>` to find it in the group.

- Extracts the most specific single keyword from the item name (`getFicKeyword` - skips filler words: of, the, a, an, and).
- Matches E3's actual `/fic` output format: `<Name> [Pack] Item Name - bag(N) slot(N) count(N)`.
- Pulls the item to the driver via `requestItemTransfer` (pull-only, never pushes to third parties).
- 2-second silence window collects all `/fic` results before resolving.

### Auto-resume after pull *(paired with Auto-locate)*
Once the located item arrives in the driver's inventory, the chain starts automatically. Previously required a manual Start press after pull.

### Speed Mode
Fixed short delays instead of adaptive polling. Roughly 2x faster than adaptive mode.

| Phase | Normal (adaptive) | Speed Mode |
|---|---|---|
| Give -> Use | adaptive timeout (5s+) | 2.5s fixed |
| Use -> Return | castTime + adaptive buffer | castTime + 1.5s |
| Return wait | polls until confirmed | max 3.0s then proceeds |

- Routes through driver same as normal mode.
- **Not recommended for unstable servers** - errors may be silently skipped.

---

## Files

| File | Purpose |
|---|---|
| `ItemPass.lua` | Main script |
| `itempass_items.txt` | Saved item list (auto-created) |
| `itempass_profiles.txt` | Saved profiles (auto-created) |
| `itempass_hidden.txt` | Hidden item list (auto-created) |

Data files are written to the MQNext root directory (`mq.TLO.MacroQuest.Path()`), not the `lua/` subfolder.

---

## Installation

Drop `ItemPass.lua` into your MQNext `lua/` folder, then run:

```
/lua run itempass
```

---

## Notes

- Run this script **on the driver toon only**.
- The item must start on the driver (or use Auto-locate to pull it).
- `2147483647` in E3 `/giveme` output is `INT32_MAX` - E3's internal sentinel for name-only item lookup. Not a bug.

---

*Originally created by Alektra <Lederhosen>*
