# ItemPass

**Originally created by Alektra <Lederhosen>**

[![Buy Me a Coffee](https://img.shields.io/badge/Support-Buy%20Me%20a%20Coffee-ffdd00?logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/shablagu)

ItemPass is a deterministic, EMU-safe item circulation tool for the  
**Project Lazarus EverQuest EMU server**, built for **MacroQuest MQNext (MQ2Mono)** and **E3Next**.

It allows a controller character to pass an item through a configurable group
chain so each member can click/use it in sequence.

<img width="577" height="750" alt="image" src="https://github.com/user-attachments/assets/d5c25c23-2b32-414b-acd5-b74948a91b66" />


---

## Features

### Core Functionality
- Deterministic item pass chain execution
- EMU-safe inventory scanning (no `FindItem`)
- Works with bags and stacked items
- Robust FSM-based execution (no timing guesswork)

### Inventory Scanning (v1.3.1)
- **Fixed bag size handling**: Now correctly counts items in bags of different sizes
- **Accurate item totals**: Each bag's actual slot count is queried independently
- **Reliable results**: Item counts are now consistent regardless of bag arrangement

### Adaptive Latency Tracking (v1.3.0)
- **Auto-Learning Transfer Times**: Script automatically measures each item transfer duration
- **Rolling Average**: Maintains last 30 measurements for smooth timeout adjustment
- **Dynamic Timeout Adjustment**: 
  - Trade timeout scales: `20s + (average × 3)` for network variance
  - Remote use delay scales: `3s + (average × 1.5)` for inventory syncing
- **Perfect for Variable Latency**: Works on slow/fast servers without manual tuning
- **Manual Override**: Set custom transfer time in GUI if needed for fine-tuning

### Controller-Aware Design (v1.1.3)
- Controller is **never included in trade chains**
- Optional controller participation via **local end-of-chain click**
- Prevents self-trade and NULL `/giveme` edge cases
- Explicit FSM phase for controller-only actions

### Chain Management
- Per-member enable/disable checkboxes
- `(Start)` marker to control chain order
- Live chain preview
- Manual start, pause, and reset controls

### Profiles
- Save and load full chain + item configurations
- Profiles persist item name, chain order, and enabled members
- Safe auto-healing if group composition changes

### UI
- ImGui-based interface
- Inventory scan with autocomplete
- Hidden-item support (filter junk permanently)
- Persistent status log with timestamps
- Latency Settings panel showing transfer metrics

---

## Requirements

- Project Lazarus EverQuest EMU
- MacroQuest **MQNext (MQ2Mono)**
- E3Next (for `/giveme` and remote `/useitem`)
- ImGui enabled

---

## Installation

1. Copy `ItemPass.lua` into your MacroQuest `lua` directory
2. In game, run:
   ```
   /lua run ItemPass
   ```
3. Open UI with `/itempassui`

---

## Quick Start

### Basic Chain Setup
1. **Enable Group Members**: Click members in "Chain Members" to toggle inclusion
2. **Select Item**: Type item name or use "Scan Inventory" → select from list
3. **Set Order** (optional): Click member to mark as `(Start)` position
4. **Start Chain**: Press "Start" button
5. **Watch Status Log**: See transfers and latency data in real-time

### Latency Tuning
- **First Run**: Script learns your group's latency automatically
- **Check Metrics**: "Latency Settings" panel shows:
  - Measured transfer count
  - Running average transfer time
  - Current mode (Adaptive or Manual override value)
- **Manual Override** (if needed):
  - Enter custom seconds in "Manual Transfer Time (seconds)" field
  - Click "Set Override" to apply
  - Click "Reset to Auto" to resume learning

### Profiles
1. Configure chain + item
2. Enter profile name and click "Save Profile"
3. Load anytime with "Load Profile" dropdown

---

## Commands

- `/itempassui` – Toggle UI on/off
- `/itempassstart` – Start chain (must have UI closed or item set via UI)
- `/itempasspause` – Pause/resume running chain
- `/itempassreset` – Stop and reset chain

---

## Files Created

- `itempass_items.txt` – Saved item names
- `itempass_profiles.txt` – Saved configurations
- `itempass_hidden.txt` – Hidden item list (for filtering)

All files are created in your MacroQuest root directory.

---

## How Adaptive Latency Works

### The Problem
Different servers and network conditions cause variable transfer times. Fixed timeouts either:
- Are too short (transfers fail on lag spikes)
- Are too long (chain execution slows down)

### The Solution
ItemPass **learns optimal timing automatically**:

1. **Measure**: Each item transfer records actual duration
2. **Average**: Rolling average of last 30 transfers smooths variance
3. **Adjust**: Timeouts dynamically scale based on measured data
4. **Transparent**: Status log shows durations and averages

### Example
- Your group averages **8.5s per transfer**
- Trade timeout becomes: `20 + (8.5 × 3) = 45.5 seconds`
- Remote use delay becomes: `3 + (8.5 × 1.5) = 15.75 seconds`

### Manual Override
If you need to fine-tune for specific scenarios:
1. Open "Latency Settings" panel in GUI
2. Enter desired timeout value (in seconds)
3. Click "Set Override"
4. Script uses your value instead of adaptive calculation
5. Click "Reset to Auto" anytime to resume learning

---

## Troubleshooting

### Items Not Transferring
- Check "Status Log" for timeout or transfer errors
- Verify all members have E3Next `/giveme` support
- Try increasing manual override timeout by 5-10 seconds

### Chain Stops Mid-Execution
- Check for network lag or disconnects
- Review measured transfer times in Latency Settings
- Consider increasing retry attempts (TRADE_MAX_ATTEMPTS in config)

### Slow Chain Execution
- Wait for script to collect ~5-10 measurements for accurate average
- Manual override with learned average value (from Status Log)
- Check for high variance—may indicate network instability

### Inventory Count Incorrect
- Make sure you're using ItemPass v1.3.1 or later
- Click "Scan Inventory" button to refresh
- Check bags are not full or bugged
- Hidden items won't be counted (see `itempass_hidden.txt`)

---

## Advanced Configuration

Edit these values at the top of `ItemPass.lua`:

```lua
local AUTO_REPEAT_CHAIN = false        -- Loop chain after all members use item
local BASE_REMOTE_USE_DELAY = 3        -- Base seconds before requesting return
local BASE_TRADE_TIMEOUT = 20          -- Base timeout for item transfer
local TRADE_MAX_ATTEMPTS = 3           -- Retries before failing
```

---

## Version History

See [CHANGELOG.md](CHANGELOG.md) for full version details.

**Current Version**: 1.3.1 (Inventory Scanning Fix + Adaptive Latency Tracking)

---

## License

MIT License – See LICENSE file

---

## Credits

- **Original Author**: Alektra <Lederhosen>
- **Maintained by**: mjdeiter
- **Special Thanks**: Project Lazarus EverQuest EMU community
