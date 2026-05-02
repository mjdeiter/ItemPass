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

-- ItemPass v1.3.0
-- Major Update:
--   + Added adaptive latency tracking (auto-learns transfer times)
--   + Manual transfer time override in GUI
--   + Configurable timeout behavior for group/server variations

local mq    = require('mq')
local ImGui = require('ImGui')

---------------------------------------------------------------------
-- VERSION / CREDITS
---------------------------------------------------------------------
local SCRIPT_VERSION = "1.3.2" -- semantic version: MAJOR.MINOR.PATCH

---------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------

local AUTO_REPEAT_CHAIN = false
local BASE_REMOTE_USE_DELAY  = 3

---------------------------------------------------------------------
-- PATHS / CONSTANTS
---------------------------------------------------------------------
local MQROOT            = mq.TLO.MacroQuest.Path() or '.'
local ITEM_FILE_PATH    = MQROOT .. '/itempass_items.txt'
local PROFILE_FILE_PATH = MQROOT .. '/itempass_profiles.txt'
local HIDDEN_FILE_PATH  = MQROOT .. '/itempass_hidden.txt'

local SLOT_MIN = 0
local SLOT_MAX = 32
local BASE_TRADE_TIMEOUT      = 20
local TRADE_MAX_ATTEMPTS = 3
local MAX_LOG            = 200

local MAX_SUGGESTIONS    = 10 -- max autocomplete entries shown

---------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------
local savedItems             = {}
local selectedSavedItem      = 1
local manualItemName         = ''
local activeItemName         = ''

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

local hiddenItems            = {}
local hiddenLookup           = {}

-- advanced autocomplete state
local lastAutocompleteChoice = nil

---------------------------------------------------------------------
-- LATENCY TRACKING STATE
---------------------------------------------------------------------
local latencyStats = {
    totalTransfers = 0,
    avgTransferTime = 0,
    measurements = {},
    manualOverride = 0,  -- 0 = use adaptive, >0 = manual seconds
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
    if #statusLog > MAX_LOG then
        table.remove(statusLog, 1)
    end
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
    if latencyStats.manualOverride > 0 then
        return  -- don't record if using manual override
    end
    
    duration = math.max(duration, 0.1)  -- minimum 0.1s
    table.insert(latencyStats.measurements, duration)
    
    -- Keep last 30 measurements for rolling average
    if #latencyStats.measurements > 30 then
        table.remove(latencyStats.measurements, 1)
    end
    
    local sum = 0
    for _, v in ipairs(latencyStats.measurements) do
        sum = sum + v
    end
    latencyStats.avgTransferTime = sum / #latencyStats.measurements
    latencyStats.totalTransfers = latencyStats.totalTransfers + 1
    
    addStatus('Transfer completed in %.1fs (avg: %.1fs over %d samples)',
        duration, latencyStats.avgTransferTime, #latencyStats.measurements)
end

local function getAdaptiveTradeTimeout()
    if latencyStats.manualOverride > 0 then
        return latencyStats.manualOverride
    end
    
    -- Adaptive timeout: base + (average transfer time * safety multiplier)
    local adaptiveTimeout = BASE_TRADE_TIMEOUT
    if latencyStats.avgTransferTime > 0 then
        -- Add 3x the average transfer time as buffer for network variance
        adaptiveTimeout = BASE_TRADE_TIMEOUT + (latencyStats.avgTransferTime * 3)
    end
    
    return adaptiveTimeout
end

local function getAdaptiveRemoteUseDelay()
    if latencyStats.manualOverride > 0 then
        return latencyStats.manualOverride
    end
    
    -- Use average transfer time + base delay as minimum wait before requesting use
    local adaptiveDelay = BASE_REMOTE_USE_DELAY
    if latencyStats.avgTransferTime > 0 then
        adaptiveDelay = BASE_REMOTE_USE_DELAY + (latencyStats.avgTransferTime * 1.5)
    end
    
    return adaptiveDelay
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
    if not fileExists(HIDDEN_FILE_PATH) then
        hiddenLookup = {}
        return
    end

    local f = io.open(HIDDEN_FILE_PATH, 'r')
    if not f then
        hiddenLookup = {}
        return
    end

    for line in f:lines() do
        local nm = trim(line)
        if nm ~= '' then table.insert(hiddenItems, nm) end
    end
    f:close()
    rebuildHiddenLookup()
end

local function saveHiddenItems()
    local f = io.open(HIDDEN_FILE_PATH, 'w')
    if not f then
        print('[ItemPass] ERROR: Cannot write hidden file.')
        return
    end
    for _, nm in ipairs(hiddenItems) do
        f:write(nm .. '\n')
    end
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

    local newList = {}
    local removed = false
    for _, nm in ipairs(hiddenItems) do
        if trim(nm):lower() == key then
            removed = true
        else
            table.insert(newList, nm)
        end
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
-- ADVANCED AUTOCOMPLETE HELPERS
---------------------------------------------------------------------

-- Simple Levenshtein distance for fuzzy match on short strings
local function levenshtein(a, b)
    a = a or ''
    b = b or ''
    local la, lb = #a, #b
    if la == 0 then return lb end
    if lb == 0 then return la end

    local prev = {}
    local curr = {}

    for j = 0, lb do
        prev[j] = j
    end

    for i = 1, la do
        curr[0] = i
        local ca = a:sub(i, i)
        for j = 1, lb do
            local cb = b:sub(j, j)
            local cost = (ca == cb) and 0 or 1
            local del  = prev[j]   + 1
            local ins  = curr[j-1] + 1
            local sub  = prev[j-1] + cost
            local v    = del
            if ins < v then v = ins end
            if sub < v then v = sub end
            curr[j] = v
        end
        prev, curr = curr, prev
    end

    return prev[lb]
end

-- Return ranked suggestions:
-- Each element: {name=string, display=string, score=number}
local function getItemSuggestions(prefix)
    prefix = trim(prefix or '')
    if prefix == '' then return {} end

    local search = prefix:lower()
    local suggestions = {}
    local seen = {}

    local function considerName(nm)
        nm = trim(nm or '')
        if nm == '' then return end
        local key = nm:lower()
        if seen[key] then return end
        seen[key] = true

        -- scoring:
        -- 0  = starts with search  (best)
        -- 1  = contains search
        -- 2+ = fuzzy (levenshtein on prefix vs leading part)
        local score
        local startPos = key:find(search, 1, true)
        if startPos == 1 then
            score = 0
        elseif startPos ~= nil then
            score = 1
        else
            local slice = key:sub(1, #search)
            score = 2 + levenshtein(search, slice)
        end

        local display = nm
        if score == 0 then
            display = '★ ' .. nm        -- highlight strong matches
        elseif score == 1 then
            display = '• ' .. nm
        end

        table.insert(suggestions, {
            name    = nm,
            display = display,
            score   = score,
        })
    end

    -- Saved items first
    for _, nm in ipairs(savedItems) do
        considerName(nm)
    end

    -- Inventory items (skip hidden)
    for _, it in ipairs(inventoryItems) do
        if not isItemHidden(it.name) then
            considerName(it.name)
        end
    end

    -- sort by score, then alpha
    table.sort(suggestions, function(a, b)
        if a.score ~= b.score then
            return a.score < b.score
        end
        return a.name:lower() < b.name:lower()
    end)

    -- trim to max suggestions
    if #suggestions > MAX_SUGGESTIONS then
        local trimmed = {}
        for i = 1, MAX_SUGGESTIONS do
            trimmed[i] = suggestions[i]
        end
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
            local nm = trim(it.Name() or '')
            local cslots = it.Container() or 0

            if cslots == 0 and nm:lower() == target then
                total = total + 1
            end

            if cslots > 0 then
                for i = 0, cslots do  -- FIX v1.3.2: start at 0 to catch slot-0 items
                    local inner = it.Item(i)
                    if inner() and inner.ID() ~= 0 then
                        local nm2 = trim(inner.Name() or '')
                        if nm2:lower() == target then
                            total = total + 1
                        end
                    end
                end
            end
        end
    end

    return total
end

local function scanInventory()
    local top, bag = {}, {}

    for slot = SLOT_MIN, SLOT_MAX do
        local it = mq.TLO.Me.Inventory(slot)
        if it() and it.ID() ~= 0 then
            local nm = trim(it.Name() or '')
            local cslots = it.Container() or 0

            if nm ~= '' and not isItemHidden(nm) then
                if cslots > 0 then
                    -- FIXED: Use each bag's own cslots, not a previous bag's
                    for i = 0, cslots do  -- FIX v1.3.2: start at 0 to catch slot-0 items
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
        table.insert(inventoryItems, {name=n, display=(c>1) and string.format('%s (x%d)', n, c) or n})
    end
    for _,n in ipairs(bn) do
        local c = bag[n]
        table.insert(inventoryItems, {name=n, display=(c>1) and string.format('%s (x%d)', n, c) or n})
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

    selectedSavedItem = (#savedItems>0) and 1 or 0
end

local function saveItemList()
    local f = io.open(ITEM_FILE_PATH, 'w')
    if not f then
        addStatus('ERROR: Cannot write item file.')
        return
    end
    for _,nm in ipairs(savedItems) do
        f:write(nm..'\n')
    end
    f:close()
end

local function saveCurrentItem()
    local nm = trim(manualItemName)
    if nm == '' then return end

    for _,v in ipairs(savedItems) do
        if v:lower()==nm:lower() then
            addStatus('"%s" already saved.', nm)
            return
        end
    end

    table.insert(savedItems, nm)
    selectedSavedItem = #savedItems
    saveItemList()
    addStatus('Saved item "%s".', nm)
end

local function deleteSelectedSavedItem()
    if #savedItems==0 or selectedSavedItem<=0 then return end
    local nm = savedItems[selectedSavedItem]
    table.remove(savedItems, selectedSavedItem)
    if selectedSavedItem > #savedItems then selectedSavedItem=#savedItems end
    if selectedSavedItem==0 and #savedItems>0 then selectedSavedItem=1 end
    saveItemList()
    addStatus('Deleted saved item "%s".', nm)
end

---------------------------------------------------------------------
-- CHAIN MEMBERS / PROFILES
---------------------------------------------------------------------
local function validateChainStart()
    if chainStartName then
        local ok=false
        for _,m in ipairs(chainMembers) do
            if m.name==chainStartName and m.enabled and m.present then
                ok=true
                break
            end
        end
        if not ok then chainStartName=nil end
    end

    if not chainStartName then
        for _,m in ipairs(chainMembers) do
            if m.enabled and m.present then
                chainStartName=m.name
                break
            end
        end
    end
end

local function refreshChainMembers()
    for _,m in ipairs(chainMembers) do m.present=false end

    local gc = mq.TLO.Group.Members() or 0

    for slot=0,gc do
        local gm=mq.TLO.Group.Member(slot)
        if gm() then
            local nm=trim(gm.Name() or '')
            if nm~='' then
                local found=false
                for _,m in ipairs(chainMembers) do
                    if m.name==nm then
                        m.present=true
                        found=true
                        break
                    end
                end
                if not found then
                    table.insert(chainMembers, {name=nm, enabled=true, present=true})
                end
            end
        end
    end

    local me = trim(mq.TLO.Me.Name() or '')
    if me~='' then
        local found=false
        for _,m in ipairs(chainMembers) do
            if m.name==me then
                m.present=true
                found=true
                break
            end
        end
        if not found then
            table.insert(chainMembers, {name=me, enabled=true, present=true})
        end
    end

    for _,m in ipairs(chainMembers) do
        if not m.present and m.enabled then
            m.enabled=false
        end
    end

    validateChainStart()

    addStatus(
        'Group refreshed (%d entries: %d present, %d missing).',
        #chainMembers,
        (function() local c=0 for _,m in ipairs(chainMembers) do if m.present then c=c+1 end end return c end)(),
        (function() local c=0 for _,m in ipairs(chainMembers) do if not m.present then c=c+1 end end return c end)()
    )
end

local function purgeMissingMembers()
    local keep={}
    for _,m in ipairs(chainMembers) do
        if m.present then table.insert(keep,m) end
    end
    chainMembers = keep
    validateChainStart()
    addStatus('Purged missing members. Remaining: %d.', #chainMembers)
end

local function buildSCMList()
    local list = {}

    -- v1.1.2 FIX:
    --  * Controller checkbox now matters (controller included only if enabled)
    --  * (Start) member is first in chain (rotation)
    for _, m in ipairs(chainMembers) do
        if m.enabled and m.present then
            table.insert(list, m.name)
        end
    end

    -- Rotate so Start is first (if valid)
    if chainStartName and #list > 1 then
        local startIdx = nil
        for i, nm in ipairs(list) do
            if nm == chainStartName then
                startIdx = i
                break
            end
        end
        if startIdx and startIdx > 1 then
            local rotated = {}
            for i = startIdx, #list do table.insert(rotated, list[i]) end
            for i = 1, startIdx - 1 do table.insert(rotated, list[i]) end
            list = rotated
        end
    end

    return list
end

---------------------------------------------------------------------
-- PROFILES
---------------------------------------------------------------------
local function loadProfiles()
    profiles={}
    if not fileExists(PROFILE_FILE_PATH) then return end

    local f = io.open(PROFILE_FILE_PATH, 'r')
    if not f then return end

    for line in f:lines() do
        local pname,item,start,rest = line:match('^(.-)|(.-)|(.-)|(.*)$')
        if not (pname and item and start and rest) then
            pname,item,rest = line:match('^(.-)|(.-)|(.*)$')
            start=''
        end
        if pname and item then
            pname=trim(pname)
            item =trim(item)
            start=trim(start)
            if pname~='' and item~='' then
                local map={}
                for pair in rest:gmatch('[^,]+') do
                    local nm,v = pair:match('(.-):([01])')
                    if nm then map[trim(nm)] = (v=='1') end
                end
                profiles[pname]={ itemName=item, startName=(start~='' and start or nil), members=map }
            end
        end
    end
    f:close()
end

local function saveProfiles()
    local f = io.open(PROFILE_FILE_PATH, 'w')
    if not f then
        addStatus('ERROR: Cannot write profile file.')
        return
    end
    for name,p in pairs(profiles) do
        local parts={}
        for nm,v in pairs(p.members or {}) do
            table.insert(parts, nm..':'..(v and '1' or '0'))
        end
        f:write(string.format('%s|%s|%s|%s\n',
            name,
            p.itemName or '',
            p.startName or '',
            table.concat(parts, ',')
        ))
    end
    f:close()
    addStatus('Profiles saved.')
end

local function saveCurrentProfile()
    local nm = trim(profileNameBuffer or '')
    if nm=='' then return end

    local item = trim(activeItemName)
    if item=='' then
        addStatus('ERROR: No active item selected.')
        return
    end

    validateChainStart()

    local map={}
    for _,m in ipairs(chainMembers) do
        map[m.name]=m.enabled
    end

    profiles[nm] = {
        itemName  = item,
        startName = chainStartName,
        members   = map,
    }

    currentProfileName = nm
    profileNameBuffer  = nm
    saveProfiles()
    addStatus('Profile "%s" saved.', nm)
end

local function loadProfileByName(pname)
    local p = profiles[pname]
    if not p then
        addStatus('ERROR: Profile "%s" not found.', pname)
        return
    end

    manualItemName = p.itemName
    activeItemName = p.itemName

    local lower = p.itemName:lower()
    local found=false
    for _,nm in ipairs(savedItems) do
        if nm:lower()==lower then found=true break end
    end
    if not found then
        table.insert(savedItems, p.itemName)
        saveItemList()
        addStatus('Profile item "%s" added to saved items.', p.itemName)
    end

    profileNameBuffer  = pname
    currentProfileName = pname

    for _,m in ipairs(chainMembers) do
        if p.members[m.name]~=nil then
            m.enabled = p.members[m.name]
        else
            m.enabled = true
        end
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
    scm.list={}
    scm.index=0
    scm.member=nil
    scm.phase='IDLE'
    scm.attempts=0
    scm.startTime=0
end

local function resetChain()
    running=false
    paused=false
    resetSCMState()
    addStatus('Chain reset.')
end

local function startChain()
    local item = trim(activeItemName)
    if item=='' then item=trim(manualItemName) end
    if item=='' then
        addStatus('ERROR: No item selected.')
        return
    end
    activeItemName=item

    local me  = trim(mq.TLO.Me.Name() or '')
    validateChainStart()
    scm.list  = buildSCMList()
    if #scm.list==0 then
        addStatus('ERROR: No enabled members.')
        return
    end

    scm.index    = 1
    scm.member   = scm.list[1]
    scm.phase    = 'WAIT_HAVE_ITEM'
    scm.attempts = 0
    scm.startTime= os.time()

    running=true
    paused=false

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
    if lastZoning or z~=lastZone then
        addStatus('Zoned into %s.', z)
        lastZone=z
        lastZoning=false
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
    if item=='' then return end

    scm.member = scm.list[scm.index]
    local now  = os.time()

    if scm.phase=='WAIT_HAVE_ITEM' then
        -- v1.1.2 FIX: If it is the controller's turn (and controller is enabled),
        -- click/use locally via a durable FSM state.
        if scm.member == me then
            if countItemByName(item) > 0 then
                scm.phase = 'USE_LOCAL'
                scm.startTime = now
            end
            return
        end

        if countItemByName(item)>0 then
            addStatus('Controller has "%s". Sending to %s.', item, scm.member)
            scm.phase='GIVE_TO_MEMBER'
            scm.attempts=0
            scm.startTime=now
            requestItemTransfer(scm.member, me, item)
        end
        return
    end

    
    if scm.phase=='USE_LOCAL' then
        useItemLocal(item)

        if scm.index < #scm.list then
            scm.index = scm.index + 1
            scm.member= scm.list[scm.index]
            scm.phase = 'WAIT_HAVE_ITEM'
            scm.attempts=0
            scm.startTime=now
            addStatus('Controller used "%s". Proceeding to next member: %s.', item, scm.member)
        else
            if AUTO_REPEAT_CHAIN then
                scm.index    = 1
                scm.member   = scm.list[1]
                scm.phase    = 'WAIT_HAVE_ITEM'
                scm.attempts = 0
                scm.startTime= now
                addStatus('Controller used "%s". Full round complete. Restarting.', item)
            else
                addStatus('Controller used "%s". Full round complete. Stopping chain.', item)
                resetSCMState()
                running=false
                paused=false
            end
        end
        return
    end

if scm.phase=='GIVE_TO_MEMBER' then
        local adaptiveTimeout = getAdaptiveTradeTimeout()
        if now - scm.startTime >= adaptiveTimeout then
            addStatus('Assuming %s received "%s" (timeout: %.1fs). Requesting remote use.', 
                scm.member, item, adaptiveTimeout)
            scm.phase='MEMBER_USE'
            scm.startTime=now
            requestRemoteUse(scm.member, item)
        end
        return
    end

    if scm.phase=='MEMBER_USE' then
        local adaptiveDelay = getAdaptiveRemoteUseDelay()
        if now - scm.startTime >= adaptiveDelay then
            addStatus('Requesting return of "%s" from %s.', item, scm.member)
            scm.phase='RETURN_TO_ME'
            scm.startTime=now
            requestItemTransfer(me, scm.member, item)
        end
        return
    end

    if scm.phase=='RETURN_TO_ME' then
        if countItemByName(item)>0 then
            local transferDuration = now - scm.startTime
            recordTransferTime(transferDuration)
            
            addStatus('Item "%s" returned from %s.', item, scm.member)

            if scm.index < #scm.list then
                scm.index = scm.index + 1
                scm.member= scm.list[scm.index]
                scm.phase = 'WAIT_HAVE_ITEM'
                scm.attempts=0
                scm.startTime=now
                addStatus('Proceeding to next member: %s.', scm.member)
            else
                if AUTO_REPEAT_CHAIN then
                    scm.index    = 1
                    scm.member   = scm.list[1]
                    scm.phase    = 'WAIT_HAVE_ITEM'
                    scm.attempts = 0
                    scm.startTime= now
                    addStatus('Full round complete. Restarting.')
                else
                    addStatus('Full round complete. Stopping chain.')
                    resetSCMState()
                    running=false
                    paused=false
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
                scm.startTime=now
                requestItemTransfer(me, scm.member, item)
            else
                addStatus('ERROR: Could not retrieve "%s" from %s.', item, scm.member)
                resetChain()
            end
        end
        return
    end
end

---------------------------------------------------------------------
-- GUI
---------------------------------------------------------------------
local function renderGUI()
    if not showUI then return end

    ImGui.SetNextWindowSize(1000, 700, ImGui.Cond_FirstUseEver)
    if ImGui.Begin('ItemPass v' .. SCRIPT_VERSION, showUI) then

        -- Status Log
        ImGui.Text('═══════════════════════════════════════════════════════════')
        ImGui.Text('Status Log')
        ImGui.Text('═══════════════════════════════════════════════════════════')
        ImGui.BeginChild('StatusLog', 0, 150, true)
        for _, line in ipairs(statusLog) do
            ImGui.TextUnformatted(line)
        end
        if ImGui.GetScrollY() >= ImGui.GetScrollMaxY() - 1 then
            ImGui.SetScrollHereY(1.0)
        end
        ImGui.EndChild()

        ImGui.Spacing()

        -- Item Selection
        ImGui.Text('═══════════════════════════════════════════════════════════')
        ImGui.Text('Item Selection')
        ImGui.Text('═══════════════════════════════════════════════════════════')

        ImGui.Text('Active Item: ' .. (trim(activeItemName) == '' and '(none)' or activeItemName))
        ImGui.Spacing()

        ImGui.PushItemWidth(300)
        manualItemName = ImGui.InputText('Item Name', manualItemName, 256)
        ImGui.PopItemWidth()

        ImGui.SameLine()
        if ImGui.Button('Save Item', 80, 0) then
            saveCurrentItem()
        end

        ImGui.Spacing()

        -- Saved Items List
        ImGui.Text('Saved Items')
        if ImGui.BeginListBox('##SavedItemsList', 300, 150) then
            for idx, nm in ipairs(savedItems) do
                local selected = (selectedSavedItem == idx)
                if ImGui.Selectable(nm, selected) then
                    selectedSavedItem = idx
                    activeItemName = nm
                end
            end
            ImGui.EndListBox()
        end

        ImGui.SameLine()
        ImGui.BeginGroup()
        if ImGui.Button('Delete', 80, 0) then
            deleteSelectedSavedItem()
            activeItemName = (selectedSavedItem > 0 and selectedSavedItem <= #savedItems) and savedItems[selectedSavedItem] or ''
        end
        ImGui.EndGroup()

        ImGui.Spacing()

        -- Inventory Items
        ImGui.Text('Your Inventory')
        if ImGui.Button('Scan Inventory') then
            scanInventory()
        end

        ImGui.SameLine()
        ImGui.Text(string.format('Inventory has %d unique items', #inventoryItems))

        if ImGui.BeginListBox('##InventoryList', 300, 150) then
            for idx, item in ipairs(inventoryItems) do
                local selected = (selectedInventoryIndex == idx)
                if ImGui.Selectable(item.display, selected) then
                    selectedInventoryIndex = idx
                    activeItemName = item.name
                end
            end
            ImGui.EndListBox()
        end

        ImGui.Spacing()

        -- Chain Members
        ImGui.Text('═══════════════════════════════════════════════════════════')
        ImGui.Text('Chain Members')
        ImGui.Text('═══════════════════════════════════════════════════════════')

        if ImGui.Button('Refresh Group') then
            refreshChainMembers()
        end

        ImGui.SameLine()
        if ImGui.Button('Purge Missing') then
            purgeMissingMembers()
        end

        if ImGui.BeginTable('MembersTable', 4, ImGui.TableFlags_Borders) then
            ImGui.TableSetupColumn('Name', ImGui.TableColumnFlags_WidthFixed, 150)
            ImGui.TableSetupColumn('Present', ImGui.TableColumnFlags_WidthFixed, 80)
            ImGui.TableSetupColumn('Enabled', ImGui.TableColumnFlags_WidthFixed, 80)
            ImGui.TableSetupColumn('Start', ImGui.TableColumnFlags_WidthFixed, 80)
            ImGui.TableHeadersRow()

            for idx, member in ipairs(chainMembers) do
                ImGui.TableNextRow()
                ImGui.TableSetColumnIndex(0)
                ImGui.TextUnformatted(member.name)
                ImGui.TableSetColumnIndex(1)
                ImGui.TextUnformatted(member.present and 'Yes' or 'No')
                ImGui.TableSetColumnIndex(2)
                local changed
                changed, chainMembers[idx].enabled = ImGui.Checkbox('##enabled_' .. idx, chainMembers[idx].enabled)
                ImGui.TableSetColumnIndex(3)
                if ImGui.RadioButton('##start_' .. idx, chainStartName == member.name) then
                    chainStartName = member.name
                end
            end

            ImGui.EndTable()
        end

        ImGui.Spacing()

        -- Profiles
        ImGui.Text('═══════════════════════════════════════════════════════════')
        ImGui.Text('Profiles')
        ImGui.Text('═══════════════════════════════════════════════════════════')

        ImGui.PushItemWidth(150)
        profileNameBuffer = ImGui.InputText('Profile Name', profileNameBuffer, 256)
        ImGui.PopItemWidth()

        ImGui.SameLine()
        if ImGui.Button('Save Profile', 100, 0) then
            saveCurrentProfile()
        end

        ImGui.SameLine()
        if ImGui.Button('Load Profile', 100, 0) then
            if currentProfileName ~= '' and profiles[currentProfileName] then
                loadProfileByName(currentProfileName)
            end
        end

        if ImGui.BeginListBox('##ProfilesList', 0, 100) then
            local profileNames = {}
            for nm, _ in pairs(profiles) do
                table.insert(profileNames, nm)
            end
            table.sort(profileNames)

            for _, nm in ipairs(profileNames) do
                local selected = (currentProfileName == nm)
                if ImGui.Selectable(nm, selected) then
                    currentProfileName = nm
                    profileNameBuffer = nm
                    loadProfileByName(nm)
                end
            end
            ImGui.EndListBox()
        end

        ImGui.Spacing()

        -- Chain Control
        ImGui.Text('═══════════════════════════════════════════════════════════')
        ImGui.Text('Chain Control')
        ImGui.Text('═══════════════════════════════════════════════════════════')

        local buttonWidth = 100
        if ImGui.Button('START CHAIN', buttonWidth, 0) then
            startChain()
        end

        ImGui.SameLine()
        if ImGui.Button(paused and 'RESUME' or 'PAUSE', buttonWidth, 0) then
            togglePause()
        end

        ImGui.SameLine()
        if ImGui.Button('RESET', buttonWidth, 0) then
            resetChain()
        end

        ImGui.Spacing()
        ImGui.Text('Status: ' .. (running and (paused and 'PAUSED' or 'RUNNING') or 'STOPPED'))

        ImGui.Spacing()

        -- Latency Settings
        ImGui.Text('═══════════════════════════════════════════════════════════')
        ImGui.Text('Latency & Timing')
        ImGui.Text('═══════════════════════════════════════════════════════════')

        ImGui.Text('Transfers: ' .. latencyStats.totalTransfers)
        ImGui.Text('Avg Time: ' .. string.format('%.2fs', latencyStats.avgTransferTime))
        ImGui.Text('Samples: ' .. #latencyStats.measurements)

        ImGui.PushItemWidth(100)
        latencyStats.manualOverride = ImGui.SliderFloat('Manual Override (0=auto)', latencyStats.manualOverride, 0, 30, '%.1f')
        ImGui.PopItemWidth()

        if ImGui.Button('Reset Latency Stats', 150, 0) then
            latencyStats.measurements = {}
            latencyStats.avgTransferTime = 0
            latencyStats.totalTransfers = 0
            addStatus('Latency stats reset.')
        end

        ImGui.End()
    end
end

---------------------------------------------------------------------
-- MAIN LOOP
---------------------------------------------------------------------
local function main()
    loadHiddenItems()
    loadItemList()
    loadProfiles()
    refreshChainMembers()

    while true do
        handleZone()
        scmTick()
        renderGUI()
        mq.delay(10)
    end
end

main()
