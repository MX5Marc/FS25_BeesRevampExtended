BR_HiveInspectionDialog = {}
BR_HiveInspectionDialog.INSTANCE = nil

local BR_HiveInspectionDialog_mt = Class(BR_HiveInspectionDialog, MessageDialog)
local modDirectory = g_currentModDirectory

local function brLog(text)
    print("BeesRevamp HIVE INSPECTION DIALOG: " .. tostring(text))
end

local function fmtBool(value)
    return value and "Yes" or "No"
end


local function setMouseCursorVisible(visible)
    if g_inputBinding ~= nil and g_inputBinding.setShowMouseCursor ~= nil then
        pcall(g_inputBinding.setShowMouseCursor, g_inputBinding, visible)
    end

    if g_inputBinding ~= nil and g_inputBinding.setMouseCursorVisible ~= nil then
        pcall(g_inputBinding.setMouseCursorVisible, g_inputBinding, visible)
    end
end

local function safeSetText(element, text)
    if element ~= nil and element.setText ~= nil then
        element:setText(tostring(text or ""))
        return true
    end
    return false
end


local function splitInspectionText(text)
    local lines = {}
    for line in tostring(text or ""):gmatch("([^\n]*)\n?") do
        if line == nil then
            break
        end
        table.insert(lines, line)
        if #lines > 40 then
            break
        end
    end

    local left = {}
    local right = {}
    local note = {}

    local target = left
    for _, line in ipairs(lines) do
        if line == "" then
            target = note
        elseif line:sub(1, 11) == "Conditions:" then
            table.insert(note, line)
            target = note
        elseif line:find("recommended") ~= nil or line:find("young") ~= nil or line:find("dead") ~= nil then
            table.insert(note, line)
        elseif #left < 7 then
            table.insert(left, line)
        else
            table.insert(right, line)
        end
    end

    return table.concat(left, "\n"), table.concat(right, "\n"), table.concat(note, "\n")
end

local function getStateName(state)
    if BeeCare ~= nil then
        if state == BeeCare.STATES.YOUNG_HIVE then
            return "Young colony"
        elseif state == BeeCare.STATES.ECONOMIC_HIVE then
            return "Economic colony"
        elseif state == BeeCare.STATES.DEAD then
            return "Dead"
        end
    end
    return "Unknown"
end

local function getNectarFlow(hive)
    if g_currentMission == nil or g_currentMission.environment == nil then
        return "Unknown"
    end

    local env = g_currentMission.environment
    local weather = env.weather
    local raining = weather ~= nil and weather:getIsRaining() or false
    local temp = weather ~= nil and weather:getCurrentTemperature() or nil
    local isWinter = env.currentSeason == Season.WINTER

    if isWinter then
        return "Stopped - winter"
    elseif raining then
        return "Stopped - raining"
    elseif temp ~= nil and temp <= 10 then
        return "Stopped - too cold"
    elseif not env.isSunOn then
        return "Stopped - night"
    end

    local specBeeHive = hive ~= nil and hive.spec_beehive or nil
    if specBeeHive ~= nil and not specBeeHive.isFxActive then
        return "Inactive"
    end

    return "Good"
end


local function getHiveAgeText(placedDay)
    if placedDay == nil or placedDay == "" then
        return "Unknown"
    end

    local placedYearString, placedPeriodString = string.match(tostring(placedDay), 'Y(%d+)M(%d+)D%d+')
    local placedYear = tonumber(placedYearString)
    local placedPeriod = tonumber(placedPeriodString)
    if placedYear == nil or placedPeriod == nil or g_currentMission == nil or g_currentMission.environment == nil then
        return tostring(placedDay)
    end

    local env = g_currentMission.environment
    local currentYear = env.currentYear or placedYear
    local currentPeriod = nil
    if g_brUtils ~= nil and g_brUtils.getStockPeriod ~= nil then
        currentPeriod = g_brUtils:getStockPeriod()
    end
    currentPeriod = currentPeriod or env.currentPeriod or placedPeriod

    local months = ((currentYear - placedYear) * 12) + (currentPeriod - placedPeriod)
    if months < 0 then
        months = 0
    end

    if months < 1 then
        return "Under 1 month"
    elseif months == 1 then
        return "1 month"
    elseif months < 12 then
        return string.format("%d months", months)
    end

    local years = math.floor(months / 12)
    local remMonths = months % 12
    if remMonths == 0 then
        if years == 1 then
            return "1 year"
        end
        return string.format("%d years", years)
    end

    if years == 1 then
        return string.format("1 year %d months", remMonths)
    end
    return string.format("%d years %d months", years, remMonths)
end

local function getSwarmControlNeeded(hive, swarmPressure)
    if hive ~= nil and hive.getSwarmControleNeeded ~= nil then
        local ok, result = pcall(hive.getSwarmControleNeeded, hive)
        if ok and result ~= nil then
            return result
        end
    end
    return swarmPressure == true
end

local function doHiveSwarmControl(hive)
    if hive == nil then
        return false, "No hive selected."
    end

    if not getSwarmControlNeeded(hive, hive.spec_beecare ~= nil and hive.spec_beecare.swarmPressure or false) then
        return false, "Swarm control is not currently needed."
    end

    if g_server ~= nil then
        if hive.doSwarmControl ~= nil then
            hive:doSwarmControl()
            return true, "Swarm control completed."
        end
        return false, "Hive has no swarm control function."
    end

    if g_client ~= nil and g_client.getServerConnection ~= nil and SwarmControlEvent ~= nil then
        g_client:getServerConnection():sendEvent(SwarmControlEvent.new(hive))
        return true, "Swarm control sent to server."
    end

    return false, "Swarm control unavailable."
end

local function buildInspectionText(hive)
    if hive == nil then
        return "No hive selected."
    end

    local specCare = hive.spec_beecare
    local specExt = hive.spec_beehiveextended
    local specBeeHive = hive.spec_beehive
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local weather = env ~= nil and env.weather or nil

    local state = specCare ~= nil and specCare.state or nil
    local rawBees = specCare ~= nil and (specCare.bees or 0) or 0
    local effectivePopulation = 0
    if hive.getBeePopulation ~= nil then
        effectivePopulation = hive:getBeePopulation() or 0
    end

    local maxBees = BeeCare ~= nil and BeeCare.DEFAULT_BEE_VALUE_MAX or 20000
    local healthPct = math.floor(math.clamp(rawBees / math.max(maxBees, 1), 0, 1) * 100 + 0.5)
    local hiveCount = specExt ~= nil and tostring(specExt.hiveCount or 1) or "1"
    local nectar = specExt ~= nil and tonumber(specExt.nectar or 0) or 0
    local radius = specBeeHive ~= nil and tonumber(specBeeHive.actionRadius or 0) or 0
    local productionActive = specBeeHive ~= nil and specBeeHive.isProductionActive or false
    local fxActive = specBeeHive ~= nil and specBeeHive.isFxActive or false
    local swarmPressure = specCare ~= nil and specCare.swarmPressure or false
    local swarmed = specCare ~= nil and specCare.swarmed or false
    local placedDay = specCare ~= nil and specCare.placedDay or ""
    local temp = weather ~= nil and weather:getCurrentTemperature() or nil
    local raining = weather ~= nil and weather:getIsRaining() or false
    local sunOn = env ~= nil and env.isSunOn or false

    local conditionText = "Conditions: "
    if temp ~= nil then
        conditionText = conditionText .. string.format("%s°C, ", g_i18n:formatNumber(temp, 1))
    end
    conditionText = conditionText .. string.format("raining %s, daylight %s", fmtBool(raining), fmtBool(sunOn))

    local recommendation = "No immediate action needed."
    if BeeCare ~= nil and state == BeeCare.STATES.YOUNG_HIVE then
        recommendation = "Young colony: honey production starts when mature."
    elseif BeeCare ~= nil and state == BeeCare.STATES.DEAD then
        recommendation = "Dead colony: no honey or crop benefit."
    elseif swarmPressure then
        recommendation = "Swarm control is recommended this month."
    end

    local swarmNeeded = getSwarmControlNeeded(hive, swarmPressure)
    local ageText = getHiveAgeText(placedDay)

    local lines = {}

    table.insert(lines, "BEE HIVE INSPECTION")
    table.insert(lines, "")
    table.insert(lines, string.format("State: %s", getStateName(state)))
    table.insert(lines, string.format("Health: %d%%", healthPct))
    table.insert(lines, string.format("Hive Age: %s", ageText))
    table.insert(lines, "")
    table.insert(lines, string.format("Population: %s bees", g_i18n:formatNumber(math.max(effectivePopulation, 0), 0)))
    table.insert(lines, string.format("Colonies: %s", hiveCount))
    table.insert(lines, "")
    table.insert(lines, string.format("Nectar: %s l", g_i18n:formatNumber(nectar, 2)))
    table.insert(lines, string.format("Nectar Flow: %s", getNectarFlow(hive)))
    table.insert(lines, "")
    table.insert(lines, string.format("Honey Production: %s", fmtBool(productionActive)))
    table.insert(lines, string.format("Flying Bees: %s", fmtBool(fxActive)))
    table.insert(lines, string.format("Swarm Risk: %s", swarmNeeded and "High" or "Low"))
    table.insert(lines, string.format("Swarmed This Year: %s", fmtBool(swarmed)))
    table.insert(lines, string.format("Action Radius: %sm", g_i18n:formatNumber(radius, 0)))
    table.insert(lines, "")
    table.insert(lines, conditionText)
    table.insert(lines, "")
    table.insert(lines, recommendation)

    return table.concat(lines, "\n")
end

function BR_HiveInspectionDialog.register()
    brLog("register")
    local dialog = BR_HiveInspectionDialog.new()
    g_gui:loadGui(modDirectory .. "gui/BR_HiveInspectionDialog.xml", "BR_HiveInspectionDialog", dialog)
    BR_HiveInspectionDialog.INSTANCE = dialog
end

function BR_HiveInspectionDialog.new(target, customMt)
    local dialog = MessageDialog.new(target, customMt or BR_HiveInspectionDialog_mt)
    dialog.hive = nil
    dialog.inspectionText = ""
    dialog.isDialogOpen = false
    dialog.mouseCursorForced = false
    return dialog
end

function BR_HiveInspectionDialog.show(hive)
    if hive == nil then
        brLog("show requested with nil hive")
        return
    end

    if BR_HiveInspectionDialog.INSTANCE == nil or BR_HiveInspectionDialog.INSTANCE.updateScreen == nil then
        BR_HiveInspectionDialog.register()
    end

    local dialog = BR_HiveInspectionDialog.INSTANCE
    if dialog == nil then
        brLog("failed to create dialog")
        return
    end

    if dialog.isDialogOpen then
        brLog("dialog already open, ignoring duplicate show")
        return
    end

    dialog.hive = hive
    dialog.inspectionText = buildInspectionText(hive)
    dialog:updateScreen()

    brLog("show custom dialog")
    dialog.isDialogOpen = true
    g_gui:showDialog("BR_HiveInspectionDialog")
end

function BR_HiveInspectionDialog:updateScreen()
    local text = self.inspectionText or buildInspectionText(self.hive)
    local okText = safeSetText(self.messageText, text) or safeSetText(self.messageTextElement, text) or safeSetText(self.dialogTextElement, text)

    if self.swarmControlButton ~= nil then
        local specCare = self.hive ~= nil and self.hive.spec_beecare or nil
        local needed = getSwarmControlNeeded(self.hive, specCare ~= nil and specCare.swarmPressure or false)
        if self.swarmControlButton.setVisible ~= nil then
            self.swarmControlButton:setVisible(needed)
        end
        if self.swarmControlButton.setDisabled ~= nil then
            self.swarmControlButton:setDisabled(not needed)
        end
    end

    if not okText then
        brLog("warning: dialog text element not bound")
    end
end

function BR_HiveInspectionDialog:onOpen()
    self.isDialogOpen = true
    self.mouseCursorForced = true
    setMouseCursorVisible(true)
    self:updateScreen()
end

function BR_HiveInspectionDialog:onClose()
    self.hive = nil
    self.inspectionText = ""
    if self.mouseCursorForced then
        setMouseCursorVisible(false)
        self.mouseCursorForced = false
    end
    self.isDialogOpen = false
    -- Do not call the superclass close here. The base dialog is already closing and
    -- calling it again can create a second/blank dialog or input context loop.
end

function BR_HiveInspectionDialog:onClickSwarmControl()
    local ok, message = doHiveSwarmControl(self.hive)
    brLog(message)
    if ok then
        self.inspectionText = buildInspectionText(self.hive)
        self:updateScreen()
    end
end

function BR_HiveInspectionDialog:onClickBack()
    self:close()
end
