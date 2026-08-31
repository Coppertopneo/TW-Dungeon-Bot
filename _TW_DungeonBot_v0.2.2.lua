--[[
    TW Dungeon Bot v0.1
    Fresh prototype, independent from Follow The Arrow.

    Goal:
      1. Find the currently available Timewalking random-dungeon queue.
      2. Detect current specialization role and queue as Tank/Healer/DPS.
      3. Accept LFG proposal automatically.
      4. Once inside, identify the party tank, record their breadcrumb route,
         and follow that saved route using WardenGG Navigation Server pathing.
      5. Assist the tank's hostile target so an external combat rotation has
         something useful to attack.
      6. Detect LFG completion.
      7. Teleport out, leave the instance party, wait briefly, and queue again.

    This is intentionally v0.1:
      - It does NOT contain a class/spec combat rotation.
      - It does NOT auto-release/ghost-run after death yet.
      - It does NOT handle every odd dungeon mechanic yet.
      - Tank following does NOT require WardenGG Navigation Server in v0.2.0.

    WardenGG scripts loaded normally receive:
        local WGG = ...
]]

local WGG = ...

local VERSION = "0.2.2-combat-safety"

local CFG = {
    navIP = "127.0.0.1",
    navPort = 47110,

    -- LFD category. Retail's Dungeon Finder category is normally 1.
    lfdCategory = _G.LE_LFG_CATEGORY_LFD or 1,

    -- Follow behavior
    followDistance = 7.5,
    combatFollowDistance = 6.0,
    stopDistance = 4.5,

    -- Do not stand inside the tank during combat.
    -- DPS uses a melee-friendly buffer. Healers stay farther back.
    combatStopDistance = 5.5,
    healerCombatStopDistance = 10.0,

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

    -- Tank breadcrumb trace.
    -- Instead of always chasing the tank's CURRENT position, record the route
    -- the tank actually walked. This preserves corners and obstacle routing
    -- while combat temporarily prevents us from moving.
    trailEnabled = true,
    trailDirectMode = true, -- NavServer not required for tank following
    -- Water / drop recovery.
    waterRecoveryEnabled = true,
    waterPitchMaxDeg = 50.0,
    waterVerticalDeadzone = 0.75,
    waterAscendThreshold = 1.25,
    waterDescendThreshold = -1.25,
    waterStallSeconds = 0.85,
    waterEmergencyAscendSeconds = 1.40,
    waterExitGrace = 0.45,

    -- Combat danger-zone avoidance.
    -- Warden AreaTriggers expose x/y/z/radius/spellId/casterGuid.
    dangerAvoidEnabled = true,
    dangerScanInterval = 0.20,
    dangerExtraMargin = 1.75,
    dangerZTolerance = 5.0,
    dangerEscapeExtra = 2.0,
    dangerEscapeMax = 8.0,
    dangerHoldSeconds = 0.20,
    dangerUnknownCasterIsHostile = true,

    trailSampleInterval = 0.25,
    trailMinSpacing = 1.5,
    trailCornerMinSpacing = 0.80,
    trailCornerAngleDeg = 28.0,
    trailReachDistance = 1.8,
    trailLookaheadDistance = 3.5,
    trailMaxLookaheadPoints = 2,
    trailForwardSyncPoints = 3,
    trailForwardSyncDistance = 4.0,
    trailGapResetDistance = 45.0,
    trailMaxPoints = 500,
    trailKeepBehind = 12,
    trailRepathInterval = 0.65,
    trailCombatRepathInterval = 1.10,
    trailStallSeconds = 0.70,
    trailProgressDistance = 0.20,

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

    tankTrail = {},
    trailCursor = 1,
    lastTrailSample = 0,
    trailMapID = nil,
    trailTargetIndex = nil,
    trailLastPathAt = 0,
    trailLastLog = 0,
    trailPathFailures = 0,
    trailWatchAt = 0,
    trailWatchDistance = nil,
    waterMode = false,
    waterAscendActive = false,
    waterDescendActive = false,
    waterEnteredAt = nil,
    waterExitAt = nil,
    waterStallAt = nil,
    waterEmergencyUntil = nil,
    waterLastPX = nil,
    waterLastPY = nil,
    waterLastPZ = nil,

    dangerActive = false,
    dangerSpellID = nil,
    dangerTargetX = nil,
    dangerTargetY = nil,
    dangerTargetZ = nil,
    dangerLastScan = 0,
    dangerSafeAt = nil,
    dangerLastLog = 0,

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

        jumpAscendStart = {
            [[
                return function()
                    if type(JumpOrAscendStart) ~= "function" then
                        error("JumpOrAscendStart unavailable")
                    end
                    JumpOrAscendStart()
                    return true
                end
            ]],
            "@TW_jumpAscendStart"
        },

        ascendStop = {
            [[
                return function()
                    if type(AscendStop) == "function" then
                        AscendStop()
                    end
                    return true
                end
            ]],
            "@TW_ascendStop"
        },

        descendStart = {
            [[
                return function()
                    if type(SitStandOrDescendStart) ~= "function" then
                        error("SitStandOrDescendStart unavailable")
                    end
                    SitStandOrDescendStart()
                    return true
                end
            ]],
            "@TW_descendStart"
        },

        descendStop = {
            [[
                return function()
                    if type(DescendStop) == "function" then
                        DescendStop()
                    end
                    return true
                end
            ]],
            "@TW_descendStop"
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
        .. " | ascend=" .. tostring(type(F.jumpAscendStart))
        .. " | descend=" .. tostring(type(F.descendStart))
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

local function stopWaterVertical()
    if S.waterAscendActive and F.ascendStop then
        protected(F.ascendStop)
    end
    if S.waterDescendActive and F.descendStop then
        protected(F.descendStop)
    end
    S.waterAscendActive=false
    S.waterDescendActive=false
end

local function stopMovement()
    if type(WGG.StopMovement) == "function" then
        pcall(WGG.StopMovement)
    end

    if S.directFollowing and F.moveForwardStop then
        protected(F.moveForwardStop)
    end

    stopWaterVertical()

    if type(WGG.SetPitch)=="function" then
        pcall(WGG.SetPitch,0)
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


-- ---------------------------------------------------------------------------
-- Tank breadcrumb trace
-- ---------------------------------------------------------------------------

local function resetTankTrail(reason)
    S.tankTrail = {}
    S.trailCursor = 1
    S.lastTrailSample = 0
    S.trailMapID = nil
    S.trailTargetIndex = nil
    S.trailLastPathAt = 0
    S.trailPathFailures = 0
    S.trailWatchAt = 0
    S.trailWatchDistance = nil

    if reason then
        log("Tank trace reset: " .. tostring(reason))
    end
end

local function angleBetween2D(ax, ay, bx, by)
    local amag = math.sqrt(ax * ax + ay * ay)
    local bmag = math.sqrt(bx * bx + by * by)
    if amag < 0.001 or bmag < 0.001 then
        return 0
    end

    local dot = (ax * bx + ay * by) / (amag * bmag)
    if dot > 1 then dot = 1 end
    if dot < -1 then dot = -1 end
    return math.deg(math.acos(dot))
end

local function snapTrailPoint(mapID, x, y, z)
    -- Preserve the exact position the tank actually occupied. In direct trace
    -- mode we do not need NavServer to validate or modify this breadcrumb.
    if CFG.trailDirectMode then
        return x,y,z
    end

    if type(WGG.ValidateWaypoint) == "function" then
        local ok, vx, vy, vz = pcall(WGG.ValidateWaypoint, mapID, x, y, z)
        if ok
            and type(vx) == "number"
            and type(vy) == "number"
            and type(vz) == "number"
        then
            return vx, vy, vz
        end
    end

    return x, y, z
end

local function pruneTankTrail()
    local trail = S.tankTrail
    local cursor = S.trailCursor or 1

    -- Once a breadcrumb is safely behind us, it no longer needs to remain in
    -- memory. Keep a small amount of history so forward-sync logic has context.
    if cursor > (CFG.trailKeepBehind + 1) then
        local removeCount = cursor - CFG.trailKeepBehind - 1
        for _ = 1, removeCount do
            table.remove(trail, 1)
        end
        S.trailCursor = cursor - removeCount

        if S.trailTargetIndex then
            S.trailTargetIndex = math.max(1, S.trailTargetIndex - removeCount)
        end
    end

    -- Hard memory bound. Five hundred points is already far more dungeon
    -- history than we should ever need, but do not let a broken run grow forever.
    while #trail > CFG.trailMaxPoints do
        table.remove(trail, 1)
        S.trailCursor = math.max(1, (S.trailCursor or 1) - 1)
        if S.trailTargetIndex then
            S.trailTargetIndex = math.max(1, S.trailTargetIndex - 1)
        end
    end
end

local function recordTankBreadcrumb(tx, ty, tz)
    if not CFG.trailEnabled then
        return
    end

    if not tx or not ty or not tz then
        return
    end

    local mapID = currentInstanceMapID()
    if not mapID then
        return
    end

    if S.trailMapID and S.trailMapID ~= mapID then
        resetTankTrail("map changed")
    end
    S.trailMapID = mapID

    local trail = S.tankTrail
    local tm = now()
    local last = trail[#trail]

    if not last then
        local x, y, z = snapTrailPoint(mapID, tx, ty, tz)
        trail[1] = {
            x = x, y = y, z = z,
            t = tm,
            corner = false,
            mapID = mapID,
        }
        S.trailCursor = 1
        S.lastTrailSample = tm
        return
    end

    local fromLast = distance3(last.x, last.y, last.z, tx, ty, tz)

    -- A teleport, elevator transfer, or other giant discontinuity should not
    -- create a fake straight segment through the dungeon.
    if fromLast >= CFG.trailGapResetDistance then
        resetTankTrail("tank position jumped " .. string.format("%.1f yd", fromLast))
        local x, y, z = snapTrailPoint(mapID, tx, ty, tz)
        S.tankTrail[1] = {
            x = x, y = y, z = z,
            t = tm,
            corner = false,
            mapID = mapID,
        }
        S.trailCursor = 1
        S.lastTrailSample = tm
        return
    end

    if tm - (S.lastTrailSample or 0) < CFG.trailSampleInterval
        and fromLast < CFG.trailMinSpacing
    then
        return
    end

    local corner = false
    if #trail >= 2 and fromLast >= CFG.trailCornerMinSpacing then
        local prev = trail[#trail - 1]
        local a1x, a1y = last.x - prev.x, last.y - prev.y
        local a2x, a2y = tx - last.x, ty - last.y
        local angle = angleBetween2D(a1x, a1y, a2x, a2y)

        if angle >= CFG.trailCornerAngleDeg then
            -- The LAST sampled point is where the direction changed, so mark
            -- that point as a must-visit corner.
            last.corner = true
            corner = true
        end
    end

    if fromLast < CFG.trailMinSpacing and not corner then
        return
    end

    local x, y, z = snapTrailPoint(mapID, tx, ty, tz)
    trail[#trail + 1] = {
        x = x, y = y, z = z,
        t = tm,
        corner = false,
        mapID = mapID,
    }

    S.lastTrailSample = tm
    pruneTankTrail()
end

local function trailPointDistance(px, py, pz, point)
    if not point then return nil end
    return distance3(px, py, pz, point.x, point.y, point.z)
end

local function advanceTrailCursor(px, py, pz)
    local trail = S.tankTrail
    local cursor = S.trailCursor or 1

    while cursor <= #trail do
        local d = trailPointDistance(px, py, pz, trail[cursor])
        if d and d <= CFG.trailReachDistance then
            cursor = cursor + 1
        else
            break
        end
    end

    -- If normal nav movement carried us past one or two ordinary samples,
    -- synchronize forward, but never skip across an unvisited corner.
    if cursor <= #trail then
        local bestIndex = cursor
        local bestDistance = trailPointDistance(px, py, pz, trail[cursor])

        local limit = math.min(#trail, cursor + CFG.trailForwardSyncPoints)
        for i = cursor + 1, limit do
            if trail[i - 1] and trail[i - 1].corner then
                break
            end

            local d = trailPointDistance(px, py, pz, trail[i])
            if d
                and d <= CFG.trailForwardSyncDistance
                and (not bestDistance or d + 0.75 < bestDistance)
            then
                bestDistance = d
                bestIndex = i
            end
        end

        cursor = bestIndex
    end

    S.trailCursor = cursor
    pruneTankTrail()
    return S.trailCursor
end

local function chooseTrailTarget(px, py, pz)
    local trail = S.tankTrail
    local cursor = advanceTrailCursor(px, py, pz)

    if cursor > #trail then
        return nil
    end

    local targetIndex = cursor
    local accumulated = 0
    local previous = trail[cursor]

    -- Never skip a recorded corner. Otherwise look several yards ahead to
    -- avoid stop-start behavior at every two-yard breadcrumb.
    for i = cursor, math.min(#trail, cursor + CFG.trailMaxLookaheadPoints) do
        local point = trail[i]

        if i > cursor then
            accumulated = accumulated + distance3(
                previous.x, previous.y, previous.z,
                point.x, point.y, point.z
            )
        end

        targetIndex = i

        if point.corner then
            return point, targetIndex, "corner"
        end

        if accumulated >= CFG.trailLookaheadDistance then
            return point, targetIndex, "lookahead"
        end

        previous = point
    end

    return trail[targetIndex], targetIndex, "tail"
end

local function trailMovementStalled(px, py, pz)
    local activeIndex = S.trailTargetIndex
    local point = activeIndex and S.tankTrail[activeIndex] or nil

    if not point then
        S.trailWatchAt = 0
        S.trailWatchDistance = nil
        return false
    end

    local d = trailPointDistance(px, py, pz, point)
    if not d then
        return false
    end

    if not S.trailWatchDistance then
        S.trailWatchDistance = d
        S.trailWatchAt = now()
        return false
    end

    if d <= (S.trailWatchDistance - CFG.trailProgressDistance) then
        S.trailWatchDistance = d
        S.trailWatchAt = now()
        return false
    end

    if now() - (S.trailWatchAt or 0) >= CFG.trailStallSeconds then
        -- Reset the watchdog window so a combat root/rotation can keep failing
        -- without destroying the breadcrumb. We simply retry this route point.
        S.trailWatchDistance = d
        S.trailWatchAt = now()
        return true
    end

    return false
end

local function shouldRepathTrail(targetIndex, combat, stalled)
    if not targetIndex then
        return false
    end

    local interval = combat
        and CFG.trailCombatRepathInterval
        or CFG.trailRepathInterval

    if stalled then
        return now() - (S.trailLastPathAt or 0) >= interval
    end

    -- If the cursor already consumed the active target, move on immediately.
    if S.trailTargetIndex
        and S.trailTargetIndex < (S.trailCursor or 1)
    then
        return true
    end

    -- Do not interrupt a healthy path merely because more breadcrumbs were
    -- recorded ahead of it. Finish the current static waypoint first.
    if nativePathMoving() == true then
        return false
    end

    if S.trailTargetIndex ~= targetIndex then
        return true
    end

    return now() - (S.trailLastPathAt or 0) >= interval
end

local function tryTrailPath(px, py, pz, point, targetIndex)
    if not point or not targetIndex then
        return false, "no trail target"
    end

    if not navConnected() then
        return false, "NAV SERVER DISCONNECTED"
    end

    if type(WGG.FindPath) ~= "function"
        or type(WGG.MoveAlongPath) ~= "function"
    then
        return false, "FindPath/MoveAlongPath unavailable"
    end

    local mapID = point.mapID or S.trailMapID or currentInstanceMapID()
    if not mapID then
        return false, "trail map unavailable"
    end

    -- Try the selected lookahead point first. If that exact endpoint cannot
    -- path, walk backward through the saved route until a reachable breadcrumb
    -- is found. Crucially, we never replace the route with "run straight at tank".
    local cursor = S.trailCursor or 1
    for i = targetIndex, cursor, -1 do
        local p = S.tankTrail[i]
        if p then
            stopMovement()

            local ok, count = pcall(
                WGG.FindPath,
                mapID,
                px, py, pz,
                p.x, p.y, p.z,
                false
            )

            count = ok and tonumber(unwrap(count)) or nil
            if count and count > 0 then
                local mok, moved = pcall(WGG.MoveAlongPath)
                if mok and moved ~= false then
                    S.trailTargetIndex = i
                    S.trailLastPathAt = now()
                    S.lastPathBuild = now()
                    S.lastMapID = mapID
                    S.pathStartAt = now()
                    S.pathStartPX, S.pathStartPY, S.pathStartPZ = px, py, pz
                    S.trailPathFailures = 0
                    S.trailWatchAt = now()
                    S.trailWatchDistance = distance3(
                        px, py, pz,
                        p.x, p.y, p.z
                    )
                    return true, count, i
                end
            end
        end
    end

    S.trailLastPathAt = now()
    S.trailPathFailures = (S.trailPathFailures or 0) + 1
    return false, "no reachable saved breadcrumb"
end


-- ---------------------------------------------------------------------------
-- v0.2.1 water / submerged recovery
-- ---------------------------------------------------------------------------

local function playerSwimmingOrSubmerged()
    local swimming=false
    local submerged=false

    if type(IsSwimming)=="function" then
        local ok,v=pcall(IsSwimming,"player")
        swimming=ok and (v==true or v==1)
    end

    if type(IsSubmerged)=="function" then
        local ok,v=pcall(IsSubmerged,"player")
        submerged=ok and (v==true or v==1)
    end

    return swimming or submerged,swimming,submerged
end

local function setWaterVerticalMode(mode)
    if mode=="up" then
        if S.waterDescendActive and F.descendStop then
            protected(F.descendStop)
            S.waterDescendActive=false
        end
        if not S.waterAscendActive and F.jumpAscendStart then
            local ok=protected(F.jumpAscendStart)
            if ok then S.waterAscendActive=true end
        end
        return
    end

    if mode=="down" then
        if S.waterAscendActive and F.ascendStop then
            protected(F.ascendStop)
            S.waterAscendActive=false
        end
        if not S.waterDescendActive and F.descendStart then
            local ok=protected(F.descendStart)
            if ok then S.waterDescendActive=true end
        end
        return
    end

    stopWaterVertical()
end

local function updateWaterMovement(point,px,py,pz)
    if not CFG.waterRecoveryEnabled or not point or not px then
        return false
    end

    local inWater,swimming,submerged=playerSwimmingOrSubmerged()
    local tm=now()

    if not inWater then
        if S.waterMode then
            if not S.waterExitAt then S.waterExitAt=tm end
            if tm-S.waterExitAt>=CFG.waterExitGrace then
                stopWaterVertical()
                if type(WGG.SetPitch)=="function" then pcall(WGG.SetPitch,0) end
                S.waterMode=false
                S.waterEnteredAt=nil
                S.waterExitAt=nil
                S.waterEmergencyUntil=nil
                log("WATER RECOVERY COMPLETE | returned to ground movement")
            end
        end
        return false
    end

    if not S.waterMode then
        S.waterMode=true
        S.waterEnteredAt=tm
        S.waterExitAt=nil
        S.waterStallAt=tm
        S.waterLastPX,S.waterLastPY,S.waterLastPZ=px,py,pz
        log(
            "WATER MODE"
            .." | swimming="..tostring(swimming)
            .." | submerged="..tostring(submerged)
            .." | breadcrumb route retained"
        )
    else
        S.waterExitAt=nil
    end

    local dx=point.x-px
    local dy=point.y-py
    local dz=point.z-pz
    local horizontal=math.sqrt(dx*dx+dy*dy)

    -- Aim toward the 3D breadcrumb. Warden SetPitch uses radians.
    if type(WGG.SetPitch)=="function" then
        local pitch=math.atan2(dz,math.max(horizontal,0.01))
        local maxPitch=math.rad(CFG.waterPitchMaxDeg)
        if pitch>maxPitch then pitch=maxPitch end
        if pitch<-maxPitch then pitch=-maxPitch end
        pcall(WGG.SetPitch,pitch)
    end

    -- Track physical progress. If we're swimming but essentially stationary,
    -- briefly force an ascent to break out of the common "stuck under ledge /
    -- wall after a drop" condition.
    local moved=distance3(
        S.waterLastPX or px,S.waterLastPY or py,S.waterLastPZ or pz,
        px,py,pz
    )

    if moved>=CFG.trailProgressDistance then
        S.waterStallAt=tm
        S.waterLastPX,S.waterLastPY,S.waterLastPZ=px,py,pz
    elseif tm-(S.waterStallAt or tm)>=CFG.waterStallSeconds
        and not S.waterEmergencyUntil
    then
        S.waterEmergencyUntil=tm+CFG.waterEmergencyAscendSeconds
        S.waterStallAt=tm
        log("WATER STALL | emergency ascend pulse")
    end

    local verticalMode=nil

    if S.waterEmergencyUntil and tm<S.waterEmergencyUntil then
        verticalMode="up"
    else
        S.waterEmergencyUntil=nil

        if dz>=CFG.waterAscendThreshold then
            verticalMode="up"
        elseif dz<=CFG.waterDescendThreshold then
            verticalMode="down"
        else
            verticalMode=nil
        end
    end

    setWaterVerticalMode(verticalMode)

    -- Keep forward movement aimed at the saved breadcrumb while vertical swim
    -- controls handle the Z axis.
    if not S.directFollowing then
        local ok,err=directFollowStart(point.x,point.y,point.z)
        if not ok then
            logError("Water forward movement failed: "..tostring(err))
        end
    else
        directFollowUpdate(point.x,point.y,point.z)
    end

    ui(
        "WATER RECOVERY",
        string.format(
            "%s | dz=%+.1f | %.1f yd | %s",
            tostring(S.tankName or "tank"),
            dz,
            distance3(px,py,pz,point.x,point.y,point.z),
            verticalMode=="up" and "ASCEND"
                or verticalMode=="down" and "DESCEND"
                or "FORWARD"
        )
    )

    return true
end

local function followTankTrace(px, py, pz, combat, tankDistance)
    if not CFG.trailEnabled then
        return false
    end

    local point, targetIndex, targetKind = chooseTrailTarget(px, py, pz)
    if not point then
        return false
    end

    local pd = trailPointDistance(px, py, pz, point)
    if pd and pd <= CFG.trailReachDistance then
        advanceTrailCursor(px, py, pz)
        point, targetIndex, targetKind = chooseTrailTarget(px, py, pz)
        if not point then
            stopMovement()
            return false
        end
        pd = trailPointDistance(px, py, pz, point)
    end

    if not pd then
        return false
    end

    -- Swimming/submerged movement needs pitch + vertical controls. The same
    -- saved breadcrumb stays authoritative, so water recovery still preserves
    -- the tank's actual route.
    if updateWaterMovement(point,px,py,pz) then
        S.trailTargetIndex=targetIndex
        return true
    end

    -- Direct breadcrumb mode:
    -- follow the STATIC point the tank actually walked through.
    -- Never replace it with the tank's live XYZ, which is what cuts corners.
    local stalled = trailMovementStalled(px, py, pz)
    local targetChanged = S.trailTargetIndex ~= targetIndex

    if stalled or targetChanged or not S.directFollowing then
        stopMovement()

        local ok, err = directFollowStart(point.x, point.y, point.z)
        if not ok then
            ui("TRACE MOVEMENT FAILED", tostring(err))
            logError(
                "Direct breadcrumb movement failed"
                .. " | crumb=" .. tostring(targetIndex)
                .. "/" .. tostring(#S.tankTrail)
                .. " | " .. tostring(err)
            )
            return true
        end

        S.trailTargetIndex = targetIndex
        S.trailLastPathAt = now()
        S.trailWatchAt = now()
        S.trailWatchDistance = pd
    else
        directFollowUpdate(point.x, point.y, point.z)
    end

    ui(
        combat and "COMBAT - FOLLOWING TRACE" or "FOLLOWING TANK TRACE",
        string.format(
            "%s | tank=%s yd | crumb %d/%d | %s | %.1f yd",
            tostring(S.tankName or "tank"),
            type(tankDistance)=="number" and string.format("%.1f",tankDistance) or "?",
            targetIndex,
            #S.tankTrail,
            stalled and "STALLED-RETRY" or tostring(targetKind),
            pd
        )
    )

    return true
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

local function combatTankSpacing()
    if S.queueRole == "HEALER" then
        return CFG.healerCombatStopDistance
    end
    return CFG.combatStopDistance
end


-- ---------------------------------------------------------------------------
-- v0.2.2 combat danger-zone avoidance
-- ---------------------------------------------------------------------------

local function groupObjectGUIDs()
    local result={}

    if type(WGG.ObjectGUID)~="function" then
        return result
    end

    local units={"player","party1","party2","party3","party4"}
    for i=1,#units do
        local unit=units[i]
        if unit=="player" or (type(UnitExists)=="function" and UnitExists(unit)) then
            local obj=resolveWGGObject(unit) or unit
            local ok,g=pcall(WGG.ObjectGUID,obj)
            if ok and g then
                result[tostring(g)]=true
            end
        end
    end

    return result
end

local function casterLooksFriendly(casterGuid,groupGuids)
    if not casterGuid then
        return false
    end

    local key=tostring(casterGuid)
    if groupGuids[key] then
        return true
    end

    -- Best-effort secondary classification. If Warden can resolve the caster
    -- GUID to a live object/token, use Blizzard's friend/attack relationship.
    if type(WGG.Object)=="function" then
        local ok,obj=pcall(WGG.Object,casterGuid)
        if ok and obj then
            local token=nil
            if type(WGG.ObjectToken)=="function" then
                local tokOK,tok=pcall(WGG.ObjectToken,obj)
                if tokOK then token=tok end
            end

            if token and type(UnitIsFriend)=="function" then
                local fOK,f=pcall(UnitIsFriend,"player",token)
                if fOK and f then return true end
            end

            if token and type(UnitCanAttack)=="function" then
                local aOK,a=pcall(UnitCanAttack,"player",token)
                if aOK and a then return false end
            end
        end
    end

    return nil
end

local function nearestDangerArea(px,py,pz)
    if not CFG.dangerAvoidEnabled
        or type(WGG.Objects)~="function"
        or type(WGG.AreaTrigger)~="function"
    then
        return nil
    end

    if now()-(S.dangerLastScan or 0) < CFG.dangerScanInterval then
        return nil
    end
    S.dangerLastScan=now()

    local ok,objects=pcall(WGG.Objects,11)
    if not ok or type(objects)~="table" then
        return nil
    end

    local groupGuids=groupObjectGUIDs()
    local best=nil
    local bestPenetration=nil

    for i=1,#objects do
        local obj=objects[i]
        local aok,info=pcall(WGG.AreaTrigger,obj)

        if aok and type(info)=="table"
            and type(info.x)=="number"
            and type(info.y)=="number"
            and type(info.z)=="number"
            and type(info.radius)=="number"
            and info.radius>0
        then
            local friendly=casterLooksFriendly(info.casterGuid,groupGuids)
            local treatDanger =
                friendly == false
                or (friendly == nil and CFG.dangerUnknownCasterIsHostile)

            if treatDanger then
                local dz=math.abs(pz-info.z)

                if dz<=CFG.dangerZTolerance then
                    local dx=px-info.x
                    local dy=py-info.y
                    local planar=math.sqrt(dx*dx+dy*dy)
                    local dangerRadius=info.radius+CFG.dangerExtraMargin
                    local penetration=dangerRadius-planar

                    if penetration>=0
                        and (not bestPenetration or penetration>bestPenetration)
                    then
                        bestPenetration=penetration
                        best={
                            x=info.x,
                            y=info.y,
                            z=info.z,
                            radius=info.radius,
                            spellId=info.spellId,
                            casterGuid=info.casterGuid,
                            distance=planar,
                            dangerRadius=dangerRadius,
                            penetration=penetration,
                        }
                    end
                end
            end
        end
    end

    return best
end

local function clearDangerAvoidance(stop)
    if stop and S.dangerActive then
        stopMovement()
    end

    S.dangerActive=false
    S.dangerSpellID=nil
    S.dangerTargetX=nil
    S.dangerTargetY=nil
    S.dangerTargetZ=nil
    S.dangerSafeAt=nil
end

local function dangerEscapePoint(area,px,py,pz,tank)
    local dx=px-area.x
    local dy=py-area.y
    local len=math.sqrt(dx*dx+dy*dy)

    -- If exactly centered in the trigger, bias away from the tank. That tends
    -- to move us out of tank-centered danger rather than deeper through it.
    if len<0.05 and tank then
        local tx,ty=objectPos(tank)
        if tx then
            dx=px-tx
            dy=py-ty
            len=math.sqrt(dx*dx+dy*dy)
        end
    end

    if len<0.05 then
        local facing=0
        if type(WGG.GetFacing)=="function" then
            local ok,f=pcall(WGG.GetFacing,"player")
            if ok and type(f)=="number" then facing=f end
        end
        dx=math.cos(facing+math.pi/2)
        dy=math.sin(facing+math.pi/2)
        len=1
    end

    dx=dx/len
    dy=dy/len

    local needed=
        (area.dangerRadius-area.distance)
        + CFG.dangerEscapeExtra

    if needed<CFG.dangerEscapeExtra then
        needed=CFG.dangerEscapeExtra
    end
    if needed>CFG.dangerEscapeMax then
        needed=CFG.dangerEscapeMax
    end

    return px+dx*needed,py+dy*needed,pz
end

local function updateDangerAvoidance(tank,px,py,pz,combat)
    if not combat or not CFG.dangerAvoidEnabled then
        if S.dangerActive then
            clearDangerAvoidance(true)
        end
        return false
    end

    local inWater=playerSwimmingOrSubmerged()
    if inWater then
        return false
    end

    local area=nearestDangerArea(px,py,pz)

    if not area then
        if S.dangerActive then
            if not S.dangerSafeAt then
                S.dangerSafeAt=now()
            end

            if now()-S.dangerSafeAt>=CFG.dangerHoldSeconds then
                clearDangerAvoidance(true)
                log("DANGER CLEAR | resuming tank breadcrumb route")
                return false
            end

            if S.dangerTargetX then
                if not S.directFollowing then
                    directFollowStart(
                        S.dangerTargetX,
                        S.dangerTargetY,
                        S.dangerTargetZ
                    )
                else
                    directFollowUpdate(
                        S.dangerTargetX,
                        S.dangerTargetY,
                        S.dangerTargetZ
                    )
                end
                return true
            end
        end
        return false
    end

    S.dangerSafeAt=nil

    local ex,ey,ez=dangerEscapePoint(area,px,py,pz,tank)

    local changed =
        not S.dangerActive
        or S.dangerSpellID~=area.spellId
        or not S.dangerTargetX
        or distance3(
            S.dangerTargetX,S.dangerTargetY,S.dangerTargetZ,
            ex,ey,ez
        )>=1.5

    if changed then
        stopMovement()
        S.dangerActive=true
        S.dangerSpellID=area.spellId
        S.dangerTargetX,S.dangerTargetY,S.dangerTargetZ=ex,ey,ez

        local ok,err=directFollowStart(ex,ey,ez)
        if not ok then
            logError("Danger escape movement failed: "..tostring(err))
            return false
        end
    else
        directFollowUpdate(ex,ey,ez)
        S.dangerTargetX,S.dangerTargetY,S.dangerTargetZ=ex,ey,ez
    end

    if now()-(S.dangerLastLog or 0)>=1.5 then
        S.dangerLastLog=now()
        log(
            "DANGER AREA"
            .." | spell="..tostring(area.spellId)
            .." | radius="..string.format("%.1f",area.radius)
            .." | insideBy="..string.format("%.1f",area.penetration)
            .." | EVADING"
        )
    end

    ui(
        "AVOIDING DANGER",
        string.format(
            "spell %s | %.1f yd radius | escape",
            tostring(area.spellId or "?"),
            area.radius
        )
    )

    -- Important: do NOT advance or clear the breadcrumb trail. Once safe, the
    -- exact prior route resumes from its existing cursor.
    return true
end

local function followTank()
    local tank = updateTank()

    if not tank then
        -- If the party token briefly disappears but we still have a saved tank
        -- route, do not throw that route away.
        local px, py, pz = playerPos()
        if px and #S.tankTrail > 0 then
            if followTankTrace(px, py, pz, playerInCombat(), nil) then
                return
            end
        end

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
    if not px then
        stopMovement()
        ui("WAITING FOR PLAYER POSITION","WGG.ObjectPos(player) unavailable")
        return
    end

    local tx, ty, tz = objectPos(tank)
    local combat = playerInCombat()

    -- Always record the tank route BEFORE doing combat/movement decisions.
    -- That means combat can pin us in place for ten seconds while the trace
    -- continues accumulating the route around corners ahead of us.
    if tx then
        recordTankBreadcrumb(tx, ty, tz)
    end

    local d = nil
    if tx then
        d = distance3(px, py, pz, tx, ty, tz)
    end

    local wanted = combat and CFG.combatFollowDistance or CFG.followDistance
    local stopAt = combat and combatTankSpacing() or CFG.stopDistance

    -- ---------------------------------------------------------------
    -- Tank leash state machine
    -- ---------------------------------------------------------------

    if not d then
        -- Current tank coordinates can disappear around unusual geometry.
        -- Treat that as a recovery condition, but use the saved trail.
        if #S.tankTrail > 0 then
            S.leashRecovery = true
        end
    elseif not S.leashRecovery and d >= CFG.hardLeash then
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
                .. " | following saved trace"
            )
        end
    elseif S.leashRecovery and d and d <= CFG.recoveredLeash then
        S.leashRecovery=false
        S.lastPathBuild=0

        log(
            "TANK LEASH RECOVERED"
            .. " | tank="..tostring(S.tankName)
            .. " | distance="..string.format("%.1f",d)
        )
    end

    -- Ground-effect avoidance beats combat positioning, looting, and following.
    -- The breadcrumb cursor is preserved while we sidestep the danger zone.
    if updateDangerAvoidance(tank,px,py,pz,combat) then
        return
    end

    -- Stop feeding combat a new target once the tank begins separating.
    if d then
        maybeAssistTank(d)
        if d > CFG.softLeash and combat and targetIsAttackable("target") then
            disengageForTankRecovery()
        end
    end

    -- Loot is allowed only while close enough to the live tank.
    if d and not S.leashRecovery and updateLooting(tank,d) then
        return
    end

    -- If we're genuinely caught up to the tank, consume any breadcrumb under
    -- our feet and let combat work. We still keep recording new breadcrumbs.
    local inWaterNow=playerSwimmingOrSubmerged()
    if d and d <= stopAt and not inWaterNow then
        -- Being physically back on the live tank is definitive proof that all
        -- older breadcrumbs have been completed. Do not later backtrack to one.
        S.trailCursor = #S.tankTrail + 1
        S.trailTargetIndex = nil
        S.trailWatchAt = 0
        S.trailWatchDistance = nil
        pruneTankTrail()
        stopMovement()
        ui(
            combat and "COMBAT - WITH TANK" or "FOLLOWING TANK",
            string.format(
                "%s | %.1f yd | trace %d/%d",
                S.tankName, d,
                math.min(S.trailCursor or 1, #S.tankTrail + 1),
                #S.tankTrail
            )
        )
        return
    end

    -- PRIMARY MOVEMENT: follow the tank's recorded breadcrumbs. The path
    -- survives combat stalls and preserves the actual route around corners.
    if #S.tankTrail > 0
        and followTankTrace(px, py, pz, combat, d)
    then
        return
    end

    -- Startup fallback only before the recorder has enough trail to drive.
    -- Directly approach the tank once. As soon as breadcrumbs exist, they take
    -- over and the live tank position is no longer used as a shortcut.
    if not tx then
        stopMovement()
        ui(
            "WAITING FOR TANK TRACE",
            "Tank identified but coordinates unavailable"
        )
        return
    end

    local ok, err = directFollowStart(tx, ty, tz)
    if ok then
        directFollowUpdate(tx,ty,tz)
        ui(
            combat and "COMBAT - STARTING TRACE" or "STARTING TRACE",
            string.format("%s | %.1f yd | NAVLESS", S.tankName, d or -1)
        )
    else
        stopMovement()
        ui("START TRACE FAILED", tostring(err))
        logError("Tank start trace: " .. tostring(err))
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

    S.waterMode=false
    S.waterAscendActive=false
    S.waterDescendActive=false
    S.waterEnteredAt=nil
    S.waterExitAt=nil
    S.waterStallAt=nil
    S.waterEmergencyUntil=nil
    S.waterLastPX,S.waterLastPY,S.waterLastPZ=nil,nil,nil

    S.dangerActive=false
    S.dangerSpellID=nil
    S.dangerTargetX,S.dangerTargetY,S.dangerTargetZ=nil,nil,nil
    S.dangerLastScan=0
    S.dangerSafeAt=nil
    S.dangerLastLog=0

    resetTankTrail()

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

        -- v0.2.0: the tank's recorded breadcrumb trail is the movement route.
        -- NavServer is optional and no longer gates active dungeon following.
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
        .. " | followMode=DIRECT-BREADCRUMB"
        .. " | nav(optional)=" .. tostring(navConnected())
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

SLASH_TWDANGER1 = "/twdanger"
SlashCmdList.TWDANGER = function()
    local px,py,pz=playerPos()
    local area=nil
    if px then
        -- Force a fresh diagnostic scan.
        S.dangerLastScan=0
        area=nearestDangerArea(px,py,pz)
    end

    log(
        "DANGER DIAG"
        .." | active="..tostring(S.dangerActive)
        .." | role="..tostring(S.queueRole)
        .." | combatSpacing="..tostring(combatTankSpacing())
        .." | areaSpell="..tostring(area and area.spellId)
        .." | areaRadius="..tostring(area and area.radius)
        .." | distance="..tostring(area and area.distance)
        .." | penetration="..tostring(area and area.penetration)
    )
end

SLASH_TWWATER1 = "/twwater"
SlashCmdList.TWWATER = function()
    local inWater,swimming,submerged=playerSwimmingOrSubmerged()
    local px,py,pz=playerPos()
    local point,index,kind=nil,nil,nil

    if px then
        point,index,kind=chooseTrailTarget(px,py,pz)
    end

    local dz=nil
    if point and pz then dz=point.z-pz end

    log(
        "WATER DIAG"
        .." | inWater="..tostring(inWater)
        .." | swimming="..tostring(swimming)
        .." | submerged="..tostring(submerged)
        .." | waterMode="..tostring(S.waterMode)
        .." | ascend="..tostring(S.waterAscendActive)
        .." | descend="..tostring(S.waterDescendActive)
        .." | crumb="..tostring(index)
        .." | kind="..tostring(kind)
        .." | dz="..tostring(dz)
    )
end

SLASH_TWTRAIL1 = "/twtrail"
SlashCmdList.TWTRAIL = function()
    local px,py,pz=playerPos()
    local point,index,kind=nil,nil,nil
    if px then
        point,index,kind=chooseTrailTarget(px,py,pz)
    end

    local pd=nil
    if px and point then
        pd=trailPointDistance(px,py,pz,point)
    end

    local corners=0
    for i=(S.trailCursor or 1),#S.tankTrail do
        if S.tankTrail[i] and S.tankTrail[i].corner then
            corners=corners+1
        end
    end

    log(
        "TRAIL DIAG | DIRECT-NAVLESS"
        .." | points="..tostring(#S.tankTrail)
        .." | cursor="..tostring(S.trailCursor)
        .." | target="..tostring(index)
        .." | targetKind="..tostring(kind)
        .." | targetDistance="..tostring(pd)
        .." | pendingCorners="..tostring(corners)
        .." | map="..tostring(S.trailMapID)
        .." | moving="..tostring(nativePathMoving())
        .." | failures="..tostring(S.trailPathFailures)
    )
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
        .." | leashRecovery="..tostring(S.leashRecovery)
        .." | trace="..tostring(S.trailCursor).."/"..tostring(#S.tankTrail)
        .." | traceTarget="..tostring(S.trailTargetIndex)
        .." | traceFailures="..tostring(S.trailPathFailures))
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
log("Loaded _TW_DungeonBot_v0.2.2.lua | tank breadcrumb trace | /twtrail /twfollow")
