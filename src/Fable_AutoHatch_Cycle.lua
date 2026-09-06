-- FABLE AUTOHATCH • CANONICAL CYCLE
-- ============================================================
-- Uses the approved UI surface, approved Egg ESP, exact UUID teams,
-- ActivePetsService garden verification, approved 13-position map,
-- and verified HatchPet / SellAllPets_RE remotes.
--
-- Cycle:
--   REDUCTION -> READY -> conditional BRONTO/HATCH -> SELL -> REDUCTION
--
-- Team security:
--   UNEQUIP ALL -> GARDEN EMPTY -> EQUIP TARGET -> EXACT UUID CHECK
--   Any mismatch hard-stops the automation.

repeat task.wait() until game:IsLoaded()

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")

local LP = Players.LocalPlayer
if not LP then return end

local ENV = (type(getgenv) == "function" and getgenv()) or _G

if type(ENV.FableAutoHatch) == "table" and type(ENV.FableAutoHatch.Stop) == "function" then
    pcall(ENV.FableAutoHatch.Stop)
end

local BASE = "https://raw.githubusercontent.com/shoroblox167-a11y/for-script-only/main/src/"
local UI_URL = "https://raw.githubusercontent.com/9kkinc-sudo/ui_lib/main/source.lua"

local function httpLoad(url)
    local source = game:HttpGet(url)
    local fn, err = loadstring(source)
    if not fn then error(err or ("loadstring failed: " .. url), 2) end
    return fn()
end

-- Reuse the exact preloaded exoui(3) library when present. Otherwise use
-- the same upstream UI source referenced by the supplied Exo/Fable base.
local Library = ENV.Library
if not Library or type(Library.CreateWindow) ~= "function" then
    Library = httpLoad(UI_URL)
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

-- Compatibility bridge required by the approved ESP source; the ESP itself
-- remains unchanged in its own repository file.
if type(ENV.getTimerText) ~= "function" then
    ENV.getTimerText = function(egg)
        local t = egg and egg:GetAttribute("TimeToHatch")
        if typeof(t) ~= "number" then return "Timer: ?" end
        if t <= 0 then return "READY" end
        t = math.max(0, t)
        local minutes = math.floor(t / 60)
        local seconds = math.floor(t % 60)
        return string.format("%02d:%02d", minutes, seconds)
    end
end

-- Canonical read-only ESP.
pcall(function()
    httpLoad(BASE .. "Fable_EggESP_v6_1_ReexecutionFix.lua")
end)

local State = {
    Running = false,
    Busy = false,
    StopRequested = false,
    Destroyed = false,
    Stage = "IDLE",
    PriorityEgg = "Campfire Egg",
    MaxEggs = 13,
    StopEggCount = 0,
    BrontoThreshold = 1.30,
    AllowBigPetHatch = true,
    Teams = {
        Reduction = {},
        Hatch = {},
        Bronto = {},
        Sell = {},
    },
}

local TEAM_NAMES = {
    Reduction = "Egg Reduction",
    Hatch = "Hatch Egg",
    Bronto = "Pet Size",
    Sell = "Sell Egg",
}

local TEAM_CALL_GAP = 0.08
local POLL_INTERVAL = 0.05
local EMPTY_STABLE_POLLS = 2
local VERIFY_STABLE_POLLS = 2
local READY_TIMEOUT = 1800
local ACTION_TIMEOUT = 10
local OCCUPANCY_RADIUS = 1.25

local ReadyByUUID = {}
local HatchRequested = {}
local Connections = {}
local PlacementPositions = {}

local StatusLabel
local SecurityLabel
local GardenLabel
local CycleLabel
local EggCountLabel
local StartToggle
local TeamDropdowns = {}
local DontHatchDropdown

local function notify(title, description, time)
    pcall(function()
        Library:Notify({Title = title, Description = description, Time = time or 3})
    end)
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
    if ok and type(datastore) == "table" and type(datastore.EquippedPets) == "table" then
        for _, uuid in ipairs(datastore.EquippedPets) do
            result[tostring(uuid)] = true
        end
    end
    return result
end

local function setCount(set)
    local n = 0
    for _ in pairs(set) do n += 1 end
    return n
end

local function setsEqual(a, b)
    for uuid in pairs(a) do
        if not b[uuid] then return false end
    end
    for uuid in pairs(b) do
        if not a[uuid] then return false end
    end
    return true
end

local function setFromTeam(role)
    local result = {}
    for uuid, enabled in pairs(State.Teams[role] or {}) do
        if enabled then result[uuid] = true end
    end
    return result
end

local function shortSet(set)
    local list = {}
    for uuid in pairs(set) do list[#list + 1] = "..." .. tostring(uuid):sub(-8) end
    table.sort(list)
    if #list == 0 then return "none" end
    return table.concat(list, ", ")
end

local function setStatus(text)
    State.Stage = text
    if StatusLabel then StatusLabel:SetText("Status • " .. tostring(text)) end
end

local function setSecurity(text, ok)
    if not SecurityLabel then return end
    SecurityLabel:SetText("Security • " .. tostring(text))
    SecurityLabel.TextColor3 = ok == true
        and Library.Scheme.Green
        or ok == false
        and Library.Scheme.Red
        or Library.Scheme.Yellow
end

local function refreshGardenLabel()
    local garden = getGardenSet()
    if GardenLabel then
        GardenLabel:SetText("Garden • " .. tostring(setCount(garden)) .. " active\n" .. shortSet(garden))
    end
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
        if tostring(egg:GetAttribute("OBJECT_UUID")) == uuid then
            return egg
        end
    end
    return nil
end

local function getSavedObject(uuid)
    local data = getData()
    local allSlots = data and data.SaveSlots and data.SaveSlots.AllSlots
    if type(allSlots) ~= "table" then return nil end
    for _, slot in pairs(allSlots) do
        if type(slot) == "table" and type(slot.SavedObjects) == "table" then
            local exact = slot.SavedObjects[uuid]
            if type(exact) == "table" then return exact end
            for key, candidate in pairs(slot.SavedObjects) do
                if tostring(key) == tostring(uuid) and type(candidate) == "table" then
                    return candidate
                end
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
        setSecurity("BLOCKED • cannot verify stop threshold", false)
        return true
    end
    if count <= State.StopEggCount then
        setStatus(string.format("STOPPED • eggs %d <= threshold %d", count, State.StopEggCount))
        return true
    end
    return false
end

local function getReadyUUIDs()
    local result = {}
    for _, egg in ipairs(getOwnedEggs(true)) do
        local timer = egg:GetAttribute("TimeToHatch")
        local uuid = egg:GetAttribute("OBJECT_UUID")
        if typeof(timer) == "number" and timer <= 0 and uuid then
            result[tostring(uuid)] = true
        end
    end
    return result
end

local function getReadyEggsForBatch(batch)
    local result = {}
    for uuid in pairs(batch) do
        local egg = findEgg(uuid)
        if egg then
            local timer = egg:GetAttribute("TimeToHatch")
            if typeof(timer) == "number" and timer <= 0 then
                result[#result + 1] = egg
            end
        end
    end
    return result
end

local function recoverReadyCache()
    if type(getconnections) ~= "function" or not EggReadyToHatch_RE then return end
    local ready = getReadyUUIDs()
    if next(ready) == nil then return end
    local function getter(func)
        if type(getupvalues) == "function" then
            local ok, v = pcall(getupvalues, func)
            return ok and v or nil
        end
        if debug and type(debug.getupvalues) == "function" then
            local ok, v = pcall(debug.getupvalues, func)
            return ok and v or nil
        end
        return nil
    end
    local function walk(root, visited, depth)
        if type(root) ~= "table" or visited[root] or depth > 8 then return end
        visited[root] = true
        for key, value in pairs(root) do
            local keyText = tostring(key)
            local valueText = tostring(value)
            if ready[keyText] and type(value) == "string" then
                ReadyByUUID[keyText] = {petType = value, source = "native renderer cache"}
            elseif ready[valueText] and type(key) == "string" then
                ReadyByUUID[valueText] = {petType = key, source = "native renderer cache"}
            end
            if type(value) == "table" then walk(value, visited, depth + 1) end
        end
    end
    local ok, connections = pcall(function() return getconnections(EggReadyToHatch_RE.OnClientEvent) end)
    if not ok or type(connections) ~= "table" then return end
    for _, connection in ipairs(connections) do
        local callback
        pcall(function() callback = connection.Function or connection.Callback end)
        local ups = callback and getter(callback)
        if type(ups) == "table" then
            for _, value in pairs(ups) do
                if type(value) == "table" then walk(value, {}, 0) end
            end
        end
    end
end

Connections.Ready = EggReadyToHatch_RE.OnClientEvent:Connect(function(petType, eggUUID)
    if eggUUID and petType then
        ReadyByUUID[tostring(eggUUID)] = {petType = tostring(petType), source = "EggReadyToHatch_RE"}
    end
end)

local function waitUntil(predicate, timeout)
    local started = os.clock()
    while State.Running and not State.StopRequested and os.clock() - started < timeout do
        if predicate() then return true end
        task.wait(POLL_INTERVAL)
    end
    return false
end

local function fireEquip(uuid)
    return pcall(function() PetsService:EquipPet(uuid) end)
end

local function fireUnequip(uuid)
    return pcall(function() PetsService:UnequipPet(uuid) end)
end

local function clearGarden()
    local garden = getGardenSet()
    local uuids = {}
    for uuid in pairs(garden) do uuids[#uuids + 1] = uuid end
    table.sort(uuids)
    for i, uuid in ipairs(uuids) do
        local ok = fireUnequip(uuid)
        if not ok then return false, "Unequip failed: ..." .. uuid:sub(-8) end
        if i < #uuids then task.wait(TEAM_CALL_GAP) end
    end
    local stable = 0
    local ok = waitUntil(function()
        local empty = next(getGardenSet()) == nil
        if empty then stable += 1 else stable = 0 end
        return stable >= EMPTY_STABLE_POLLS
    end, ACTION_TIMEOUT)
    return ok, ok and nil or "Garden did not become empty"
end

local function equipExact(role, overrideSet)
    local target = overrideSet or setFromTeam(role)
    if next(target) == nil then return false, "Target team is empty" end
    for uuid in pairs(target) do
        if not inventoryHas(uuid) then
            return false, "Target UUID is no longer in inventory: ..." .. tostring(uuid):sub(-8)
        end
    end
    local clearOK, clearErr = clearGarden()
    if not clearOK then return false, clearErr end
    local uuids = {}
    for uuid in pairs(target) do uuids[#uuids + 1] = uuid end
    table.sort(uuids)
    for i, uuid in ipairs(uuids) do
        local ok = fireEquip(uuid)
        if not ok then return false, "Equip failed: ..." .. uuid:sub(-8) end
        if i < #uuids then task.wait(TEAM_CALL_GAP) end
    end
    local stable = 0
    local verified = waitUntil(function()
        local same = setsEqual(target, getGardenSet())
        if same then stable += 1 else stable = 0 end
        return stable >= VERIFY_STABLE_POLLS
    end, ACTION_TIMEOUT)
    if not verified then
        local actual = getGardenSet()
        return false, "SECURITY MISMATCH • target: " .. shortSet(target) .. " • garden: " .. shortSet(actual)
    end
    return true
end

local function loadPlacementPositions()
    if #PlacementPositions > 0 then return true end
    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(game:HttpGet(BASE .. "Fable_AutoHatch_Positions.json"))
    end)
    if not ok or type(decoded) ~= "table" then return false end
    for _, point in ipairs(decoded) do
        if tonumber(point.x) and tonumber(point.y) and tonumber(point.z) then
            PlacementPositions[#PlacementPositions + 1] = Vector3.new(point.x, point.y, point.z)
        end
    end
    return #PlacementPositions > 0
end

local function isOccupied(position)
    for _, egg in ipairs(getOwnedEggs(true)) do
        local part = egg.PrimaryPart or egg:FindFirstChildWhichIsA("BasePart", true)
        if part and (part.Position - position).Magnitude <= OCCUPANCY_RADIUS then
            return true
        end
    end
    return false
end

local function findEggTool()
    local containers = {LP.Character, LP.Backpack}
    local wanted = string.lower(State.PriorityEgg)
    for _, container in ipairs(containers) do
        if container then
            for _, child in ipairs(container:GetChildren()) do
                if child:IsA("Tool") and string.lower(child.Name):find(wanted, 1, true) then
                    return child
                end
            end
        end
    end
    return nil
end

local function equipEggTool()
    local tool = findEggTool()
    if not tool then return false end
    local humanoid = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return false end
    if tool.Parent ~= LP.Character then
        local ok = pcall(function() humanoid:EquipTool(tool) end)
        if not ok then return false end
        task.wait(0.05)
    end
    return true
end

local function eggAtPosition(position)
    for _, egg in ipairs(getOwnedEggs(true)) do
        local part = egg.PrimaryPart or egg:FindFirstChildWhichIsA("BasePart", true)
        if part and (part.Position - position).Magnitude <= OCCUPANCY_RADIUS then
            return egg
        end
    end
    return nil
end

local function createEggAt(position)
    if not equipEggTool() then return false, "No matching egg tool in Backpack/Character" end
    if isOccupied(position) then return true end
    local before = {}
    for _, egg in ipairs(getOwnedEggs(true)) do
        local uuid = egg:GetAttribute("OBJECT_UUID")
        if uuid then before[tostring(uuid)] = true end
    end
    local ok, err = pcall(function() PetEggService:FireServer("CreateEgg", position) end)
    if not ok then return false, tostring(err) end
    local found = waitUntil(function()
        local egg = eggAtPosition(position)
        if not egg then return false end
        local uuid = egg:GetAttribute("OBJECT_UUID")
        return uuid and not before[tostring(uuid)]
    end, ACTION_TIMEOUT)
    return found, found and nil or "CreateEgg verification failed"
end

local function maintainEggCount()
    if not loadPlacementPositions() then return false, "Approved placement map unavailable" end
    local target = math.clamp(math.floor(State.MaxEggs), 0, 13)
    if target <= 0 then return false, "Max eggs must be greater than 0" end
    while State.Running and not State.StopRequested do
        local eggs = getOwnedEggs(true)
        if #eggs >= target then return true end
        local placed = false
        for _, position in ipairs(PlacementPositions) do
            if #getOwnedEggs(true) >= target then return true end
            if not isOccupied(position) then
                local ok, err = createEggAt(position)
                if not ok then return false, err end
                placed = true
            end
        end
        if not placed then
            return false, "No approved Region 1 middle placement slot available"
        end
    end
    return false, "Stopped"
end

local function waitBatchReady(batch)
    local started = os.clock()
    while State.Running and not State.StopRequested and os.clock() - started < READY_TIMEOUT do
        recoverReadyCache()
        local allReady = true
        for uuid in pairs(batch) do
            local egg = findEgg(uuid)
            if not egg then
                allReady = false
                break
            end
            local timer = egg:GetAttribute("TimeToHatch")
            local petType = getPetType(uuid)
            if typeof(timer) ~= "number" or timer > 0 or not petType then
                allReady = false
                break
            end
        end
        if allReady then return true end
        task.wait(0.25)
    end
    return false
end

local function classifyBatch(batch)
    local normal, big = {}, {}
    recoverReadyCache()
    for uuid in pairs(batch) do
        local petType = getPetType(uuid)
        local baseWeight = getBaseWeight(uuid)
        if not petType then return nil, nil, "Ready pet type unavailable for ..." .. tostring(uuid):sub(-8) end
        if baseWeight == nil then return nil, nil, "Ready BaseWeight unavailable for ..." .. tostring(uuid):sub(-8) end
        local entry = {uuid = uuid, petType = petType, baseWeight = baseWeight}
        if State.AllowBigPetHatch and baseWeight > State.BrontoThreshold then
            big[#big + 1] = entry
        else
            normal[#normal + 1] = entry
        end
    end
    return normal, big
end

local function hatchEntries(entries, role)
    if #entries == 0 then return true end
    local target = setFromTeam(role)
    local ok, err = equipExact(role, target)
    if not ok then return false, err end
    setSecurity("PASS • " .. TEAM_NAMES[role], true)
    for _, entry in ipairs(entries) do
        if State.StopRequested then return false, "Stopped" end
        local egg = findEgg(entry.uuid)
        if not egg then return false, "Ready egg disappeared: ..." .. entry.uuid:sub(-8) end
        if HatchRequested[entry.uuid] then continue end
        HatchRequested[entry.uuid] = true
        local fireOK, fireErr = pcall(function()
            PetEggService:FireServer("HatchPet", egg)
        end)
        if not fireOK then
            HatchRequested[entry.uuid] = nil
            return false, tostring(fireErr)
        end
        local gone = waitUntil(function() return findEgg(entry.uuid) == nil end, ACTION_TIMEOUT)
        if not gone then
            return false, "Hatch verification failed: ..." .. entry.uuid:sub(-8)
        end
        task.wait(0.05)
    end
    return true
end

local function sellStage()
    local ok, err = equipExact("Sell")
    if not ok then return false, err end
    setSecurity("PASS • " .. TEAM_NAMES.Sell, true)
    local fired, fireErr = pcall(function() SellAllPets_RE:FireServer() end)
    if not fired then return false, tostring(fireErr) end
    task.wait(0.20)
    return true
end

local function runCycle()
    if stopThresholdReached() then return true end

    setStatus("REDUCTION • switching")
    local ok, err = equipExact("Reduction")
    if not ok then return false, err end
    setSecurity("PASS • REDUCTION", true)

    setStatus("REDUCTION • maintaining eggs")
    ok, err = maintainEggCount()
    if not ok then return false, err end

    if stopThresholdReached() then return true end

    local batch = {}
    for _, egg in ipairs(getOwnedEggs(true)) do
        local uuid = egg:GetAttribute("OBJECT_UUID")
        if uuid then batch[tostring(uuid)] = true end
    end
    if next(batch) == nil then return false, "No priority eggs on farm" end

    setStatus("WAITING • eggs to become READY")
    ok = waitBatchReady(batch)
    if not ok then return false, "READY batch timeout or missing ready pet data" end

    local normal, big
    normal, big, err = classifyBatch(batch)
    if not normal then return false, err end

    setStatus(string.format("HATCH • %d normal / %d Bronto", #normal, #big))
    if #big > 0 then
        if not State.AllowBigPetHatch then
            return false, "Big pet hatch disabled but a Bronto-class egg is present"
        end
        ok, err = hatchEntries(big, "Bronto")
        if not ok then return false, err end
    end

    if #normal > 0 then
        ok, err = hatchEntries(normal, "Hatch")
        if not ok then return false, err end
    end

    setStatus("SELL • switching")
    ok, err = sellStage()
    if not ok then return false, err end

    table.clear(HatchRequested)
    return true
end

-- ------------------------------------------------------------
-- UI
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
local Hatching = Window:AddTab({Name = "Hatching Teams", Description = "Exact UUID team configuration."})
local Eggs = Window:AddTab({Name = "Eggs Priority", Description = "Egg selection and placement settings."})
local Sell = Window:AddTab({Name = "Pet Sell Settings", Description = "Selling configuration."})
local Premium = Window:AddTab({Name = "Premium", Description = "Conditional Brontosaurus settings."})

local homeLeft = Home:AddLeftGroupbox("Fable Status")
local homeRight = Home:AddRightGroupbox("Cycle")
StatusLabel = homeLeft:AddLabel({Text = "Status • IDLE", DoesWrap = true})
SecurityLabel = homeLeft:AddLabel({Text = "Security • IDLE", DoesWrap = true})
GardenLabel = homeLeft:AddLabel({Text = "Garden • 0 active", DoesWrap = true})
CycleLabel = homeRight:AddLabel({Text = "Cycle • 0", DoesWrap = true})
EggCountLabel = homeRight:AddLabel({Text = "Eggs • ?", DoesWrap = true})

StartToggle = homeRight:AddToggle("AutoHatch", {
    Text = "Auto Hatch",
    Default = false,
    Callback = function(value)
        if value then
            if State.Running then return end
            State.StopRequested = false
            State.Running = true
            task.spawn(function()
                local cycleNumber = 0
                while State.Running and not State.StopRequested and not State.Destroyed do
                    cycleNumber += 1
                    if CycleLabel then CycleLabel:SetText("Cycle • " .. tostring(cycleNumber)) end
                    local ok, err = pcall(runCycle)
                    if not ok then err = tostring(err) end
                    if not ok or err == false then
                        State.Running = false
                        setSecurity("BLOCKED • " .. tostring(err), false)
                        setStatus("STOPPED • cycle failure")
                        notify("FABLE AUTOHATCH", tostring(err), 6)
                        break
                    end
                    if State.StopRequested then break end
                    task.wait(0.10)
                end
                State.Busy = false
                if StartToggle and StartToggle.Value then
                    pcall(function() StartToggle:SetValue(false, true) end)
                end
            end)
        else
            State.StopRequested = true
            State.Running = false
            setStatus("STOPPING")
        end
    end,
})

homeRight:AddButton("Stop / Reset", function()
    State.StopRequested = true
    State.Running = false
    State.Busy = false
    setStatus("IDLE")
    setSecurity("IDLE", nil)
    if StartToggle then pcall(function() StartToggle:SetValue(false, true) end) end
end)

homeRight:AddButton("Refresh Egg ESP", function()
    if ENV.FableEggESP and type(ENV.FableEggESP.Refresh) == "function" then
        ENV.FableEggESP.Refresh()
    end
end)

-- Team editors: same exact-UUID inventory concept as the approved base.
local teamBoxes = {
    Reduction = Hatching:AddLeftGroupbox("Egg Reduction Team"),
    Hatch = Hatching:AddLeftGroupbox("Hatch Egg Team"),
    Bronto = Hatching:AddRightGroupbox("Pet Size Team"),
    Sell = Hatching:AddRightGroupbox("Sell Egg Team"),
}

local function createTeamEditor(role)
    local box = teamBoxes[role]
    local values, lookup = getInventoryValues()
    box:AddLabel({Text = TEAM_NAMES[role] .. " • exact inventory UUIDs", DoesWrap = true})
    local dropdown = box:AddDropdown("Team_" .. role, {
        Text = "Select pets",
        Values = values,
        Multi = true,
        Searchable = true,
        Callback = function(selected)
            local newSet = {}
            if type(selected) == "table" then
                for value, enabled in pairs(selected) do
                    if enabled and lookup[value] then newSet[lookup[value]] = true end
                end
                for _, value in ipairs(selected) do
                    if lookup[value] then newSet[lookup[value]] = true end
                end
            end
            local n = setCount(newSet)
            if n > 8 then
                notify("FABLE", TEAM_NAMES[role] .. " exceeds 8 pets; selection was blocked.", 4)
                return
            end
            State.Teams[role] = newSet
        end,
    })
    TeamDropdowns[role] = dropdown
    box:AddButton("Reload Inventory", function()
        local newValues = getInventoryValues()
        dropdown:SetValues(newValues)
    end)
    box:AddButton("Verify Garden", function()
        local wanted = setFromTeam(role)
        local garden = getGardenSet()
        if setsEqual(wanted, garden) then
            notify("SECURITY OK", TEAM_NAMES[role] .. " exactly matches the garden.", 3)
        else
            notify("SECURITY BLOCKED", "Target: " .. shortSet(wanted) .. "\nGarden: " .. shortSet(garden), 6)
        end
    end)
end

createTeamEditor("Reduction")
createTeamEditor("Hatch")
createTeamEditor("Bronto")
createTeamEditor("Sell")

-- Eggs.
local eggLeft = Eggs:AddLeftGroupbox("Egg Priority")
local eggRight = Eggs:AddRightGroupbox("Placement")
eggLeft:AddDropdown("PriorityEgg", {
    Text = "#1 Priority",
    Values = {"Campfire Egg", "Rainbow Campfire Egg"},
    Default = "Campfire Egg",
    Callback = function(value) State.PriorityEgg = value end,
})
eggLeft:AddInput("MaxEggs", {
    Text = "Max eggs to place",
    Default = "13",
    Numeric = true,
    Finished = true,
    Callback = function(value)
        local n = tonumber(value)
        if n then State.MaxEggs = math.clamp(math.floor(n), 1, 13) end
    end,
})
eggLeft:AddInput("StopEggCount", {
    Text = "Stop when eggs <=",
    Default = "0",
    Numeric = true,
    Finished = true,
    Callback = function(value)
        local n = tonumber(value)
        if n then State.StopEggCount = math.max(0, math.floor(n)) end
    end,
})
eggLeft:AddButton("Maintain Eggs Now", function()
    if State.Running then return end
    local ok, err = maintainEggCount()
    notify(ok and "PLACEMENT" or "PLACEMENT BLOCKED", ok and "Approved Region 1 middle positions maintained." or tostring(err), ok and 3 or 6)
end)
eggRight:AddToggle("EggESP", {
    Text = "Egg ESP active",
    Default = true,
    Callback = function(value)
        if value and ENV.FableEggESP and type(ENV.FableEggESP.Refresh) == "function" then
            ENV.FableEggESP.Refresh()
        end
    end,
})
eggRight:AddToggle("HideUnready", {
    Text = "Hide unready eggs",
    Default = false,
    Callback = function(value)
        if ENV.FableEggESP and type(ENV.FableEggESP.SetHideUnready) == "function" then
            ENV.FableEggESP.SetHideUnready(value)
        end
    end,
})
eggRight:AddSlider("ESPDistance", {
    Text = "Egg ESP distance",
    Default = 250,
    Min = 50,
    Max = 500,
    Rounding = 0,
    Callback = function(value)
        if ENV.FableEggESP and type(ENV.FableEggESP.SetMaxDistance) == "function" then
            ENV.FableEggESP.SetMaxDistance(value)
        end
    end,
})

-- Sell.
local sellLeft = Sell:AddLeftGroupbox("Pet Sell List")
local sellRight = Sell:AddRightGroupbox("Pet Sell Controls")
sellLeft:AddDropdown("SellEgg", {
    Text = "Select Egg",
    Values = {"Campfire Egg", "Rainbow Campfire Egg"},
    Default = "Campfire Egg",
})
sellLeft:AddToggle("OnlySellHatchedPets", {
    Text = "Only sell hatched pets",
    Default = true,
})
sellRight:AddButton("Sell All Pets", function()
    if State.Running then return end
    local ok, err = pcall(function() SellAllPets_RE:FireServer() end)
    notify(ok and "SELL" or "SELL FAILED", ok and "SellAllPets_RE fired." or tostring(err), ok and 3 or 6)
end)
sellRight:AddLabel({Text = "Verified max-inventory sell remote: SellAllPets_RE", DoesWrap = true})

-- Premium / conditional Bronto.
local premiumLeft = Premium:AddLeftGroupbox("Big Pet Hatch")
local premiumRight = Premium:AddRightGroupbox("Brontosaurus")
premiumLeft:AddToggle("AllowBigPetHatch", {
    Text = "Allow Big Pet Hatch",
    Default = true,
    Callback = function(value) State.AllowBigPetHatch = value end,
})
premiumRight:AddInput("BrontoThreshold", {
    Text = "BaseWeight threshold",
    Default = "1.30",
    Numeric = true,
    Finished = true,
    Callback = function(value)
        local n = tonumber(value)
        if n then State.BrontoThreshold = n end
    end,
})
premiumRight:AddLabel({
    Text = "Strict rule: BaseWeight > threshold uses Brontosaurus; <= uses the normal Hatch team. Bronto is part of HATCH, not a separate cycle.",
    DoesWrap = true,
})

local dontHatchValues = {}
DontHatchDropdown = Premium:AddLeftGroupbox("Egg Filters"):AddDropdown("DontHatch", {
    Text = "Don't Hatch Pet",
    Values = dontHatchValues,
    Multi = true,
    Searchable = true,
    Default = {},
})

-- Keep the exclusion UI populated without rebuilding it unnecessarily.
task.spawn(function()
    local last = ""
    while LP.Parent and not State.Destroyed do
        local seen, names = {}, {}
        recoverReadyCache()
        for _, egg in ipairs(getOwnedEggs(true)) do
            local uuid = egg:GetAttribute("OBJECT_UUID")
            local petType = uuid and getPetType(uuid)
            if petType and not seen[petType] then
                seen[petType] = true
                names[#names + 1] = petType
            end
        end
        table.sort(names)
        local signature = table.concat(names, "\0")
        if signature ~= last and DontHatchDropdown then
            last = signature
            DontHatchDropdown:SetValues(names)
        end
        refreshGardenLabel()
        local count = getEggCount()
        if EggCountLabel then EggCountLabel:SetText("Eggs • " .. (count and tostring(count) or "?")) end
        task.wait(0.5)
    end
end)

ENV.FableAutoHatch = {
    Stop = function()
        State.StopRequested = true
        State.Running = false
        State.Destroyed = true
        for _, connection in pairs(Connections) do
            pcall(function() connection:Disconnect() end)
        end
        table.clear(Connections)
    end,
    GetState = function() return State end,
}

if type(Library.OnUnload) == "function" then
    pcall(function() Library:OnUnload(function() ENV.FableAutoHatch.Stop() end) end)
end

setStatus("IDLE • configure teams")
setSecurity("IDLE", nil)
notify("FABLE AUTOHATCH", "Canonical cycle loaded.", 4)
print("[FABLE] Canonical AutoHatch cycle loaded.")
print("[FABLE] Reduction -> conditional Hatch/Bronto -> Sell -> Reduction")
