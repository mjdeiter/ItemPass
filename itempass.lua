-- ItemPass (Project Lazarus EMU / MQNext / E3Next)
-- Controller-based item passing script:
--   Controller starts with the item
--   -> sends item to each enabled group member in order
--   -> tells them to /useitem
--   -> pulls the item back
-- After the last member, the item returns to the controller and the chain stops
-- (unless AUTO_REPEAT_CHAIN is enabled).
--
-- ItemPass v1.7.2
-- Bugfixes + Debug Logging:
--   + Fixed: controller was excluded from rotation due to m.name ~= me filter in
--     buildSCMList(); checked in UI but never actually in the chain
--   + Fixed: Chain Preview showed [controller]/[end] bookends regardless of actual
--     inclusion; now shows [click] at real position and [return] when not in rotation
--   + Fixed: Speed Mode -- controller-first self-transfer wasted full SPEED_GIVE_DELAY;
--     give step is now skipped and /useitem fires immediately
--   + Fixed: Speed Mode -- controller-last useDelay was 0 (item not yet transferred);
--     now uses SPEED_GIVE_DELAY for all non-first positions
--   + Fixed: Speed Mode -- SPEED_WAIT_RETURN hung forever when controller was last
--     (item consumed/used, countItemByName always 0); completion is now timer-based
--     via speedControllerIsLast flag (castTime + 1.5s buffer)
--   + Added: Debug logging mode -- UI checkbox writes all status + verbose [DBG] FSM
--     tracing to itempass_debug.txt; gated behind verbose param so render loop never
--     triggers file I/O
-- Speed Mode Pipeline refactor:
--   + Speed Mode now uses a pre-built flat pipeline of {delay, fn} steps
--   + Pipeline built once at chain start (buildSpeedPipeline)
--   + Uses os.clock() for sub-second precision (was os.time() = 1s granularity)
--   + Dedicated speedTick() replaces inline speed branches in scmTick()
--   + chainTick() routes to speedTick vs scmTick based on EXP_speedMode
--   + New phases: SPEED_PIPELINE (stepping) and SPEED_WAIT_RETURN (polling)
--   + 10s timeout on final return with auto-retry pull
--
-- ItemPass v1.6.0
-- Experimental additions:
--   + Speed Mode toggle in UI
--     Fixed delays: give=3.0s, use=castTime+2.0s, return max=4.0s
--     No inventory polling in speed mode. ~2x faster than adaptive.
--   + Auto-resume after /fic locate: paired checkbox next to Auto-locate
--     When ON: chain starts automatically once item arrives at controller
--
-- ItemPass v1.5.1
-- Experimental Bugfixes:
--   + Fixed: /fic only accepts one word -- now extracts longest non-filler keyword
--     e.g. "Nimbus of Midnight" -> /fic Midnight (not /fic Nimbus of Midnight)
--   + Fixed: event parser now matches E3 actual output format:
--     <Name> [Pack] Item Name - bag(N) slot(N) count(N)
--     (old pattern "has item" never matched real E3 output)
--
-- ItemPass v1.5.0
-- Experimental Layer:
--   + Added EXP_autoLocate toggle (UI checkbox under new Experimental section)
--   + When ON: if controller lacks item at chain start, fires /fic to locate it
--   + /fic output captured via mq.event; 2-second silence window collects all results
--   + Pulls matching item to controller via requestItemTransfer (safe, pull-only)
--   + Chain does NOT auto-resume after pull -- user hits Start again manually
--   + ficTick() runs in chainTick() gating loop; yields scmTick until resolved
--   + Zero impact when OFF -- all EXP code is fully isolated from core FSM
--
-- ItemPass v1.4.2
-- UI / UX:
--   + Window now opens expanded at 500x700 on first use (was collapsed/tiny)
--   + Latency section rewritten with plain language:
--       - "Last chain took" shows total elapsed time for the completed chain (resets on next start)
--       - "Avg swap time" explains what the learned value means and how many samples it's from
--       - Override label clarified to "Override swap time (s, 0=auto)"
--
-- ItemPass v1.4.1
-- Bugfix:
--   + Fixed: collapsing window to title bar permanently hid the UI. ImGui.Begin returns
--     false on collapse (not just on close), and the old code set showUI=false in that
--     path, unregistering the window entirely. Fix: leave showUI alone on collapse;
--     just call ImGui.End() and return. Window stays registered, expands on click.
--     /itempassui still toggles full hide/show as before.
--
-- ItemPass v1.4.0
-- Performance Update:
--   + BASE_TRADE_TIMEOUT reduced from 20s to 5s
--   + Adaptive latency seeded at 1.5s baseline (no longer starts blind on first chain)
--   + Dynamic cast time detection via local inventory scan at chain start
--   + MEMBER_USE delay now = detected cast time + adaptive network buffer (not flat 3s)
--   + Fixed: mq.imgui.init used for correct ImGui registration (not direct loop call)
--   + Fixed: pcall wrapper on entire GUI to prevent crashes from killing the script

local mq    = require('mq')
local ImGui = require('ImGui')

---------------------------------------------------------------------
-- VERSION / CREDITS
---------------------------------------------------------------------
local SCRIPT_VERSION = "1.7.2" -- semantic version: MAJOR.MINOR.PATCH

-- Update check: fetches version.txt from GitHub on load, notifies if newer version exists
local function checkForUpdate()
    local ok, http = pcall(require, 'socket.http')
    if not ok then return end
    pcall(function()
        local body, code = http.request('https://raw.githubusercontent.com/mjdeiter/ItemPass/main/version.txt')
        if code == 200 and body then
            local latest = body:match('^%%s*([%%d%%.]+)%%s*$')
            if latest and latest ~= SCRIPT_VERSION then
                addStatus(string.format('\\ayUpdate available: v%s (you have v%s)', latest, SCRIPT_VERSION))
                addStatus('\\ayGet it at: https://github.com/mjdeiter/ItemPass')
            end
        end
    end)
end

---------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------
local AUTO_REPEAT_CHAIN     = false
local BASE_REMOTE_USE_DELAY = 3

---------------------------------------------------------------------
-- PATHS / CONSTANTS
---------------------------------------------------------------------
local MQROOT            = mq.TLO.MacroQuest.Path() or '.'
local ITEM_FILE_PATH    = MQROOT .. '/itempass_items.txt'
local PROFILE_FILE_PATH = MQROOT .. '/itempass_profiles.txt'
local HIDDEN_FILE_PATH  = MQROOT .. '/itempass_hidden.txt'
local DEBUG_LOG_PATH    = MQROOT .. '/itempass_debug.txt'

local SLOT_MIN           = 0
local SLOT_MAX           = 32
local BASE_TRADE_TIMEOUT = 5        -- v1.4.0: reduced from 20s
local TRADE_MAX_ATTEMPTS = 3
local MAX_LOG            = 200
local MAX_SUGGESTIONS    = 10

---------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------
local savedItems             = {}
local selectedSavedItem      = 1
local manualItemName         = ''
local activeItemName         = ''
local activeItemCastTime     = 1.0  -- v1.4.0: cast time in seconds, detected at chain start

local inventoryItems         = {}
local selectedInventoryIndex = 0

local chainMembers           = {}
local chainStartName         = nil

local profiles               = {}
local currentProfileName     = ''
local profileNameBuffer      = ''

local running                = false
local paused                 = false
local showUI                 = true

local statusLog              = {}

local lastZone               = mq.TLO.Zone.ShortName() or ''
local lastZoning             = mq.TLO.Me.Zoning() or false

local scm = {
    list      = {},
    index     = 0,
    phase     = 'IDLE',
    member    = nil,
    attempts  = 0,
    startTime = 0,
}

local hiddenItems        = {}
local hiddenLookup       = {}
local lastAutocompleteChoice = nil
local windowSizeSet          = false  -- true after first SetNextWindowSize call
local debugMode              = false  -- when true, verbose FSM events written to DEBUG_LOG_PATH

---------------------------------------------------------------------
-- LATENCY TRACKING STATE
---------------------------------------------------------------------
local latencyStats = {
    totalTransfers  = 0,
    avgTransferTime = 1.5,  -- v1.4.0: seeded baseline so first chain isn't blind
    measurements    = {},
    manualOverride  = 0,    -- 0 = adaptive, >0 = manual seconds
}

local chainTimer = {
    startTime = 0,    -- os.time() when chain started
    lastTotal = nil,  -- seconds the last completed chain took (nil = no chain run yet)
}

---------------------------------------------------------------------
-- EXPERIMENTAL: Auto-locate item state (SAFE LAYER)
-- This block is isolated from core FSM. Bugs here cannot corrupt chain.
---------------------------------------------------------------------
local EXP_autoLocate  = false
local ficResults      = {}
local ficPending      = false
local ficLastUpdate   = 0
local FIC_TIMEOUT      = 2   -- seconds of silence = done collecting
-- Forward declarations so startChain / chainTick can reference these
-- before the actual definitions appear later in the file.
local runFicLocate
local ficTick

---------------------------------------------------------------------
-- EXPERIMENTAL: Speed Mode (SAFE LAYER)
-- Pipeline-based: pre-built sequence of {delay, fn} steps fired in order.
-- Uses os.clock() for sub-second precision. No inventory polling during pipeline.
---------------------------------------------------------------------
local EXP_speedMode      = false
local SPEED_GIVE_DELAY   = 3.0   -- seconds to wait after give before issuing /useitem
local SPEED_USE_DELAY    = 2.0   -- extra seconds added to cast time before passing on
local SPEED_RETURN_DELAY = 4.0   -- legacy constant (kept for UI display; not used in pipeline path)

-- Pipeline state vars
local speedPhaseStart    = 0      -- os.clock() timestamp of when current pipeline step started
local speedPipeline      = {}     -- pre-built sequence of {delay, fn} steps
local speedPipelineIndex = 1      -- current position in the pipeline

---------------------------------------------------------------------
-- EXPERIMENTAL: Auto-resume after /fic locate
---------------------------------------------------------------------
local ficAutoResume       = false  -- user toggle: auto-start chain after locate+pull
local ficWaitingForReturn = false  -- internal: item requested, waiting for it to arrive

---------------------------------------------------------------------
-- UTILITIES
---------------------------------------------------------------------
local function trim(s)
    if not s then return '' end
    return s:gsub('^%s+', ''):gsub('%s+$', '')
end

local function timestamp()
    return os.date('%H:%M:%S')
end

local function addStatus(fmt, ...)
    local msg  = string.format(fmt, ...)
    local line = string.format('[%s] %s', timestamp(), msg)
    table.insert(statusLog, line)
    if #statusLog > MAX_LOG then table.remove(statusLog, 1) end
    print(line)
    -- When debug mode is on, every status line is appended to the log file
    -- so you can paste the full session into chat for diagnosis.
    if debugMode then
        local f = io.open(DEBUG_LOG_PATH, 'a')
        if f then f:write(line .. '\n') f:close() end
    end
end

-- debugLog: verbose FSM tracing, only written when debugMode is on.
-- Does NOT appear in the in-game status panel -- keeps it from flooding.
local function debugLog(fmt, ...)
    if not debugMode then return end
    local msg  = string.format(fmt, ...)
    local line = string.format('[%s] [DBG] %s', timestamp(), msg)
    print(line)
    local f = io.open(DEBUG_LOG_PATH, 'a')
    if f then f:write(line .. '\n') f:close() end
end

local function fileExists(path)
    local f = io.open(path, 'r')
    if f then f:close() return true end
    return false
end

---------------------------------------------------------------------
-- LATENCY TRACKING
---------------------------------------------------------------------
local function recordTransferTime(duration)
    if latencyStats.manualOverride > 0 then return end

    duration = math.max(duration, 0.1)
    table.insert(latencyStats.measurements, duration)
    if #latencyStats.measurements > 30 then
        table.remove(latencyStats.measurements, 1)
    end

    local sum = 0
    for _, v in ipairs(latencyStats.measurements) do sum = sum + v end
    latencyStats.avgTransferTime = sum / #latencyStats.measurements
    latencyStats.totalTransfers  = latencyStats.totalTransfers + 1

    addStatus('Transfer completed in %.1fs (avg: %.1fs over %d samples)',
        duration, latencyStats.avgTransferTime, #latencyStats.measurements)
end

local function getAdaptiveTradeTimeout()
    if latencyStats.manualOverride > 0 then return latencyStats.manualOverride end
    local t = BASE_TRADE_TIMEOUT
    if latencyStats.avgTransferTime > 0 then
        t = BASE_TRADE_TIMEOUT + (latencyStats.avgTransferTime * 3)
    end
    return t
end

local function getAdaptiveRemoteUseDelay()
    if latencyStats.manualOverride > 0 then return latencyStats.manualOverride end
    local d = BASE_REMOTE_USE_DELAY
    if latencyStats.avgTransferTime > 0 then
        d = BASE_REMOTE_USE_DELAY + (latencyStats.avgTransferTime * 1.5)
    end
    return d
end

---------------------------------------------------------------------
-- HIDDEN ITEM LIST
---------------------------------------------------------------------
local function rebuildHiddenLookup()
    hiddenLookup = {}
    for _, nm in ipairs(hiddenItems) do
        local key = trim(nm):lower()
        if key ~= '' then hiddenLookup[key] = true end
    end
end

local function loadHiddenItems()
    hiddenItems = {}
    if not fileExists(HIDDEN_FILE_PATH) then hiddenLookup = {} return end
    local f = io.open(HIDDEN_FILE_PATH, 'r')
    if not f then hiddenLookup = {} return end
    for line in f:lines() do
        local nm = trim(line)
        if nm ~= '' then table.insert(hiddenItems, nm) end
    end
    f:close()
    rebuildHiddenLookup()
end

local function saveHiddenItems()
    local f = io.open(HIDDEN_FILE_PATH, 'w')
    if not f then print('[ItemPass] ERROR: Cannot write hidden file.') return end
    for _, nm in ipairs(hiddenItems) do f:write(nm .. '\n') end
    f:close()
    rebuildHiddenLookup()
end

local function isItemHidden(name)
    local key = trim(name or ''):lower()
    if key == '' then return false end
    return hiddenLookup[key] == true
end

local function hideItemByName(name)
    local nm = trim(name or '')
    if nm == '' then return end
    if isItemHidden(nm) then
        print(string.format('[ItemPass] "%s" is already hidden.', nm))
        return
    end
    table.insert(hiddenItems, nm)
    saveHiddenItems()
    print(string.format('[ItemPass] Item "%s" added to hidden list.', nm))
end

local function unhideItemByName(name)
    local key = trim(name or ''):lower()
    if key == '' then return end
    local newList, removed = {}, false
    for _, nm in ipairs(hiddenItems) do
        if trim(nm):lower() == key then removed = true
        else table.insert(newList, nm) end
    end
    hiddenItems = newList
    saveHiddenItems()
    if removed then
        print(string.format('[ItemPass] Item "%s" removed from hidden list.', name))
    else
        print(string.format('[ItemPass] Item "%s" was not in hidden list.', name))
    end
end

---------------------------------------------------------------------
-- AUTOCOMPLETE
---------------------------------------------------------------------
local function levenshtein(a, b)
    a, b = a or '', b or ''
    local la, lb = #a, #b
    if la == 0 then return lb end
    if lb == 0 then return la end
    local prev, curr = {}, {}
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        curr[0] = i
        local ca = a:sub(i, i)
        for j = 1, lb do
            local cb   = b:sub(j, j)
            local cost = (ca == cb) and 0 or 1
            local v    = prev[j] + 1
            local ins  = curr[j-1] + 1
            local sub  = prev[j-1] + cost
            if ins < v then v = ins end
            if sub < v then v = sub end
            curr[j] = v
        end
        prev, curr = curr, prev
    end
    return prev[lb]
end

local function getItemSuggestions(prefix)
    prefix = trim(prefix or '')
    if prefix == '' then return {} end
    local search      = prefix:lower()
    local suggestions = {}
    local seen        = {}

    local function considerName(nm)
        nm = trim(nm or '')
        if nm == '' then return end
        local key = nm:lower()
        if seen[key] then return end
        seen[key] = true
        local score
        local startPos = key:find(search, 1, true)
        if startPos == 1 then
            score = 0
        elseif startPos ~= nil then
            score = 1
        else
            score = 2 + levenshtein(search, key:sub(1, #search))
        end
        local display = nm
        if score == 0 then display = '[*] ' .. nm
        elseif score == 1 then display = '[~] ' .. nm end
        table.insert(suggestions, {name=nm, display=display, score=score})
    end

    for _, nm in ipairs(savedItems) do considerName(nm) end
    for _, it in ipairs(inventoryItems) do
        if not isItemHidden(it.name) then considerName(it.name) end
    end

    table.sort(suggestions, function(a, b)
        if a.score ~= b.score then return a.score < b.score end
        return a.name:lower() < b.name:lower()
    end)

    if #suggestions > MAX_SUGGESTIONS then
        local trimmed = {}
        for i = 1, MAX_SUGGESTIONS do trimmed[i] = suggestions[i] end
        suggestions = trimmed
    end

    return suggestions
end

---------------------------------------------------------------------
-- INVENTORY SCANNING
---------------------------------------------------------------------
local function countItemByName(name)
    name = trim(name)
    if name == '' then return 0 end
    local target = name:lower()
    local total  = 0

    for slot = SLOT_MIN, SLOT_MAX do
        local it = mq.TLO.Me.Inventory(slot)
        if it() and it.ID() ~= 0 then
            local nm     = trim(it.Name() or '')
            local cslots = it.Container() or 0
            if cslots == 0 and nm:lower() == target then total = total + 1 end
            if cslots > 0 then
                for i = 0, cslots do
                    local inner = it.Item(i)
                    if inner() and inner.ID() ~= 0 then
                        if trim(inner.Name() or ''):lower() == target then total = total + 1 end
                    end
                end
            end
        end
    end
    return total
end

-- v1.4.0: Detect cast time via local inventory scan. No FindItem, no unsafe TLOs.
-- Returns seconds. Falls back to 1.0s with a warning if item not found.
local function getItemCastTimeSecs(name)
    name = trim(name)
    if name == '' then return 1.0 end
    local target = name:lower()

    for slot = SLOT_MIN, SLOT_MAX do
        local it = mq.TLO.Me.Inventory(slot)
        if it() and it.ID() ~= 0 then
            local nm     = trim(it.Name() or '')
            local cslots = it.Container() or 0
            if cslots == 0 and nm:lower() == target then
                local ct = it.CastTime() or 0
                return math.max(ct / 1000.0, 0.5)
            end
            if cslots > 0 then
                for i = 0, cslots do
                    local inner = it.Item(i)
                    if inner() and inner.ID() ~= 0 then
                        if trim(inner.Name() or ''):lower() == target then
                            local ct = inner.CastTime() or 0
                            return math.max(ct / 1000.0, 0.5)
                        end
                    end
                end
            end
        end
    end

    addStatus('WARN: Could not detect cast time for "%s". Defaulting to 1.0s.', name)
    return 1.0
end

local function scanInventory()
    local top, bag = {}, {}

    for slot = SLOT_MIN, SLOT_MAX do
        local it = mq.TLO.Me.Inventory(slot)
        if it() and it.ID() ~= 0 then
            local nm     = trim(it.Name() or '')
            local cslots = it.Container() or 0
            if nm ~= '' and not isItemHidden(nm) then
                if cslots > 0 then
                    for i = 0, cslots do
                        local inner = it.Item(i)
                        if inner() and inner.ID() ~= 0 then
                            local nm2 = trim(inner.Name() or '')
                            if nm2 ~= '' and not isItemHidden(nm2) then
                                bag[nm2] = (bag[nm2] or 0) + 1
                            end
                        end
                    end
                else
                    top[nm] = (top[nm] or 0) + 1
                end
            end
        end
    end

    local tn, bn = {}, {}
    for k,_ in pairs(top) do table.insert(tn, k) end
    for k,_ in pairs(bag) do table.insert(bn, k) end
    table.sort(tn, function(a,b) return a:lower() < b:lower() end)
    table.sort(bn, function(a,b) return a:lower() < b:lower() end)

    inventoryItems = {}
    for _,n in ipairs(tn) do
        local c = top[n]
        table.insert(inventoryItems, {name=n, display=(c>1) and string.format('%s (x%d)',n,c) or n})
    end
    for _,n in ipairs(bn) do
        local c = bag[n]
        table.insert(inventoryItems, {name=n, display=(c>1) and string.format('%s (x%d)',n,c) or n})
    end

    selectedInventoryIndex = 0
    addStatus('Inventory scanned (%d unique names).', #inventoryItems)
end

---------------------------------------------------------------------
-- SAVED ITEMS
---------------------------------------------------------------------
local function loadItemList()
    savedItems = {}
    if not fileExists(ITEM_FILE_PATH) then return end
    local f = io.open(ITEM_FILE_PATH, 'r')
    if not f then return end
    for line in f:lines() do
        local nm = trim(line)
        if nm ~= '' then table.insert(savedItems, nm) end
    end
    f:close()
    selectedSavedItem = (#savedItems > 0) and 1 or 0
end

local function saveItemList()
    local f = io.open(ITEM_FILE_PATH, 'w')
    if not f then addStatus('ERROR: Cannot write item file.') return end
    for _,nm in ipairs(savedItems) do f:write(nm..'\n') end
    f:close()
end

local function saveCurrentItem()
    local nm = trim(manualItemName)
    if nm == '' then return end
    for _,v in ipairs(savedItems) do
        if v:lower() == nm:lower() then addStatus('"%s" already saved.', nm) return end
    end
    table.insert(savedItems, nm)
    selectedSavedItem = #savedItems
    saveItemList()
    addStatus('Saved item "%s".', nm)
end

local function deleteSelectedSavedItem()
    if #savedItems == 0 or selectedSavedItem <= 0 then return end
    local nm = savedItems[selectedSavedItem]
    table.remove(savedItems, selectedSavedItem)
    if selectedSavedItem > #savedItems then selectedSavedItem = #savedItems end
    if selectedSavedItem == 0 and #savedItems > 0 then selectedSavedItem = 1 end
    saveItemList()
    addStatus('Deleted saved item "%s".', nm)
end

---------------------------------------------------------------------
-- CHAIN MEMBERS
---------------------------------------------------------------------
local function validateChainStart()
    if chainStartName then
        local ok = false
        for _,m in ipairs(chainMembers) do
            if m.name == chainStartName and m.enabled and m.present then ok=true break end
        end
        if not ok then chainStartName = nil end
    end
    if not chainStartName then
        for _,m in ipairs(chainMembers) do
            if m.enabled and m.present then chainStartName = m.name break end
        end
    end
end

local function refreshChainMembers()
    for _,m in ipairs(chainMembers) do m.present = false end

    local gc = mq.TLO.Group.Members() or 0
    for slot = 0, gc do
        local gm = mq.TLO.Group.Member(slot)
        if gm() then
            local nm = trim(gm.Name() or '')
            if nm ~= '' then
                local found = false
                for _,m in ipairs(chainMembers) do
                    if m.name == nm then m.present=true found=true break end
                end
                if not found then
                    table.insert(chainMembers, {name=nm, enabled=false, present=true})
                end
            end
        end
    end

    local me = trim(mq.TLO.Me.Name() or '')
    if me ~= '' then
        local found = false
        for _,m in ipairs(chainMembers) do
            if m.name == me then m.present=true found=true break end
        end
        if not found then
            table.insert(chainMembers, {name=me, enabled=false, present=true})
        end
    end

    for _,m in ipairs(chainMembers) do
        if not m.present and m.enabled then m.enabled = false end
    end

    validateChainStart()
    addStatus('Group refreshed (%d entries: %d present, %d missing).',
        #chainMembers,
        (function() local c=0 for _,m in ipairs(chainMembers) do if m.present then c=c+1 end end return c end)(),
        (function() local c=0 for _,m in ipairs(chainMembers) do if not m.present then c=c+1 end end return c end)()
    )
end

local function purgeMissingMembers()
    local keep = {}
    for _,m in ipairs(chainMembers) do if m.present then table.insert(keep,m) end end
    chainMembers = keep
    validateChainStart()
    addStatus('Purged missing members. Remaining: %d.', #chainMembers)
end

local function buildSCMList(verbose)
    local me = trim(mq.TLO.Me.Name() or '')
    local list = {}

    -- Build list INCLUDING controller if they are enabled.
    -- USE_LOCAL in scmTick() handles the controller's self-click when their
    -- name appears in the list; excluding them here was preventing that branch
    -- from ever being reached.
    -- verbose=true only when called from startChain; Chain Preview passes no arg
    -- so debugLog is never called from the render loop (prevents IO flood on Windows).
    for _, m in ipairs(chainMembers) do
        if verbose then
            debugLog('buildSCMList: checking %s | enabled=%s present=%s',
                m.name, tostring(m.enabled), tostring(m.present))
        end
        if m.enabled and m.present then
            table.insert(list, m.name)
        end
    end

    if verbose then
        debugLog('buildSCMList: raw list = [%s]', table.concat(list, ', '))
        debugLog('buildSCMList: controller = %s | in list = %s',
            me, tostring((function() for _,n in ipairs(list) do if n==me then return true end end return false end)()))
    end

    -- Apply rotation among all enabled members (controller included)
    if chainStartName and #list > 1 then
        local startIdx = nil
        for i, nm in ipairs(list) do
            if nm == chainStartName then
                startIdx = i
                break
            end
        end

        if verbose then
            debugLog('buildSCMList: chainStartName=%s startIdx=%s',
                tostring(chainStartName), tostring(startIdx))
        end

        if startIdx and startIdx > 1 then
            local rotated = {}
            for i = startIdx, #list do table.insert(rotated, list[i]) end
            for i = 1, startIdx-1 do table.insert(rotated, list[i]) end
            list = rotated
            if verbose then
                debugLog('buildSCMList: rotated list = [%s]', table.concat(list, ', '))
            end
        end
    end

    if verbose then
        debugLog('buildSCMList: final list = [%s]', table.concat(list, ', '))
    end
    return list
end

---------------------------------------------------------------------
-- PROFILES
---------------------------------------------------------------------
local function loadProfiles()
    profiles = {}
    if not fileExists(PROFILE_FILE_PATH) then return end
    local f = io.open(PROFILE_FILE_PATH, 'r')
    if not f then return end
    for line in f:lines() do
        local pname,item,start,rest = line:match('^(.-)|(.-)|(.-)|(.*)$')
        if not (pname and item and start and rest) then
            pname,item,rest = line:match('^(.-)|(.-)|(.*)$')
            start = ''
        end
        if pname and item then
            pname = trim(pname) item = trim(item) start = trim(start)
            if pname ~= '' and item ~= '' then
                local map = {}
                for pair in rest:gmatch('[^,]+') do
                    local nm,v = pair:match('(.-):([01])')
                    if nm then map[trim(nm)] = (v=='1') end
                end
                profiles[pname] = {itemName=item, startName=(start~='' and start or nil), members=map}
            end
        end
    end
    f:close()
end

local function saveProfiles()
    local f = io.open(PROFILE_FILE_PATH, 'w')
    if not f then addStatus('ERROR: Cannot write profile file.') return end
    for name,p in pairs(profiles) do
        local parts = {}
        for nm,v in pairs(p.members or {}) do
            table.insert(parts, nm..':'..(v and '1' or '0'))
        end
        f:write(string.format('%s|%s|%s|%s\n',
            name, p.itemName or '', p.startName or '', table.concat(parts,',')))
    end
    f:close()
    addStatus('Profiles saved.')
end

local function saveCurrentProfile()
    local nm = trim(profileNameBuffer or '')
    if nm == '' then return end
    local item = trim(activeItemName)
    if item == '' then addStatus('ERROR: No active item selected.') return end
    validateChainStart()
    local map = {}
    for _,m in ipairs(chainMembers) do map[m.name] = m.enabled end
    profiles[nm] = {itemName=item, startName=chainStartName, members=map}
    currentProfileName = nm
    profileNameBuffer  = nm
    saveProfiles()
    addStatus('Profile "%s" saved.', nm)
end

local function loadProfileByName(pname)
    local p = profiles[pname]
    if not p then addStatus('ERROR: Profile "%s" not found.', pname) return end
    manualItemName = p.itemName
    activeItemName = p.itemName
    local lower = p.itemName:lower()
    local found = false
    for _,nm in ipairs(savedItems) do if nm:lower()==lower then found=true break end end
    if not found then
        table.insert(savedItems, p.itemName)
        saveItemList()
        addStatus('Profile item "%s" added to saved items.', p.itemName)
    end
    profileNameBuffer  = pname
    currentProfileName = pname
    for _,m in ipairs(chainMembers) do
        m.enabled = (p.members[m.name] ~= nil) and p.members[m.name] or true
    end
    chainStartName = p.startName
    validateChainStart()
    addStatus('Profile "%s" loaded.', pname)
end

---------------------------------------------------------------------
-- TRADE & REMOTE USE
---------------------------------------------------------------------
local function useItemLocal(name)
    addStatus('Using "%s" on controller.', name)
    mq.cmdf('/useitem "%s"', name)
end

local function requestItemTransfer(target, source, item)
    addStatus('Requesting "%s" from %s -> %s.', item, source, target)
    mq.cmdf('/e3bct %s /giveme %s "%s"', target, source, item)
end

local function requestRemoteUse(toon, item)
    addStatus('Telling %s to use "%s".', toon, item)
    mq.cmdf('/e3bct %s /useitem "%s"', toon, item)
end

---------------------------------------------------------------------
-- FSM RESET / START / PAUSE
---------------------------------------------------------------------
local function resetSCMState()
    scm.list={} scm.index=0 scm.member=nil
    scm.phase='IDLE' scm.attempts=0 scm.startTime=0
    -- also reset pipeline state so speedTick starts clean
    speedPipeline         = {}
    speedPipelineIndex    = 1
    speedPhaseStart       = 0
    speedControllerIsLast = false
end

local function resetChain()
    running=false paused=false
    resetSCMState()
    addStatus('Chain reset.')
end

---------------------------------------------------------------------
-- EXPERIMENTAL: Speed Mode -- pipeline builder
-- Builds a flat ordered list of {delay, fn} steps at chain start.
-- Each step fires delay seconds after the *previous* step completed.
-- Controller -> M1 -> M2 -> ... -> Mn -> Controller (return)
---------------------------------------------------------------------
local function buildSpeedPipeline(list, controller, itemName)
    local steps    = {}
    local castWait = activeItemCastTime + SPEED_USE_DELAY

    -- Step 0: give item to first member.
    -- If the first member IS the controller they already have the item,
    -- so skip the give and go straight to use (saves SPEED_GIVE_DELAY seconds).
    local first = list[1]
    if first ~= controller then
        table.insert(steps, {delay=0.0, fn=function()
            addStatus('[SPD] Sending "%s" to %s.', itemName, first)
            requestItemTransfer(first, controller, itemName)
        end})
    else
        addStatus('[SPD] Controller is first -- skipping self-give, going straight to use.')
    end

    for i, member in ipairs(list) do
        local m = member  -- capture for closure

        -- After SPEED_GIVE_DELAY: tell this member to use the item.
        -- useDelay = 0 ONLY when controller is first and the give step was skipped
        -- (they already hold the item). For all other positions, including controller
        -- last, we still need SPEED_GIVE_DELAY so the transfer completes first.
        local skipWasApplied = (i == 1 and first == controller)
        local useDelay = skipWasApplied and 0.0 or SPEED_GIVE_DELAY
        table.insert(steps, {delay=useDelay, fn=function()
            addStatus('[SPD] Telling %s to use.', m)
            requestRemoteUse(m, itemName)
        end})

        if i < #list then
            -- After cast+buffer: pass item to next member
            local nxt = list[i+1]
            table.insert(steps, {delay=castWait, fn=function()
                addStatus('[SPD] %s -> %s.', m, nxt)
                requestItemTransfer(nxt, m, itemName)
            end})
        else
            -- Last member: pull item back to controller (skip if controller is last)
            if m ~= controller then
                table.insert(steps, {delay=castWait, fn=function()
                    addStatus('[SPD] Pulling back from %s.', m)
                    requestItemTransfer(controller, m, itemName)
                end})
            end
        end
    end

    return steps
end

---------------------------------------------------------------------
-- EXPERIMENTAL: speedTick -- advances the pipeline each frame
-- Replaces inline speed-mode branches that were inside scmTick().
-- Phases used: SPEED_PIPELINE (stepping), SPEED_WAIT_RETURN (polling).
---------------------------------------------------------------------
local function speedTick()
    if scm.phase == 'IDLE' or not running or paused then return end
    local me   = trim(mq.TLO.Me.Name() or '')
    local item = trim(activeItemName)
    if item == '' then return end
    local now  = os.clock()

    -- Advance through pipeline steps
    if scm.phase == 'SPEED_PIPELINE' then
        if speedPipelineIndex > #speedPipeline then
            -- All steps fired; switch to polling for return
            scm.phase       = 'SPEED_WAIT_RETURN'
            speedPhaseStart = now
            return
        end
        local step = speedPipeline[speedPipelineIndex]
        if now - speedPhaseStart >= step.delay then
            step.fn()
            speedPipelineIndex = speedPipelineIndex + 1
            speedPhaseStart    = now
        end
        return
    end

    -- Poll for item return after last pull request
    if scm.phase == 'SPEED_WAIT_RETURN' then
        -- Controller-last: they used the item themselves so no return is coming.
        -- Wait castTime + buffer for the use to complete, then declare done.
        if speedControllerIsLast then
            if now - speedPhaseStart >= (activeItemCastTime + 1.5) then
                chainTimer.lastTotal = os.time() - chainTimer.startTime
                addStatus('[SPD] Pipeline complete in %.0fs. (controller clicked last)', chainTimer.lastTotal)
                resetSCMState()
                running = false
                paused  = false
            end
            return
        end
        -- Normal: poll for the item returning to the controller
        if countItemByName(item) > 0 then
            chainTimer.lastTotal = os.time() - chainTimer.startTime
            addStatus('[SPD] Pipeline complete in %.0fs.', chainTimer.lastTotal)
            resetSCMState()
            running = false
            paused  = false
            return
        end
        -- Retry pull if we've been waiting too long (item may have stalled)
        if now - speedPhaseStart >= 10.0 then
            addStatus('[SPD] Timeout waiting for return. Retrying pull from %s.', scm.list[#scm.list])
            requestItemTransfer(me, scm.list[#scm.list], item)
            speedPhaseStart = now
        end
        return
    end
end

local function startChain()
    local item = trim(activeItemName)
    if item == '' then item = trim(manualItemName) end
    if item == '' then addStatus('ERROR: No item selected.') return end
    activeItemName = item

    activeItemCastTime = getItemCastTimeSecs(item)
    addStatus('Detected cast time for "%s": %.2fs.', item, activeItemCastTime)

    local me = trim(mq.TLO.Me.Name() or '')
    validateChainStart()
    scm.list = buildSCMList(true)  -- verbose=true: log full member state at chain start
    if #scm.list == 0 then addStatus('ERROR: No enabled members.') return end

    scm.index    = 1
    scm.member   = scm.list[1]
    scm.attempts = 0
    scm.startTime= os.time()

    running = true
    paused  = false
    chainTimer.startTime = os.time()
    chainTimer.lastTotal = nil  -- reset display until this chain completes

    addStatus('Starting chain. Controller=%s. Order=%s', me, table.concat(scm.list,'->'))

    -- EXPERIMENTAL: if auto-locate is on and controller is missing the item, attempt /fic
    if EXP_autoLocate and countItemByName(item) == 0 then
        addStatus('[EXP] Controller does not have "%s". Attempting locate...', item)
        runFicLocate(item)
        -- SAFE EXIT: do not start FSM yet. User hits Start again after item arrives.
        running = false
        return
    else
        addStatus('The item must start on the controller (%s).', me)
    end

    -- Route to speed pipeline or normal adaptive FSM
    if EXP_speedMode then
        speedPipeline         = buildSpeedPipeline(scm.list, me, item)
        speedPipelineIndex    = 1
        speedPhaseStart       = os.clock()
        speedControllerIsLast = (scm.list[#scm.list] == me)
        scm.phase             = 'SPEED_PIPELINE'
        addStatus('[SPD] Pipeline built (%d steps). Fire! ControllerLast=%s',
            #speedPipeline, tostring(speedControllerIsLast))
    else
        scm.phase = 'WAIT_HAVE_ITEM'
    end
end

local function togglePause()
    if not running then return end
    paused = not paused
    addStatus(paused and 'Chain paused.' or 'Chain resumed.')
end

---------------------------------------------------------------------
-- ZONING
---------------------------------------------------------------------
local function handleZone()
    local zoning = mq.TLO.Me.Zoning() or false
    if zoning then lastZoning=true return end
    local z = mq.TLO.Zone.ShortName() or ''
    if lastZoning or z ~= lastZone then
        addStatus('Zoned into %s.', z)
        lastZone=z lastZoning=false
        resetSCMState()
    end
end

---------------------------------------------------------------------
-- FSM TICK (adaptive / normal mode)
---------------------------------------------------------------------
local function scmTick()
    if scm.phase=='IDLE' or not running or paused then return end

    local me   = trim(mq.TLO.Me.Name() or '')
    local item = trim(activeItemName)
    if item == '' then return end

    scm.member = scm.list[scm.index]
    local now  = os.time()

    if scm.phase == 'WAIT_HAVE_ITEM' then
        if scm.member == me then
            local cnt = countItemByName(item)
            debugLog('scmTick WAIT_HAVE_ITEM: member==controller (%s) | itemCount=%d', me, cnt)
            if cnt > 0 then
                debugLog('scmTick: controller has item -> USE_LOCAL')
                scm.phase='USE_LOCAL' scm.startTime=now
            end
            return
        end
        local cnt = countItemByName(item)
        debugLog('scmTick WAIT_HAVE_ITEM: member=%s | itemCount=%d', scm.member, cnt)
        if cnt > 0 then
            addStatus('Controller has "%s". Sending to %s.', item, scm.member)
            scm.phase='GIVE_TO_MEMBER' scm.attempts=0 scm.startTime=now
            requestItemTransfer(scm.member, me, item)
        end
        return
    end

    if scm.phase == 'USE_LOCAL' then
        debugLog('scmTick USE_LOCAL: firing useItemLocal for controller | index=%d of %d', scm.index, #scm.list)
        useItemLocal(item)
        if scm.index < #scm.list then
            scm.index=scm.index+1 scm.member=scm.list[scm.index]
            scm.phase='WAIT_HAVE_ITEM' scm.attempts=0 scm.startTime=now
            addStatus('Controller used "%s". Proceeding to: %s.', item, scm.member)
        else
            if AUTO_REPEAT_CHAIN then
                scm.index=1 scm.member=scm.list[1]
                scm.phase='WAIT_HAVE_ITEM' scm.attempts=0 scm.startTime=now
                addStatus('Controller used "%s". Full round complete. Restarting.', item)
            else
                addStatus('Controller used "%s". Full round complete. Stopping.', item)
                chainTimer.lastTotal = os.time() - chainTimer.startTime
                resetSCMState() running=false paused=false
            end
        end
        return
    end

    if scm.phase == 'GIVE_TO_MEMBER' then
        if now - scm.startTime >= getAdaptiveTradeTimeout() then
            addStatus('Assuming %s received "%s" (%.1fs). Requesting use.',
                scm.member, item, getAdaptiveTradeTimeout())
            scm.phase='MEMBER_USE' scm.startTime=now
            requestRemoteUse(scm.member, item)
        end
        return
    end

    if scm.phase == 'MEMBER_USE' then
        local useDelay = activeItemCastTime + getAdaptiveRemoteUseDelay()
        if now - scm.startTime >= useDelay then
            addStatus('Requesting return of "%s" from %s.', item, scm.member)
            scm.phase='RETURN_TO_ME' scm.startTime=now
            requestItemTransfer(me, scm.member, item)
        end
        return
    end

    if scm.phase == 'RETURN_TO_ME' then
        if countItemByName(item) > 0 then
            recordTransferTime(now - scm.startTime)
            addStatus('Item "%s" returned from %s.', item, scm.member)
            if scm.index < #scm.list then
                scm.index=scm.index+1 scm.member=scm.list[scm.index]
                scm.phase='WAIT_HAVE_ITEM' scm.attempts=0 scm.startTime=now
                addStatus('Proceeding to next member: %s.', scm.member)
            else
                if AUTO_REPEAT_CHAIN then
                    scm.index=1 scm.member=scm.list[1]
                    scm.phase='WAIT_HAVE_ITEM' scm.attempts=0 scm.startTime=now
                    addStatus('Full round complete. Restarting.')
                else
                    addStatus('Full round complete. Stopping chain.')
                    chainTimer.lastTotal = os.time() - chainTimer.startTime
                    resetSCMState() running=false paused=false
                end
            end
            return
        end

        local adaptiveTimeout = getAdaptiveTradeTimeout()
        if now - scm.startTime >= adaptiveTimeout then
            scm.attempts = scm.attempts + 1
            if scm.attempts < TRADE_MAX_ATTEMPTS then
                addStatus('Still waiting for "%s" from %s; retry (%d/%d).',
                    item, scm.member, scm.attempts, TRADE_MAX_ATTEMPTS)
                scm.startTime = now
                requestItemTransfer(me, scm.member, item)
            else
                addStatus('ERROR: Could not retrieve "%s" from %s.', item, scm.member)
                resetChain()
            end
        end
        return
    end
end

local function chainTick()
    -- EXPERIMENTAL: drain /fic results first; yields to main tick when done
    if ficPending then
        if ficTick() then return end
    end

    -- EXPERIMENTAL: auto-resume -- poll for item arrival after locate pull
    if ficWaitingForReturn then
        local item = trim(activeItemName)
        if item ~= '' and countItemByName(item) > 0 then
            ficWaitingForReturn = false
            addStatus('[EXP] Item arrived. Auto-starting chain...')
            startChain()
        end
        return
    end

    -- Route to the appropriate tick based on mode
    if EXP_speedMode then
        speedTick()
    else
        scmTick()
    end
end

---------------------------------------------------------------------
-- BINDS
---------------------------------------------------------------------
mq.bind('/itempassui',    function() showUI = not showUI end)
mq.bind('/itempassstart', startChain)
mq.bind('/itempasspause', togglePause)
mq.bind('/itempassreset', resetChain)

---------------------------------------------------------------------
-- EXPERIMENTAL: /fic capture event (non-intrusive)
-- Only active when ficPending=true.
-- Matches E3 /fic output format:
--   <Name> [Pack] Item Name - bag(N) slot(N) count(N)
---------------------------------------------------------------------
mq.event('itempass_fic_generic', '#*#', function(line)
    if not ficPending then return end
    ficLastUpdate = os.time()
    -- Match E3's actual /fic output: <Who> [Pack] Item Name - bag(...
    local who, item = line:match('<(%w+)>%s+%[Pack%]%s+(.-)%s+%-')
    if who and item then
        table.insert(ficResults, {
            name = trim(who),
            item = trim(item)
        })
    end
end)

---------------------------------------------------------------------
-- EXPERIMENTAL: /fic locate runner
-- /fic only accepts a single word -- extract the longest non-filler
-- word from the item name so we get the most specific match.
-- e.g. "Nimbus of Midnight" -> "Midnight" / "Amulet of the Void" -> "Amulet"
---------------------------------------------------------------------
local FIC_FILLER = {['of']=true,['the']=true,['a']=true,['an']=true,['and']=true}

local function getFicKeyword(itemName)
    local best = ''
    for w in itemName:gmatch('%S+') do
        if not FIC_FILLER[w:lower()] and #w > #best then
            best = w
        end
    end
    return (best ~= '') and best or itemName
end

runFicLocate = function(itemName)
    ficResults    = {}
    ficPending    = true
    ficLastUpdate = os.time()
    local keyword = getFicKeyword(itemName)
    addStatus('[EXP] Locating "%s" via /fic (keyword: "%s")...', itemName, keyword)
    mq.cmdf('/fic %s', keyword)
end

---------------------------------------------------------------------
-- EXPERIMENTAL: ficTick -- resolves /fic results after silence window
-- Returns true while still collecting, false when done.
---------------------------------------------------------------------
ficTick = function()
    if not ficPending then return false end

    -- Still within silence window -- keep collecting
    if os.time() - ficLastUpdate < FIC_TIMEOUT then
        return true
    end

    ficPending = false

    local item = trim(activeItemName)
    local me   = trim(mq.TLO.Me.Name() or '')

    if #ficResults == 0 then
        addStatus('[EXP] /fic returned no results for "%s".', item)
        return false
    end

    -- Find holder by substring match against full item name
    local target = item:lower()
    local holder = nil
    for _, r in ipairs(ficResults) do
        if r.item:lower():find(target, 1, true) then
            holder = r.name
            break
        end
    end

    if not holder then
        addStatus('[EXP] No matching holder found in /fic output.')
        return false
    end

    addStatus('[EXP] Found "%s" on %s. Requesting transfer to controller...', item, holder)
    -- SAFE: always pulls item to controller (me), never to a third party
    requestItemTransfer(me, holder, item)

    if ficAutoResume then
        ficWaitingForReturn = true
        addStatus('[EXP] Auto-resume ON. Will start chain when item arrives.')
    else
        addStatus('[EXP] Hit Start when item arrives.')
    end

    return false
end

---------------------------------------------------------------------
-- GUI
-- Registered via mq.imgui.init -- NOT called directly from the main loop.
-- Wrapped in pcall so any ImGui error logs and recovers instead of killing the script.
---------------------------------------------------------------------
local function renderUI()
    if not showUI then return end

    local ok, err = pcall(function()

        -- ImGui.Begin returns false when the window is collapsed to its title bar.
        -- In that case we must still call ImGui.End(), but we do NOT touch showUI --
        -- the window is still registered and will re-expand normally.
        -- showUI is only set to false by /itempassui or by the script itself.
        if not windowSizeSet then
            ImGui.SetNextWindowSize(500, 700)
            windowSizeSet = true
        end
        local open = ImGui.Begin(string.format('ItemPass v%s', SCRIPT_VERSION))
        if not open then
            ImGui.End()
            return
        end

        ----------------------------------------------------
        -- ITEM CONFIG
        ----------------------------------------------------
        ImGui.Text('Item Configuration')

        manualItemName = ImGui.InputText('Item Name##item_input', manualItemName or '', 64)

        local suggestions = getItemSuggestions(manualItemName)

        ImGui.SameLine()
        if ImGui.Button('Set Active##btn_setactive') then
            local nm = trim(manualItemName)
            if nm ~= '' then
                activeItemName = nm
                addStatus('Active item set to "%s".', nm)
            else
                addStatus('No item name entered.')
            end
        end

        if manualItemName and trim(manualItemName) ~= '' then
            ImGui.SameLine()
            if #suggestions > 0 then
                ImGui.TextDisabled(string.format('(%d matches)', #suggestions))
            else
                ImGui.TextDisabled('(no matches)')
            end
        end

        ----------------------------------------------------
        -- AUTOCOMPLETE DROPDOWN
        ----------------------------------------------------
        local chosen = nil
        if #suggestions > 0 then
            if ImGui.BeginCombo('Autocomplete##item_autocomplete', 'Select match...') then
                for _, entry in ipairs(suggestions) do
                    local sel = (entry.name == manualItemName)
                    if ImGui.Selectable(entry.display, sel) then
                        chosen = entry.name
                    end
                    if sel then ImGui.SetItemDefaultFocus() end
                end
                ImGui.EndCombo()
            end
        end

        if chosen and chosen ~= lastAutocompleteChoice then
            manualItemName         = chosen
            activeItemName         = chosen
            lastAutocompleteChoice = chosen
            addStatus('Autocomplete selected "%s".', chosen)
        elseif not chosen then
            lastAutocompleteChoice = nil
        end

        ----------------------------------------------------
        -- SAVE / SCAN / HIDE
        ----------------------------------------------------
        if ImGui.Button('Save Item Name##btn_saveitem') then saveCurrentItem() end

        ImGui.SameLine()
        if ImGui.Button('Scan Inventory##btn_scaninv') then scanInventory() end

        ImGui.SameLine()
        local hidden = isItemHidden(manualItemName)
        if ImGui.Button(hidden and 'Unhide Item##unhide' or 'Hide Item##hide') then
            if hidden then unhideItemByName(manualItemName)
            else hideItemByName(manualItemName) end
            scanInventory()
        end

        ----------------------------------------------------
        -- SAVED ITEMS COMBO
        ----------------------------------------------------
        if #savedItems > 0 then
            local preview = savedItems[selectedSavedItem] or 'Select...'
            if ImGui.BeginCombo('Saved Items##combo_saved', preview) then
                for i,nm in ipairs(savedItems) do
                    local sel = (i == selectedSavedItem)
                    if ImGui.Selectable(nm, sel) then
                        selectedSavedItem = i
                        manualItemName    = nm
                        activeItemName    = nm
                    end
                    if sel then ImGui.SetItemDefaultFocus() end
                end
                ImGui.EndCombo()
            end
            if ImGui.Button('Delete Selected##del_saved') then deleteSelectedSavedItem() end
        else
            ImGui.TextDisabled('No saved items.')
        end

        ----------------------------------------------------
        -- INVENTORY COMBO
        ----------------------------------------------------
        if #inventoryItems > 0 then
            local preview = 'Select...'
            if selectedInventoryIndex > 0 and inventoryItems[selectedInventoryIndex] then
                preview = inventoryItems[selectedInventoryIndex].display
            end
            if ImGui.BeginCombo('Inventory Items##combo_inv', preview) then
                for i,it in ipairs(inventoryItems) do
                    local sel = (i == selectedInventoryIndex)
                    if ImGui.Selectable(it.display, sel) then
                        selectedInventoryIndex = i
                        manualItemName         = it.name
                        activeItemName         = it.name
                    end
                    if sel then ImGui.SetItemDefaultFocus() end
                end
                ImGui.EndCombo()
            end
        else
            ImGui.TextDisabled('Inventory not scanned yet.')
        end

        ImGui.Text(string.format('Active Item: %s', activeItemName ~= '' and activeItemName or '<none>'))
        ImGui.Separator()

        ----------------------------------------------------
        -- CHAIN MEMBERS
        ----------------------------------------------------
        ImGui.Text('Chain Members')
        if ImGui.Button('Refresh Group##ref_group') then refreshChainMembers() end
        ImGui.SameLine()
        if ImGui.Button('Purge Missing##purge_miss') then purgeMissingMembers() end

        for _,m in ipairs(chainMembers) do
            local controller = trim(mq.TLO.Me.Name() or '')
            local mark       = m.enabled and '[X]' or '[ ]'
            local selfTag    = (m.name == controller) and ' [You]' or ''
            local missTag    = (not m.present) and ' [missing]' or ''
            local startTag   = (m.name == chainStartName) and ' (Start)' or ''
            local label      = string.format('%s %s%s%s%s', mark, m.name, selfTag, startTag, missTag)

            if m.present then
                if ImGui.Selectable(label, false) then
                    m.enabled = not m.enabled
                    validateChainStart()
                end
            else
                ImGui.Selectable(label, false)
            end
        end

        ----------------------------------------------------
        -- CHAIN PREVIEW
        ----------------------------------------------------
        ImGui.Separator()
        ImGui.Text('Chain Preview')
        local me   = trim(mq.TLO.Me.Name() or '')
        local list = buildSCMList()
        if #list == 0 then
            ImGui.TextWrapped('Enable at least one member...')
        else
            -- Check whether controller is in the rotation list
            local controllerInList = false
            for _, nm in ipairs(list) do
                if nm == me then controllerInList = true break end
            end

            local parts = {me .. ' [controller]'}
            for _, nm in ipairs(list) do
                -- Tag the controller's position in the chain so it's clear
                -- they will self-click here, not just appear as a cosmetic bookend.
                if nm == me then
                    table.insert(parts, nm .. ' [click]')
                else
                    table.insert(parts, nm)
                end
            end
            -- Only append [return] if controller is NOT in the list;
            -- if they are, the chain ends when they click (no extra return step).
            if not controllerInList then
                table.insert(parts, me .. ' [return]')
            end
            ImGui.TextWrapped(table.concat(parts, ' -> '))
        end

        ----------------------------------------------------
        -- CONTROLS
        ----------------------------------------------------
        ImGui.Separator()
        if not running then
            if ImGui.Button('Start##start') then startChain() end
        else
            if ImGui.Button(paused and 'Resume##resume' or 'Pause##pause') then togglePause() end
        end
        ImGui.SameLine()
        if ImGui.Button('Reset##reset') then resetChain() end

        local statusStr = 'Stopped'
        if running then statusStr = paused and 'Paused' or 'Running' end
        ImGui.Text(string.format('Status: %s', statusStr))

        if activeItemCastTime > 0 and activeItemName ~= '' then
            ImGui.Text(string.format('Cast Time: %.2fs (detected)', activeItemCastTime))
        end

        ImGui.Separator()

        ----------------------------------------------------
        -- TIMING / LATENCY
        ----------------------------------------------------
        ImGui.Text('Timing')

        -- Last chain total time
        if chainTimer.lastTotal then
            ImGui.Text(string.format('Last chain took: %.0fs', chainTimer.lastTotal))
        else
            ImGui.TextDisabled('Last chain took: --')
        end

        -- Avg swap time explanation + value
        if latencyStats.manualOverride > 0 then
            ImGui.Text(string.format('Avg swap time: %.1fs (manual)', latencyStats.manualOverride))
        else
            local n = #latencyStats.measurements
            if n == 0 then
                ImGui.TextDisabled(string.format('Avg swap time: %.1fs (estimated, no data yet)', latencyStats.avgTransferTime))
            else
                ImGui.Text(string.format('Avg swap time: %.1fs (learned from %d swap%s)', latencyStats.avgTransferTime, n, n==1 and '' or 's'))
            end
        end
        ImGui.TextWrapped('Swap time = how long each individual item hand-off takes. The script learns this automatically and uses it to set wait times.')

        -- Manual override
        local prevOverride = latencyStats.manualOverride
        local overrideStr  = ImGui.InputText('Override swap time (s, 0=auto)##latency_override',
                                string.format('%.1f', prevOverride), 16)
        local newOverride  = tonumber(overrideStr) or 0
        if newOverride < 0 then newOverride = 0 end
        if newOverride ~= prevOverride then
            latencyStats.manualOverride = newOverride
            if newOverride > 0 then
                addStatus('Swap time override set to %.1f seconds.', newOverride)
            else
                addStatus('Back to auto swap time.')
            end
        end

        ImGui.SameLine()
        if ImGui.Button('Reset to Auto##reset_latency') then
            latencyStats.manualOverride  = 0
            latencyStats.measurements    = {}
            latencyStats.avgTransferTime = 1.5
            addStatus('Swap time reset to auto.')
        end

        ImGui.Separator()

        ----------------------------------------------------
        -- EXPERIMENTAL (may have bugs -- safe layer only)
        ----------------------------------------------------

        -- Auto-locate + auto-resume
        EXP_autoLocate = ImGui.Checkbox('Auto-locate item##exp_locate', EXP_autoLocate)
        if EXP_autoLocate then
            ImGui.SameLine()
            ficAutoResume = ImGui.Checkbox('Auto-resume after pull##exp_resume', ficAutoResume)
        end
        if EXP_autoLocate then
            if ficPending then
                ImGui.TextDisabled('Locate: searching via /fic...')
            elseif ficWaitingForReturn then
                ImGui.TextDisabled('Locate: item requested, waiting for arrival...')
            elseif #ficResults > 0 then
                ImGui.TextDisabled(string.format('Locate: last scan found %d result(s)', #ficResults))
            else
                ImGui.TextDisabled('Locate: idle')
            end
            if not ficAutoResume then
                ImGui.TextWrapped('Auto-locate: finds and pulls item. Hit Start again after pull.')
            else
                ImGui.TextWrapped('Auto-locate + Auto-resume: finds, pulls, then starts chain automatically.')
            end
        end

        -- Speed Mode
        EXP_speedMode = ImGui.Checkbox('Speed Mode##exp_speed', EXP_speedMode)
        if EXP_speedMode then
            ImGui.TextDisabled(string.format('Give: %.1fs | Use buffer: +%.1fs | (pipeline, no adaptive wait)',
                SPEED_GIVE_DELAY, SPEED_USE_DELAY))
            ImGui.TextWrapped('Pre-built pipeline: fires all commands up front with fixed delays. ~2x faster. Use on stable systems only.')
        end

        ImGui.Separator()

        ----------------------------------------------------
        -- DEBUG LOGGING
        ----------------------------------------------------
        ImGui.Text('Debug Logging')
        local prevDebug = debugMode
        debugMode = ImGui.Checkbox('Enable Debug Log##dbg_enable', debugMode)
        if debugMode and not prevDebug then
            -- Write a session header when first enabled so the log is clearly segmented
            local f = io.open(DEBUG_LOG_PATH, 'a')
            if f then
                f:write(string.format('\n=== ItemPass debug session started %s ===\n', os.date('%Y-%m-%d %H:%M:%S')))
                f:close()
            end
            addStatus('[DBG] Debug logging ON -> %s', DEBUG_LOG_PATH)
        elseif not debugMode and prevDebug then
            addStatus('[DBG] Debug logging OFF.')
        end

        if debugMode then
            ImGui.SameLine()
            if ImGui.Button('Clear Log##dbg_clear') then
                local f = io.open(DEBUG_LOG_PATH, 'w')
                if f then f:close() end
                addStatus('[DBG] Debug log cleared.')
            end
            ImGui.TextDisabled(DEBUG_LOG_PATH)
            ImGui.TextWrapped('Verbose FSM tracing is written to the file above.')
        end

        ImGui.Separator()

        ----------------------------------------------------
        -- PROFILES
        ----------------------------------------------------
        ImGui.Text('Profiles')
        profileNameBuffer = ImGui.InputText('Profile Name##prof_name', profileNameBuffer or '', 64)

        ImGui.SameLine()
        if ImGui.Button('Save Profile##save_prof') then saveCurrentProfile() end

        local pnames = {}
        for n,_ in pairs(profiles) do table.insert(pnames, n) end
        table.sort(pnames)

        if #pnames > 0 then
            local preview = currentProfileName ~= '' and currentProfileName or 'Select...'
            if ImGui.BeginCombo('Load Profile##load_prof', preview) then
                for _,n in ipairs(pnames) do
                    local sel = (n == currentProfileName)
                    if ImGui.Selectable(n, sel) then
                        if not sel then loadProfileByName(n) end
                    end
                    if sel then ImGui.SetItemDefaultFocus() end
                end
                ImGui.EndCombo()
            end
        else
            ImGui.TextDisabled('No profiles saved.')
        end

        ImGui.Separator()

        ----------------------------------------------------
        -- STATUS LOG
        ----------------------------------------------------
        ImGui.Text('Status Log:')
        for _,ln in ipairs(statusLog) do
            ImGui.TextWrapped(ln)
        end

        ImGui.End()
    end)

    if not ok then
        addStatus('GUI ERROR: %s', tostring(err))
    end
end

---------------------------------------------------------------------
-- INIT & LOOP
---------------------------------------------------------------------
local function init()
    print('\atOriginally created by Alektra <Lederhosen>')
    print('\agItemPass v' .. SCRIPT_VERSION .. ' Loaded')

    addStatus('ItemPass (EMU) loading...')
    addStatus('Run this script only on the controller toon.')

    loadHiddenItems()
    loadItemList()
    loadProfiles()
    refreshChainMembers()
    scanInventory()

    mq.imgui.init('itempass_ui', renderUI)

    addStatus('Ready. Commands: /itempassui /itempassstart /itempasspause /itempassreset')
    checkForUpdate()
end

init()

while true do
    handleZone()
    chainTick()
    mq.delay(100)
    mq.doevents()
end