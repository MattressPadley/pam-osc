-- pam-OSC. It allows to controll GrandMA3 with Midi Devices over Open Stage Controll and allows for Feedback from MA.
-- Copyright (C) 2024  xxpasixx
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>. 
local executorsToWatch = {}
local oldValues = {}
local oldButtonValues = {}
local oldColorValues = {}
local oldNameValues = {}
local oldMasterEnabledValues = {
    highlight = false,
    lowlight = false,
    solo = false,
    blind = false
}
local oldTimecodes = {}

local oscEntry = 2
local messageDelay = 0.01 -- 1ms delay between messages
local tick = 1/10 -- Main loop tick rate

-- Configure executors to watch
local function setupExecutorsToWatch()
    -- Page 1
    for i = 101, 122 do executorsToWatch[#executorsToWatch + 1] = i end
    for i = 191, 198 do executorsToWatch[#executorsToWatch + 1] = i end
    -- Page 2
    for i = 201, 222 do executorsToWatch[#executorsToWatch + 1] = i end
    for i = 291, 298 do executorsToWatch[#executorsToWatch + 1] = i end
    -- Page 3
    for i = 301, 322 do executorsToWatch[#executorsToWatch + 1] = i end
    -- Page 4
    for i = 401, 422 do executorsToWatch[#executorsToWatch + 1] = i end
end

-- Helper functions
local function getAppearanceColor(sequence)
    if not sequence or not sequence["APPEARANCE"] then
        return "255,255,255,255"
    end
    local app = sequence["APPEARANCE"]
    return string.format("%s,%s,%s,%s", 
        app['BACKR'], app['BACKG'], app['BACKB'], app['BACKALPHA'])
end

local function getName(sequence)
    if not sequence then return ";" end
    local cueName = sequence["CUENAME"] or ""
    return sequence["NAME"] .. ";" .. cueName
end

local function getMasterEnabled(masterName)
    return MasterPool()['Grand'][masterName]['FADERENABLED'] or false
end

-- Send a single OSC message with coroutine yield
local function sendOSC(path, value)
    Cmd(string.format('SendOSC %d "%s,%s"', oscEntry, path, value))
    coroutine.yield(messageDelay)
end

-- Helper function to map values to 0-127 range
local function mapTo127(value)
    -- Ensure value is between 0 and 1
    value = math.max(0, math.min(1, value))
    -- Map to 0-127 range
    return math.floor(value * 127 + 0.5)
end

-- Send a mass update for all executors on a page
local function sendMassUpdate(destPage)
    Printf("Sending mass update for page " .. destPage)
    
    -- Send master states
    for masterName, _ in pairs(oldMasterEnabledValues) do
        local currentValue = getMasterEnabled(masterName)
        sendOSC("/masterEnabled/" .. masterName, "i," .. (currentValue and 1 or 0))
        oldMasterEnabledValues[masterName] = currentValue
    end
    
    -- Get all executors for the page
    local executors = DataPool().Pages[destPage]:Children()
    
    -- Process each executor we're watching
    for _, execNumber in ipairs(executorsToWatch) do
        local faderValue = 0
        local buttonValue = false
        local colorValue = "0,0,0,0"
        local nameValue = ";"
        
        -- Find the executor
        for _, executor in pairs(executors) do
            if executor.No == execNumber then
                -- Get fader value
                local faderOptions = {
                    value = faderEnd,
                    token = "FaderMaster",
                    faderDisabled = false
                }
                faderValue = executor:GetFader(faderOptions)
                
                -- Get other values
                local obj = executor.Object
                if obj then
                    buttonValue = obj:HasActivePlayback()
                    colorValue = getAppearanceColor(obj)
                    nameValue = getName(obj)
                end
                
                break
            end
        end
        
        -- Get and normalize fader value
        if type(faderValue) == "number" then
            faderValue = math.max(0, math.min(1, faderValue))
        else
            faderValue = 0
        end
        
        -- Send all values for this executor
        local basePath = string.format("/Page%d", destPage)
        
        -- Always send in mass update with proper mapping
        local mappedValue = mapTo127(faderValue)
        sendOSC(basePath .. "/Fader" .. execNumber, "i," .. mappedValue)
        sendOSC(basePath .. "/Button" .. execNumber, "s," .. (buttonValue and "On" or "Off"))
        
        if GetVar(GlobalVars(), "sendColors") then
            sendOSC(basePath .. "/Color" .. execNumber, "s," .. string.gsub(colorValue, ",", ";"))
        end
        
        if GetVar(GlobalVars(), "sendNames") then
            sendOSC(basePath .. "/Name" .. execNumber, "s," .. nameValue)
        end
        
        -- Update stored values
        oldValues[execNumber] = faderValue
        oldButtonValues[execNumber] = buttonValue
        oldColorValues[execNumber] = colorValue
        oldNameValues[execNumber] = nameValue
    end
    
    -- Send timecode if enabled
    if GetVar(GlobalVars(), "sendTimecode") then
        for _, slot in pairs(Root().TimecodeSlots:Children()) do
            local time = slot.timestring
            sendOSC("/Timecode" .. slot.no, "s," .. time)
            oldTimecodes[slot.no] = time
        end
    end
end

-- Process and send executor values
local function processExecutor(executor, destPage)
    if not executor then return end
    
    local number = executor.No
    local faderValue = 0
    local buttonValue = false
    local colorValue = "0,0,0,0"
    local nameValue = ";"
    
    -- Get current values
    local faderOptions = {
        value = faderEnd,
        token = "FaderMaster",
        faderDisabled = false
    }
    -- Get and normalize fader value
    faderValue = executor:GetFader(faderOptions)
    if type(faderValue) == "number" then
        faderValue = math.max(0, math.min(1, faderValue))
    else
        faderValue = 0
    end
    
    local obj = executor.Object
    if obj then
        buttonValue = obj:HasActivePlayback()
        colorValue = getAppearanceColor(obj)
        nameValue = getName(obj)
    end
    
    -- Send values if changed
    local basePath = string.format("/Page%d", destPage)
    
    if oldValues[number] ~= faderValue then
        local mappedValue = mapTo127(faderValue)
        sendOSC(basePath .. "/Fader" .. number, "i," .. mappedValue)
        oldValues[number] = faderValue
    end
    
    if oldButtonValues[number] ~= buttonValue then
        sendOSC(basePath .. "/Button" .. number, "s," .. (buttonValue and "On" or "Off"))
        oldButtonValues[number] = buttonValue
    end
    
    if GetVar(GlobalVars(), "sendColors") and oldColorValues[number] ~= colorValue then
        sendOSC(basePath .. "/Color" .. number, "s," .. string.gsub(colorValue, ",", ";"))
        oldColorValues[number] = colorValue
    end
    
    if GetVar(GlobalVars(), "sendNames") and oldNameValues[number] ~= nameValue then
        sendOSC(basePath .. "/Name" .. number, "s," .. nameValue)
        oldNameValues[number] = nameValue
    end
end

-- Main function
local function main()
    -- Initialize
    setupExecutorsToWatch()
    
    -- Get initial settings
    local settings = {
        automaticResendButtons = GetVar(GlobalVars(), "automaticResendButtons") or false,
        sendColors = GetVar(GlobalVars(), "sendColors") or false,
        sendNames = GetVar(GlobalVars(), "sendNames") or false,
        sendTimecode = GetVar(GlobalVars(), "sendTimecode") or false
    }
    
    Printf("Starting pam-OSC")
    for k, v in pairs(settings) do
        Printf(k .. ": " .. tostring(v))
    end

    -- Set up update flag
    if GetVar(GlobalVars(), "updateOSC") == nil then
        SetVar(GlobalVars(), "updateOSC", true)
    end

    local currentPage = CurrentExecPage().index
    
    -- Send initial mass update
    Printf("Sending initial mass update...")
    sendMassUpdate(currentPage)
    Printf("Initial mass update complete")

    -- Main loop
    while GetVar(GlobalVars(), "updateOSC") do
        -- Check for settings updates
        if GetVar(GlobalVars(), "forceReload") then
            for k in pairs(settings) do
                settings[k] = GetVar(GlobalVars(), k) or false
            end
            sendMassUpdate(currentPage)
            SetVar(GlobalVars(), "forceReload", false)
        end

        -- Check page changes
        local newPage = CurrentExecPage().index
        if newPage ~= currentPage then
            currentPage = newPage
            sendOSC("/updatePage/current", "i," .. currentPage)
            sendMassUpdate(currentPage)
        end

        -- Process regular updates
        local executors = DataPool().Pages[currentPage]:Children()
        for _, executor in pairs(executors) do
            if executor and executor.No then
                processExecutor(executor, currentPage)
            end
        end

        -- Rest of the loop remains the same...
        coroutine.yield(tick)
    end
end

return main
