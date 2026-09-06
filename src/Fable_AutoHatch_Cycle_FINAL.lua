-- FABLE AUTOHATCH • FINAL CYCLE
-- ============================================================
-- Canonical production cycle for the Fable AutoHatch repository.
--
-- REDUCTION -> READY -> conditional HATCH/BRONTO -> SELL -> repeat
--
-- Team transition is always:
--   UNEQUIP ALL -> GARDEN EMPTY -> EQUIP TARGET -> EXACT UUID VERIFY
--
-- This file does not replace the approved Egg ESP or live stats source.

repeat task.wait() until game:IsLoaded()

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")

local LP = Players.LocalPlayer
if not LP then return end

local ENV = (type(getgenv) == "function" and getgenv()) or _G
local BASE = "https://raw.githubusercontent.com/shoroblox167-a11y/for-script-only/main/src/"
local UI_URL = "https://raw.githubusercontent.com/9kkinc-sudo/ui_lib/main/source.lua"

if type(ENV.FableAutoHatch) == "table" and type(ENV.FableAutoHatch.Stop) == "function" then
    pcall(ENV.FableAutoHatch.Stop)
end

local function load(url)
    local source = game:HttpGet(url)
    local fn, err = loadstring(source)
    if not fn then error(err or ("load failed: " .. url), 2) end
    return fn()
end

-- Reuse a preloaded exoui(3) library; otherwise load the referenced Exo UI source.
local Library = ENV.Library
if not Library or type(Library.CreateWindow) ~= "function" then
    Library = load(UI_URL)
end
ENV.Library = Library

local Modules = ReplicatedStorage:WaitForChild("Modules")
local PetServices = Modules:WaitForChild("PetServices")
local GameEvents = ReplicatedStorage:WaitForChild("GameEvents")
local DataService = require(Modules:WaitForChild("DataService"))
local PetsService = require(PetServices:WaitForChild("PetsService"))
local ActivePetsService = require(PetServices:WaitForChild("ActivePetsService"))
local PetEggService = GameEvents:WaitForChild("PetEggService")
local EggReadyToHatch_RE = GameEvents:WaitForChild("EggReadyToHatch_RE")
local SellAllPets_RE = GameEvents:WaitForChild("SellAllPets_RE")

-- Compatibility function used by the approved ESP source.
if type(ENV.getTimerText) ~= "function" then
    ENV.getTimerText = function(egg)
        local t = egg and egg:GetAttribute("TimeToHatch")
        if typeof(t) ~= "number" then return "Timer: ?" end
        if t <= 0 then return "READY" end
        return string.format("%02d:%02d", math.floor(t / 60), math.floor(t % 60))
    end
end

local ESPLoaded = pcall(function()
    load(BASE .. "Fable_EggESP_v6_1_ReexecutionFix.lua")
end)

local State = {
    Running = false,
    StopRequested = false,
    Destroyed = false,
    Stage = "IDLE",
    Cycle = 0,
    PriorityEgg = "Campfire Egg",
    MaxEggs = 13,
    StopEggCount = 0,
    BrontoThreshold = 1.30,
    AllowBigPetHatch = true,
    DontHatch = {},
    Teams = {Reduction = {}, Hatch = {}, Bronto = {}, Sell = {}},
}

local TEAM_NAMES = {
    Reduction = "Egg Reduction",
    Hatch = "Hatch Egg",
    Bronto = "Pet Size",
    Sell = "Sell Egg",
}

local POLL = 0.05
local TEAM_GAP = 0.08
local TEAM_TIMEOUT = 10
local READY_TIMEOUT = 1800
local EGG_TIMEOUT = 10
local EMPTY_STABLE = 2
local EXACT_STABLE = 2
local OCCUPANCY_RADIUS = 1.25
local MAX_TEAM = 8

local ReadyByUUID = {}
local HatchRequested = {}
local PlacementPositions = {}
local Connections = {}
local GardenReadFailed = false

local StatusLabel
local SecurityLabel
local GardenLabel
local CycleLabel
local EggCountLabel
local StartToggle
local DontHatchDropdown

local function notify(title, description, time)
    pcall(function() Library:Notify({Title = title, Description = description, Time = time or 3}) end)
end

local function setStatus(text)
    State.Stage = tostring(text)
    if StatusLabel then StatusLabel:SetText("Status • " .. tostring(text)) end
end

local function setSecurity(text)
    if SecurityLabel then SecurityLabel:SetText("Security • " .. tostring(text)) end
end

local function getData()
    local ok, data = pcall(function() return DataService:GetData() end)
    return ok and type(data) == "table" and data or nil
end

local function getInventory()
    local data = getData()
    local stored = data and data.PetsData and data.PetsData.PetInventory and data.PetsData.PetInventory.Data
    return type(stored) == "table" and stored or {}
end

local function inventoryHas(uuid)
    return getInventory()[uuid] ~= nil
end

local function countSet(set)
    local n = 0
    for _ in pairs(set) do n += 1 end
    return n
end

local function getInventoryValues()
    local values, lookup = {}, {}
    for uuid, record in pairs(getInventory()) do
        if type(record) == "table" and record.PetType ~= nil then
            local petData = type(record.PetData) == "table" and record.PetData or {}
            local id = tostring(uuid)
            local weight = tonumber(petData.BaseWeight)
            local label = string.format(
                "%s • Lv.%d • %s • {%s}",
                tostring(record.PetType),
                tonumber(petData.Level) or 1,
                weight and string.format("%.2fkg", weight) or "?kg",
                id
            )
            values[#values + 1] = label
            lookup[label] = id
        end
    end
    table.sort(values)
    return values, lookup
end

local function getGardenSet()
    local result = {}
    local ok, datastore = pcall(function()
        return ActivePetsService:GetPlayerDatastorePetData(LP.Name)
    end)
    if not ok or type(datastore) ~= "table" or type(datastore.EquippedPets) ~= "table" then
        GardenReadFailed = true
        return result
    end
    GardenReadFailed = false
    for _, uuid in ipairs(datastore.EquippedPets) do result[tostring(uuid)] = true end
    return result
end

local function equalSet(a, b)
    for uuid in pairs(a) do if not b[uuid] then return false end end
    for uuid in pairs(b) do if not a[uuid] then return false end end
    return true
end

local function teamSet(role)
    local out = {}
    for uuid, enabled in pairs(State.Teams[role] or {}) do if enabled then out[uuid] = true end end
    return out
end

local function shortSet(set)
    local out = {}
    for uuid in pairs(set) do out[#out + 1] = "..." .. tostring(uuid):sub(-8) end
    table.sort(out)
    return #out > 0 and table.concat(out, ", ") or "none"
end

local function getOwnedEggs(priorityOnly)
    local result = {}
    for _, egg in ipairs(CollectionService:GetTagged("PetEggServer")) do
        if egg:GetAttribute("OWNER") == LP.Name then
            if not priorityOnly or egg:GetAttribute("EggName") == State.PriorityEgg then
                result[#result + 1] = egg
            end
        end
    end
    return result
end

local function findEgg(uuid)
    uuid = tostring(uuid)
    for _, egg in ipairs(getOwnedEggs(false)) do
        if tostring(egg:GetAttribute("OBJECT_UUID")) == uuid then return egg end
    end
    return nil
end

local function getSavedObject(uuid)
    local data = getData()
    local slots = data and data.SaveSlots and data.SaveSlots.AllSlots
    if type(slots) ~= "table" then return nil end
    for _, slot in pairs(slots) do
        if type(slot) == "table" and type(slot.SavedObjects) == "table" then
            local direct = slot.SavedObjects[uuid]
            if type(direct) == "table" then return direct end
            for key, candidate in pairs(slot.SavedObjects) do
                if tostring(key) == tostring(uuid) and type(candidate) == "table" then return candidate end
            end
        end
    end
    return nil
end

local function getBaseWeight(uuid)
    local object = getSavedObject(uuid)
    local data = object and object.Data
    return type(data) == "table" and tonumber(data.BaseWeight) or nil
end

local function getPetType(uuid)
    local info = ReadyByUUID[tostring(uuid)]
    return info and info.petType or nil
end

local function getEggCount()
    local data = getData()
    return data and tonumber(data.Egg) or nil
end

local function stopThresholdReached()
    if State.StopEggCount <= 0 then return false end
    local count = getEggCount()
    if count == nil then
        setStatus("STOPPED • egg count unavailable")
        setSecurity("BLOCKED • stop threshold cannot be verified")
        return true
    end
    return count <= State.StopEggCount
end

local function waitFor(predicate, timeout, manual)
    local started = os.clock()
    while not State.StopRequested and os.clock() - started < timeout do
        if not manual and not State.Running then return false end
        local ok, result = pcall(predicate)
        if ok and result then return true end
        task.wait(POLL)
    end
    return false
end

local function clearGarden()
    local garden = getGardenSet()
    if GardenReadFailed then return false, "Active garden state unavailable" end
    local ids = {}
    for uuid in pairs(garden) do ids[#ids + 1] = uuid end
    table.sort(ids)
    for i, uuid in ipairs(ids) do
        local ok = pcall(function() PetsService:UnequipPet(uuid) end)
        if not ok then return false, "Unequip failed: ..." .. uuid:sub(-8) end
        if i < #ids then task.wait(TEAM_GAP) end
    end
    local stable = 0
    local ok = waitFor(function()
        local current = getGardenSet()
        if GardenReadFailed then return false end
        local empty = next(current) == nil
        stable = empty and stable + 1 or 0
        return stable >= EMPTY_STABLE
    end, TEAM_TIMEOUT)
    return ok, ok and nil or "Garden did not become empty"
end

local function equipExact(role)
    local target = teamSet(role)
    local targetCount = countSet(target)
    if targetCount == 0 then return false, "Target team is empty" end
    if targetCount > MAX_TEAM then return false, "Target team exceeds 8 pets" end
    for uuid in pairs(target) do
        if not inventoryHas(uuid) then return false, "Target UUID missing from inventory: ..." .. uuid:sub(-8) end
    end

    local ok, err = clearGarden()
    if not ok then return false, err end

    local ids = {}
    for uuid in pairs(target) do ids[#ids + 1] = uuid end
    table.sort(ids)
    for i, uuid in ipairs(ids) do
        local fired = pcall(function() PetsService:EquipPet(uuid) end)
        if not fired then return false, "Equip failed: ..." .. uuid:sub(-8) end
        if i < #ids then task.wait(TEAM_GAP) end
    end

    local stable = 0
    local verified = waitFor(function()
        local garden = getGardenSet()
        if GardenReadFailed then return false end
        local same = equalSet(target, garden)
        stable = same and stable + 1 or 0
        return stable >= EXACT_STABLE
    end, TEAM_TIMEOUT)
    if not verified then
        return false, "SECURITY MISMATCH • target=" .. shortSet(target) .. " • garden=" .. shortSet(getGardenSet())
    end
    setSecurity("PASS • " .. TEAM_NAMES[role])
    return true
end

local function loadPositions()
    if #PlacementPositions > 0 then return true end
    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(game:HttpGet(BASE .. "Fable_AutoHatch_Positions.json"))
    end)
    if not ok or type(decoded) ~= "table" then return false end
    for _, p in ipairs(decoded) do
        if tonumber(p.x) and tonumber(p.y) and tonumber(p.z) then
            PlacementPositions[#PlacementPositions + 1] = Vector3.new(p.x, p.y, p.z)
        end
    end
    return #PlacementPositions == 13
end

local function eggPart(egg)
    return egg.PrimaryPart or egg:FindFirstChildWhichIsA("BasePart", true)
end

local function occupied(position)
    for _, egg in ipairs(getOwnedEggs(true)) do
        local part = eggPart(egg)
        if part and (part.Position - position).Magnitude <= OCCUPANCY_RADIUS then return true end
    end
    return false
end

local function findEggTool()
    local wanted = string.lower(State.PriorityEgg)
    for _, container in ipairs({LP.Character, LP.Backpack}) do
        if container then
            for _, child in ipairs(container:GetChildren()) do
                if child:IsA("Tool") then
                    local name = string.lower(child.Name)
                    if name:sub(1, #wanted) == wanted then return child end
                end
            end
        end
    end
    return nil
end

local function equipEggTool()
    local tool = findEggTool()
    local humanoid = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
    if not tool or not humanoid then return false end
    if tool.Parent ~= LP.Character then
        local ok = pcall(function() humanoid:EquipTool(tool) end)
        if not ok then return false end
        task.wait(0.05)
    end
    return true
end

local function eggAt(position)
    for _, egg in ipairs(getOwnedEggs(true)) do
        local part = eggPart(egg)
        if part and (part.Position - position).Magnitude <= OCCUPANCY_RADIUS then return egg end
    end
    return nil
end

local function createEggAt(position)
    if occupied(position) then return true end
    if not equipEggTool() then return false, "No selected egg tool found" end
    local before = {}
    for _, egg in ipairs(getOwnedEggs(true)) do
        local uuid = egg:GetAttribute("OBJECT_UUID")
        if uuid then before[tostring(uuid)] = true end
    end
    local fired, err = pcall(function() PetEggService:FireServer("CreateEgg", position) end)
    if not fired then return false, tostring(err) end
    local verified = waitFor(function()
        local egg = eggAt(position)
        if not egg then return false end
        local uuid = egg:GetAttribute("OBJECT_UUID")
        return uuid and not before[tostring(uuid)]
    end, EGG_TIMEOUT)
    return verified, verified and nil or "CreateEgg verification failed"
end

local function maintainEggs(manual)
    if not loadPositions() then return false, "Approved Region 1 middle map unavailable" end
    local target = math.clamp(math.floor(State.MaxEggs), 1, 13)
    while not State.StopRequested and (manual or State.Running) do
        if #getOwnedEggs(true) >= target then return true end
        local progress = false
        for _, position in ipairs(PlacementPositions) do
            if #getOwnedEggs(true) >= target then return true end
            if not occupied(position) then
                local ok, err = createEggAt(position)
                if not ok then return false, err end
                progress = true
            end
        end
        if not progress then return false, "No approved placement slot available" end
    end
    return false, "Stopped"
end

local function recoverReadyCache()
    if type(getconnections) ~= "function" then return end
    local wanted = {}
    for _, egg in ipairs(getOwnedEggs(true)) do
        local timer = egg:GetAttribute("TimeToHatch")
        local uuid = egg:GetAttribute("OBJECT_UUID")
        if typeof(timer) == "number" and timer <= 0 and uuid then wanted[tostring(uuid)] = true end
    end
    if next(wanted) == nil then return end
    local getter = getupvalues
    if type(getter) ~= "function" and debug and type(debug.getupvalues) == "function" then getter = debug.getupvalues end
    if type(getter) ~= "function" then return end
    local function walk(root, visited, depth)
        if type(root) ~= "table" or visited[root] or depth > 8 then return end
        visited[root] = true
        for key, value in pairs(root) do
            local k, v = tostring(key), tostring(value)
            if wanted[k] and type(value) == "string" then ReadyByUUID[k] = {petType = value, source = "native cache"} end
            if wanted[v] and type(key) == "string" then ReadyByUUID[v] = {petType = key, source = "native cache"} end
            if type(value) == "table" then walk(value, visited, depth + 1) end
        end
    end
    local ok, list = pcall(function() return getconnections(EggReadyToHatch_RE.OnClientEvent) end)
    if not ok or type(list) ~= "table" then return end
    for _, connection in ipairs(list) do
        local callback
        pcall(function() callback = connection.Function or connection.Callback end)
        if type(callback) == "function" then
            local ups
            pcall(function() ups = getter(callback) end)
            if type(ups) == "table" then
                for _, value in pairs(ups) do if type(value) == "table" then walk(value, {}, 0) end end
            end
        end
    end
end

Connections.Ready = EggReadyToHatch_RE.OnClientEvent:Connect(function(petType, eggUUID)
    if petType and eggUUID then
        ReadyByUUID[tostring(eggUUID)] = {petType = tostring(petType), source = "EggReadyToHatch_RE"}
    end
end)

local function waitBatchReady(batch)
    local started = os.clock()
    while State.Running and not State.StopRequested and os.clock() - started < READY_TIMEOUT do
        recoverReadyCache()
        local allReady = true
        for uuid in pairs(batch) do
            local egg = findEgg(uuid)
            local timer = egg and egg:GetAttribute("TimeToHatch")
            if not egg or typeof(timer) ~= "number" or timer > 0 or not getPetType(uuid) then
                allReady = false
                break
            end
        end
        if allReady then return true end
        task.wait(0.25)
    end
    return false
end

local function classify(batch)
    local normal, big = {}, {}
    recoverReadyCache()
    for uuid in pairs(batch) do
        local petType = getPetType(uuid)
        local baseWeight = getBaseWeight(uuid)
        if not petType then return nil, nil, "READY PetType unavailable: ..." .. uuid:sub(-8) end
        if baseWeight == nil then return nil, nil, "READY BaseWeight unavailable: ..." .. uuid:sub(-8) end
        if State.DontHatch[petType] then continue end
        local entry = {uuid = uuid, petType = petType, baseWeight = baseWeight}
        if State.AllowBigPetHatch and baseWeight > State.BrontoThreshold then
            big[#big + 1] = entry
        else
            normal[#normal + 1] = entry
        end
    end
    if #normal == 0 and #big == 0 then return nil, nil, "All READY pets are excluded" end
    return normal, big
end

local function hatchEntries(entries, role)
    if #entries == 0 then return true end
    local ok, err = equipExact(role)
    if not ok then return false, err end
    for _, entry in ipairs(entries) do
        if State.StopRequested then return false, "Stopped" end
        local egg = findEgg(entry.uuid)
        if not egg then return false, "READY egg disappeared: ..." .. entry.uuid:sub(-8) end
        if HatchRequested[entry.uuid] then continue end
        HatchRequested[entry.uuid] = true
        local fired, fireErr = pcall(function() PetEggService:FireServer("HatchPet", egg) end)
        if not fired then return false, tostring(fireErr) end
        local gone = waitFor(function() return findEgg(entry.uuid) == nil end, EGG_TIMEOUT)
        if not gone then return false, "Hatch verification failed: ..." .. entry.uuid:sub(-8) end
    end
    return true
end

local function sellStage()
    local ok, err = equipExact("Sell")
    if not ok then return false, err end
    local fired, fireErr = pcall(function() SellAllPets_RE:FireServer() end)
    if not fired then return false, tostring(fireErr) end
    task.wait(0.20)
    return true
end

local function runCycle()
    if stopThresholdReached() then return true end
    local ok, err

    setStatus("REDUCTION • switching")
    ok, err = equipExact("Reduction")
    if not ok then return false, err end

    setStatus("REDUCTION • maintaining eggs")
    ok, err = maintainEggs(false)
    if not ok then return false, err end

    local batch = {}
    for _, egg in ipairs(getOwnedEggs(true)) do
        local uuid = egg:GetAttribute("OBJECT_UUID")
        if uuid then batch[tostring(uuid)] = true end
    end
    if next(batch) == nil then return false, "No priority eggs on farm" end

    setStatus("WAITING • READY eggs")
    if not waitBatchReady(batch) then return false, "READY batch timeout or ready data missing" end

    local normal, big
    normal, big, err = classify(batch)
    if not normal then return false, err end

    setStatus(string.format("HATCH • %d normal / %d Bronto", #normal, #big))
    ok, err = hatchEntries(big, "Bronto")
    if not ok then return false, err end
    ok, err = hatchEntries(normal, "Hatch")
    if not ok then return false, err end

    setStatus("SELL • switching")
    ok, err = sellStage()
    if not ok then return false, err end

    table.clear(HatchRequested)
    return true
end

-- ------------------------------------------------------------
-- UI: compact Exo/Fable layout with four UUID team cards.
-- ------------------------------------------------------------
local Window = Library:CreateWindow({
    Title = "FABLE • AUTOHATCH",
    Footer = "Fable • canonical",
    Size = UDim2.fromOffset(760, 600),
    AutoShow = true,
    Center = true,
    Resizable = true,
    SearchbarSize = UDim2.fromScale(1, 1),
    CornerRadius = 4,
    NotifySide = "Right",
    Font = Enum.Font.Code,
    ToggleKeybind = Enum.KeyCode.RightControl,
    MobileButtonsSide = "Left",
})

local Home = Window:AddTab({Name = "Home", Description = "Fable AutoHatch status and controls."})
local Teams = Window:AddTab({Name = "Hatching Teams", Description = "Exact UUID inventory teams."})
local Eggs = Window:AddTab({Name = "Eggs Priority", Description = "Egg selection and placement."})
local Sell = Window:AddTab({Name = "Pet Sell Settings", Description = "Verified selling stage."})
local Premium = Window:AddTab({Name = "Premium", Description = "Conditional Brontosaurus settings."})

local homeLeft = Home:AddLeftGroupbox("Fable Status")
local homeRight = Home:AddRightGroupbox("AutoHatch")
StatusLabel = homeLeft:AddLabel({Text = "Status • IDLE", DoesWrap = true})
SecurityLabel = homeLeft:AddLabel({Text = "Security • IDLE", DoesWrap = true})
GardenLabel = homeLeft:AddLabel({Text = "Garden • 0 active", DoesWrap = true})
CycleLabel = homeRight:AddLabel({Text = "Cycle • 0", DoesWrap = true})
EggCountLabel = homeRight:AddLabel({Text = "Eggs • ?", DoesWrap = true})

StartToggle = homeRight:AddToggle("AutoHatch", {
    Text = "Auto Hatch",
    Default = false,
    Callback = function(value)
        if not value then
            State.StopRequested = true
            State.Running = false
            if not State.Destroyed then setStatus("STOPPING") end
            return
        end
        if State.Running then return end
        if not ESPLoaded then
            setStatus("STOPPED • approved Egg ESP failed to load")
            setSecurity("BLOCKED • required ESP unavailable")
            pcall(function() StartToggle:SetValue(false, true) end)
            return
        end
        State.StopRequested = false
        State.Running = true
        task.spawn(function()
            while State.Running and not State.StopRequested and not State.Destroyed do
                State.Cycle += 1
                CycleLabel:SetText("Cycle • " .. tostring(State.Cycle))
                local callOK, cycleOK, err = pcall(runCycle)
                if not callOK then
                    cycleOK = false
                    err = tostring(err)
                end
                if not cycleOK then
                    State.Running = false
                    setSecurity("BLOCKED • " .. tostring(err))
                    setStatus("STOPPED • cycle failure")
                    notify("FABLE AUTOHATCH", tostring(err), 6)
                    break
                end
                if stopThresholdReached() then
                    State.Running = false
                    break
                end
                task.wait(0.10)
            end
            State.Running = false
            if StartToggle and StartToggle.Value then pcall(function() StartToggle:SetValue(false, true) end) end
        end)
    end,
})

homeRight:AddButton("Stop / Reset", function()
    State.StopRequested = true
    State.Running = false
    setStatus("IDLE")
    setSecurity("IDLE")
    pcall(function() StartToggle:SetValue(false, true) end)
end)

homeRight:AddButton("Refresh Egg ESP", function()
    if ENV.FableEggESP and type(ENV.FableEggESP.Refresh) == "function" then ENV.FableEggESP.Refresh() end
end)

local teamBoxes = {
    Reduction = Teams:AddLeftGroupbox("Egg Reduction Team"),
    Hatch = Teams:AddLeftGroupbox("Hatch Egg Team"),
    Bronto = Teams:AddRightGroupbox("Pet Size Team"),
    Sell = Teams:AddRightGroupbox("Sell Egg Team"),
}

for role, box in pairs(teamBoxes) do
    local values, lookup = getInventoryValues()
    box:AddLabel({Text = TEAM_NAMES[role] .. " • exact inventory UUIDs", DoesWrap = true})
    local dropdown = box:AddDropdown("Team_" .. role, {
        Text = "Select pets",
        Values = values,
        Multi = true,
        Searchable = true,
        Default = {},
        Callback = function(selected)
            local newSet = {}
            if type(selected) == "table" then
                for value, enabled in pairs(selected) do if enabled and lookup[value] then newSet[lookup[value]] = true end end
                for _, value in ipairs(selected) do if lookup[value] then newSet[lookup[value]] = true end end
            end
            if countSet(newSet) <= MAX_TEAM then State.Teams[role] = newSet end
        end,
    })
    TeamDropdowns[role] = dropdown
    box:AddButton("Reload Inventory", function()
        local newValues = getInventoryValues()
        dropdown:SetValues(newValues)
    end)
    box:AddButton("Verify Garden", function()
        local target, garden = teamSet(role), getGardenSet()
        if not GardenReadFailed and equalSet(target, garden) then
            notify("SECURITY OK", TEAM_NAMES[role] .. " exactly matches the garden.", 3)
        else
            notify("SECURITY BLOCKED", "Target: " .. shortSet(target) .. "\nGarden: " .. shortSet(garden), 6)
        end
    end)
end

local eggLeft = Eggs:AddLeftGroupbox("Egg Priority")
local eggRight = Eggs:AddRightGroupbox("Placement / ESP")
eggLeft:AddDropdown("PriorityEgg", {Text = "#1 Priority", Values = {"Campfire Egg", "Rainbow Campfire Egg"}, Default = "Campfire Egg", Callback = function(v) State.PriorityEgg = v end})
eggLeft:AddInput("MaxEggs", {Text = "Max eggs to place", Default = "13", Numeric = true, Finished = true, Callback = function(v) local n = tonumber(v); if n then State.MaxEggs = math.clamp(math.floor(n), 1, 13) end end})
eggLeft:AddInput("StopEggCount", {Text = "Stop when eggs <=", Default = "0", Numeric = true, Finished = true, Callback = function(v) local n = tonumber(v); if n then State.StopEggCount = math.max(0, math.floor(n)) end end})
eggLeft:AddButton("Maintain Eggs Now", function()
    if State.Running then return end
    local ok, err = maintainEggs(true)
    notify(ok and "PLACEMENT" or "PLACEMENT BLOCKED", ok and "Approved Region 1 middle positions maintained." or tostring(err), ok and 3 or 6)
end)
eggRight:AddToggle("HideUnready", {Text = "Hide unready eggs", Default = false, Callback = function(v) if ENV.FableEggESP and type(ENV.FableEggESP.SetHideUnready) == "function" then ENV.FableEggESP.SetHideUnready(v) end end})
eggRight:AddSlider("ESPDistance", {Text = "Egg ESP distance", Default = 250, Min = 50, Max = 500, Rounding = 0, Callback = function(v) if ENV.FableEggESP and type(ENV.FableEggESP.SetMaxDistance) == "function" then ENV.FableEggESP.SetMaxDistance(v) end end})

local sellLeft = Sell:AddLeftGroupbox("Pet Sell List")
local sellRight = Sell:AddRightGroupbox("Pet Sell Controls")
sellLeft:AddToggle("OnlySellHatchedPets", {Text = "Only sell hatched pets", Default = true})
sellRight:AddButton("Sell All Pets", function()
    if State.Running then return end
    local ok, err = pcall(function() SellAllPets_RE:FireServer() end)
    notify(ok and "SELL" or "SELL FAILED", ok and "SellAllPets_RE fired." or tostring(err), ok and 3 or 6)
end)
sellRight:AddLabel({Text = "Verified max-inventory sell remote: SellAllPets_RE", DoesWrap = true})

local premiumLeft = Premium:AddLeftGroupbox("Big Pet Hatch")
local premiumRight = Premium:AddRightGroupbox("Brontosaurus")
premiumLeft:AddToggle("AllowBigPetHatch", {Text = "Allow Big Pet Hatch", Default = true, Callback = function(v) State.AllowBigPetHatch = v end})
premiumRight:AddInput("BrontoThreshold", {Text = "BaseWeight threshold", Default = "1.30", Numeric = true, Finished = true, Callback = function(v) local n = tonumber(v); if n then State.BrontoThreshold = n end end})
premiumRight:AddLabel({Text = "Strict rule: BaseWeight > threshold → Brontosaurus; BaseWeight <= threshold → normal Hatch. Bronto is conditional inside HATCH.", DoesWrap = true})

local filterBox = Premium:AddLeftGroupbox("Egg Filters")
DontHatchDropdown = filterBox:AddDropdown("DontHatch", {Text = "Don't Hatch Pet", Values = {}, Multi = true, Searchable = true, Default = {}, Callback = function(values)
    table.clear(State.DontHatch)
    if type(values) == "table" then
        for petName, enabled in pairs(values) do if enabled and type(petName) == "string" then State.DontHatch[petName] = true end end
        for _, petName in ipairs(values) do if type(petName) == "string" then State.DontHatch[petName] = true end end
    end
end})

ENV.FableAutoHatch = {
    Stop = function()
        State.StopRequested = true
        State.Running = false
        State.Destroyed = true
        for _, connection in pairs(Connections) do pcall(function() connection:Disconnect() end) end
        table.clear(Connections)
    end,
    GetState = function() return State end,
}

if type(Library.OnUnload) == "function" then
    pcall(function() Library:OnUnload(function() ENV.FableAutoHatch.Stop() end) end)
end

task.spawn(function()
    local last = ""
    while LP.Parent and not State.Destroyed do
        local garden = getGardenSet()
        if GardenLabel then
            GardenLabel:SetText("Garden • " .. tostring(countSet(garden)) .. " active\n" .. shortSet(garden))
        end
        local eggCount = getEggCount()
        if EggCountLabel then EggCountLabel:SetText("Eggs • " .. (eggCount and tostring(eggCount) or "?")) end
        if DontHatchDropdown then
            recoverReadyCache()
            local names, seen = {}, {}
            for _, egg in ipairs(getOwnedEggs(true)) do
                local uuid = egg:GetAttribute("OBJECT_UUID")
                local petType = uuid and getPetType(uuid)
                if petType and not seen[petType] then seen[petType] = true; names[#names + 1] = petType end
            end
            table.sort(names)
            local signature = table.concat(names, "\0")
            if signature ~= last then last = signature; DontHatchDropdown:SetValues(names) end
        end
        task.wait(0.5)
    end
end)

setStatus("IDLE • configure teams")
setSecurity("IDLE")
notify("FABLE AUTOHATCH", "Final canonical cycle loaded.", 4)
print("[FABLE] Final canonical cycle loaded.")
print("[FABLE] REDUCTION -> conditional HATCH/BRONTO -> SELL -> REDUCTION")
