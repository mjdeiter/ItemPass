# ItemPass

**Controller-based item passing script for Project Lazarus (MQNext / E3Next EMU)**

Passes a clickable item through every group member in order, has each member use it,
then returns it to the controller. Fully automated and adaptive.

---

## Features

| Feature | Status |
|---|---|
| FSM-based chain (give -> use -> return -> next) | Stable |
| Adaptive latency (learns swap time from live data) | Stable |
| Dynamic cast time detection (local inventory scan) | Stable |
| Saved items + profiles | Stable |
| Inventory autocomplete with fuzzy matching | Stable |
| Hidden item list | Stable |
| ImGui overlay UI | Stable |
| Auto-locate item via `/fic` | Experimental |
| Auto-resume chain after locate pull | Experimental |
| Speed Mode (pre-built pipeline, os.clock precision) | Experimental |

---

## Installation

1. Copy `itempass.lua` to your MQNext `lua` folder.
2. In-game, run: `/lua run itempass`
3. Use `/itempassui` to toggle the overlay.

---

## Commands

| Command | Action |
|---|---|
| `/itempassui` | Toggle UI |
| `/itempassstart` | Start chain |
| `/itempasspause` | Pause / resume |
| `/itempassreset` | Reset chain |

---

## Experimental Features

> These features are isolated from the core FSM. Bugs in the experimental layer
> cannot corrupt the chain. Toggle them in the UI under the **Experimental** section.

### Auto-locate item
If the controller doesn't have the item when Start is pressed, the script fires
`/fic <keyword>` to locate it among group members and pull it to the controller.

- `/fic` only accepts one word - `getFicKeyword()` extracts the longest non-filler
  word from the item name. Example: "Nimbus of Midnight" -> `/fic Midnight`
- E3 `/fic` output format: `<Name> [Pack] Item Name - bag(N) slot(N) count(N)`

### Auto-resume after locate
When paired with Auto-locate, the chain starts automatically once the item arrives.
No need to hit Start a second time.

### Speed Mode (v1.7.0 - Pipeline Refactor)
Skips all adaptive waits and inventory polling. A flat pipeline of `{delay, fn}` steps
is built once at chain start and fired in sequence using `os.clock()` for sub-second
precision. Approximately 2x faster than adaptive mode.

| Phase | Delay |
|---|---|
| Give -> Use | 3.0s |
| Use -> Pass/Return | castTime + 2.0s |
| Final return timeout | 10s (auto-retry pull) |

> Item loss is possible if the server lags. Use only on stable, tested chains.

---

## How It Works

```
Controller has item
  -> Give to Member 1
       -> Member 1 uses item
            -> Return to Controller
                 -> Give to Member 2
                      -> ...
                           -> Return to Controller -> Chain complete
```

The adaptive latency system measures how long each return transfer actually takes
and uses that to calibrate wait times automatically over the course of a session.

Speed Mode bypasses this entirely with a pre-built command pipeline.

---

## Version

Current: **v1.7.0**
See [CHANGELOG.md](CHANGELOG.md) for full history.

---

*Created by Alektra \<Lederhosen\> - Project Lazarus*