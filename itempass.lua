-- ItemPass (Project Lazarus EMU / MQNext / E3Next)
-- Controller-based item passing script:
--   Controller starts with the item
--   -> sends item to each enabled group member in order
--   -> tells them to /useitem
--   -> pulls the item back
-- After the last member, the item returns to the controller and the chain stops
-- (unless AUTO_REPEAT_CHAIN is enabled).
--
-- EMU safe: NO FindItem/FindItemCount. Local inventory via Me.Inventory/Container/Item only.
-- Hidden Items:
--   - Stored in itempass_hidden.txt
--   - Hidden items are filtered from Inventory dropdown & inventory-based autocomplete
--   - Hidden items are NOT removed from Saved Items

-- ItemPass v1.4.0
-- Performance Update:
--   + BASE_TRADE_TIMEOUT reduced from 20s to 5s (more appropriate for EMU server latency)
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
local SCRIPT_VERSION = "1.4.0" -- semantic version: MAJOR.MINOR.PATCH

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

---------------------------------------------------------------------
-- LATENCY TRACKING STATE
---------------------------------------------------------------------
local latencyStats = {
    totalTransfers  = 0,
    avgTransferTime = 1.5,  -- v1.4.0: seeded baseline so first chain isn't blind
    measurements    = {},
    manualOverride  = 0,    -- 0 = adaptive, >0 = manual seconds
}

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
                    table.insert(chainMembers, {name=nm, enabled=true, present=true})
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
            table.insert(chainMembers, {name=me, enabled=true, present=true})
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

local function buildSCMList()
    local list = {}
    for _, m in ipairs(chainMembers) do
        if m.enabled and m.present then table.insert(list, m.name) end
    end
    if chainStartName and #list > 1 then
        local startIdx = nil
        for i, nm in ipairs(list) do
            if nm == chainStartName then startIdx = i break end
        end
        if startIdx and startIdx > 1 then
            local rotated = {}
            for i = startIdx, #list do table.insert(rotated, list[i]) end
            for i = 1, startIdx-1 do table.insert(rotated, list[i]) end
            list = rotated
        end
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
end

local function resetChain()
    running=false paused=false
    resetSCMState()
    addStatus('Chain reset.')
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
    scm.list = buildSCMList()
    if #scm.list == 0 then addStatus('ERROR: No enabled members.') return end

    scm.index    = 1
    scm.member   = scm.list[1]
    scm.phase    = 'WAIT_HAVE_ITEM'
    scm.attempts = 0
    scm.startTime= os.time()

    running = true
    paused  = false

    addStatus('Starting chain. Controller=%s. Order=%s', me, table.concat(scm.list,'->'))
    addStatus('The item must start on the controller (%s).', me)
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
-- FSM TICK
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
            if countItemByName(item) > 0 then
                scm.phase='USE_LOCAL' scm.startTime=now
            end
            return
        end
        if countItemByName(item) > 0 then
            addStatus('Controller has "%s". Sending to %s.', item, scm.member)
            scm.phase='GIVE_TO_MEMBER' scm.attempts=0 scm.startTime=now
            requestItemTransfer(scm.member, me, item)
        end
        return
    end

    if scm.phase == 'USE_LOCAL' then
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
                resetSCMState() running=false paused=false
            end
        end
        return
    end

    if scm.phase == 'GIVE_TO_MEMBER' then
        local adaptiveTimeout = getAdaptiveTradeTimeout()
        if now - scm.startTime >= adaptiveTimeout then
            addStatus('Assuming %s received "%s" (timeout: %.1fs). Requesting use.',
                scm.member, item, adaptiveTimeout)
            scm.phase='MEMBER_USE' scm.startTime=now
            requestRemoteUse(scm.member, item)
        end
        return
    end

    if scm.phase == 'MEMBER_USE' then
        local adaptiveDelay = activeItemCastTime + getAdaptiveRemoteUseDelay()
        if now - scm.startTime >= adaptiveDelay then
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
    scmTick()
end

---------------------------------------------------------------------
-- BINDS
---------------------------------------------------------------------
mq.bind('/itempassui',    function() showUI = not showUI end)
mq.bind('/itempassstart', startChain)
mq.bind('/itempasspause', togglePause)
mq.bind('/itempassreset', resetChain)

---------------------------------------------------------------------
-- GUI
-- Registered via mq.imgui.init — NOT called directly from the main loop.
-- Wrapped in pcall so any ImGui error logs and recovers instead of killing the script.
---------------------------------------------------------------------
local function renderUI()
    if not showUI then return end

    local ok, err = pcall(function()

        local open = ImGui.Begin(string.format('ItemPass v%s', SCRIPT_VERSION))
        if not open then
            showUI = false
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
            ImGui.TextWrapped('Enable at least one other member...')
        else
            local parts = {me .. ' [controller]'}
            for _,nm in ipairs(list) do table.insert(parts, nm) end
            table.insert(parts, me .. ' [end]')
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
        -- LATENCY SETTINGS
        ----------------------------------------------------
        ImGui.Text('Latency Settings')
        ImGui.TextWrapped('Script learns optimal transfer times automatically. Use manual override to tune.')

        local prevOverride = latencyStats.manualOverride
        local overrideStr  = ImGui.InputText('Manual Transfer Time (s)##latency_override',
                                string.format('%.1f', prevOverride), 16)
        local newOverride  = tonumber(overrideStr) or 0
        if newOverride < 0 then newOverride = 0 end
        if newOverride ~= prevOverride then
            latencyStats.manualOverride = newOverride
            if newOverride > 0 then
                addStatus('Transfer time override set to %.1f seconds.', newOverride)
            else
                addStatus('Using adaptive latency tracking.')
            end
        end

        ImGui.SameLine()
        if ImGui.Button('Reset to Auto##reset_latency') then
            latencyStats.manualOverride  = 0
            latencyStats.measurements    = {}
            latencyStats.avgTransferTime = 1.5
            addStatus('Latency tracking reset.')
        end

        local modeStr
        if latencyStats.manualOverride > 0 then
            modeStr = string.format('Manual: %.1fs', latencyStats.manualOverride)
        else
            modeStr = string.format('Adaptive: %.1fs (n=%d)', latencyStats.avgTransferTime, #latencyStats.measurements)
        end
        ImGui.TextDisabled(string.format('Mode: %s', modeStr))
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
end

init()

while true do
    handleZone()
    chainTick()
    mq.delay(100)
    mq.doevents()
end
