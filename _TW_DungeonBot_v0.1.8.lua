--[[
    TW Dungeon Bot v0.1
    Fresh prototype, independent from Follow The Arrow.

    Goal:
      1. Find the currently available Timewalking random-dungeon queue.
      2. Detect current specialization role and queue as Tank/Healer/DPS.
      3. Accept LFG proposal automatically.
      4. Once inside, identify the party tank and follow them using WardenGG
         Navigation Server ground pathing.
      5. Assist the tank's hostile target so an external combat rotation has
         something useful to attack.
      6. Detect LFG completion.
      7. Teleport out, leave the instance party, wait briefly, and queue again.

    This is intentionally v0.1:
      - It does NOT contain a class/spec combat rotation.
      - It does NOT auto-release/ghost-run after death yet.
      - It does NOT handle every odd dungeon mechanic yet.
      - It requires WardenGG Navigation Server for dungeon movement.

    WardenGG scripts loaded normally receive:
        local WGG = ...
]]

local WGG = ...

local VERSION = "0.1.8-loot-scope-fix"

local CFG = {
    navIP = "127.0.0.1",
    navPort = 47110,

    -- LFD category. Retail's Dungeon Finder category is normally 1.
    lfdCategory = _G.LE_LFG_CATEGORY_LFD or 1,

    -- Follow behavior
    followDistance = 7.5,
    combatFollowDistance = 4.0,
    stopDistance = 4.5,
    combatStopDistance = 2.8,

    repathInterval = 1.10,
    repathTankMove = 3.0,
    tankObjectRefresh = 1.0,
    maxTankSearchUnits = 4,

    -- Native movement watchdog. If MoveAlongPath says it started but the
    -- character physically does not move, pulse direct movement toward the
    -- tank at short range instead of standing there forever.
    nativeMoveGrace = 0.60,
    nativeMinProgress = 0.35,

    -- Normal direct fallback stays short, but emergency combat recovery is
    -- allowed farther when the tank has become separated from us.
    directFallbackDistance = 13.0,
    emergencyDirectDistance = 21.0,

    -- Tank leash:
    -- above softLeash we stop acquiring combat targets and prioritize travel.
    -- above hardLeash we clear our target/attack and aggressively catch up.
    softLeash = 11.0,
    hardLeash = 16.0,
    recoveredLeash = 8.0,

    -- Repath slower during normal movement so we do not stop/restart a valid
    -- MoveAlongPath every ~1 second. Catch-up paths update much faster.
    movingRepathInterval = 2.40,
    catchupRepathInterval = 0.65,
    catchupTankMove = 2.0,

    -- Looting:
    -- Only divert for nearby loot while the tank is still close enough that
    -- looting cannot break the party leash.
    lootEnabled = true,
    lootScanInterval = 0.55,
    lootInteractRange = 5.5,
    lootApproachRange = 10.0,
    lootTankMaxDistance = 11.0,
    lootTimeout = 2.2,
    lootRetryCooldown = 1.2,

    -- Queue / completion behavior
    queueRetry = 8.0,
    proposalRetry = 2.0,
    completionWait = 6.0,

    -- Preferred completion exit:
    -- leave the completed instance party and let WoW remove/return us.
    leavePartyRetry = 3.0,
    leaveExitGrace = 6.0,

    -- Safety fallback only if leaving the group does not get us outside.
    teleportRetry = 4.0,

    requeueWait = 6.0,

    -- Tick rate
    tick = 0.15,

    -- Assist tank target for an external rotation.
    assistTankTarget = true,
    assistInterval = 1.0,
}

local S = {
    enabled = false,
    status = "OFF",

    twDungeonID = nil,
    twDungeonName = nil,
    queueRole = nil,
    specName = nil,

    tankUnit = nil,
    tankName = nil,
    tankObject = nil,
    tankGUID = nil,
    lastTankObjectResolve = 0,

    lastTick = 0,
    lastQueueAttempt = 0,
    lastProposalAttempt = 0,
    lastAssist = 0,

    lastPathBuild = 0,
    lastTankX = nil,
    lastTankY = nil,
    lastTankZ = nil,
    lastMapID = nil,

    pathStartAt = nil,
    pathStartPX = nil,
    pathStartPY = nil,
    pathStartPZ = nil,
    directFollowing = false,
    directStartedAt = nil,
    lastDirectLog = 0,

    leashRecovery = false,
    lastLeashLog = 0,
    lastCatchupPath = 0,

    lastLootScan = 0,
    lastLootAttempt = 0,
    lootTarget = nil,
    lootTargetGUID = nil,
    lootTargetName = nil,
    lootStartedAt = nil,

    completeAt = nil,
    leaveAttemptAt = nil,
    groupLeftAt = nil,
    teleportAttemptAt = nil,
    teleportedOutAt = nil,
    requeueAt = nil,

    wasInDungeon = false,
    wasLFGComplete = false,

    lastStatePrint = nil,
    lastErrorPrint = 0,
}

local F = {}

local function now()
    if type(GetTime) == "function" then
        return GetTime()
    end
    return 0
end

local function unwrap(v)
    return v
end

local function log(msg)
    print("|cff4cc9ff[TW-BOT]|r " .. tostring(msg))
end

local function logError(msg)
    if now() - (S.lastErrorPrint or 0) >= 2 then
        S.lastErrorPrint = now()
        print("|cffff5555[TW-BOT]|r " .. tostring(msg))
    end
end

local function protected(fn, ...)
    if type(WGG.CallProtected) ~= "function" then
        return false, "WGG.CallProtected unavailable"
    end
    local ok, a, b, c, d = WGG.CallProtected(fn, ...)
    if not ok then
        return false, a
    end
    return true, a, b, c, d
end

local function compileOne(code, chunk)
    if type(WGG.LoadString) ~= "function" then
        return nil, "WGG.LoadString unavailable"
    end

    -- WGG.LoadString("return function(...) ... end") returns the COMPILED
    -- outer chunk. Calling that chunk produces the actual inner function.
    --
    -- v0.1/v0.1.1 mistakenly passed the outer chunk into CallProtected().
    -- Result: CallProtected executed "return function(...)" and returned a
    -- function pointer instead of executing the queue/accept/teleport action.
    local loader = WGG.LoadString(code, chunk)
    if type(loader) ~= "function" then
        return nil, tostring(loader)
    end

    local ok, fn = pcall(loader)
    if not ok then
        return nil, "loader execution failed: " .. tostring(fn)
    end

    if type(fn) ~= "function" then
        return nil, "compiled chunk returned " .. type(fn) .. ": " .. tostring(fn)
    end

    return fn
end

local function compile()
    local defs = {
        queueDPS = {
            [[
                return function(category, dungeonID, queueRole)
                    -- Load the same Blizzard module that owns the Retail LFD UI.
                    if C_AddOns and type(C_AddOns.LoadAddOn) == "function" then
                        pcall(C_AddOns.LoadAddOn, "Blizzard_GroupFinder")
                    elseif type(UIParentLoadAddOn) == "function" then
                        pcall(UIParentLoadAddOn, "Blizzard_GroupFinder")
                    end

                    -- Select exactly the current specialization's role.
                    local tank = queueRole == "TANK"
                    local healer = queueRole == "HEALER"
                    local dps = queueRole == "DAMAGER"

                    if not tank and not healer and not dps then
                        dps = true
                        queueRole = "DAMAGER"
                    end

                    if type(SetLFGRoles) == "function" then
                        SetLFGRoles(false, tank, healer, dps)
                    end

                    -- Preferred path: do exactly what the current Retail
                    -- Dungeon Finder UI does.
                    if type(LFDQueueFrame_SetType) == "function"
                        and type(LFDQueueFrame_Join) == "function"
                    then
                        LFDQueueFrame_SetType(dungeonID)
                        LFDQueueFrame_Join()
                        return "LFDQueueFrame_Join"
                    end

                    -- Same helper one layer lower.
                    if type(LFG_JoinDungeon) == "function" then
                        LFG_JoinDungeon(
                            category,
                            dungeonID,
                            _G.LFDDungeonList,
                            _G.LFDHiddenByCollapseList
                        )
                        return "LFG_JoinDungeon"
                    end

                    -- Old fallback only.
                    if type(JoinSingleLFG) == "function" then
                        JoinSingleLFG(category, dungeonID)
                        return "JoinSingleLFG fallback"
                    end

                    error("No usable Dungeon Finder join API")
                end
            ]],
            "@TW_queueDPS"
        },

        acceptProposal = {
            [[
                return function()
                    if type(AcceptProposal) ~= "function" then
                        error("AcceptProposal unavailable")
                    end
                    AcceptProposal()
                    return true
                end
            ]],
            "@TW_acceptProposal"
        },

        roleCheck = {
            [[
                return function()
                    if type(CompleteLFGRoleCheck) == "function" then
                        CompleteLFGRoleCheck(true)
                        return true
                    end
                    return false
                end
            ]],
            "@TW_roleCheck"
        },

        readyCheck = {
            [[
                return function()
                    if type(CompleteLFGReadyCheck) == "function" then
                        CompleteLFGReadyCheck(true)
                        return true
                    end
                    return false
                end
            ]],
            "@TW_readyCheck"
        },

        teleportOut = {
            [[
                return function()
                    if type(LFGTeleport) ~= "function" then
                        error("LFGTeleport unavailable")
                    end
                    LFGTeleport(true)
                    return true
                end
            ]],
            "@TW_teleportOut"
        },

        leaveInstanceParty = {
            [[
                return function()
                    local instanceCategory = _G.LE_PARTY_CATEGORY_INSTANCE or 1

                    if C_PartyInfo and type(C_PartyInfo.LeaveParty) == "function" then
                        C_PartyInfo.LeaveParty(instanceCategory)
                        return true
                    end

                    if type(LeaveParty) == "function" then
                        LeaveParty()
                        return true
                    end

                    error("No LeaveParty API available")
                end
            ]],
            "@TW_leaveInstanceParty"
        },

        stopAttack = {
            [[
                return function()
                    if type(StopAttack)=="function" then
                        StopAttack()
                    end
                    return true
                end
            ]],
            "@TW_stopAttack"
        },

        clearTarget = {
            [[
                return function()
                    if type(ClearTarget)=="function" then
                        ClearTarget()
                    end
                    return true
                end
            ]],
            "@TW_clearTarget"
        },

        moveForwardStart = {
            [[
                return function()
                    if type(MoveForwardStart) ~= "function" then
                        error("MoveForwardStart unavailable")
                    end
                    MoveForwardStart()
                    return true
                end
            ]],
            "@TW_moveForwardStart"
        },

        moveForwardStop = {
            [[
                return function()
                    if type(MoveForwardStop) ~= "function" then
                        error("MoveForwardStop unavailable")
                    end
                    MoveForwardStop()
                    return true
                end
            ]],
            "@TW_moveForwardStop"
        },

        targetUnit = {
            [[
                return function(unit)
                    if type(TargetUnit) ~= "function" then
                        error("TargetUnit unavailable")
                    end
                    TargetUnit(unit)
                    return true
                end
            ]],
            "@TW_targetUnit"
        },
    }

    for key, def in pairs(defs) do
        local fn, err = compileOne(def[1], def[2])
        if not fn then
            return false, key .. ": " .. tostring(err)
        end
        F[key] = fn
    end

    log(
        "Protected actions compiled"
        .. " | queue=" .. tostring(type(F.queueDPS))
        .. " | proposal=" .. tostring(type(F.acceptProposal))
        .. " | teleport=" .. tostring(type(F.teleportOut))
        .. " | leave=" .. tostring(type(F.leaveInstanceParty))
        .. " | moveStart=" .. tostring(type(F.moveForwardStart))
        .. " | moveStop=" .. tostring(type(F.moveForwardStop))
        .. " | stopAttack=" .. tostring(type(F.stopAttack))
        .. " | clearTarget=" .. tostring(type(F.clearTarget))
    )

    return true
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local panel = CreateFrame("Frame", "TW_DungeonBotPanel", UIParent, "BackdropTemplate")
panel:SetSize(285, 78)
panel:SetPoint("CENTER", UIParent, "CENTER", 0, 155)
panel:SetFrameStrata("DIALOG")
panel:SetClampedToScreen(true)
panel:EnableMouse(true)
panel:SetMovable(true)
panel:RegisterForDrag("LeftButton")
panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
panel:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

panel:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
panel:SetBackdropColor(0.04, 0.04, 0.04, 0.92)

local toggle = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
toggle:SetSize(265, 26)
toggle:SetPoint("TOP", 0, -7)
toggle:SetText("TW DUNGEON BOT: OFF")

local statusText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
statusText:SetPoint("TOP", toggle, "BOTTOM", 0, -6)
statusText:SetWidth(268)
statusText:SetJustifyH("CENTER")
statusText:SetText("OFF")

local detailText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
detailText:SetPoint("TOP", statusText, "BOTTOM", 0, -2)
detailText:SetWidth(268)
detailText:SetJustifyH("CENTER")
detailText:SetText("v" .. VERSION)

local function ui(status, detail)
    S.status = tostring(status or "")
    statusText:SetText(S.status)
    detailText:SetText(tostring(detail or ("v" .. VERSION)))

    if S.enabled then
        toggle:SetText("TW DUNGEON BOT: ON")
    else
        toggle:SetText("TW DUNGEON BOT: OFF")
    end
end

-- ---------------------------------------------------------------------------
-- Warden navigation helpers
-- ---------------------------------------------------------------------------

local function navConfigure()
    if type(WGG.SetNavServerAddress) == "function" then
        pcall(WGG.SetNavServerAddress, CFG.navIP, CFG.navPort)
    end
end

local function navConnected()
    if type(WGG.UpdateNavigation) == "function" then
        pcall(WGG.UpdateNavigation)
    end

    if type(WGG.IsNavConnected) ~= "function" then
        return false
    end

    local ok, v = pcall(WGG.IsNavConnected)
    return ok and (unwrap(v) == true or unwrap(v) == 1)
end

local function stopMovement()
    if type(WGG.StopMovement) == "function" then
        pcall(WGG.StopMovement)
    end

    if S.directFollowing and F.moveForwardStop then
        protected(F.moveForwardStop)
    end

    S.directFollowing = false
    S.directStartedAt = nil
end

local function playerPos()
    if type(WGG.GetPlayerPosition) == "function" then
        local ok, x, y, z, success = pcall(WGG.GetPlayerPosition)
        if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then
            if success == nil or success == true or success == 1 then
                return x, y, z
            end
        end
    end

    if type(WGG.ObjectPos) == "function" then
        local ok, x, y, z = pcall(WGG.ObjectPos, "player")
        if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then
            return x, y, z
        end
    end

    return nil
end

local function resolveWGGObject(unit)
    if not unit then return nil end
    if type(WGG.Object)=="function" then
        local ok,obj=pcall(WGG.Object,unit)
        if ok and obj then return obj end
        if type(UnitGUID)=="function" then
            local gok,g=pcall(UnitGUID,unit)
            if gok and g then
                local ok2,obj2=pcall(WGG.Object,g)
                if ok2 and obj2 then return obj2 end
            end
        end
    end
    return nil
end

local function objectPos(unit)
    if type(WGG.ObjectPos)~="function" then return nil end
    local obj=resolveWGGObject(unit) or unit
    local ok,x,y,z=pcall(WGG.ObjectPos,obj)
    if ok and type(x)=="number" and type(y)=="number" and type(z)=="number" then
        return x,y,z,obj
    end
end

local function objectFacing(unit)
    local obj=resolveWGGObject(unit) or unit
    if type(WGG.GetFacing)=="function" then
        local ok,f=pcall(WGG.GetFacing,obj)
        if ok and type(f)=="number" then return f end
    end
    if type(WGG.ObjectFacing)=="function" then
        local ok,f=pcall(WGG.ObjectFacing,obj)
        if ok and type(f)=="number" then return f end
    end
end

local function distance3(x1, y1, z1, x2, y2, z2)
    if type(WGG.Distance) == "function" then
        local ok, d = pcall(WGG.Distance, x1, y1, z1, x2, y2, z2)
        if ok and type(d) == "number" then
            return d
        end
    end

    local dx, dy, dz = x2 - x1, y2 - y1, z2 - z1
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function nativePathMoving()
    if type(WGG.IsMovingAlongPath) ~= "function" then
        return nil
    end
    local ok,v=pcall(WGG.IsMovingAlongPath)
    if not ok then return nil end
    return v == true or v == 1
end

local function directFollowStart(tx,ty,tz)
    if not F.moveForwardStart then
        return false,"direct movement action unavailable"
    end

    if type(WGG.SetFacing)=="function" then
        local ok=pcall(WGG.SetFacing,tx,ty,tz)
        if not ok then
            return false,"SetFacing failed"
        end
    else
        return false,"WGG.SetFacing unavailable"
    end

    if not S.directFollowing then
        local ok,err=protected(F.moveForwardStart)
        if not ok then return false,err end
        S.directFollowing=true
        S.directStartedAt=now()
    end

    return true
end

local function directFollowUpdate(tx,ty,tz)
    if type(WGG.SetFacing)=="function" then
        pcall(WGG.SetFacing,tx,ty,tz)
    end
end

local function currentInstanceMapID()
    if C_Map and type(C_Map.GetBestMapForUnit)=="function"
        and type(C_Map.GetPlayerMapPosition)=="function"
        and type(C_Map.GetWorldPosFromMapPos)=="function"
    then
        local ok,m=pcall(C_Map.GetBestMapForUnit,"player")
        if ok and m then
            local okp,p=pcall(C_Map.GetPlayerMapPosition,m,"player")
            if okp and p then
                local okw,wm=pcall(C_Map.GetWorldPosFromMapPos,m,p)
                wm=okw and tonumber(unwrap(wm)) or nil
                if wm then return wm,m,"C_Map world" end
            end
        end
    end
    if type(GetInstanceInfo)=="function" then
        local _,typ,_,_,_,_,_,id=GetInstanceInfo()
        if typ=="party" and type(id)=="number" and id>0 then
            return id,nil,"GetInstanceInfo"
        end
    end
    return nil,nil,"unavailable"
end

local function tankFollowPoint(tx, ty, tz, tankUnit, wantedDistance)
    local facing = objectFacing(tankUnit)

    if type(facing) ~= "number" then
        return tx, ty, tz
    end

    -- Sit behind the tank instead of pathing directly onto the player's feet.
    local gx = tx - math.cos(facing) * wantedDistance
    local gy = ty - math.sin(facing) * wantedDistance
    return gx, gy, tz
end

local function shouldRepath(tx,ty,tz,catchup)
    local tm=now()

    if catchup then
        if tm-(S.lastPathBuild or 0) >= CFG.catchupRepathInterval then
            return true
        end

        if not S.lastTankX then
            return true
        end

        local moved=distance3(
            S.lastTankX,S.lastTankY,S.lastTankZ,
            tx,ty,tz
        )
        return moved >= CFG.catchupTankMove
    end

    local moving=nativePathMoving()

    -- A path that is genuinely moving should be left alone. Repeatedly
    -- stopping/restarting it was one source of the random pauses.
    if moving == true then
        if not S.lastTankX then return false end

        local tankMoved=distance3(
            S.lastTankX,S.lastTankY,S.lastTankZ,
            tx,ty,tz
        )

        return tankMoved >= (CFG.repathTankMove * 2)
            and tm-(S.lastPathBuild or 0) >= CFG.movingRepathInterval
    end

    -- If native movement says it is no longer moving, rebuild immediately
    -- after a small normal interval.
    if tm-(S.lastPathBuild or 0) >= CFG.repathInterval then
        return true
    end

    if not S.lastTankX then
        return true
    end

    local moved=distance3(
        S.lastTankX,S.lastTankY,S.lastTankZ,
        tx,ty,tz
    )

    return moved >= CFG.repathTankMove
end

local function buildTankPath(tankUnit, wantedDistance, catchup)
    if not navConnected() then
        return false, "NAV SERVER DISCONNECTED"
    end

    local px, py, pz = playerPos()
    local tx, ty, tz = objectPos(tankUnit)

    if not px or not tx then
        return false, "PLAYER/TANK POSITION UNAVAILABLE"
    end

    local mapID,uiMapID,mapSource = currentInstanceMapID()
    if not mapID then return false, "INSTANCE/NAV MAP ID UNAVAILABLE" end

    local gx, gy, gz

    if catchup then
        -- During recovery, path nearly to the tank instead of chasing a
        -- constantly shifting 4-8 yd offset behind them.
        gx,gy,gz = tankFollowPoint(tx,ty,tz,tankUnit,2.5)
    else
        gx,gy,gz = tankFollowPoint(tx,ty,tz,tankUnit,wantedDistance)
    end
    if type(WGG.ValidateWaypoint)=="function" then
        local ok,vx,vy,vz=pcall(WGG.ValidateWaypoint,mapID,gx,gy,gz)
        if ok and type(vx)=="number" and type(vy)=="number" and type(vz)=="number" then
            gx,gy,gz=vx,vy,vz
        end
    end

    if type(WGG.FindPath) ~= "function" or type(WGG.MoveAlongPath) ~= "function" then
        return false, "FindPath/MoveAlongPath unavailable"
    end

    stopMovement()

    local ok, count = pcall(
        WGG.FindPath,
        mapID,
        px, py, pz,
        gx, gy, gz,
        false
    )

    count = ok and tonumber(unwrap(count)) or nil
    if not count or count <= 0 then
        return false, "FindPath returned "..tostring(count)
            .." | worldMap="..tostring(mapID)
            .." | uiMap="..tostring(uiMapID)
            .." | source="..tostring(mapSource)
    end

    local mok, moved = pcall(WGG.MoveAlongPath)
    if not mok or moved == false then
        return false, "MoveAlongPath failed: " .. tostring(moved)
    end

    S.lastPathBuild = now()
    S.lastTankX, S.lastTankY, S.lastTankZ = tx, ty, tz
    S.lastMapID = mapID

    S.pathStartAt = now()
    S.pathStartPX, S.pathStartPY, S.pathStartPZ = px, py, pz

    return true, count
end

local function currentSpecRole()
    local specIndex = type(GetSpecialization)=="function" and GetSpecialization() or nil
    local role = nil
    local specName = nil

    if specIndex then
        if type(GetSpecializationRole)=="function" then
            local ok,r=pcall(GetSpecializationRole,specIndex)
            if ok then role=r end
        end

        if type(GetSpecializationInfo)=="function" then
            local ok,_,name=pcall(GetSpecializationInfo,specIndex)
            if ok then specName=name end
        end
    end

    if role ~= "TANK" and role ~= "HEALER" and role ~= "DAMAGER" then
        role = "DAMAGER"
    end

    S.queueRole = role
    S.specName = specName or "Unknown Spec"
    return role,S.specName
end

-- ---------------------------------------------------------------------------
-- Dungeon Finder helpers
-- ---------------------------------------------------------------------------

local function lower(s)
    return string.lower(tostring(s or ""))
end

local function timewalkingCandidate(index)
    local values = { GetLFGRandomDungeonInfo(index) }

    local id = tonumber(values[1])
    local name = tostring(values[2] or "")
    local isTimeWalker = values[19] == true

    if not id or id <= 0 or name == "" then
        return nil
    end

    local lname = lower(name)
    local nameLooksTW =
        string.find(lname, "timewalking", 1, true) ~= nil
        or string.find(lname, "time walking", 1, true) ~= nil

    if not isTimeWalker and not nameLooksTW then
        return nil
    end

    -- Skip obviously unavailable entries when the API exposes joinability.
    if type(IsLFGDungeonJoinable) == "function" then
        local ok, allJoinable, playerJoinable = pcall(IsLFGDungeonJoinable, id)
        if ok and playerJoinable == false then
            return nil
        end
    end

    return {
        id = id,
        name = name,
        isTimeWalker = isTimeWalker,
        index = index,
    }
end

local function findTimewalkingQueue()
    if type(GetNumRandomDungeons) ~= "function"
        or type(GetLFGRandomDungeonInfo) ~= "function"
    then
        return nil, "Random dungeon APIs unavailable"
    end

    local count = GetNumRandomDungeons()
    if type(count) ~= "number" then
        return nil, "GetNumRandomDungeons returned " .. tostring(count)
    end

    local fallback = nil

    for i = 1, count do
        local c = timewalkingCandidate(i)
        if c then
            if c.isTimeWalker then
                return c
            end
            fallback = fallback or c
        end
    end

    -- During some special Timewalking events Blizzard can report the flag
    -- differently, so name matching is retained as a fallback.
    if fallback then
        return fallback
    end

    return nil, "No Timewalking random queue found"
end

local function refreshTimewalkingQueue(forceLog)
    local c, err = findTimewalkingQueue()

    if not c then
        S.twDungeonID = nil
        S.twDungeonName = nil
        if forceLog then
            log("Timewalking scan: " .. tostring(err))
        end
        return false, err
    end

    local changed =
        S.twDungeonID ~= c.id
        or S.twDungeonName ~= c.name

    S.twDungeonID = c.id
    S.twDungeonName = c.name

    if forceLog or changed then
        log(string.format(
            "Timewalking queue: %s | ID %d | index %d | isTimeWalker=%s",
            c.name, c.id, c.index, tostring(c.isTimeWalker)
        ))
    end

    return true
end

local function queueMode()
    if type(GetLFGMode) ~= "function" then
        return nil, nil
    end

    -- Blizzard's current Retail LFD frame checks the category-wide mode.
    local ok, mode, submode = pcall(GetLFGMode, CFG.lfdCategory)
    if ok and mode ~= nil then
        return mode, submode
    end

    -- Compatibility fallback for older behavior.
    if S.twDungeonID then
        local ok2, mode2, submode2 = pcall(
            GetLFGMode,
            CFG.lfdCategory,
            S.twDungeonID
        )
        if ok2 then
            return mode2, submode2
        end
    end

    return nil, nil
end

local function isQueued()
    local mode = queueMode()
    if mode == "queued"
        or mode == "proposal"
        or mode == "rolecheck"
        or mode == "listed"
    then
        return true
    end

    -- Extra fallback from queue stats.
    if type(GetLFGQueueStats) == "function" then
        local ok, hasData = pcall(GetLFGQueueStats, CFG.lfdCategory)
        if ok and hasData == true then
            return true
        end
    end

    return false
end

local function pendingProposal()
    if type(GetLFGProposal) ~= "function" then
        return false
    end

    local ok, exists, id, _, _, name, _, role, hasResponded =
        pcall(GetLFGProposal)

    if not ok or not exists then
        return false
    end

    return true, {
        id = id,
        name = name,
        role = role,
        hasResponded = hasResponded,
    }
end

local function acceptProposalIfNeeded()
    local exists, p = pendingProposal()
    if not exists or not p then
        return false
    end

    if p.hasResponded then
        ui("PROPOSAL ACCEPTED", tostring(p.name or S.twDungeonName or "Waiting..."))
        return true
    end

    if now() - S.lastProposalAttempt < CFG.proposalRetry then
        return true
    end

    S.lastProposalAttempt = now()

    local ok, err = protected(F.acceptProposal)
    if ok then
        log("Accepted LFG proposal: " .. tostring(p.name or p.id or "?"))
        ui("ACCEPTING DUNGEON", tostring(p.name or S.twDungeonName or "Proposal"))
    else
        logError("AcceptProposal failed: " .. tostring(err))
    end

    return true
end

local function joinTimewalking()
    if not S.twDungeonID then
        local ok, err = refreshTimewalkingQueue(true)
        if not ok then
            return false, err
        end
    end

    if now() - S.lastQueueAttempt < CFG.queueRetry then
        return false, "queue retry cooldown"
    end

    S.lastQueueAttempt = now()

    local role,specName = currentSpecRole()

    local ok, pathOrErr = protected(
        F.queueDPS,
        CFG.lfdCategory,
        S.twDungeonID,
        role
    )

    if not ok then
        return false, pathOrErr
    end

    if type(pathOrErr) == "function" then
        return false, "compiler bug: queue action returned a function instead of executing"
    end

    log(
        "Queue request sent via "
        .. tostring(pathOrErr)
        .. ": "
        .. tostring(S.twDungeonName)
        .. " | role=" .. tostring(role)
        .. " | spec=" .. tostring(specName)
    )
    ui(
        "QUEUE REQUEST SENT",
        tostring(S.twDungeonName)
        .. " | " .. tostring(role)
        .. " | " .. tostring(pathOrErr)
    )

    -- Verify shortly after the protected call instead of claiming we are
    -- queued merely because the Lua function returned.
    if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(0.75, function()
            if not S.enabled then return end

            local mode, sub = queueMode()
            local queued = isQueued()

            log(
                "Queue verify | queued=" .. tostring(queued)
                .. " | mode=" .. tostring(mode)
                .. " | submode=" .. tostring(sub)
            )

            if queued then
                ui("WAITING IN QUEUE", tostring(S.twDungeonName))
            else
                ui(
                    "QUEUE NOT CONFIRMED",
                    "Join path=" .. tostring(pathOrErr)
                )
            end
        end)
    end

    return true
end

-- ---------------------------------------------------------------------------
-- Loot helpers
-- ---------------------------------------------------------------------------

local function objectGUID(obj)
    if not obj or type(WGG.ObjectGUID)~="function" then return nil end
    local ok,g=pcall(WGG.ObjectGUID,obj)
    return ok and g or nil
end

local function objectName(obj)
    if not obj or type(WGG.ObjectName)~="function" then return nil end
    local ok,n=pcall(WGG.ObjectName,obj)
    return ok and n or nil
end

local function objectType(obj)
    if not obj or type(WGG.ObjectType)~="function" then return nil end
    local ok,v=pcall(WGG.ObjectType,obj)
    return ok and tonumber(v) or nil
end

local function isLootable(obj)
    if not obj or type(WGG.IsLootable)~="function" then return false end
    local ok,v=pcall(WGG.IsLootable,obj)
    return ok and (v==true or v==1)
end

local function objectDistanceFromPlayer(obj)
    if not obj then return nil end

    if type(WGG.ObjectDistance)=="function" then
        local ok,d=pcall(WGG.ObjectDistance,"player",obj)
        if ok and type(d)=="number" then return d end
    end

    local px,py,pz=playerPos()
    local ox,oy,oz=nil,nil,nil
    if type(WGG.ObjectPos)=="function" then
        local ok,x,y,z=pcall(WGG.ObjectPos,obj)
        if ok then ox,oy,oz=x,y,z end
    end

    if px and ox then
        return distance3(px,py,pz,ox,oy,oz)
    end

    return nil
end

local function clearLootTarget()
    S.lootTarget=nil
    S.lootTargetGUID=nil
    S.lootTargetName=nil
    S.lootStartedAt=nil
end

local function findNearestLootable(maxRange)
    if type(WGG.GetObjectCount)~="function"
        or type(WGG.GetObjectWithIndex)~="function"
        or type(WGG.IsLootable)~="function"
    then
        return nil
    end

    local ok,count=pcall(WGG.GetObjectCount)
    if not ok or type(count)~="number" then return nil end

    local best,bestD=nil,nil

    -- Warden object-manager examples use indexed objects. Accept both common
    -- index conventions so one off-by-one convention cannot kill looting.
    for i=0,count do
        local ook,obj=pcall(WGG.GetObjectWithIndex,i)
        if ook and obj and isLootable(obj) then
            local typ=objectType(obj)

            -- Lootable corpses are normally Unit objects (type 5). Do not
            -- require the type if Warden exposes a lootable object differently.
            if typ==nil or typ==5 or typ==6 then
                local d=objectDistanceFromPlayer(obj)
                if type(d)=="number" and d<=maxRange
                    and (not bestD or d<bestD)
                then
                    best=obj
                    bestD=d
                end
            end
        end
    end

    return best,bestD
end

local function interactLoot(obj)
    if not obj then return false,"nil loot object" end

    if type(WGG.ObjectInteract)=="function" then
        local ok,v=pcall(WGG.ObjectInteract,obj)
        if ok and v~=false then
            return true,"ObjectInteract"
        end
    end

    -- World-space right-click fallback.
    if type(WGG.MouseClick)=="function"
        and type(WGG.ObjectPos)=="function"
    then
        local pok,x,y,z=pcall(WGG.ObjectPos,obj)
        if pok and type(x)=="number" then
            local guid=objectGUID(obj)
            local ok,v=pcall(WGG.MouseClick,x,y,z,1,guid)
            if ok and v~=false then
                return true,"MouseClick"
            end
        end
    end

    return false,"loot interaction failed"
end

local function lootAllowed(tankDistance)
    if not CFG.lootEnabled then return false end
    if S.leashRecovery then return false end
    if type(UnitIsDeadOrGhost)=="function" and UnitIsDeadOrGhost("player") then
        return false
    end
    if type(tankDistance)~="number" then return false end
    if tankDistance>CFG.lootTankMaxDistance then return false end
    return true
end

-- ---------------------------------------------------------------------------
-- Party / tank helpers
-- ---------------------------------------------------------------------------

local function validPartyUnit(unit)
    if type(UnitExists) == "function" and not UnitExists(unit) then
        return false
    end
    if type(UnitIsConnected) == "function" and not UnitIsConnected(unit) then
        return false
    end
    return true
end

local function findTank()
    if type(UnitGroupRolesAssigned) ~= "function" then
        return nil
    end

    for i = 1, CFG.maxTankSearchUnits do
        local unit = "party" .. i
        if validPartyUnit(unit) then
            local role = UnitGroupRolesAssigned(unit)
            if role == "TANK" then
                return unit
            end
        end
    end

    return nil
end

local function tankDisplayName(unit)
    if not unit or type(UnitName) ~= "function" then
        return tostring(unit or "?")
    end

    local name = UnitName(unit)
    return tostring(name or unit)
end

local function updateTank()
    local tank = findTank()

    if tank ~= S.tankUnit then
        S.tankUnit = tank
        S.tankName = tankDisplayName(tank)
        S.tankGUID = tank and UnitGUID and UnitGUID(tank) or nil
        S.tankObject = tank and resolveWGGObject(tank) or nil
        S.lastTankObjectResolve = now()
        S.lastTankX, S.lastTankY, S.lastTankZ = nil, nil, nil
        S.lastPathBuild = 0
        stopMovement()

        if tank then
            log("Tank acquired: "..S.tankName.." ("..tank..")"
                .." | guid="..tostring(S.tankGUID)
                .." | wggObject="..tostring(S.tankObject))
        else
            log("Tank unavailable")
        end
    end

    return tank
end

local function tankTargetUnit()
    if not S.tankUnit then
        return nil
    end
    return S.tankUnit .. "target"
end

local function targetIsAttackable(unit)
    if not unit or type(UnitExists) ~= "function" or not UnitExists(unit) then
        return false
    end

    if type(UnitIsDeadOrGhost) == "function" and UnitIsDeadOrGhost(unit) then
        return false
    end

    if type(UnitCanAttack) == "function" then
        local can = UnitCanAttack("player", unit)
        if not can then
            return false
        end
    end

    return true
end

local function disengageForTankRecovery()
    if F.stopAttack then
        protected(F.stopAttack)
    end
    if F.clearTarget then
        protected(F.clearTarget)
    end
end

local function maybeAssistTank(tankDistance)
    if not CFG.assistTankTarget or not S.tankUnit then
        return
    end

    -- Movement takes priority when separated. Do not keep feeding the combat
    -- rotation new targets while we're trying to catch the tank.
    if S.leashRecovery then
        return
    end

    if type(tankDistance)=="number" and tankDistance > CFG.softLeash then
        return
    end

    if now() - S.lastAssist < CFG.assistInterval then
        return
    end
    S.lastAssist = now()

    local tt = tankTargetUnit()
    if not targetIsAttackable(tt) then
        return
    end

    local needTarget =
        not targetIsAttackable("target")

    if not needTarget then
        return
    end

    local ok, err = protected(F.targetUnit, tt)
    if ok then
        log("Assisting tank target: " .. tostring(UnitName(tt) or tt))
    else
        logError("TargetUnit failed: " .. tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- Opportunistic loot controller
-- ---------------------------------------------------------------------------

local function updateLooting(tankUnit,tankDistance)
    if not lootAllowed(tankDistance) then
        if S.lootTarget then
            clearLootTarget()
        end
        return false
    end

    -- Existing loot target.
    if S.lootTarget then
        if not isLootable(S.lootTarget) then
            log("Looted: "..tostring(S.lootTargetName or S.lootTargetGUID or "corpse"))
            clearLootTarget()
            S.lastPathBuild=0
            return false
        end

        if S.lootStartedAt and now()-S.lootStartedAt >= CFG.lootTimeout then
            log("Loot timeout -> returning to tank")
            stopMovement()
            clearLootTarget()
            S.lastPathBuild=0
            return false
        end

        local d=objectDistanceFromPlayer(S.lootTarget)
        if not d then
            clearLootTarget()
            return false
        end

        -- Tank started leaving while we were looting. Abort immediately.
        if tankDistance > CFG.lootTankMaxDistance then
            stopMovement()
            clearLootTarget()
            S.lastPathBuild=0
            return false
        end

        if d <= CFG.lootInteractRange then
            stopMovement()

            if now()-S.lastLootAttempt >= CFG.lootRetryCooldown then
                S.lastLootAttempt=now()
                local ok,method=interactLoot(S.lootTarget)
                if ok then
                    ui(
                        "LOOTING",
                        tostring(S.lootTargetName or "corpse")
                        .." | "..string.format("%.1f yd",d)
                    )
                    log(
                        "Loot interact -> "
                        ..tostring(S.lootTargetName or S.lootTargetGUID or "corpse")
                        .." | method="..tostring(method)
                    )
                else
                    logError("Loot interaction failed: "..tostring(method))
                end
            end
            return true
        end

        -- Only walk a very short distance for loot.
        if d <= CFG.lootApproachRange then
            if type(WGG.ObjectPos)=="function" then
                local ok,x,y,z=pcall(WGG.ObjectPos,S.lootTarget)
                if ok and type(x)=="number" then
                    -- Direct movement is deliberate here: this is at most a
                    -- few yards and we abort the instant the tank leash opens.
                    local dok,derr=directFollowStart(x,y,z)
                    if dok then
                        directFollowUpdate(x,y,z)
                        ui(
                            "APPROACHING LOOT",
                            tostring(S.lootTargetName or "corpse")
                            .." | "..string.format("%.1f yd",d)
                        )
                        return true
                    else
                        logError("Loot approach failed: "..tostring(derr))
                    end
                end
            end
        end

        clearLootTarget()
        return false
    end

    -- Never interrupt active combat merely to pick up trash loot.
    -- Do not call playerInCombat() here because updateLooting() is declared
    -- earlier in this Lua chunk than that local helper.
    local inCombat =
        type(UnitAffectingCombat)=="function"
        and UnitAffectingCombat("player")

    if inCombat then return false end

    if now()-S.lastLootScan < CFG.lootScanInterval then
        return false
    end
    S.lastLootScan=now()

    local obj,d=findNearestLootable(CFG.lootApproachRange)
    if not obj then return false end

    S.lootTarget=obj
    S.lootTargetGUID=objectGUID(obj)
    S.lootTargetName=objectName(obj)
    S.lootStartedAt=now()

    log(
        "Lootable corpse found: "
        ..tostring(S.lootTargetName or S.lootTargetGUID or "corpse")
        .." | "..string.format("%.1f yd",d or -1)
    )

    return true
end

-- ---------------------------------------------------------------------------
-- Follow controller
-- ---------------------------------------------------------------------------

local function playerInCombat()
    return type(UnitAffectingCombat) == "function"
        and UnitAffectingCombat("player")
end

local function playerDead()
    return type(UnitIsDeadOrGhost) == "function"
        and UnitIsDeadOrGhost("player")
end

local function followTank()
    local tank = updateTank()

    if not tank then
        stopMovement()
        local r={}
        for i=1,CFG.maxTankSearchUnits do
            local u="party"..i
            if UnitExists and UnitExists(u) then
                r[#r+1]=u..":"..tostring(UnitGroupRolesAssigned(u))
            end
        end
        ui("WAITING FOR TANK",#r>0 and table.concat(r," | ") or "No party units visible")
        return
    end

    local px, py, pz = playerPos()
    local tx, ty, tz = objectPos(tank)

    if not px or not tx then
        stopMovement()
        ui("WAITING FOR TANK POSITION",
            tostring(S.tankName).." | token="..tostring(tank)
            .." | object="..tostring(S.tankObject))
        return
    end

    local d = distance3(px, py, pz, tx, ty, tz)
    local combat = playerInCombat()

    local wanted = combat and CFG.combatFollowDistance or CFG.followDistance
    local stopAt = combat and CFG.combatStopDistance or CFG.stopDistance

    -- ---------------------------------------------------------------
    -- Tank leash state machine
    -- ---------------------------------------------------------------

    if not S.leashRecovery and d >= CFG.hardLeash then
        clearLootTarget()
        S.leashRecovery=true
        disengageForTankRecovery()
        stopMovement()
        S.lastPathBuild=0
        S.pathStartAt=nil

        if now()-(S.lastLeashLog or 0) >= 2 then
            S.lastLeashLog=now()
            log(
                "TANK LEASH LOST"
                .. " | tank="..tostring(S.tankName)
                .. " | distance="..string.format("%.1f",d)
                .. " | combat="..tostring(combat)
                .. " | prioritizing catch-up"
            )
        end
    elseif S.leashRecovery and d <= CFG.recoveredLeash then
        S.leashRecovery=false
        S.lastPathBuild=0

        log(
            "TANK LEASH RECOVERED"
            .. " | tank="..tostring(S.tankName)
            .. " | distance="..string.format("%.1f",d)
        )
    end

    -- Even before hard recovery, stop feeding the combat rotation targets
    -- once the tank is outside our soft leash.
    maybeAssistTank(d)

    if S.leashRecovery then
        -- A clear short gap is best recovered directly because a combat
        -- rotation can repeatedly disturb short navmesh paths.
        if d <= CFG.emergencyDirectDistance and d > CFG.recoveredLeash then
            if type(WGG.StopMovement)=="function" then
                pcall(WGG.StopMovement)
            end

            local dok,derr=directFollowStart(tx,ty,tz)
            if dok then
                directFollowUpdate(tx,ty,tz)
                ui(
                    "CATCHING TANK",
                    string.format("%s | %.1f yd | DIRECT",S.tankName,d)
                )
                return
            else
                logError("Emergency direct follow failed: "..tostring(derr))
            end
        end

        -- Farther away, force an aggressively refreshed native path.
        if S.directFollowing then
            stopMovement()
        end

        if shouldRepath(tx,ty,tz,true) then
            local ok,result=buildTankPath(tank,wanted,true)
            if ok then
                ui(
                    "CATCHING TANK",
                    string.format(
                        "%s | %.1f yd | NAV %s nodes | moving=%s",
                        S.tankName,d,tostring(result),tostring(nativePathMoving())
                    )
                )
            else
                ui("CATCH-UP PATH FAILED",tostring(result))
                logError("Catch-up path: "..tostring(result))
            end
        else
            if type(WGG.UpdateNavigation)=="function" then
                pcall(WGG.UpdateNavigation)
            end

            ui(
                "CATCHING TANK",
                string.format(
                    "%s | %.1f yd | NAV moving=%s",
                    S.tankName,d,tostring(nativePathMoving())
                )
            )
        end

        return
    end

    -- Opportunistic corpse looting is lower priority than the tank leash.
    -- It runs only while out of combat and the tank remains close.
    if updateLooting(tank,d) then
        return
    end

    -- If direct fallback is already active, keep facing the live tank.
    if S.directFollowing then
        if d <= stopAt then
            stopMovement()
        elseif d <= (
            S.leashRecovery and CFG.emergencyDirectDistance
            or CFG.directFallbackDistance
        ) then
            directFollowUpdate(tx,ty,tz)
            ui(
                combat and "COMBAT - DIRECT FOLLOW" or "DIRECT FOLLOW",
                string.format("%s | %.1f yd",S.tankName,d)
            )
            return
        else
            -- Tank got far enough away that navmesh pathing is preferable.
            stopMovement()
            S.lastPathBuild=0
        end
    end

    -- Native Warden movement can occasionally report a valid path but never
    -- produce physical player movement. Verify actual displacement.
    if S.pathStartAt
        and (now()-S.pathStartAt) >= CFG.nativeMoveGrace
        and S.pathStartPX
        and d <= CFG.emergencyDirectDistance
        and d > stopAt
    then
        local moved=distance3(
            S.pathStartPX,S.pathStartPY,S.pathStartPZ,
            px,py,pz
        )
        local nativeMoving=nativePathMoving()

        if moved < CFG.nativeMinProgress or nativeMoving == false then
            if type(WGG.StopMovement)=="function" then
                pcall(WGG.StopMovement)
            end

            local dok,derr=directFollowStart(tx,ty,tz)
            if dok then
                if now()-(S.lastDirectLog or 0) >= 2 then
                    S.lastDirectLog=now()
                    log(
                        "Native follow stalled"
                        .. " | moved="..string.format("%.2f",moved)
                        .. " | IsMovingAlongPath="..tostring(nativeMoving)
                        .. " | direct fallback to "..tostring(S.tankName)
                    )
                end
                ui(
                    combat and "COMBAT - DIRECT FOLLOW" or "DIRECT FOLLOW",
                    string.format("%s | %.1f yd | native stalled",S.tankName,d)
                )
                return
            else
                logError("Direct follow failed: "..tostring(derr))
            end
        end

        -- Only test each native path start once.
        S.pathStartAt=nil
        S.pathStartPX,S.pathStartPY,S.pathStartPZ=nil,nil,nil
    end

    if d > CFG.softLeash and combat then
        -- Do not keep swinging at a mob behind us while the tank moves ahead.
        if targetIsAttackable("target") then
            disengageForTankRecovery()
        end
    end

    -- Close enough. Let the external combat rotation do its thing instead of
    -- continuously shoving us into the tank's character model.
    if d <= stopAt then
        stopMovement()
        ui(
            combat and "COMBAT - WITH TANK" or "FOLLOWING TANK",
            string.format("%s | %.1f yd", S.tankName, d)
        )
        return
    end

    if not shouldRepath(tx, ty, tz, false) then
        if type(WGG.UpdateNavigation) == "function" then
            pcall(WGG.UpdateNavigation)
        end

        ui(
            combat and "COMBAT - FOLLOWING TANK" or "FOLLOWING TANK",
            string.format("%s | %.1f yd | map %s",
                S.tankName, d, tostring(S.lastMapID or "?"))
        )
        return
    end

    local ok, result = buildTankPath(tank, wanted, false)

    if ok then
        ui(
            combat and "COMBAT - FOLLOWING TANK" or "FOLLOWING TANK",
            string.format(
                "%s | %.1f yd | %s nodes | moving=%s",
                S.tankName, d, tostring(result), tostring(nativePathMoving())
            )
        )
    else
        stopMovement()
        ui("TANK PATH FAILED", tostring(result))
        logError("Tank follow: " .. tostring(result))
    end
end

-- ---------------------------------------------------------------------------
-- Completion / leave / repeat
-- ---------------------------------------------------------------------------

local function inLFGDungeon()
    local mode=queueMode()
    if mode=="lfgparty" or mode=="abandonedInDungeon" then
        return true,"GetLFGMode:"..tostring(mode)
    end
    if type(IsInLFGDungeon)=="function" then
        local ok,v=pcall(IsInLFGDungeon)
        if ok and (unwrap(v)==true or unwrap(v)==1) then
            return true,"IsInLFGDungeon"
        end
    end
    if type(IsInInstance)=="function" then
        local ok,inside,typ=pcall(IsInInstance)
        if ok and inside and typ=="party" then
            return true,"IsInInstance:party"
        end
    end
    return false,"not in LFG dungeon"
end

local function lfgComplete()
    if type(IsLFGComplete) ~= "function" then
        return false
    end

    local ok, v = pcall(IsLFGComplete)
    return ok and (unwrap(v) == true or unwrap(v) == 1)
end

local function inInstanceParty()
    local category = _G.LE_PARTY_CATEGORY_INSTANCE or 1

    if type(IsInGroup) == "function" then
        local ok, v = pcall(IsInGroup, category)
        if ok then
            return v == true or v == 1
        end
    end

    if type(IsPartyLFG) == "function" then
        local ok, v = pcall(IsPartyLFG)
        if ok then
            return v == true or v == 1
        end
    end

    return false
end

local function resetRunState()
    S.tankUnit = nil
    S.tankName = nil
    S.tankObject = nil
    S.tankGUID = nil
    S.lastTankObjectResolve = 0

    S.lastPathBuild = 0
    S.lastTankX, S.lastTankY, S.lastTankZ = nil, nil, nil
    S.lastMapID = nil
    S.pathStartAt = nil
    S.pathStartPX,S.pathStartPY,S.pathStartPZ = nil,nil,nil
    S.directFollowing = false
    S.directStartedAt = nil
    S.leashRecovery = false
    S.lastLeashLog = 0
    S.lastCatchupPath = 0

    S.lastLootScan = 0
    S.lastLootAttempt = 0
    clearLootTarget()

    S.completeAt = nil
    S.leaveAttemptAt = nil
    S.groupLeftAt = nil
    S.teleportAttemptAt = nil
    S.teleportedOutAt = nil
    S.requeueAt = nil

    S.wasInDungeon = false
    S.wasLFGComplete = false

    stopMovement()
end

local function handleCompletedDungeon()
    stopMovement()
    clearLootTarget()

    if not S.completeAt then
        S.completeAt = now()
        S.wasLFGComplete = true
        log("Dungeon complete detected. Waiting briefly before leaving instance group.")
    end

    local elapsed = now() - S.completeAt
    if elapsed < CFG.completionWait then
        ui(
            "DUNGEON COMPLETE",
            string.format("Leaving group in %.1f sec", CFG.completionWait - elapsed)
        )
        return
    end

    -- Preferred exit: leave the instance group. In normal completed LFD runs
    -- this also removes us from the instance / returns us outside.
    if inInstanceParty() then
        if not S.leaveAttemptAt
            or now() - S.leaveAttemptAt >= CFG.leavePartyRetry
        then
            S.leaveAttemptAt = now()

            local ok, err = protected(F.leaveInstanceParty)
            if ok then
                if not S.groupLeftAt then
                    S.groupLeftAt = now()
                end
                log("Dungeon complete -> Leave instance group requested")
                ui("LEAVING INSTANCE GROUP", "Waiting to return outside")
            else
                ui("LEAVE GROUP FAILED", tostring(err))
                logError("Leave instance group failed: " .. tostring(err))
            end
        end
        return
    end

    -- We are no longer in the instance group but may still physically be
    -- inside for a moment while Blizzard processes the exit.
    if not S.groupLeftAt then
        S.groupLeftAt = now()
    end

    local inside = inLFGDungeon()
    if not inside then
        ui("INSTANCE GROUP LEFT", "Outside confirmed")
        return
    end

    local grace = now() - S.groupLeftAt
    if grace < CFG.leaveExitGrace then
        ui(
            "WAITING FOR INSTANCE EXIT",
            string.format("%.1f sec", CFG.leaveExitGrace - grace)
        )
        return
    end

    -- Fallback only. If leaving the group did not physically remove us after
    -- the grace period, use the old LFG teleport-out behavior.
    if not S.teleportAttemptAt
        or now() - S.teleportAttemptAt >= CFG.teleportRetry
    then
        S.teleportAttemptAt = now()

        local ok, err = protected(F.teleportOut)
        if ok then
            log("Leave-group exit stalled -> fallback LFGTeleport(true)")
            ui("FALLBACK TELEPORT OUT", "Instance exit did not complete")
        else
            ui("FALLBACK TELEPORT FAILED", tostring(err))
            logError("Fallback LFGTeleport failed: " .. tostring(err))
        end
    end
end

local function handleOutsideAfterCompletion()
    stopMovement()

    if not S.teleportedOutAt then
        S.teleportedOutAt = now()
        log("Outside completed dungeon confirmed.")
    end

    -- Normally the instance group was already left by handleCompletedDungeon.
    -- If WoW still reports it for a moment, wait rather than issuing another
    -- leave call and potentially fighting state transitions.
    if inInstanceParty() then
        ui("WAITING FOR GROUP EXIT", "Blizzard still reports instance group")
        return
    end

    if not S.requeueAt then
        S.requeueAt = now() + CFG.requeueWait
        log("Completed group exited. Requeue scheduled.")
    end

    local remain = S.requeueAt - now()
    if remain > 0 then
        ui("REQUEUE COOLDOWN", string.format("%.1f sec", remain))
        return
    end

    resetRunState()

    -- Rescan because weekly/special event queues can change.
    refreshTimewalkingQueue(true)
    local ok, err = joinTimewalking()

    if not ok and err ~= "queue retry cooldown" then
        ui("REQUEUE FAILED", tostring(err))
        logError("Requeue failed: " .. tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- Main state machine
-- ---------------------------------------------------------------------------

local function tick()
    if not S.enabled then
        return
    end

    if playerDead() then
        stopMovement()
        ui("DEAD - MANUAL RECOVERY", "v0.1 does not release/ghost-run yet")
        return
    end

    if acceptProposalIfNeeded() then
        return
    end

    local inside,insideReason = inLFGDungeon()

    if inside then
        if not S.wasInDungeon then log("Dungeon detected via "..tostring(insideReason)) end
        S.wasInDungeon = true

        if lfgComplete() or S.wasLFGComplete or S.completeAt then
            handleCompletedDungeon()
            return
        end

        -- New active run.
        S.completeAt = nil
        S.leaveAttemptAt = nil
        S.groupLeftAt = nil
        S.teleportAttemptAt = nil
        S.teleportedOutAt = nil
        S.requeueAt = nil

        if not navConnected() then
            stopMovement()
            ui(
                "NAV SERVER REQUIRED",
                CFG.navIP .. ":" .. tostring(CFG.navPort)
            )
            return
        end

        followTank()
        return
    end

    -- We were in a completed dungeon, and now we are outside it.
    if S.wasInDungeon and S.wasLFGComplete then
        handleOutsideAfterCompletion()
        return
    end

    -- We left/teleported unexpectedly before completion.
    if S.wasInDungeon and not inside then
        stopMovement()
        ui("LEFT DUNGEON BEFORE COMPLETE", "Paused to avoid deserter/requeue loops")
        return
    end

    -- Normal queue / waiting state.
    local mode, submode = queueMode()

    if isQueued() then
        ui(
            "WAITING IN QUEUE",
            string.format(
                "%s | mode=%s%s",
                tostring(S.twDungeonName or "Timewalking"),
                tostring(mode or "?"),
                submode and (" / " .. tostring(submode)) or ""
            )
        )
        return
    end

    -- Don't queue while in an ordinary party. This fresh bot is designed for
    -- solo DPS queueing in v0.1.
    local homeCategory = _G.LE_PARTY_CATEGORY_HOME or 1
    if type(IsInGroup) == "function"
        and IsInGroup(homeCategory)
        and not inInstanceParty()
    then
        ui("IN NON-LFG PARTY", "Leave normal party before starting solo queue")
        return
    end

    local ok, err = joinTimewalking()
    if not ok and err ~= "queue retry cooldown" then
        ui("QUEUE FAILED", tostring(err))
        logError("Queue failed: " .. tostring(err))
    elseif not ok then
        ui("WAITING TO RETRY QUEUE", tostring(S.twDungeonName or "Timewalking"))
    end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("LFG_PROPOSAL_SHOW")
events:RegisterEvent("LFG_PROPOSAL_UPDATE")
events:RegisterEvent("LFG_PROPOSAL_SUCCEEDED")
events:RegisterEvent("LFG_ROLE_CHECK_SHOW")
events:RegisterEvent("LFG_READY_CHECK_SHOW")
events:RegisterEvent("LFG_COMPLETION_REWARD")
events:RegisterEvent("LFG_UPDATE")

events:SetScript("OnEvent", function(_, event)
    if not S.enabled then
        return
    end

    if event == "LFG_PROPOSAL_SHOW"
        or event == "LFG_PROPOSAL_UPDATE"
    then
        acceptProposalIfNeeded()
        return
    end

    if event == "LFG_ROLE_CHECK_SHOW" then
        local ok, err = protected(F.roleCheck)
        log("Role check response: " .. tostring(ok) .. " " .. tostring(err or ""))
        return
    end

    if event == "LFG_READY_CHECK_SHOW" then
        local ok, err = protected(F.readyCheck)
        log("Ready check response: " .. tostring(ok) .. " " .. tostring(err or ""))
        return
    end

    if event == "LFG_COMPLETION_REWARD" then
        if not S.completeAt then
            S.completeAt = now()
        end
        S.wasLFGComplete = true
        log("LFG_COMPLETION_REWARD event received | leave-group exit armed")
        return
    end

    if event == "GROUP_ROSTER_UPDATE" then
        updateTank()
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        S.lastPathBuild = 0
        S.lastTankX, S.lastTankY, S.lastTankZ = nil, nil, nil
        stopMovement()
        return
    end
end)

-- ---------------------------------------------------------------------------
-- Enable / disable
-- ---------------------------------------------------------------------------

local function enable()
    if S.enabled then
        return
    end

    local ok, err = compile()
    if not ok then
        ui("COMPILE FAILED", tostring(err))
        logError("Compile failed: " .. tostring(err))
        return
    end

    S.enabled = true
    resetRunState()
    navConfigure()

    local twOK, twErr = refreshTimewalkingQueue(true)
    local role,specName = currentSpecRole()

    log(
        "AUTO ROLE | spec="..tostring(specName).." | role="..tostring(role)
    )

    log(
        "LOADED " .. VERSION
        .. " | nav=" .. tostring(navConnected())
        .. " | TW=" .. tostring(twOK and S.twDungeonName or twErr)
    )

    ui(
        "STARTING",
        twOK
            and tostring(S.twDungeonName)
            or tostring(twErr)
    )
end

local function disable(reason)
    S.enabled = false
    stopMovement()

    ui("OFF", tostring(reason or ("v" .. VERSION)))
    log("OFF" .. (reason and (" | " .. tostring(reason)) or ""))
end

toggle:SetScript("OnClick", function()
    if S.enabled then
        disable("User toggle")
    else
        enable()
    end
end)

-- ---------------------------------------------------------------------------
-- OnUpdate
-- ---------------------------------------------------------------------------

local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function(_, elapsed)
    if not S.enabled then
        return
    end

    S.lastTick = S.lastTick + elapsed
    if S.lastTick < CFG.tick then
        return
    end
    S.lastTick = 0

    if type(WGG.UpdateNavigation) == "function" then
        pcall(WGG.UpdateNavigation)
    end

    local ok, err = pcall(tick)
    if not ok then
        stopMovement()
        ui("RUNTIME ERROR", tostring(err))
        logError("Runtime error: " .. tostring(err))
    end
end)

-- ---------------------------------------------------------------------------
-- Queue diagnostics
-- ---------------------------------------------------------------------------

local function dumpQueueDiagnostics()
    local mode, sub = queueMode()

    local leader, tank, healer, dps = nil, nil, nil, nil
    if type(GetLFGRoles) == "function" then
        local ok, a, b, c, d = pcall(GetLFGRoles)
        if ok then
            leader, tank, healer, dps = a, b, c, d
        end
    end

    local allJoinable, playerJoinable, hideIfNotJoinable, groupSize = nil, nil, nil, nil
    if S.twDungeonID and type(IsLFGDungeonJoinable) == "function" then
        local ok, a, b, c, d = pcall(IsLFGDungeonJoinable, S.twDungeonID)
        if ok then
            allJoinable, playerJoinable, hideIfNotJoinable, groupSize = a, b, c, d
        end
    end

    local uiType = nil
    if _G.LFDQueueFrame then
        uiType = _G.LFDQueueFrame.type
    end

    log(
        "QUEUE DIAG"
        .. " | category=" .. tostring(CFG.lfdCategory)
        .. " | dungeon=" .. tostring(S.twDungeonID)
        .. " | name=" .. tostring(S.twDungeonName)
        .. " | mode=" .. tostring(mode)
        .. " | sub=" .. tostring(sub)
        .. " | queued=" .. tostring(isQueued())
    )

    log(
        "QUEUE DIAG roles"
        .. " | leader=" .. tostring(leader)
        .. " tank=" .. tostring(tank)
        .. " healer=" .. tostring(healer)
        .. " dps=" .. tostring(dps)
    )

    log(
        "QUEUE DIAG joinable"
        .. " | all=" .. tostring(allJoinable)
        .. " player=" .. tostring(playerJoinable)
        .. " hide=" .. tostring(hideIfNotJoinable)
        .. " groupSize=" .. tostring(groupSize)
    )

    log(
        "QUEUE DIAG APIs"
        .. " | LFDQueueFrame_SetType=" .. tostring(type(_G.LFDQueueFrame_SetType))
        .. " | LFDQueueFrame_Join=" .. tostring(type(_G.LFDQueueFrame_Join))
        .. " | LFG_JoinDungeon=" .. tostring(type(_G.LFG_JoinDungeon))
        .. " | JoinSingleLFG=" .. tostring(type(_G.JoinSingleLFG))
        .. " | uiType=" .. tostring(uiType)
    )

    log(
        "QUEUE DIAG compiled"
        .. " | queue=" .. tostring(type(F.queueDPS))
        .. " | accept=" .. tostring(type(F.acceptProposal))
        .. " | teleport=" .. tostring(type(F.teleportOut))
        .. " | leave=" .. tostring(type(F.leaveInstanceParty))
    )
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

SLASH_TWDUNGEONBOT1 = "/twbot"
SlashCmdList.TWDUNGEONBOT = function()
    if S.enabled then
        disable("Slash toggle")
    else
        enable()
    end
end

SLASH_TWSCAN1 = "/twscan"
SlashCmdList.TWSCAN = function()
    if type(GetNumRandomDungeons) ~= "function"
        or type(GetLFGRandomDungeonInfo) ~= "function"
    then
        log("Random dungeon APIs unavailable")
        return
    end

    local count = GetNumRandomDungeons()
    log("Random dungeon entries: " .. tostring(count))

    for i = 1, count do
        local values = { GetLFGRandomDungeonInfo(i) }
        local id = values[1]
        local name = values[2]
        local isTW = values[19]

        if id and name then
            log(string.format(
                "[%d] ID=%s | TW=%s | %s",
                i, tostring(id), tostring(isTW), tostring(name)
            ))
        end
    end

    refreshTimewalkingQueue(true)
end

SLASH_TWQUEUE1 = "/twqueue"
SlashCmdList.TWQUEUE = function()
    refreshTimewalkingQueue(true)
    dumpQueueDiagnostics()
end

SLASH_TWLOOT1 = "/twloot"
SlashCmdList.TWLOOT = function()
    local tank=updateTank()
    local px,py,pz=playerPos()
    local tx,ty,tz=nil,nil,nil
    if tank then tx,ty,tz=objectPos(tank) end
    local tankD=nil
    if px and tx then tankD=distance3(px,py,pz,tx,ty,tz) end

    local obj,d=findNearestLootable(30)
    log(
        "LOOT DIAG"
        .." | enabled="..tostring(CFG.lootEnabled)
        .." | combat="..tostring(playerInCombat())
        .." | tankDistance="..tostring(tankD)
        .." | leash="..tostring(S.leashRecovery)
        .." | nearest="..tostring(obj)
        .." | name="..tostring(obj and objectName(obj))
        .." | distance="..tostring(d)
        .." | lootable="..tostring(obj and isLootable(obj))
    )
end

SLASH_TWFOLLOW1 = "/twfollow"
SlashCmdList.TWFOLLOW = function()
    local inside,reason=inLFGDungeon()
    local tank=updateTank()
    local px,py,pz=playerPos()
    local tx,ty,tz,obj=nil,nil,nil,nil
    if tank then
        tx,ty,tz,obj=objectPos(tank)
    end
    local mapID,uiMapID,mapSource=currentInstanceMapID()
    log("FOLLOW DIAG | inside="..tostring(inside).." | reason="..tostring(reason)
        .." | tank="..tostring(tank).." | name="..tostring(S.tankName)
        .." | guid="..tostring(S.tankGUID).." | object="..tostring(obj or S.tankObject))
    log("FOLLOW POS | player="..tostring(px)..","..tostring(py)..","..tostring(pz)
        .." | tank="..tostring(tx)..","..tostring(ty)..","..tostring(tz)
        .." | worldMap="..tostring(mapID).." | uiMap="..tostring(uiMapID)
        .." | source="..tostring(mapSource).." | nav="..tostring(navConnected())
        .." | nativeMoving="..tostring(nativePathMoving())
        .." | direct="..tostring(S.directFollowing)
        .." | leashRecovery="..tostring(S.leashRecovery))
    for i=1,CFG.maxTankSearchUnits do
        local u="party"..i
        if UnitExists and UnitExists(u) then
            log("PARTY "..u.." | "..tostring(UnitName(u))
                .." | role="..tostring(UnitGroupRolesAssigned(u))
                .." | object="..tostring(resolveWGGObject(u)))
        end
    end
end

SLASH_TWSTATE1 = "/twstate"
SlashCmdList.TWSTATE = function()
    local mode, submode = queueMode()
    local pExists, p = pendingProposal()
    local inside,insideReason = inLFGDungeon()
    local complete = lfgComplete()
    local mapID,uiMapID,mapSource = currentInstanceMapID()

    log(
        "STATE"
        .. " | version=" .. VERSION
        .. " | enabled=" .. tostring(S.enabled)
        .. " | TW=" .. tostring(S.twDungeonName)
        .. " | id=" .. tostring(S.twDungeonID)
        .. " | mode=" .. tostring(mode)
        .. " | submode=" .. tostring(submode)
        .. " | proposal=" .. tostring(pExists)
        .. " | responded=" .. tostring(p and p.hasResponded)
        .. " | inDungeon=" .. tostring(inside)
        .. " | insideReason=" .. tostring(insideReason)
        .. " | complete=" .. tostring(complete)
        .. " | worldMap=" .. tostring(mapID)
        .. " | uiMap=" .. tostring(uiMapID)
        .. " | mapSource=" .. tostring(mapSource)
        .. " | nav=" .. tostring(navConnected())
        .. " | tank=" .. tostring(S.tankName)
    )
end

ui("OFF", "v" .. VERSION)
log("Loaded _TW_DungeonBot_v0.1.8.lua | loot scope fix | /twloot /twfollow")
