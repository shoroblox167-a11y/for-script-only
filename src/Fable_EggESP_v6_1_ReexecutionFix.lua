--[[
    FABLE EGG ESP v6
    =================
    FIXES OLD READY EGGS

    Target display:
        PetName [Age 1 Weight] [Age 1]

    Why v5 could miss old eggs:
      The native game renderer receives:
          EggReadyToHatch_RE(PetType, EggUUID)
      and stores the result in a PRIVATE renderer table.

      If our ESP starts later, our own listener missed the event.

    v6 reads the native renderer's already-existing READY cache when the
    executor exposes getconnections/getupvalues. This is the important
    difference for eggs that were already READY before Fable started.

    Native path:
      ReplicatedStorage.Modules.PetServices.PetEggRenderer

      Its EggReadyToHatch_RE callback stores:
          readyCache[eggUUID] = petType

    Weight:
      DataService.SaveSlots.AllSlots[*].SavedObjects[eggUUID].Data.BaseWeight

    Display weight:
      PetUtilities:CalculateWeight(BaseWeight, 1, PetType)

    Age is fixed to 1.
    Buffs are NOT applied.

    READ-ONLY:
      No HatchPet
      No CreateEgg
      No EquipPet
      No data writes
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    warn("[FABLE-ESP] LocalPlayer unavailable.")
    return
end

local Modules = ReplicatedStorage:FindFirstChild("Modules")
local GameEvents = ReplicatedStorage:FindFirstChild("GameEvents")

local DataService
pcall(function()
    local module = Modules and Modules:FindFirstChild("DataService")
    if module then
        DataService = require(module)
    end
end)

local PetUtilities
pcall(function()
    local folder = Modules and Modules:FindFirstChild("PetServices")
    local module = folder and folder:FindFirstChild("PetUtilities")
    if module then
        PetUtilities = require(module)
    end
end)

local ReadyEvent = GameEvents and GameEvents:FindFirstChild("EggReadyToHatch_RE")

local ENV = (type(getgenv) == "function" and getgenv()) or _G

if type(ENV.FableEggESP) == "table"
    and type(ENV.FableEggESP.Destroy) == "function"
then
    pcall(ENV.FableEggESP.Destroy)
end

-- Always keep a valid namespace for subsequent executions.
ENV.FableEggESP = {}

local Config = {
    updateInterval = 0.15,
    maxDistance = 250,
    hideUnready = false,
}

local ReadyByUUID = {}
local BillboardByEgg = {}

local function str(v)
    local ok, result = pcall(tostring, v)
    return ok and result or "?"
end

local function isNumber(v)
    return typeof(v) == "number"
end

local function getData()
    if not DataService then
        return nil
    end

    local ok, data = pcall(function()
        return DataService:GetData()
    end)

    if ok and type(data) == "table" then
        return data
    end

    return nil
end

local function getReadyEggs()
    local result = {}

    for _, egg in ipairs(CollectionService:GetTagged("PetEggServer")) do
        if egg:GetAttribute("OWNER") == LocalPlayer.Name then
            local timer = egg:GetAttribute("TimeToHatch")

            if typeof(timer) == "number" and timer <= 0 then
                result[#result + 1] = egg
            end
        end
    end

    return result
end

local function getSavedObject(uuid)
    local data = getData()

    if type(data) ~= "table" then
        return nil
    end

    local saveSlots = data.SaveSlots
    local allSlots = saveSlots and saveSlots.AllSlots

    if type(allSlots) ~= "table" then
        return nil
    end

    for _, slotData in pairs(allSlots) do
        if type(slotData) == "table" then
            local savedObjects = slotData.SavedObjects

            if type(savedObjects) == "table" then
                local exact = savedObjects[uuid]

                if type(exact) == "table" then
                    return exact
                end

                for key, candidate in pairs(savedObjects) do
                    if str(key) == uuid and type(candidate) == "table" then
                        return candidate
                    end
                end
            end
        end
    end

    return nil
end

local function getBaseWeight(uuid)
    local object = getSavedObject(uuid)

    if type(object) ~= "table" then
        return nil
    end

    local data = object.Data

    if type(data) == "table" and isNumber(data.BaseWeight) then
        return data.BaseWeight
    end

    return nil
end

local function calculateAge1Weight(baseWeight, petType)
    if not isNumber(baseWeight)
        or type(petType) ~= "string"
        or not PetUtilities
    then
        return nil
    end

    -- Exactly Age/Level 1.
    -- No SIZE_MODIFICATION or pet boost calculation.
    local ok, result = pcall(function()
        return PetUtilities:CalculateWeight(
            baseWeight,
            1,
            petType
        )
    end)

    if ok and isNumber(result) then
        return result
    end

    local ok2, result2 = pcall(function()
        return PetUtilities:CalculateWeight(
            baseWeight,
            1
        )
    end)

    if ok2 and isNumber(result2) then
        return result2
    end

    return nil
end

local function getAllUpvalues(func)
    local getter

    if type(getupvalues) == "function" then
        getter = getupvalues
    elseif debug and type(debug.getupvalues) == "function" then
        getter = debug.getupvalues
    end

    if not getter or type(func) ~= "function" then
        return nil
    end

    local ok, values = pcall(getter, func)

    if ok and type(values) == "table" then
        return values
    end

    return nil
end

local function collectUUIDStringPairs(root, targetUUIDs, visited, depth, results)
    if depth > 8 or type(root) ~= "table" then
        return
    end

    if visited[root] then
        return
    end

    visited[root] = true

    for key, value in pairs(root) do
        local keyText = str(key)
        local valueText = str(value)

        -- Native renderer cache has:
        -- cache[eggUUID] = exactPetType
        if targetUUIDs[keyText]
            and type(value) == "string"
        then
            results[keyText] = {
                petType = value,
                source = "native PetEggRenderer ready cache",
            }

            print(
                "[FABLE-ESP] OLD READY CACHE:",
                keyText,
                "=>",
                value
            )
        end

        if targetUUIDs[valueText]
            and type(key) == "string"
        then
            results[valueText] = {
                petType = key,
                source = "native PetEggRenderer inverted cache",
            }

            print(
                "[FABLE-ESP] OLD READY CACHE (inverted):",
                valueText,
                "=>",
                key
            )
        end

        if type(value) == "table" then
            collectUUIDStringPairs(
                value,
                targetUUIDs,
                visited,
                depth + 1,
                results
            )
        end
    end
end

local function recoverNativeReadyCache()
    if type(getconnections) ~= "function" then
        print("[FABLE-ESP] getconnections unavailable; old-cache scan skipped.")
        return
    end

    if not ReadyEvent then
        return
    end

    local readyEggs = getReadyEggs()

    if #readyEggs == 0 then
        return
    end

    local targetUUIDs = {}

    for _, egg in ipairs(readyEggs) do
        local uuid = egg:GetAttribute("OBJECT_UUID")

        if uuid then
            targetUUIDs[str(uuid)] = true
        end
    end

    local ok, connections = pcall(function()
        return getconnections(ReadyEvent.OnClientEvent)
    end)

    if not ok or type(connections) ~= "table" then
        warn("[FABLE-ESP] Could not inspect EggReadyToHatch_RE connections.")
        return
    end

    print(
        "[FABLE-ESP] Inspecting native EggReadyToHatch_RE connections:",
        #connections
    )

    for _, connection in ipairs(connections) do
        local callback

        pcall(function()
            callback = connection.Function or connection.Callback
        end)

        if type(callback) == "function" then
            local upvalues = getAllUpvalues(callback)

            if type(upvalues) == "table" then
                local results = {}

                for _, value in pairs(upvalues) do
                    if type(value) == "table" then
                        collectUUIDStringPairs(
                            value,
                            targetUUIDs,
                            {},
                            0,
                            results
                        )
                    end
                end

                for uuid, info in pairs(results) do
                    ReadyByUUID[uuid] = {
                        petType = info.petType,
                        source = info.source,
                        recoveredAt = os.clock(),
                    }
                end
            end
        end
    end
end

local function processNativeReadyEvent(petType, eggUUID)
    local uuid = str(eggUUID)

    ReadyByUUID[uuid] = {
        petType = str(petType),
        source = "EggReadyToHatch_RE",
        receivedAt = os.clock(),
    }

    print(
        "[FABLE-ESP] READY EVENT:",
        str(petType),
        "| UUID:",
        uuid
    )
end

if ReadyEvent then
    ReadyEvent.OnClientEvent:Connect(processNativeReadyEvent)
else
    warn("[FABLE-ESP] EggReadyToHatch_RE not found.")
end

local function makeBillboard(egg)
    local gui = BillboardByEgg[egg]

    if gui and gui.Parent then
        return gui
    end

    gui = Instance.new("BillboardGui")
    gui.Name = "FableEggESP_V6"
    gui.AlwaysOnTop = true
    gui.LightInfluence = 0
    gui.Size = UDim2.fromOffset(205, 56)
    gui.StudsOffset = Vector3.new(0, 4.15, 0)
    gui.MaxDistance = Config.maxDistance

    gui.Adornee =
        egg.PrimaryPart
        or egg:FindFirstChild("HitBox", true)
        or egg:FindFirstChildWhichIsA("BasePart", true)

    gui.Parent = egg

    local card = Instance.new("Frame")
    card.Name = "Card"
    card.Size = UDim2.fromScale(1, 1)
    card.BackgroundColor3 = Color3.fromRGB(13, 13, 18)
    card.BackgroundTransparency = 0.08
    card.BorderSizePixel = 0
    card.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 7)
    corner.Parent = card

    local outline = Instance.new("UIStroke")
    outline.Color = Color3.fromRGB(126, 84, 255)
    outline.Thickness = 1
    outline.Parent = card

    local main = Instance.new("TextLabel")
    main.Name = "Main"
    main.BackgroundTransparency = 1
    main.Position = UDim2.fromOffset(7, 4)
    main.Size = UDim2.new(1, -14, 0, 24)
    main.Text = "Revealing..."
    main.TextColor3 = Color3.fromRGB(248, 248, 250)
    main.TextSize = 11
    main.Font = Enum.Font.GothamBold
    main.TextXAlignment = Enum.TextXAlignment.Center
    main.Parent = card

    local sub = Instance.new("TextLabel")
    sub.Name = "Sub"
    sub.BackgroundTransparency = 1
    sub.Position = UDim2.fromOffset(7, 29)
    sub.Size = UDim2.new(1, -14, 0, 20)
    sub.Text = ""
    sub.TextColor3 = Color3.fromRGB(150, 150, 165)
    sub.TextSize = 8
    sub.Font = Enum.Font.Code
    sub.TextXAlignment = Enum.TextXAlignment.Center
    sub.Parent = card

    BillboardByEgg[egg] = gui

    return gui
end

local function removeBillboard(egg)
    local gui = BillboardByEgg[egg]

    if gui then
        pcall(function()
            gui:Destroy()
        end)
    end

    BillboardByEgg[egg] = nil
end

local function updateEgg(egg)
    local gui = makeBillboard(egg)

    local card = gui:FindFirstChild("Card")
    if not card then
        return
    end

    local main = card:FindFirstChild("Main")
    local sub = card:FindFirstChild("Sub")

    local eggName = str(egg:GetAttribute("EggName"))
    local uuidValue = egg:GetAttribute("OBJECT_UUID")
    local uuid = uuidValue and str(uuidValue) or nil

    local timer = egg:GetAttribute("TimeToHatch")
    local ready = typeof(timer) == "number" and timer <= 0

    if not ready then
        gui.Enabled = not Config.hideUnready

        if main then
            main.Text = eggName
        end

        if sub then
            sub.Text = getTimerText(egg)
            sub.TextColor3 = Color3.fromRGB(150, 150, 165)
        end

        return
    end

    gui.Enabled = true

    if not uuid then
        if main then
            main.Text = "READY"
        end

        if sub then
            sub.Text = eggName
            sub.TextColor3 = Color3.fromRGB(95, 232, 145)
        end

        return
    end

    -- Try to recover native renderer cache again if this UUID wasn't found
    -- during startup.
    if not ReadyByUUID[uuid] then
        recoverNativeReadyCache()
    end

    local info = ReadyByUUID[uuid]
    local petType = info and info.petType

    local baseWeight = getBaseWeight(uuid)

    if not petType then
        if main then
            main.Text = "Revealing..."
        end

        if sub then
            sub.Text = eggName .. " • READY"
            sub.TextColor3 = Color3.fromRGB(95, 232, 145)
        end

        return
    end

    local age1Weight =
        calculateAge1Weight(
            baseWeight,
            petType
        )

    if main then
        if age1Weight then
            main.Text = string.format(
                "%s [%.2f KG] [Age 1]",
                petType,
                age1Weight
            )
        else
            main.Text = petType .. " [Age 1]"
        end
    end

    if sub then
        sub.Text = eggName .. " • READY"
        sub.TextColor3 = Color3.fromRGB(95, 232, 145)
    end
end

function ENV.FableEggESP.SetHideUnready(value)
    Config.hideUnready = value == true
end

function ENV.FableEggESP.SetMaxDistance(value)
    value = tonumber(value)

    if value and value > 0 then
        Config.maxDistance = value
    end
end

function ENV.FableEggESP.Refresh()
    recoverNativeReadyCache()

    for _, egg in ipairs(CollectionService:GetTagged("PetEggServer")) do
        if egg:GetAttribute("OWNER") == LocalPlayer.Name then
            pcall(updateEgg, egg)
        end
    end
end

function ENV.FableEggESP.Destroy()
    for egg in pairs(BillboardByEgg) do
        removeBillboard(egg)
    end

    if SnapshotListener then
        pcall(function()
            SnapshotListener:Disconnect()
        end)
        SnapshotListener = nil
    end

    -- Keep the namespace table alive so re-executing the script cannot
    -- produce "attempt to index nil with SetHideUnready".
    table.clear(ReadyByUUID)
end

print("==============================================================")
print(" FABLE EGG ESP v6")
print(" OLD + NEW READY EGGS • AGE 1 • NO BUFF")
print("==============================================================")
print("NEW ready source: EggReadyToHatch_RE")
print("OLD ready source: native PetEggRenderer callback cache")
print("BaseWeight: SavedObjects[UUID].Data.BaseWeight")
print("Display: CalculateWeight(BaseWeight, 1, PetType)")
print("==============================================================")

-- Critical startup step for existing READY eggs.
recoverNativeReadyCache()

task.spawn(function()
    while LocalPlayer.Parent do
        task.wait(Config.updateInterval)

        local present = {}

        for _, egg in ipairs(CollectionService:GetTagged("PetEggServer")) do
            if egg:GetAttribute("OWNER") == LocalPlayer.Name then
                present[egg] = true

                pcall(function()
                    updateEgg(egg)
                end)
            end
        end

        for egg in pairs(BillboardByEgg) do
            if not present[egg] or not egg.Parent then
                removeBillboard(egg)
            end
        end
    end
end)

print("[FABLE-ESP] Loaded.")
