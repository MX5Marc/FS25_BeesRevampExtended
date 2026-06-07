-- Bee hive inspection input handler
-- Adds a hold-R action when the player is close to a BeesRevamp hive.

BR_HiveInspectionInput = BR_HiveInspectionInput or {}
BR_HiveInspectionInput.isInitialized = BR_HiveInspectionInput.isInitialized or false
BR_HiveInspectionInput.hooksInstalled = BR_HiveInspectionInput.hooksInstalled or false

local brInspectionHive = nil
local brInspectionActionId = nil
local brInspectionHoldHive = nil
local brInspectionHoldTime = 0
local brInspectionHoldThreshold = 600
local brInspectionMaxDistance = 5.0
local brLastInspectionOpenTime = -999999
local brInspectionOpenCooldown = 1000

local function brLog(text)
    print('BeesRevamp HIVE INSPECTION: ' .. tostring(text))
end

brLog('script loaded')

local function brResetInspectionHoldState()
    brInspectionHoldHive = nil
    brInspectionHoldTime = 0
end

local function brIsInspectionDialogOpen()
    return BR_HiveInspectionDialog ~= nil
        and BR_HiveInspectionDialog.INSTANCE ~= nil
        and BR_HiveInspectionDialog.INSTANCE.isDialogOpen == true
end



local function brGetPlayerOrCameraNode(player)
    if player ~= nil and player.rootNode ~= nil then
        return player.rootNode
    end

    local mission = g_currentMission
    if mission ~= nil then
        if mission.player ~= nil and mission.player.rootNode ~= nil then
            return mission.player.rootNode
        end
        if mission.playerSystem ~= nil and mission.playerSystem.players ~= nil then
            for _, p in pairs(mission.playerSystem.players) do
                if p ~= nil and p.rootNode ~= nil then
                    return p.rootNode
                end
            end
        end
    end

    if getCamera ~= nil then
        local ok, cam = pcall(getCamera)
        if ok and cam ~= nil and cam ~= 0 then
            return cam
        end
    end

    return nil
end

local function brGetCurrentPlayer()
    local mission = g_currentMission
    if mission == nil then
        return nil
    end
    if mission.player ~= nil then
        return mission.player
    end
    if mission.playerSystem ~= nil and mission.playerSystem.players ~= nil then
        for _, p in pairs(mission.playerSystem.players) do
            if p ~= nil then
                return p
            end
        end
    end
    return nil
end

local function brGetHiveRootNode(hive)
    if hive == nil then
        return nil
    end
    return hive.rootNode or hive.nodeId or hive.components ~= nil and hive.components[1] ~= nil and hive.components[1].node or nil
end

local function brGetHiveDistanceToPlayer(hive, player)
    if hive == nil then
        return math.huge
    end

    local targetNode = brGetPlayerOrCameraNode(player)
    if targetNode == nil or targetNode == 0 then
        return math.huge
    end

    if hive.getDistanceToNode ~= nil then
        local ok, distance = pcall(hive.getDistanceToNode, hive, targetNode)
        if ok and distance ~= nil then
            return distance
        end
    end

    local hiveNode = brGetHiveRootNode(hive)
    if hiveNode == nil or hiveNode == 0 then
        return math.huge
    end

    local hx, _, hz = getWorldTranslation(hiveNode)
    local px, _, pz = getWorldTranslation(targetNode)
    if hx == nil or px == nil then
        return math.huge
    end

    return MathUtil.vector2Length(hx - px, hz - pz)
end

local function brHasHiveSpecs(hive)
    return hive ~= nil and hive.spec_beehive ~= nil and hive.spec_beecare ~= nil and hive.spec_beehiveextended ~= nil
end

local function brCanInspectHive(hive, player)
    if not brHasHiveSpecs(hive) then
        return false
    end

    if g_currentMission ~= nil and g_currentMission.accessHandler ~= nil and g_currentMission.accessHandler.canPlayerAccess ~= nil then
        local ok = true
        local success, result = pcall(g_currentMission.accessHandler.canPlayerAccess, g_currentMission.accessHandler, hive, player)
        if success and result ~= nil then
            ok = result
        end
        if not ok then
            return false
        end
    end

    return brGetHiveDistanceToPlayer(hive, player) <= brInspectionMaxDistance
end

local function brGetNearestInspectionHive(player)
    local mission = g_currentMission
    local system = mission ~= nil and mission.beehiveSystem or nil
    local hives = system ~= nil and system.beehivesSortedRadius or nil
    if hives == nil then
        return nil
    end

    local bestHive = nil
    local bestDistance = brInspectionMaxDistance

    for i = 1, #hives do
        local hive = hives[i]
        if brCanInspectHive(hive, player) then
            local distance = brGetHiveDistanceToPlayer(hive, player)
            if distance <= bestDistance then
                bestDistance = distance
                bestHive = hive
            end
        end
    end

    return bestHive
end

local function brOnInputHiveInspection(actionName, inputValue, callbackState, isAnalog)
    if brIsInspectionDialogOpen() then
        brResetInspectionHoldState()
        return
    end

    if brInspectionHive == nil then
        brResetInspectionHoldState()
        return
    end

    if inputValue == 0 then
        brResetInspectionHoldState()
        return
    end

    if brInspectionHoldHive ~= brInspectionHive then
        brInspectionHoldHive = brInspectionHive
        brInspectionHoldTime = 0
    end

    brInspectionHoldTime = brInspectionHoldTime + g_currentDt
    if brInspectionHoldTime >= brInspectionHoldThreshold then
        local now = g_time or 0
        if now - brLastInspectionOpenTime >= brInspectionOpenCooldown then
            brLastInspectionOpenTime = now
            if BR_HiveInspectionDialog ~= nil then
                BR_HiveInspectionDialog.show(brInspectionHive)
            else
                brLog('dialog class missing')
            end
        else
            -- Suppress repeated hold callbacks while the key is still down.
        end
        brResetInspectionHoldState()
    end
end

local function brOnPlayerInputComponentUpdate(inputComponent, superFunc, dt)
    superFunc(inputComponent, dt)

    if inputComponent == nil or inputComponent.player == nil then
        return
    end

    if not inputComponent.player.isOwner
        or g_inputBinding:getContextName() ~= PlayerInputComponent.INPUT_CONTEXT_NAME
        or brInspectionActionId == nil then
        return
    end

    local previousHive = brInspectionHive
    brInspectionHive = nil

    local player = inputComponent.player
    if player ~= nil
        and player.isControlled
        and not player:getIsInVehicle()
        and not player:getAreHandsHoldingObject()
        and not player:getIsHoldingHandTool() then
        brInspectionHive = brGetNearestInspectionHive(player)
    end

    if brInspectionHive ~= previousHive then
        brResetInspectionHoldState()
    end

    local isActive = brInspectionHive ~= nil and not brIsInspectionDialogOpen()
    g_inputBinding:setActionEventActive(brInspectionActionId, isActive)

    if isActive then
        g_inputBinding:setActionEventText(brInspectionActionId, 'Hold: Inspect Hive')
    else
        brResetInspectionHoldState()
    end
end

local function brGetInspectionInputAction()
    if InputAction ~= nil and InputAction.BR_HIVE_INSPECTION ~= nil then
        return InputAction.BR_HIVE_INSPECTION, 'BR_HIVE_INSPECTION'
    end

    -- Fallback to the vanilla interaction key if the custom action is not parsed.
    -- This still gives the R prompt and lets us test the hive detection/dialog flow.
    if InputAction ~= nil and InputAction.ACTIVATE_OBJECT ~= nil then
        return InputAction.ACTIVATE_OBJECT, 'ACTIVATE_OBJECT fallback'
    end

    return nil, 'none'
end

local function brOnPlayerInputComponentRegisterActionEvents(inputComponent)
    if inputComponent == nil or inputComponent.player == nil or not inputComponent.player.isOwner then
        return
    end

    local action, actionName = brGetInspectionInputAction()
    if action == nil then
        brLog('no usable input action found')
        return
    end

    g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)

    local _, eventId = g_inputBinding:registerActionEvent(
        action,
        inputComponent,
        brOnInputHiveInspection,
        true,
        true,
        true,
        true,
        nil,
        true
    )

    brInspectionActionId = eventId
    brLog('action registered action=' .. tostring(actionName) .. ' eventId=' .. tostring(eventId))

    if brInspectionActionId ~= nil then
        g_inputBinding:setActionEventActive(brInspectionActionId, false)
        g_inputBinding:setActionEventTextPriority(brInspectionActionId, GS_PRIO_NORMAL)
    end

    g_inputBinding:endActionEventsModification()
end

local function brConsoleInspectHive()
    local player = brGetCurrentPlayer()
    local hive = brGetNearestInspectionHive(player)
    brLog('brHiveInspect player=' .. tostring(player) .. ' hive=' .. tostring(hive))
    if hive ~= nil and BR_HiveInspectionDialog ~= nil then
        BR_HiveInspectionDialog.show(hive)
        return 'BeesRevamp opened hive inspection dialog'
    end
    return 'BeesRevamp found no inspectable hive nearby'
end

local function brConsoleHiveScan()
    local mission = g_currentMission
    local player = brGetCurrentPlayer()
    local system = mission ~= nil and mission.beehiveSystem or nil
    local hives = system ~= nil and system.beehivesSortedRadius or nil
    local count = hives ~= nil and #hives or 0
    brLog('brHiveScan hives=' .. tostring(count) .. ' player=' .. tostring(player))
    if hives ~= nil then
        for i = 1, math.min(count, 30) do
            local hive = hives[i]
            local distance = brGetHiveDistanceToPlayer(hive, player)
            local canInspect = brCanInspectHive(hive, player)
            brLog(string.format('hive[%d]=%s dist=%s canInspect=%s hasBee=%s hasCare=%s hasExt=%s rootNode=%s', i, tostring(hive), tostring(distance), tostring(canInspect), tostring(hive ~= nil and hive.spec_beehive ~= nil), tostring(hive ~= nil and hive.spec_beecare ~= nil), tostring(hive ~= nil and hive.spec_beehiveextended ~= nil), tostring(brGetHiveRootNode(hive))))
        end
    end
    return 'BeesRevamp hive scan written to log'
end

_G.brHiveInspect = brConsoleInspectHive
_G.brHiveScan = brConsoleHiveScan

function BR_HiveInspectionInput:consoleCommandHiveInspect()
    return brConsoleInspectHive()
end

function BR_HiveInspectionInput:consoleCommandHiveScan()
    return brConsoleHiveScan()
end

function BR_HiveInspectionInput:init()
    brLog('init called')
    if self.isInitialized then
        brLog('already initialized')
        return
    end
    self.isInitialized = true

    if not self.hooksInstalled then
        self.hooksInstalled = true
        PlayerInputComponent.update = Utils.overwrittenFunction(PlayerInputComponent.update, brOnPlayerInputComponentUpdate)
        PlayerInputComponent.registerActionEvents = Utils.appendedFunction(PlayerInputComponent.registerActionEvents, brOnPlayerInputComponentRegisterActionEvents)
        brLog('player input hooks installed')
    end
end

-- Register immediately as well as during mission load. Some FS builds/mod load orders
-- only expose console commands if they are added while the source file is loaded.
if addConsoleCommand ~= nil then
    addConsoleCommand('brHiveInspect', 'Open BeesRevamp hive inspection dialog for nearest hive', 'brHiveInspect', _G)
    addConsoleCommand('brHiveScan', 'Debug BeesRevamp hive inspection target detection', 'brHiveScan', _G)
    brLog('console commands registered globally')
else
    brLog('addConsoleCommand is nil at source load')
end
