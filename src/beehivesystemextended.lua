---
-- BeehiveSystemExtended
--
-- The BeehiveSystemExtended class derives from the original BeehiveSystem class
-- and adds some special cases to it.
--
-- Copyright (c) Peppie84, 2024
-- https://github.com/Peppie84/FS25_BeesRevamp
--
BeehiveSystemExtended = {
    MOD_NAME = g_currentModName or 'unknown',
    MAX_HONEY_PER_MONTH_INDEXED_BY_PERIOD = { 0.75, 1.50, 2.25, 3.20, 2.80, 2.00, 1.50, 0.75, -0.5, -0.5, -0.5, -0.5 },
    DEBUG = false,
    LAST_FRUIT_INDEX_BY_FIELDID = {},
    OVER_POPULATION_INDEX_BY_FIELDID = {},
    HIGH_BEE_POPULATION_FIX = 1.25
}

local BeehiveSystemExtended_mt = Class(BeehiveSystemExtended, BeehiveSystem)

---Create a new BeehiveSystemExtended class
---@param mission table current loaded mission table
---@param customMt any custom metatable class
---@return table (BeehiveSystemExtended) returns BeehiveSystemExtended instance
function BeehiveSystemExtended.new(mission, beehivePatchMeta, customMt)
    local self = BeehiveSystemExtended:superClass().new(mission, customMt or BeehiveSystemExtended_mt)

    self.beehiveInfluenceFactorAtHiveCount = 0
    self.fieldUpdateCache = FruitType.UNKNOWN
    self.lastFieldUpdateCache = 0
    self.beehivePatchMeta = beehivePatchMeta

    g_brUtils:logDebug('BeehiveSystemExtended.new')
    self:addFieldInfoExtension()

    -- Debug commands added by ChatGPT compatibility patch
    addConsoleCommand('brBeeDebug', 'BeesRevamp: dump hive, spawner and state information', 'consoleCommandBeeDebug', self)
    addConsoleCommand('brBeeDebugField', 'BeesRevamp: dump bee influence information for the field at the player position', 'consoleCommandBeeDebugField', self)
    addConsoleCommand('brBeeForceEconomic', 'BeesRevamp: force all loaded hives to Economic Hive state for testing', 'consoleCommandBeeForceEconomic', self)
    addConsoleCommand('brBeeDebugFieldInfo', 'BeesRevamp: toggle debug logging for field info bee bonus calculations', 'consoleCommandBeeDebugFieldInfo', self)

    return self
end

---TODO
function BeehiveSystemExtended:updateState()
    local environment = self.mission.environment
    self.isFxActive = true
    self.isProductionActive = true

    local isRaining = environment.weather:getIsRaining()
    local isTemperaturToFly = environment.weather:getCurrentTemperature() > 10
    local isSunOn = environment.isSunOn
    local isWinterSeason = environment.currentSeason == Season.WINTER

    if isRaining or not isTemperaturToFly or not isSunOn or isWinterSeason then
        self.isFxActive = false
    end

    if isWinterSeason then
        self.isProductionActive = false
    end
end

---Get the growth factor of the hive, based on the given month
---@param period number
---@return number
function BeehiveSystemExtended:getGrowthFactor(period)
    return self.MAX_HONEY_PER_MONTH_INDEXED_BY_PERIOD[period]
end

---Delete the class
function BeehiveSystemExtended:delete()
    removeConsoleCommand('brBeeDebug')
    removeConsoleCommand('brBeeDebugField')
    removeConsoleCommand('brBeeForceEconomic')
    BeehiveSystemExtended:superClass().delete(self)
end

---TODO
---@param farmId number
function BeehiveSystemExtended:updateBeehivesOutput(farmId)
    if self.mission:getIsServer() then
        for i = 1, #self.beehivesSortedRadius do
            local beehive = self.beehivesSortedRadius[i]
            local beehiveOwner = beehive:getOwnerFarmId()

            if farmId == nil or farmId == beehiveOwner then
                local palletSpawner = BeehiveSystemExtended:superClass().getFarmBeehivePalletSpawner(self, beehiveOwner)

                if palletSpawner ~= nil then
                    local honeyAmount = beehive:getHoneyAmountToSpawn()
                    g_brUtils:logDebug('- honeyAmount: %s', tostring(honeyAmount))

                    palletSpawner:addFillLevel(honeyAmount)
                end
            end
        end
    end
end

---TODO
---@param wx number
---@param wz number
---@return number
function BeehiveSystemExtended:getBeehiveInfluenceFactorAt(wx, wz)
    local beehiveCount = self:getBeehiveInfluenceHiveCountAt(wx, wz)
    local farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(wx, wz)

    if farmlandId == nil then
        return 0
    end

    local farmLand = g_farmlandManager:getFarmlandById(farmlandId)
    if farmLand == nil then
        return 0
    end

    local lastFruitIndex = self.LAST_FRUIT_INDEX_BY_FIELDID[farmlandId]
    if lastFruitIndex == nil then
        return 0
    end

    -- FS25/farmland compatibility:
    -- Some maps/builds expose totalFieldArea in square metres/pixels, while areaInHa
    -- is already hectares.  The bee formula expects hectares.  Prefer areaInHa and
    -- convert suspiciously large totalFieldArea values down to hectares.
    local totalFieldArea = farmLand.areaInHa or farmLand.totalFieldArea
    if totalFieldArea == nil then
        return 0
    end

    if totalFieldArea > 1000 then
        totalFieldArea = totalFieldArea / 10000
    end

    if totalFieldArea <= 0 then
        return 0
    end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(lastFruitIndex)
    if fruitType == nil then
        return 0
    end

    local fruitYieldBonus = self:getYieldBonusByFruitName(fruitType.name)
    if fruitYieldBonus.yieldBonus == 0 then
        return 0
    end

    local beeYieldBonus = (beehiveCount / (totalFieldArea * fruitYieldBonus.hivesPerHa))
    local beeYieldBonusFixer = 0

    -- some over populate fix at 125%
    if beeYieldBonus > BeehiveSystemExtended.HIGH_BEE_POPULATION_FIX then
        beeYieldBonusFixer = (beeYieldBonus - BeehiveSystemExtended.HIGH_BEE_POPULATION_FIX)
    end

    self.OVER_POPULATION_INDEX_BY_FIELDID[farmlandId] = beeYieldBonusFixer

    -- Compatibility/realism patch:
    -- The original mod subtracted the overpopulation amount from the bonus.
    -- With FS25 hive placeables containing multiple hive units, even one or two
    -- placed hive objects can exceed the ideal hives/ha and drive the displayed
    -- Bee Bonus back to 0%.  Overpopulation should cap the benefit rather than
    -- remove it completely, so we return a simple 0..1 saturation factor.
    return math.min(beeYieldBonus, 1)
end

---TODO
---@param wx number
---@param wz number
---@return number
function BeehiveSystemExtended:getBeehiveInfluenceHiveCountAt(wx, wz)
    local beehiveInfluenceCounter = 0

    for i = 1, #self.beehivesSortedRadius do
        local beehive = self.beehivesSortedRadius[i]
        if beehive:getBeehiveInfluenceFactor(wx, wz) > 0 and beehive:getBeePopulation() > 0 and beehive:getHiveState() == BeeCare.STATES.ECONOMIC_HIVE then
            beehiveInfluenceCounter = beehiveInfluenceCounter + beehive:getBeehiveHiveCount()
        end
    end

    return beehiveInfluenceCounter
end

-------------------------------------------------------------------------------

function BeehiveSystemExtended:addFieldInfoExtension()
    g_brUtils:logDebug('Utils.appendedFunction %s', 'PlayerHUDUpdater.fieldAddField')
    PlayerHUDUpdater.fieldAddFarmland = Utils.appendedFunction(
        PlayerHUDUpdater.fieldAddFarmland,
        BeehiveSystemExtended.fieldAddField
    )
end

function BeehiveSystemExtended:onFieldDataUpdateFinished(data)
    g_brUtils:logDebug('BeehiveSystemExtended:onFieldDataUpdateFinished')
    self.requestedFieldData = true
end

---BeehiveSystemExtended:updateFieldInfoOverPopulation
---@param fieldInfo any
---@param startWorldX any
---@param startWorldZ any
---@param widthWorldX any
---@param widthWorldZ any
---@param heightWorldX any
---@param heightWorldZ any
---@param isColorBlindMode any
function BeehiveSystemExtended:updateFieldInfoOverPopulation(fieldInfo, startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ, isColorBlindMode)
    if g_farmlandManager:getOwnerIdAtWorldPosition(startWorldX, startWorldZ) ~= self.mission.player.farmId then
        return nil
    end

    local player = g_currentMission.player

    local farmLand = g_farmlandManager:getFarmlandAtWorldPosition(
        player.baseInformation.lastPositionX,
        player.baseInformation.lastPositionZ
    )

    if farmLand == nil then
        return nil
    end

    local fruitTypeIndex = self.fieldUpdateCache
    if fruitTypeIndex == nil or fruitTypeIndex == FruitType.UNKNOWN then
        return nil
    end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)

    if not self:hasFruitTypeYieldBonus(fruitType.name) then
        return nil
    end

    local beeOverPopulateFixer = g_currentMission.beehiveSystem.OVER_POPULATION_INDEX_BY_FIELDID[farmLand.id]

    if beeOverPopulateFixer == nil or beeOverPopulateFixer <= 0 then
        return nil
    end

    local value = g_brUtils:getModText('beesrevamp_beehivesystemextended_info_bee_bonus_is_shrinking')

    -- value, color, additionalValue
    return value, KeyValueInfoHUDBox.COLOR.TEXT_HIGHLIGHT, nil
end

---BeehiveSystemExtended:updateFieldInfoDisplayBeeBonus
---@param fieldInfo any
---@param startWorldX any
---@param startWorldZ any
---@param widthWorldX any
---@param widthWorldZ any
---@param heightWorldX any
---@param heightWorldZ any
---@param isColorBlindMode any
function BeehiveSystemExtended:updateFieldInfoDisplayBeeBonus(fieldInfo, startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ, isColorBlindMode)
    local player = self.mission.player
    if g_farmlandManager:getOwnerIdAtWorldPosition(startWorldX, startWorldZ) ~= player.farmId then
        return nil
    end

    if (g_currentMission.environment.timeUpdateTime-self.lastFieldUpdateCache) > 1000 then
        return nil
    end

    local fruitTypeIndex = self.fieldUpdateCache
    if fruitTypeIndex == nil or fruitTypeIndex == FruitType.UNKNOWN then
        return nil
    end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    local fruitYieldBonus = self:getYieldBonusByFruitName(fruitType.name)

    local beeHiveYieldBonusAtPlayerPosition = g_currentMission.beehiveSystem:getBeehiveInfluenceFactorAt(
        player.baseInformation.lastPositionX,
        player.baseInformation.lastPositionZ
    ) * fruitType.beeYieldBonusPercentage

    fieldInfo.beeHiveYieldBonusAtPlayerPosition = beeHiveYieldBonusAtPlayerPosition
    fieldInfo.beeYieldBonus = fruitYieldBonus

    local value = string.format(
        '+ %s %%',
        g_i18n:formatNumber(beeHiveYieldBonusAtPlayerPosition * 100, 2)
    )

    -- value, color, additionalValue
    return value, KeyValueInfoHUDBox.COLOR.TEXT_DEFAULT, nil
end

---BeehiveSystemExtended:updateFieldInfoDisplayInfluenced
---@param fieldInfo any
---@param startWorldX any
---@param startWorldZ any
---@param widthWorldX any
---@param widthWorldZ any
---@param heightWorldX any
---@param heightWorldZ any
---@param isColorBlindMode any
function BeehiveSystemExtended:updateFieldInfoDisplayInfluenced(fieldInfo, startWorldX, startWorldZ, widthWorldX, widthWorldZ,
                                                       heightWorldX, heightWorldZ, isColorBlindMode)
    if g_farmlandManager:getOwnerIdAtWorldPosition(startWorldX, startWorldZ) ~= self.mission.player.farmId then
        return nil
    end

    local beeHiveInfluencedHiveCount = g_currentMission.beehiveSystem:getBeehiveInfluenceHiveCountAt(
        startWorldX,
        startWorldZ
    )
    fieldInfo.beeHiveInfluencedHiveCount = beeHiveInfluencedHiveCount

    local labelInfluencedHiveSingular = g_brUtils:getModText('beesrevamp_beehivesystemextended_info_influenced_hive_singular')
    local labelInfluencedHivePlural = g_brUtils:getModText('beesrevamp_beehivesystemextended_info_influenced_hive_plural')
    local labelInfluencedHives = labelInfluencedHiveSingular

    if beeHiveInfluencedHiveCount ~= 1 then
        labelInfluencedHives = labelInfluencedHivePlural
    end

    local value = string.format(
        '%s ' .. labelInfluencedHives,
        g_i18n:formatNumber(beeHiveInfluencedHiveCount, 0)
    )

    return value, KeyValueInfoHUDBox.COLOR.TEXT_DEFAULT, nil
end

---BeehiveSystemExtended:fieldAddFruit
---@param data table
---@param box table InfoBox
function BeehiveSystemExtended:fieldAddField(data, box)
    local player = g_currentMission.hud.player
    local positionX, positionY, positionZ = player:getPosition()

    if g_farmlandManager:getOwnerIdAtWorldPosition(positionX, positionZ) ~= player.farmId then
        return
    end

    local beehiveSystemExtended = g_currentMission.beehiveSystem
    local fruitTypeIndex = data.lastFruitTypeIndex
    if fruitTypeIndex == nil then
        return
    end

    local farmLand = g_farmlandManager:getFarmlandAtWorldPosition(positionX, positionZ)
    if farmLand == nil then
        return
    end

    beehiveSystemExtended.LAST_FRUIT_INDEX_BY_FIELDID[farmLand.id] = fruitTypeIndex

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitType == nil or fruitType.beeYieldBonusPercentage == nil then
        return
    end
    local beeHiveYieldBonusAtPlayerPosition = beehiveSystemExtended:getBeehiveInfluenceFactorAt(
        positionX,
        positionZ
    ) * fruitType.beeYieldBonusPercentage

    local beeHiveInfluencedHiveCount = beehiveSystemExtended:getBeehiveInfluenceHiveCountAt(
        positionX,
        positionZ
    )

    if beehiveSystemExtended.DEBUG_FIELD_INFO == nil then
        beehiveSystemExtended.DEBUG_FIELD_INFO = false
    end
    if beehiveSystemExtended.DEBUG_FIELD_INFO then
        local areaHa = farmLand.areaInHa or farmLand.totalFieldArea
        local rawTotal = farmLand.totalFieldArea
        local influenceFactor = beehiveSystemExtended:getBeehiveInfluenceFactorAt(positionX, positionZ)
        log(string.format(
            'BeesRevamp DEBUG FIELD: farmland=%s fruit=%s beeCount=%s areaInHa=%s totalFieldArea=%s influenceFactor=%s fruitBeePct=%s displayedBonusPct=%s',
            tostring(farmLand.id),
            tostring(fruitType.name),
            tostring(beeHiveInfluencedHiveCount),
            tostring(areaHa),
            tostring(rawTotal),
            tostring(influenceFactor),
            tostring(fruitType.beeYieldBonusPercentage),
            tostring(beeHiveYieldBonusAtPlayerPosition * 100)
        ))
    end

    local labelInfluencedByBees = g_brUtils:getModText('beesrevamp_beehivesystemextended_info_influenced_by_bees')
    local labelBeeBonus = g_brUtils:getModText('beesrevamp_beehivesystemextended_info_bee_bonus')
    local labelInfluencedHiveSingular = g_brUtils:getModText('beesrevamp_beehivesystemextended_info_influenced_hive_singular')
    local labelInfluencedHivePlural = g_brUtils:getModText('beesrevamp_beehivesystemextended_info_influenced_hive_plural')
    local labelInfluencedHives = labelInfluencedHiveSingular

    if beeHiveInfluencedHiveCount ~= 1 then
        labelInfluencedHives = labelInfluencedHivePlural
    end

    local beeOverPopulateFixer = beehiveSystemExtended.OVER_POPULATION_INDEX_BY_FIELDID[farmLand.id]

    box:addLine(labelInfluencedByBees, string.format('%s ' .. labelInfluencedHives, g_i18n:formatNumber(beeHiveInfluencedHiveCount, 0)))
    box:addLine(labelBeeBonus, string.format('+ %s %%', g_i18n:formatNumber(beeHiveYieldBonusAtPlayerPosition * 100, 2)))

    if beeOverPopulateFixer ~= nil and beehiveSystemExtended:hasFruitTypeYieldBonus(fruitType.name) and beeOverPopulateFixer > 0 then
        box:addLine(g_brUtils:getModText('beesrevamp_beehivesystemextended_info_title_bee_bonus_is_shrinking') .. ' ' .. g_brUtils:getModText('beesrevamp_beehivesystemextended_info_bee_bonus_is_shrinking'), '', true)
    end
end

---Returns the PATCHLIST_YIELD_BONUS table entry for the given fruitName. A 0-value table is returned when no entry is found.
---@param fruitName string Fruit name
---@return table {yieldBonus, hivesPerHa}
function BeehiveSystemExtended:getYieldBonusByFruitName(fruitName)
    local defaultYieldBonus = { ['yieldBonus'] = 0, ['hivesPerHa'] = 0 }

    local fruitYieldBonus = self.beehivePatchMeta.PATCHLIST_YIELD_BONUS[fruitName:upper()]
    if fruitYieldBonus == nil then
        return defaultYieldBonus
    end

    return fruitYieldBonus
end

---BeehiveSystemExtended:hasFruitTypeYieldBonus
---@param fruitName string Fruit name
function BeehiveSystemExtended:hasFruitTypeYieldBonus(fruitName)
    return (self.beehivePatchMeta.PATCHLIST_YIELD_BONUS[fruitName:upper()] ~= nil)
end


-------------------------------------------------------------------------------
-- Debug helpers added by ChatGPT compatibility patch

function BeehiveSystemExtended:getDebugStateName(state)
    if state == BeeCare.STATES.YOUNG_HIVE then
        return 'YOUNG_HIVE'
    elseif state == BeeCare.STATES.ECONOMIC_HIVE then
        return 'ECONOMIC_HIVE'
    elseif state == BeeCare.STATES.DEAD then
        return 'DEAD'
    end

    return tostring(state)
end

function BeehiveSystemExtended:debugLog(messageFormat, ...)
    log(string.format('BeesRevamp DEBUG: ' .. messageFormat, ...))
end

function BeehiveSystemExtended:getDebugPlayerPosition()
    local player = g_currentMission ~= nil and g_currentMission.player or nil
    if player == nil then
        return nil, nil, nil
    end

    -- In FS25 1.19 player:getPosition() can exist but still return nil in some
    -- console-command contexts.  Try it, then fall back to baseInformation.
    if player.getPosition ~= nil then
        local x, y, z = player:getPosition()
        if x ~= nil and z ~= nil then
            return x, y, z
        end
    end

    if player.baseInformation ~= nil then
        local x = player.baseInformation.lastPositionX
        local z = player.baseInformation.lastPositionZ
        if x ~= nil and z ~= nil then
            return x, 0, z
        end
    end

    -- Final fallback: use the controlled vehicle if available.
    if g_currentMission.controlledVehicle ~= nil then
        local x, y, z = getWorldTranslation(g_currentMission.controlledVehicle.rootNode)
        if x ~= nil and z ~= nil then
            return x, y, z
        end
    end

    return nil, nil, nil
end


function BeehiveSystemExtended:consoleCommandBeeDebugFieldInfo()
    self.DEBUG_FIELD_INFO = not self.DEBUG_FIELD_INFO
    log(string.format('BeesRevamp DEBUG FIELD: field info debug is now %s', tostring(self.DEBUG_FIELD_INFO)))
    return string.format('BeesRevamp field info debug %s', self.DEBUG_FIELD_INFO and 'enabled' or 'disabled')
end

function BeehiveSystemExtended:consoleCommandBeeDebug()
    self:debugLog('---------------- brBeeDebug start ----------------')
    self:debugLog('mission=%s isServer=%s isClient=%s', tostring(self.mission), tostring(self.mission ~= nil and self.mission:getIsServer()), tostring(self.mission ~= nil and self.mission:getIsClient()))
    self:debugLog('system isFxActive=%s isProductionActive=%s currentSeason=%s currentPeriod=%s currentYear=%s currentHour=%s isSunOn=%s temp=%s raining=%s',
        tostring(self.isFxActive),
        tostring(self.isProductionActive),
        tostring(g_currentMission.environment.currentSeason),
        tostring(g_currentMission.environment.currentPeriod),
        tostring(g_currentMission.environment.currentYear),
        tostring(g_currentMission.environment.currentHour),
        tostring(g_currentMission.environment.isSunOn),
        tostring(g_currentMission.environment.weather:getCurrentTemperature()),
        tostring(g_currentMission.environment.weather:getIsRaining())
    )
    self:debugLog('beehivesSortedRadius count=%s beehivePalletSpawners count=%s', tostring(#self.beehivesSortedRadius), tostring(#self.beehivePalletSpawners))

    for i = 1, #self.beehivePalletSpawners do
        local spawner = self.beehivePalletSpawners[i]
        local sx, sy, sz = nil, nil, nil
        if spawner ~= nil and spawner.rootNode ~= nil then
            sx, sy, sz = getWorldTranslation(spawner.rootNode)
        elseif spawner ~= nil and spawner.node ~= nil then
            sx, sy, sz = getWorldTranslation(spawner.node)
        end
        self:debugLog('spawner[%s] object=%s nodePos=(%s,%s,%s)', tostring(i), tostring(spawner), tostring(sx), tostring(sy), tostring(sz))
    end

    local px, py, pz = self:getDebugPlayerPosition()
    self:debugLog('playerPos=(%s,%s,%s) farmId=%s', tostring(px), tostring(py), tostring(pz), tostring(g_currentMission.player ~= nil and g_currentMission.player.farmId))

    for i = 1, #self.beehivesSortedRadius do
        local hive = self.beehivesSortedRadius[i]
        local wx, wy, wz = nil, nil, nil
        if hive ~= nil and hive.rootNode ~= nil then
            wx, wy, wz = getWorldTranslation(hive.rootNode)
        end

        local specBee = hive ~= nil and hive.spec_beehive or nil
        local specCare = hive ~= nil and hive.spec_beecare or nil
        local specExt = hive ~= nil and hive.spec_beehiveextended or nil

        local state = specCare ~= nil and specCare.state or nil
        local bees = specCare ~= nil and specCare.bees or nil
        local placedDay = specCare ~= nil and specCare.placedDay or nil
        local lastOxucare = specCare ~= nil and specCare.lastOxucare or nil
        local swarmed = specCare ~= nil and specCare.swarmed or nil
        local swarmPressure = specCare ~= nil and specCare.swarmPressure or nil
        local nectar = specExt ~= nil and specExt.nectar or nil
        local hiveCount = specExt ~= nil and specExt.hiveCount or nil
        local radius = specBee ~= nil and specBee.actionRadius or nil
        local radiusSquared = specBee ~= nil and specBee.actionRadiusSquared or nil
        local hiveFx = specBee ~= nil and specBee.isFxActive or nil
        local hiveProd = specBee ~= nil and specBee.isProductionActive or nil
        local owner = hive ~= nil and hive.getOwnerFarmId ~= nil and hive:getOwnerFarmId() or nil

        local distance = nil
        local influence = nil
        if px ~= nil and pz ~= nil and hive ~= nil and hive.getBeehiveInfluenceFactor ~= nil then
            influence = hive:getBeehiveInfluenceFactor(px, pz)
            if wx ~= nil and wz ~= nil then
                distance = MathUtil.vector2Length(px - wx, pz - wz)
            end
        end

        local countedAsEco = false
        if influence ~= nil and specCare ~= nil and hive ~= nil and hive.getBeePopulation ~= nil then
            countedAsEco = influence > 0 and hive:getBeePopulation() > 0 and specCare.state == BeeCare.STATES.ECONOMIC_HIVE
        end

        self:debugLog('hive[%s] object=%s owner=%s pos=(%s,%s,%s) distanceToPlayer=%s influenceAtPlayer=%s countedAsEco=%s', tostring(i), tostring(hive), tostring(owner), tostring(wx), tostring(wy), tostring(wz), tostring(distance), tostring(influence), tostring(countedAsEco))
        self:debugLog('hive[%s] state=%s bees=%s hiveCount=%s nectar=%s placedDay=%s lastOxucare=%s swarmed=%s swarmPressure=%s', tostring(i), self:getDebugStateName(state), tostring(bees), tostring(hiveCount), tostring(nectar), tostring(placedDay), tostring(lastOxucare), tostring(swarmed), tostring(swarmPressure))
        self:debugLog('hive[%s] radius=%s radiusSquared=%s hiveFxActive=%s hiveProductionActive=%s hasBeeSpec=%s hasBeeCareSpec=%s hasBeeExtSpec=%s', tostring(i), tostring(radius), tostring(radiusSquared), tostring(hiveFx), tostring(hiveProd), tostring(specBee ~= nil), tostring(specCare ~= nil), tostring(specExt ~= nil))
    end

    self:debugLog('---------------- brBeeDebug end ----------------')
    return 'BeesRevamp debug written to log.txt'
end

function BeehiveSystemExtended:consoleCommandBeeDebugField()
    local px, py, pz = self:getDebugPlayerPosition()
    self:debugLog('---------------- brBeeDebugField start ----------------')
    self:debugLog('playerPos=(%s,%s,%s)', tostring(px), tostring(py), tostring(pz))

    if px == nil or pz == nil then
        self:debugLog('No player position available')
        return 'BeesRevamp field debug failed: no player position'
    end

    local farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(px, pz)
    local farmLand = nil
    if farmlandId ~= nil then
        farmLand = g_farmlandManager:getFarmlandById(farmlandId)
    end

    local lastFruitIndex = farmlandId ~= nil and self.LAST_FRUIT_INDEX_BY_FIELDID[farmlandId] or nil
    local fruitType = lastFruitIndex ~= nil and g_fruitTypeManager:getFruitTypeByIndex(lastFruitIndex) or nil
    local fruitYieldBonus = fruitType ~= nil and self:getYieldBonusByFruitName(fruitType.name) or nil
    local hiveCount = self:getBeehiveInfluenceHiveCountAt(px, pz)
    local influence = self:getBeehiveInfluenceFactorAt(px, pz)

    self:debugLog('farmlandId=%s owner=%s areaInHa=%s totalFieldArea=%s', tostring(farmlandId), tostring(farmLand ~= nil and farmLand.farmId), tostring(farmLand ~= nil and farmLand.areaInHa), tostring(farmLand ~= nil and farmLand.totalFieldArea))
    self:debugLog('lastFruitIndex=%s fruitName=%s fruitBeeYieldBonusPercentage=%s patchYieldBonus=%s patchHivesPerHa=%s', tostring(lastFruitIndex), tostring(fruitType ~= nil and fruitType.name), tostring(fruitType ~= nil and fruitType.beeYieldBonusPercentage), tostring(fruitYieldBonus ~= nil and fruitYieldBonus.yieldBonus), tostring(fruitYieldBonus ~= nil and fruitYieldBonus.hivesPerHa))
    self:debugLog('influenceHiveCount=%s influenceFactor=%s finalCropBonusIfPatched=%s', tostring(hiveCount), tostring(influence), tostring(fruitType ~= nil and fruitType.beeYieldBonusPercentage ~= nil and influence * fruitType.beeYieldBonusPercentage or nil))
    self:debugLog('---------------- brBeeDebugField end ----------------')

    return 'BeesRevamp field debug written to log.txt'
end

function BeehiveSystemExtended:consoleCommandBeeForceEconomic()
    local changed = 0
    for i = 1, #self.beehivesSortedRadius do
        local hive = self.beehivesSortedRadius[i]
        if hive ~= nil and hive.spec_beecare ~= nil then
            hive.spec_beecare.state = BeeCare.STATES.ECONOMIC_HIVE
            hive.spec_beecare.bees = math.max(hive.spec_beecare.bees or 0, BeeCare.DEFAULT_BEE_VALUE)
            hive.spec_beecare.swarmed = false
            hive.spec_beecare.swarmPressure = false
            if hive.spec_beecare.updateInfoTables ~= nil then
                hive.spec_beecare:updateInfoTables()
            end
            if hive.raiseDirtyFlags ~= nil and hive.spec_beecare.dirtyFlag ~= nil then
                hive:raiseDirtyFlags(hive.spec_beecare.dirtyFlag)
            end
            if hive.updateBeehiveState ~= nil then
                hive:updateBeehiveState()
            end
            changed = changed + 1
        end
    end

    self:debugLog('brBeeForceEconomic changed %s hives to Economic Hive state', tostring(changed))
    return string.format('BeesRevamp forced %s hives to Economic Hive state', tostring(changed))
end
