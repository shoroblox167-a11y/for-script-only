--[[
    FABLE TRANSFER V1

    Dedicated egg-transfer automation.
    This script intentionally contains NO pet-selling system.

    Locked workflow:
      • Night Egg only
      • Always fill the farm to MAX eggs
      • Fast / direct egg placement
      • Middle egg placement
      • Overdrive + Ultra timing
      • One-phase Egg Reduction team:
          Birb, Rainbow Birb, Mimic Octopus
      • Koi team:
          1 Koi + remaining slots filled with Ruby Squid
      • Fast-gift every Night Egg pet to mysto_sailor
        (existing pets count too; no freshness requirement)
      • Trade Pet Teams always enabled
      • Only auto-handle trade requests from arimabns
      • Before accepting arimabns, remove the current garden pet team
      • Auto accept/finish arimabns trades
      • Auto Pet Slot:
          Common Egg + Uncommon Egg pet types only
          Lowest qualifying level for each stage
          Uses the game's single UnlockSlotFromPet remote
      • Continuous cycle until the user toggles the script OFF

    Source-backed game paths reused from Fable V53:
      ReplicatedStorage.GameEvents.PetsService
      ReplicatedStorage.GameEvents.PetEggService
      ReplicatedStorage.GameEvents.TradeEvents.AddItem
      ReplicatedStorage.GameEvents.UnlockSlotFromPet
      ReplicatedStorage.Modules.DataService
      ReplicatedStorage.Modules.PetServices.PetGiftingService
      Farm.Important.Objects_Physical / PetEgg attributes
]]

if getgenv and getgenv().FABLE_TRANSFER_V1 then
    warn("[FABLE TRANSFER V1] Already loaded.")
    return
end
if getgenv then
    getgenv().FABLE_TRANSFER_V1 = true
end

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    return
end

-- Same game gate used by the working Fable code.
if tostring(game.GameId) ~= "7436755782" then
    warn("[FABLE TRANSFER V1] Unsupported game.")
    return
end

---------------------------------------------------------------------
-- SERVICES / MODULES
---------------------------------------------------------------------

local GameEvents = ReplicatedStorage:WaitForChild("GameEvents")
local PetsService = GameEvents:WaitForChild("PetsService")
local PetEggService = GameEvents:WaitForChild("PetEggService")
local AddItemRemote = GameEvents:WaitForChild("TradeEvents"):WaitForChild("AddItem")
local UnlockSlotRemote = GameEvents:WaitForChild("UnlockSlotFromPet")

local okData, DataService = pcall(function()
    return require(ReplicatedStorage.Modules.DataService)
end)
if not okData or not DataService then
    warn("[FABLE TRANSFER V1] Failed to require DataService.")
    return
end

local okGift, PetGiftingService = pcall(function()
    return require(ReplicatedStorage.Modules.PetServices.PetGiftingService)
end)
if not okGift or not PetGiftingService then
    warn("[FABLE TRANSFER V1] Failed to require PetGiftingService.")
    return
end

---------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------

local CONFIG = {
    TARGET_GIFT_PLAYER = "mysto_sailor",
    TARGET_TRADE_PLAYER = "arimabns",
    DEFAULT_EGG = "Night Egg",

    -- Continuous max fill.
    MAX_EGG_TARGET = 0, -- 0 = use the game's live MaxEggsInFarm value.

    -- Fast placement / timing mode.
    FAST_PLACEMENT = true,
    MIDDLE_EGGS = true,
    OVERDRIVE = true,
    ULTRA = true,

    -- Team definitions.
    REDUCTION_PETS = {
        "Birb",
        "Rainbow Birb",
        "Mimic Octopus",
    },

    -- Night Egg membership from the supplied V53 egg data.
    -- All listed names count regardless of the old sell-flag value.
    NIGHT_EGG_PETS = {
        ["Hedgehog"] = true,
        ["Mole"] = true,
        ["Frog"] = true,
        ["Echo Frog"] = true,
        ["Night Owl"] = true,
        ["Raccoon"] = true,
    },

    -- Common + Uncommon Egg contents from the supplied V53 egg data.
    AUTO_SLOT_PETS = {
        ["Dog"] = true,
        ["Golden Lab"] = true,
        ["Bunny"] = true,
        ["Black Bunny"] = true,
        ["Chicken"] = true,
        ["Cat"] = true,
        ["Deer"] = true,
    },

    -- Exact Auto Pet Slot stage requirements in the working V53 code.
    AUTO_SLOT_REQUIREMENTS = { 20, 30, 45, 60, 75 },

    -- Small delays only; kept low for transfer speed.
    PLACE_STAGGER = 0.025,
    TEAM_SETTLE = 0.25,
    GIFT_STAGGER = 0.08,
    LOOP_IDLE = 0.15,
}

---------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------

local State = {
    enabled = false,
    shuttingDown = false,

    -- V1 UI-connected controls.
    autoGiftEnabled = true,
    autoPetSlotEnabled = true,
    tradePetTeamsEnabled = true,

    character = LocalPlayer.Character,
    humanoid = nil,
    backpack = nil,

    farm = nil,
    objectsPhysical = nil,
    centerPart = nil,

    currentGardenTeamName = nil,
    currentGardenTeam = {},

    tradeBusy = false,
    acceptedArimabnsRequest = false,
    lastTradeHandledAt = 0,

    autoSlotBusy = false,
    autoGiftBusy = false,
    cycleBusy = false,

    lastStatus = "Starting...",
}

local Connections = {}
local Threads = {}

---------------------------------------------------------------------
-- CHARACTER / INVENTORY HELPERS
---------------------------------------------------------------------

local function refreshCharacterRefs()
    State.character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    State.humanoid = State.character:FindFirstChildOfClass("Humanoid")
    State.backpack = LocalPlayer:FindFirstChildOfClass("Backpack") or LocalPlayer:WaitForChild("Backpack")
end

refreshCharacterRefs()

Connections.character = LocalPlayer.CharacterAdded:Connect(function()
    task.wait(0.25)
    refreshCharacterRefs()
end)

local function getData()
    local ok, result = pcall(function()
        return DataService:GetData()
    end)
    if ok and type(result) == "table" then
        return result
    end
    return nil
end

local function getPetsData(data)
    if not data then
        return nil
    end
    return data.PetsData or data
end

local function getPetInventory(data)
    local petsData = getPetsData(data)
    if not petsData then
        return {}
    end

    local node = petsData.PetInventory
    if type(node) == "table" and type(node.Data) == "table" then
        return node.Data
    end
    if type(node) == "table" then
        return node
    end
    return {}
end

local function getEquippedPets(data)
    local petsData = getPetsData(data)
    if not petsData then
        return {}
    end

    if type(petsData.EquippedPets) == "table" then
        return petsData.EquippedPets
    end
    return {}
end

local function getMaxEggCapacity(data)
    local petsData = getPetsData(data)
    if not petsData then
        return 0
    end

    local stats = petsData.MutableStats
    if type(stats) == "table" then
        return tonumber(stats.MaxEggsInFarm) or 0
    end

    return tonumber(petsData.MaxEggsInFarm) or 0
end

local function getMaxEquippedPets(data)
    local petsData = getPetsData(data)
    if not petsData then
        return 0
    end

    local stats = petsData.MutableStats
    if type(stats) == "table" then
        return tonumber(stats.MaxEquippedPets) or 0
    end

    return tonumber(petsData.MaxEquippedPets) or 0
end

local function getToolByPetUUID(uuid)
    if not uuid then
        return nil
    end

    local backpack = State.backpack or LocalPlayer:FindFirstChildOfClass("Backpack")
    if backpack then
        for _, item in ipairs(backpack:GetChildren()) do
            if item:IsA("Tool") then
                local petUUID = item:GetAttribute("PET_UUID")
                if petUUID == uuid then
                    return item
                end
            end
        end
    end

    local character = State.character
    if character then
        local item = character:FindFirstChildOfClass("Tool")
        if item then
            local petUUID = item:GetAttribute("PET_UUID")
            if petUUID == uuid then
                return item
            end
        end
    end

    return nil
end

local function equipTool(tool)
    refreshCharacterRefs()
    if not tool or not tool.Parent or not State.humanoid then
        return false
    end

    local ok = pcall(function()
        State.humanoid:EquipTool(tool)
    end)
    return ok
end

local function unequipTools()
    refreshCharacterRefs()
    if State.humanoid then
        pcall(function()
            State.humanoid:UnequipTools()
        end)
    end
end

local function getEquippedTool()
    local character = State.character
    if not character then
        return nil
    end
    return character:FindFirstChildOfClass("Tool")
end

---------------------------------------------------------------------
-- FARM / EGG HELPERS
---------------------------------------------------------------------

local function findMyFarm()
    local farms = workspace:FindFirstChild("Farm")
    if not farms then
        return nil
    end

    for _, farm in ipairs(farms:GetChildren()) do
        local important = farm:FindFirstChild("Important")
        local data = important and important:FindFirstChild("Data")
        local owner = data and data:FindFirstChild("Owner")

        if owner and owner:IsA("StringValue") and owner.Value == LocalPlayer.Name then
            return farm
        end
    end

    return nil
end

local function refreshFarmRefs()
    State.farm = findMyFarm()
    State.objectsPhysical = nil
    State.centerPart = nil

    if not State.farm then
        return false
    end

    local important = State.farm:FindFirstChild("Important")
    if not important then
        return false
    end

    State.objectsPhysical = important:FindFirstChild("Objects_Physical")
    State.centerPart = State.farm:FindFirstChild("Center_Point")
        or important:FindFirstChild("Center_Point")

    return State.objectsPhysical ~= nil and State.centerPart ~= nil
end

refreshFarmRefs()

local function getFarmEggModels()
    local result = {}
    local folder = State.objectsPhysical
    if not folder then
        return result
    end

    for _, obj in ipairs(folder:GetChildren()) do
        if obj:IsA("Model") and obj.Name == "PetEgg" then
            table.insert(result, obj)
        end
    end

    return result
end

local function getFarmEggCount()
    return #getFarmEggModels()
end

local function getReadyNightEggs()
    local result = {}

    for _, egg in ipairs(getFarmEggModels()) do
        local timeToHatch = tonumber(egg:GetAttribute("TimeToHatch"))
        local eggName = egg:GetAttribute("EggName")

        if timeToHatch == 0 and eggName == CONFIG.DEFAULT_EGG then
            table.insert(result, egg)
        end
    end

    return result
end

local function getNightEggTool()
    local character = State.character
    if character then
        local equipped = character:FindFirstChildOfClass("Tool")
        if equipped and equipped:GetAttribute("h") == CONFIG.DEFAULT_EGG then
            return equipped
        end
    end

    local backpack = State.backpack
    if backpack then
        for _, tool in ipairs(backpack:GetChildren()) do
            if tool:IsA("Tool") and tool:GetAttribute("h") == CONFIG.DEFAULT_EGG then
                return tool
            end
        end
    end

    return nil
end

local function getEggToolUses(tool)
    if not tool then
        return 0
    end
    return tonumber(tool:GetAttribute("e")) or 0
end

local function getTakenEggPositions()
    local positions = {}

    for _, egg in ipairs(getFarmEggModels()) do
        local hitbox = egg:FindFirstChild("HitBox", true)
        if hitbox and hitbox:IsA("BasePart") then
            table.insert(positions, hitbox.Position)
        elseif egg.PrimaryPart then
            table.insert(positions, egg.PrimaryPart.Position)
        end
    end

    return positions
end

-- Same middle-egg geometry used by the working V53 implementation.
local function makeMiddleEggPositions(center, blockedList)
    local positions = {}

    local blockRadius = 4
    local blockDistSq = blockRadius * blockRadius
    local SQUARE_SIZE = 55
    local GRASS_WIDTH = 14
    local SPACING = 3

    local halfOuter = SQUARE_SIZE / 2
    local halfGrass = GRASS_WIDTH / 2

    local function isBlocked(worldPos)
        for _, blocked in ipairs(blockedList or {}) do
            local dx = worldPos.X - blocked.X
            local dz = worldPos.Z - blocked.Z
            if (dx * dx + dz * dz) <= blockDistSq then
                return true
            end
        end
        return false
    end

    for x = -halfOuter, halfOuter, SPACING do
        for z = -halfOuter, halfOuter, SPACING do
            if math.abs(x) > halfGrass then
                local worldPos = Vector3.new(center.X + x, center.Y, center.Z + z)
                if not isBlocked(worldPos) then
                    table.insert(positions, worldPos)
                end
            end
        end
    end

    table.sort(positions, function(a, b)
        local da = (a.X - center.X) ^ 2 + (a.Z - center.Z) ^ 2
        local db = (b.X - center.X) ^ 2 + (b.Z - center.Z) ^ 2
        return da < db
    end)

    return positions
end

---------------------------------------------------------------------
-- PET TEAM HELPERS
---------------------------------------------------------------------

local function chooseOnePetUUIDByName(inventory, petName)
    local selectedUUID = nil
    local selectedLevel = nil

    for uuid, entry in pairs(inventory) do
        local petType = entry and entry.PetType
        local petData = entry and entry.PetData

        if petType == petName and petData then
            local level = tonumber(petData.Level) or 0

            -- Deterministic choice. We prefer the lowest level only for the
            -- helper's single-pet selections; Auto Pet Slot has its own exact
            -- lowest-qualifying rule below.
            if not selectedLevel or level < selectedLevel then
                selectedLevel = level
                selectedUUID = uuid
            end
        end
    end

    return selectedUUID
end

local function buildReductionTeam()
    local inventory = getPetInventory(getData())
    local team = {}
    local maxPets = getMaxEquippedPets(getData())

    if maxPets <= 0 then
        maxPets = 5
    end

    for _, petName in ipairs(CONFIG.REDUCTION_PETS) do
        if #team >= maxPets then
            break
        end

        local uuid = chooseOnePetUUIDByName(inventory, petName)
        if uuid then
            table.insert(team, uuid)
        end
    end

    return team
end

local function buildKoiTeam()
    local inventory = getPetInventory(getData())
    local maxPets = getMaxEquippedPets(getData())
    if maxPets <= 0 then
        maxPets = 5
    end

    local team = {}
    local koiUUID
    local rubyUUIDs = {}

    for uuid, entry in pairs(inventory) do
        local petType = entry and entry.PetType
        if petType == "Koi" and not koiUUID then
            koiUUID = uuid
        elseif petType == "Ruby Squid" then
            table.insert(rubyUUIDs, uuid)
        end
    end

    -- Exact requested pattern: 1 Koi + Ruby Squid for the remaining slots.
    if koiUUID then
        table.insert(team, koiUUID)
    end

    table.sort(rubyUUIDs)

    for _, uuid in ipairs(rubyUUIDs) do
        if #team >= maxPets then
            break
        end
        table.insert(team, uuid)
    end

    return team
end

local function unequipAllGardenPets()
    local data = getData()
    local equipped = getEquippedPets(data)
    local sent = {}

    for _, uuid in ipairs(equipped) do
        if uuid and not sent[uuid] then
            sent[uuid] = true
            pcall(function()
                PetsService:FireServer("UnequipPet", uuid)
            end)
        end
    end

    task.wait(0.2)
end

local function equipGardenTeam(team, teamName)
    if type(team) ~= "table" or #team == 0 then
        State.currentGardenTeamName = teamName
        State.currentGardenTeam = {}
        return false
    end

    unequipAllGardenPets()

    local data = getData()
    local maxPets = getMaxEquippedPets(data)
    if maxPets <= 0 then
        maxPets = #team
    end

    local count = 0
    local center = State.centerPart and State.centerPart.Position
    if not center then
        refreshFarmRefs()
        center = State.centerPart and State.centerPart.Position
    end
    if not center then
        return false
    end

    local placementCF = CFrame.new(center)

    for _, uuid in ipairs(team) do
        if count >= maxPets then
            break
        end

        if uuid then
            pcall(function()
                PetsService:FireServer("EquipPet", uuid, placementCF)
            end)
            count += 1
        end
    end

    State.currentGardenTeamName = teamName
    State.currentGardenTeam = table.clone(team)
    task.wait(CONFIG.TEAM_SETTLE)
    return true
end

local function ensureReductionTeam()
    local team = buildReductionTeam()
    if #team == 0 then
        State.currentGardenTeamName = "Reduction"
        State.currentGardenTeam = {}
        return false
    end

    if State.currentGardenTeamName == "Reduction" then
        return true
    end

    return equipGardenTeam(team, "Reduction")
end

local function ensureKoiTeam()
    local team = buildKoiTeam()
    if #team == 0 then
        State.currentGardenTeamName = "Koi"
        State.currentGardenTeam = {}
        return false
    end

    if State.currentGardenTeamName == "Koi" then
        return true
    end

    return equipGardenTeam(team, "Koi")
end

---------------------------------------------------------------------
-- FAST NIGHT EGG PLACEMENT
---------------------------------------------------------------------

local function placeNightEggsToMax()
    if not State.enabled or State.tradeBusy then
        return
    end

    if not State.objectsPhysical or not State.centerPart then
        if not refreshFarmRefs() then
            return
        end
    end

    local data = getData()
    local maxEggs = CONFIG.MAX_EGG_TARGET
    if maxEggs <= 0 then
        maxEggs = getMaxEggCapacity(data)
    end

    if maxEggs <= 0 then
        return
    end

    local current = getFarmEggCount()
    local missing = math.max(0, maxEggs - current)
    if missing <= 0 then
        return
    end

    local eggTool = getNightEggTool()
    if not eggTool then
        State.lastStatus = "Waiting for Night Eggs..."
        return
    end

    local uses = getEggToolUses(eggTool)
    if uses <= 0 then
        State.lastStatus = "Night Egg stock is empty."
        return
    end

    local amountToPlace = math.min(missing, uses)
    if amountToPlace <= 0 then
        return
    end

    local center = State.centerPart.Position
    local taken = getTakenEggPositions()
    local positions

    if CONFIG.MIDDLE_EGGS then
        positions = makeMiddleEggPositions(center, taken)
    else
        -- V1 compact-settings fallback: place across the full farm square
        -- instead of preferring the middle-only layout.
        positions = {}
        local halfOuter = 55 / 2
        local spacing = 3

        local function blocked(worldPos)
            for _, blockedPos in ipairs(taken) do
                local dx = worldPos.X - blockedPos.X
                local dz = worldPos.Z - blockedPos.Z
                if (dx * dx + dz * dz) <= 16 then
                    return true
                end
            end
            return false
        end

        for x = -halfOuter, halfOuter, spacing do
            for z = -halfOuter, halfOuter, spacing do
                local worldPos = Vector3.new(center.X + x, center.Y, center.Z + z)
                if not blocked(worldPos) then
                    table.insert(positions, worldPos)
                end
            end
        end
    end

    if #positions == 0 then
        State.lastStatus = "No valid egg positions."
        return
    end

    unequipTools()
    if not equipTool(eggTool) then
        State.lastStatus = "Failed to equip Night Egg."
        return
    end

    State.lastStatus = string.format("Placing Night Eggs %d/%d...", amountToPlace, maxEggs)

    for i = 1, amountToPlace do
        if not State.enabled or State.tradeBusy then
            break
        end

        local pos = positions[i]
        if not pos then
            break
        end

        -- Revalidate the equipped tool so another local UI action can't cause
        -- a disabled/default egg to slip into CreateEgg.
        local held = getEquippedTool()
        if held ~= eggTool or held:GetAttribute("h") ~= CONFIG.DEFAULT_EGG then
            unequipTools()
            if not equipTool(eggTool) then
                break
            end
        end

        if CONFIG.FAST_PLACEMENT then
            task.spawn(function(position, index)
                task.wait((index - 1) * CONFIG.PLACE_STAGGER)
                if State.enabled and not State.tradeBusy then
                    pcall(function()
                        PetEggService:FireServer("CreateEgg", position)
                    end)
                end
            end, pos, i)
        else
            if State.enabled and not State.tradeBusy then
                pcall(function()
                    PetEggService:FireServer("CreateEgg", pos)
                end)
            end
            task.wait(0.08)
        end
    end

    -- Keep this short. The main cycle rechecks the live model count.
    task.wait(math.max(0.15, amountToPlace * CONFIG.PLACE_STAGGER + 0.15))
    unequipTools()
end

---------------------------------------------------------------------
-- HATCH READY NIGHT EGGS
---------------------------------------------------------------------

local function hatchReadyNightEggs()
    if not State.enabled or State.tradeBusy then
        return 0
    end

    local ready = getReadyNightEggs()
    if #ready == 0 then
        return 0
    end

    State.lastStatus = string.format("Hatching %d Night Egg(s)...", #ready)

    for index, eggModel in ipairs(ready) do
        if not State.enabled or State.tradeBusy then
            break
        end

        local spacing = CONFIG.ULTRA and CONFIG.OVERDRIVE and 0.01
            or (CONFIG.OVERDRIVE and 0.02 or 0.05)

        task.spawn(function(model, order, delayBetween)
            task.wait((order - 1) * delayBetween)
            if State.enabled and not State.tradeBusy and model and model.Parent then
                pcall(function()
                    PetEggService:FireServer("HatchPet", model)
                end)
            end
        end, eggModel, index, spacing)
    end

    -- Allow the server to consume the ready egg models before the next scan.
    local deadline = os.clock() + 3
    repeat
        task.wait(0.08)
        if not State.enabled then
            break
        end
        if #getReadyNightEggs() == 0 then
            break
        end
    until os.clock() >= deadline

    return #ready
end

---------------------------------------------------------------------
-- NIGHT EGG PET GIFTING
---------------------------------------------------------------------

local function collectNightEggPetEntries()
    local data = getData()
    local inventory = getPetInventory(data)
    local result = {}

    for uuid, entry in pairs(inventory) do
        local petType = entry and entry.PetType
        local petData = entry and entry.PetData

        if petData and CONFIG.NIGHT_EGG_PETS[petType] then
            local tool = getToolByPetUUID(uuid)
            if tool then
                table.insert(result, {
                    uuid = uuid,
                    tool = tool,
                    petType = petType,
                    level = tonumber(petData.Level) or 0,
                })
            end
        end
    end

    table.sort(result, function(a, b)
        if a.petType == b.petType then
            return a.level < b.level
        end
        return a.petType < b.petType
    end)

    return result
end

local function findGiftTarget()
    return Players:FindFirstChild(CONFIG.TARGET_GIFT_PLAYER)
end

local function fastGiftAllNightEggPets()
    if State.autoGiftBusy or State.tradeBusy or not State.enabled or not State.autoGiftEnabled then
        return
    end

    local target = findGiftTarget()
    if not target then
        State.lastStatus = "Waiting for mysto_sailor..."
        return
    end

    State.autoGiftBusy = true

    local ok, err = pcall(function()
        while State.enabled and not State.tradeBusy do
            local pets = collectNightEggPetEntries()
            if #pets == 0 then
                break
            end

            for _, pet in ipairs(pets) do
                if not State.enabled or State.tradeBusy then
                    break
                end

                local currentTarget = findGiftTarget()
                if not currentTarget then
                    break
                end

                local tool = getToolByPetUUID(pet.uuid)
                if not tool then
                    continue
                end

                -- Keep the target exact. Existing Night Egg pets are also valid;
                -- there is intentionally no "freshly hatched" check here.
                unequipTools()
                equipTool(tool)

                State.lastStatus = "Fast gifting " .. tostring(pet.petType) .. "..."

                pcall(function()
                    PetGiftingService:GivePet(currentTarget)
                end)

                task.wait(CONFIG.GIFT_STAGGER)
                unequipTools()
            end

            task.wait(0.05)
        end
    end)

    if not ok then
        warn("[FABLE TRANSFER V1] Gift error:", err)
    end

    State.autoGiftBusy = false
end

---------------------------------------------------------------------
-- AUTO PET SLOT
---------------------------------------------------------------------

local function getPurchasedSlotCount(data)
    local petsData = getPetsData(data)
    return tonumber(petsData and petsData.PurchasedEquipSlots) or 0
end

local function findLowestQualifyingPetUUID(inventory, requiredLevel)
    local bestUUID = nil
    local bestLevel = nil
    local bestPetName = nil

    for uuid, entry in pairs(inventory) do
        local petType = entry and entry.PetType
        local petData = entry and entry.PetData

        if petData and CONFIG.AUTO_SLOT_PETS[petType] then
            local level = tonumber(petData.Level) or 0

            if level >= requiredLevel then
                if not bestLevel
                    or level < bestLevel
                    or (level == bestLevel and tostring(petType) < tostring(bestPetName))
                then
                    bestUUID = uuid
                    bestLevel = level
                    bestPetName = petType
                end
            end
        end
    end

    return bestUUID, bestLevel, bestPetName
end

local function startAutoPetSlot()
    if State.autoSlotBusy or not State.autoPetSlotEnabled then
        return
    end

    State.autoSlotBusy = true

    Threads.autoPetSlot = task.spawn(function()
        while State.enabled and State.autoPetSlotEnabled do
            local data = getData()
            local purchased = getPurchasedSlotCount(data)
            local stage = purchased + 1
            local requiredLevel = CONFIG.AUTO_SLOT_REQUIREMENTS[stage]

            if not requiredLevel then
                -- All five stages are already purchased.
                break
            end

            local inventory = getPetInventory(data)
            local uuid, level, petName = findLowestQualifyingPetUUID(inventory, requiredLevel)

            if not uuid then
                task.wait(0.5)
                continue
            end

            -- The game's real remote is exactly one remote:
            -- UnlockSlotFromPet:FireServer(UUID, "Pet")
            State.lastStatus = string.format(
                "Auto Pet Slot: %s Lv.%d -> %d+",
                tostring(petName),
                tonumber(level) or 0,
                requiredLevel
            )

            local before = purchased
            pcall(function()
                UnlockSlotRemote:FireServer(uuid, "Pet")
            end)

            -- Wait for the live purchased-slot value to advance so the same
            -- pet/remote isn't hammered while replication is catching up.
            local deadline = os.clock() + 2.5
            while State.enabled and os.clock() < deadline do
                task.wait(0.15)
                local fresh = getPurchasedSlotCount(getData())
                if fresh > before then
                    break
                end
            end
        end

        State.autoSlotBusy = false
    end)
end

---------------------------------------------------------------------
-- TRADE DETECTION / ACCEPT
---------------------------------------------------------------------

local function textContainsTarget(root, target)
    if not root then
        return false
    end

    local wanted = tostring(target):lower()

    for _, obj in ipairs(root:GetDescendants()) do
        if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
            local text = tostring(obj.Text or ""):lower()
            if text:find(wanted, 1, true) then
                return true
            end
        end
    end

    return false
end

local function isArimabnsTradeRequestVisible()
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if not playerGui then
        return false
    end

    local notification = playerGui:FindFirstChild("Gift_Notification")
    if not notification or notification.Enabled == false then
        return false
    end

    local frame = notification:FindFirstChild("Frame")
    if not frame then
        return false
    end

    local tradeReq = frame:FindFirstChild("TradeRequest")
    if not tradeReq then
        return false
    end

    return textContainsTarget(tradeReq, CONFIG.TARGET_TRADE_PLAYER)
end

local function clickTradeRequestAccept()
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if not playerGui then
        return false
    end

    local notification = playerGui:FindFirstChild("Gift_Notification")
    if not notification then
        return false
    end

    local frame = notification:FindFirstChild("Frame")
    local tradeReq = frame and frame:FindFirstChild("TradeRequest")
    if not tradeReq then
        return false
    end

    -- Exact V53 path:
    -- TradeRequest -> Wrapper -> Canvas -> Segment -> Buttons ->
    -- ACCEPT_BUTTON -> Main -> SENSOR
    local wrapper = tradeReq:FindFirstChild("Wrapper")
    local canvas = wrapper and wrapper:FindFirstChild("Canvas")
    local segment = canvas and canvas:FindFirstChild("Segment")
    local buttons = segment and segment:FindFirstChild("Buttons")
    local acceptBtn = buttons and buttons:FindFirstChild("ACCEPT_BUTTON")
    local main = acceptBtn and acceptBtn:FindFirstChild("Main")
    local sensor = main and main:FindFirstChild("SENSOR")

    if not sensor then
        return false
    end

    local didClick = false

    if getconnections then
        pcall(function()
            for _, connection in pairs(getconnections(sensor.MouseButton1Click)) do
                connection:Fire()
                didClick = true
            end
        end)

        pcall(function()
            for _, connection in pairs(getconnections(sensor.Activated)) do
                connection:Fire()
                didClick = true
            end
        end)
    end

    if not didClick and sensor:IsA("GuiButton") then
        pcall(function()
            sensor:Activate()
            didClick = true
        end)
    end

    return didClick
end

local function isTradeUIActive()
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    local tradingUI = playerGui and playerGui:FindFirstChild("TradingUI")
    return tradingUI ~= nil and tradingUI.Enabled == true
end

local function isActiveTradeArimabns()
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    local tradingUI = playerGui and playerGui:FindFirstChild("TradingUI")
    if not tradingUI then
        return false
    end

    -- Prefer exact UI text. We also retain State.acceptedArimabnsRequest
    -- after we accepted a verified arimabns request.
    if textContainsTarget(tradingUI, CONFIG.TARGET_TRADE_PLAYER) then
        return true
    end

    return State.acceptedArimabnsRequest and tradingUI.Enabled == true
end

local function otherPlayerReady()
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    local tradingUI = playerGui and playerGui:FindFirstChild("TradingUI")
    if not tradingUI then
        return false
    end

    local liveTrade = tradingUI:FindFirstChild("LiveTrade")
    local other = liveTrade and liveTrade:FindFirstChild("OtherPlr")
    local ready = other and other:FindFirstChild("Ready")

    if ready then
        return (tonumber(ready.BackgroundTransparency) or 1) < 1
    end

    return false
end

local function myTradeItemCount()
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    local tradingUI = playerGui and playerGui:FindFirstChild("TradingUI")
    local liveTrade = tradingUI and tradingUI:FindFirstChild("LiveTrade")
    local myPlr = liveTrade and liveTrade:FindFirstChild("MyPlr")
    local scrolling = myPlr and myPlr:FindFirstChild("ScrollingFrame")

    if not scrolling then
        return 0
    end

    local count = 0
    for _, item in ipairs(scrolling:GetChildren()) do
        if item:IsA("ImageButton") and item.Name == "ItemTemplate" then
            count += 1
        end
    end

    return count
end

local function clickTradeAccept()
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    local tradingUI = playerGui and playerGui:FindFirstChild("TradingUI")
    if not tradingUI or not tradingUI.Enabled then
        return false
    end

    local liveTrade = tradingUI:FindFirstChild("LiveTrade")
    local options = liveTrade and liveTrade:FindFirstChild("Options")
    local acceptBtn = options and options:FindFirstChild("Accept")
    if not acceptBtn then
        return false
    end

    local didClick = false

    if getconnections then
        pcall(function()
            for _, connection in pairs(getconnections(acceptBtn.MouseButton1Click)) do
                connection:Fire()
                didClick = true
            end
        end)

        pcall(function()
            for _, connection in pairs(getconnections(acceptBtn.Activated)) do
                connection:Fire()
                didClick = true
            end
        end)
    end

    if not didClick and acceptBtn:IsA("GuiButton") then
        pcall(function()
            acceptBtn:Activate()
            didClick = true
        end)
    end

    return didClick
end

local function getTradeTeamUUIDs()
    local seen = {}
    local result = {}

    local reduction = buildReductionTeam()
    local koi = buildKoiTeam()

    for _, team in ipairs({ reduction, koi }) do
        for _, uuid in ipairs(team) do
            if uuid and not seen[uuid] then
                seen[uuid] = true
                table.insert(result, uuid)
            end
        end
    end

    return result
end

local function addTradePetTeams()
    if not State.tradePetTeamsEnabled then
        return
    end

    local teamUUIDs = getTradeTeamUUIDs()

    for _, uuid in ipairs(teamUUIDs) do
        if myTradeItemCount() >= 12 then
            break
        end

        if getToolByPetUUID(uuid) then
            pcall(function()
                AddItemRemote:FireServer("Pet", uuid)
            end)
            task.wait(0.06)
        end
    end
end

local function handleArimabnsTrade()
    if State.tradeBusy or not State.enabled then
        return false
    end

    if not isArimabnsTradeRequestVisible() then
        return false
    end

    State.tradeBusy = true
    State.lastStatus = "arimabns trade request detected."

    -- Save exactly what the transfer loop had in the garden.
    local savedTeamName = State.currentGardenTeamName
    local savedTeam = table.clone(State.currentGardenTeam)

    -- Requirement: remove garden team BEFORE accepting the request.
    unequipAllGardenPets()
    State.currentGardenTeamName = nil
    State.currentGardenTeam = {}

    task.wait(0.08)

    local acceptedRequest = clickTradeRequestAccept()
    if acceptedRequest then
        State.acceptedArimabnsRequest = true
    end

    if not acceptedRequest then
        State.lastStatus = "Could not accept arimabns request."
        State.tradeBusy = false
        State.acceptedArimabnsRequest = false
        if savedTeamName and #savedTeam > 0 then
            equipGardenTeam(savedTeam, savedTeamName)
        end
        return false
    end

    -- Wait for the actual trade UI.
    local deadline = os.clock() + 5
    while State.enabled and os.clock() < deadline do
        if isTradeUIActive() and isActiveTradeArimabns() then
            break
        end
        task.wait(0.08)
    end

    if State.enabled and isTradeUIActive() and isActiveTradeArimabns() then
        State.lastStatus = "arimabns trade active. Adding Trade Pet Teams..."

        addTradePetTeams()

        -- Accept/confirm automatically. We wait for the other side to be ready,
        -- but also keep trying periodically because the game's UI can switch
        -- between staged accept buttons.
        local tradeDeadline = os.clock() + 25
        while State.enabled and isTradeUIActive() and os.clock() < tradeDeadline do
            if not isActiveTradeArimabns() then
                break
            end

            if otherPlayerReady() or myTradeItemCount() > 0 then
                clickTradeAccept()
            end

            task.wait(0.35)
        end
    else
        State.lastStatus = "arimabns request accepted; waiting for trade UI..."
    end

    State.acceptedArimabnsRequest = false
    State.lastTradeHandledAt = os.clock()

    -- Restore the garden team that was active before the trade.
    if State.enabled then
        if savedTeamName and #savedTeam > 0 then
            equipGardenTeam(savedTeam, savedTeamName)
        else
            -- Rebuild the correct default phase if no snapshot was available.
            ensureReductionTeam()
        end
    end

    State.tradeBusy = false
    State.lastStatus = "Trade complete. Resuming transfer."
    return true
end

---------------------------------------------------------------------
-- COMPACT FABLE TAB UI
---------------------------------------------------------------------

local function getUIParent()
    if gethui then
        local ok, hui = pcall(gethui)
        if ok and hui then
            return hui
        end
    end

    return CoreGui
end

local uiParent = getUIParent()

local oldUI = uiParent:FindFirstChild("FableTransferV1")
if oldUI then
    pcall(function()
        oldUI:Destroy()
    end)
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "FableTransferV1"
ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = true
ScreenGui.DisplayOrder = 9999
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = uiParent

local Main = Instance.new("Frame")
Main.Name = "Main"
Main.Size = UDim2.fromOffset(350, 280)
Main.Position = UDim2.new(0.5, -175, 0, 28)
Main.BackgroundColor3 = Color3.fromRGB(11, 9, 18)
Main.BackgroundTransparency = 0.04
Main.BorderSizePixel = 0
Main.Parent = ScreenGui

local MainCorner = Instance.new("UICorner")
MainCorner.CornerRadius = UDim.new(0, 12)
MainCorner.Parent = Main

local MainStroke = Instance.new("UIStroke")
MainStroke.Thickness = 1.5
MainStroke.Color = Color3.fromRGB(178, 105, 248)
MainStroke.Transparency = 0.12
MainStroke.Parent = Main

local Header = Instance.new("Frame")
Header.BackgroundTransparency = 1
Header.Position = UDim2.fromOffset(10, 8)
Header.Size = UDim2.new(1, -20, 0, 28)
Header.Parent = Main

local Title = Instance.new("TextLabel")
Title.BackgroundTransparency = 1
Title.Size = UDim2.new(1, -38, 1, 0)
Title.Font = Enum.Font.GothamBold
Title.Text = "FABLE TRANSFER V1"
Title.TextColor3 = Color3.fromRGB(231, 214, 255)
Title.TextSize = 16
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Parent = Header

local Close = Instance.new("TextButton")
Close.Size = UDim2.fromOffset(26, 26)
Close.Position = UDim2.new(1, -26, 0, 0)
Close.BackgroundColor3 = Color3.fromRGB(40, 35, 48)
Close.BorderSizePixel = 0
Close.Text = "×"
Close.TextColor3 = Color3.fromRGB(220, 215, 230)
Close.Font = Enum.Font.GothamBold
Close.TextSize = 18
Close.Parent = Header

local CloseCorner = Instance.new("UICorner")
CloseCorner.CornerRadius = UDim.new(0, 7)
CloseCorner.Parent = Close

local TabsBar = Instance.new("Frame")
TabsBar.BackgroundTransparency = 1
TabsBar.Position = UDim2.fromOffset(10, 40)
TabsBar.Size = UDim2.new(1, -20, 0, 28)
TabsBar.Parent = Main

local TabNames = {"Transfer", "Pet Teams", "Settings"}
local TabButtons = {}
local Pages = {}

local function makeTabButton(name, index)
    local button = Instance.new("TextButton")
    button.Name = name:gsub("%s+", "") .. "Tab"
    button.Size = UDim2.new(1 / #TabNames, -4, 1, 0)
    button.Position = UDim2.new((index - 1) / #TabNames, (index - 1) * 2, 0, 0)
    button.BackgroundColor3 = Color3.fromRGB(35, 30, 44)
    button.BorderSizePixel = 0
    button.AutoButtonColor = true
    button.Text = name
    button.TextColor3 = Color3.fromRGB(165, 155, 180)
    button.Font = Enum.Font.GothamSemibold
    button.TextSize = 10
    button.Parent = TabsBar

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 7)
    corner.Parent = button

    TabButtons[name] = button
    return button
end

for index, name in ipairs(TabNames) do
    makeTabButton(name, index)
end

local PagesHolder = Instance.new("Frame")
PagesHolder.BackgroundTransparency = 1
PagesHolder.Position = UDim2.fromOffset(10, 74)
PagesHolder.Size = UDim2.new(1, -20, 1, -84)
PagesHolder.Parent = Main

local function makePage(name)
    local page = Instance.new("Frame")
    page.Name = name:gsub("%s+", "") .. "Page"
    page.BackgroundTransparency = 1
    page.Size = UDim2.fromScale(1, 1)
    page.Visible = false
    page.Parent = PagesHolder
    Pages[name] = page
    return page
end

local TransferPage = makePage("Transfer")
local TeamsPage = makePage("Pet Teams")
local SettingsPage = makePage("Settings")

local function makeSection(parent, titleText, y, height)
    local section = Instance.new("Frame")
    section.Size = UDim2.new(1, 0, 0, height)
    section.Position = UDim2.fromOffset(0, y)
    section.BackgroundColor3 = Color3.fromRGB(20, 17, 28)
    section.BackgroundTransparency = 0.08
    section.BorderSizePixel = 0
    section.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 9)
    corner.Parent = section

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Position = UDim2.fromOffset(10, 6)
    title.Size = UDim2.new(1, -20, 0, 16)
    title.Font = Enum.Font.GothamBold
    title.Text = titleText
    title.TextColor3 = Color3.fromRGB(212, 195, 235)
    title.TextSize = 10
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = section

    return section
end

local function makeLine(parent, y, leftText, rightText)
    local left = Instance.new("TextLabel")
    left.BackgroundTransparency = 1
    left.Position = UDim2.fromOffset(10, y)
    left.Size = UDim2.new(0.62, 0, 0, 18)
    left.Font = Enum.Font.GothamMedium
    left.Text = leftText
    left.TextColor3 = Color3.fromRGB(160, 152, 175)
    left.TextSize = 9
    left.TextXAlignment = Enum.TextXAlignment.Left
    left.Parent = parent

    local right = Instance.new("TextLabel")
    right.BackgroundTransparency = 1
    right.Position = UDim2.new(0.62, 0, 0, y)
    right.Size = UDim2.new(0.38, -10, 0, 18)
    right.Font = Enum.Font.GothamBold
    right.Text = rightText
    right.TextColor3 = Color3.fromRGB(235, 231, 242)
    right.TextSize = 9
    right.TextXAlignment = Enum.TextXAlignment.Right
    right.Parent = parent

    return left, right
end

local function makeToggle(parent, y, labelText, defaultValue, callback)
    local button = Instance.new("TextButton")
    button.Size = UDim2.new(1, 0, 0, 28)
    button.Position = UDim2.fromOffset(0, y)
    button.BackgroundColor3 = Color3.fromRGB(31, 27, 39)
    button.BorderSizePixel = 0
    button.AutoButtonColor = true
    button.Text = ""
    button.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 7)
    corner.Parent = button

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(10, 0)
    label.Size = UDim2.new(1, -62, 1, 0)
    label.Font = Enum.Font.GothamSemibold
    label.Text = labelText
    label.TextColor3 = Color3.fromRGB(225, 220, 235)
    label.TextSize = 9
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = button

    local stateLabel = Instance.new("TextLabel")
    stateLabel.BackgroundTransparency = 1
    stateLabel.Position = UDim2.new(1, -54, 0, 0)
    stateLabel.Size = UDim2.fromOffset(45, 28)
    stateLabel.Font = Enum.Font.GothamBold
    stateLabel.TextSize = 9
    stateLabel.TextXAlignment = Enum.TextXAlignment.Right
    stateLabel.Parent = button

    local value = defaultValue == true
    local function render()
        stateLabel.Text = value and "ON" or "OFF"
        stateLabel.TextColor3 = value
            and Color3.fromRGB(143, 255, 173)
            or Color3.fromRGB(150, 145, 160)

        button.BackgroundColor3 = value
            and Color3.fromRGB(42, 31, 52)
            or Color3.fromRGB(31, 27, 39)
    end

    local function setValue(newValue, fireCallback)
        value = newValue == true
        render()
        if fireCallback and callback then
            callback(value)
        end
    end

    button.Activated:Connect(function()
        setValue(not value, true)
    end)

    render()
    return {
        Button = button,
        Set = function(_, newValue, fireCallback)
            setValue(newValue, fireCallback ~= false)
        end,
        Get = function()
            return value
        end,
    }
end

-- Transfer page.
local transferSection = makeSection(TransferPage, "TRANSFER", 0, 145)

local autoHatchToggle = makeToggle(
    transferSection,
    28,
    "Auto Hatch / Transfer",
    false,
    function(value)
        State.enabled = value
        if value then
            State.lastStatus = "Transfer enabled."
            if State.autoPetSlotEnabled and not State.autoSlotBusy then
                startAutoPetSlot()
            end
        else
            State.lastStatus = "Transfer stopped."
        end
    end
)

local transferEggLabel = makeLine(transferSection, 61, "Egg", CONFIG.DEFAULT_EGG)
local transferModeLabel = makeLine(transferSection, 82, "Placement", CONFIG.FAST_PLACEMENT and "FAST" or "NORMAL")
local transferMaxLabel = makeLine(transferSection, 103, "Garden", "MAX")
local transferTeamLabel = makeLine(transferSection, 124, "Team", "None")

local statusSection = makeSection(TransferPage, "STATUS", 153, 66)

local statusLabel = Instance.new("TextLabel")
statusLabel.BackgroundTransparency = 1
statusLabel.Position = UDim2.fromOffset(10, 25)
statusLabel.Size = UDim2.new(1, -20, 0, 33)
statusLabel.Font = Enum.Font.GothamMedium
statusLabel.Text = "Auto Hatch is OFF"
statusLabel.TextColor3 = Color3.fromRGB(225, 220, 235)
statusLabel.TextSize = 9
statusLabel.TextWrapped = true
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextYAlignment = Enum.TextYAlignment.Center
statusLabel.Parent = statusSection

-- Pet Teams page.
local teamTop = makeSection(TeamsPage, "CURRENT GARDEN TEAM", 0, 68)

local teamNameLabel = Instance.new("TextLabel")
teamNameLabel.BackgroundTransparency = 1
teamNameLabel.Position = UDim2.fromOffset(10, 24)
teamNameLabel.Size = UDim2.new(1, -20, 0, 17)
teamNameLabel.Font = Enum.Font.GothamBold
teamNameLabel.Text = "None"
teamNameLabel.TextColor3 = Color3.fromRGB(200, 165, 255)
teamNameLabel.TextSize = 10
teamNameLabel.TextXAlignment = Enum.TextXAlignment.Left
teamNameLabel.Parent = teamTop

local equippedLabel = Instance.new("TextLabel")
equippedLabel.BackgroundTransparency = 1
equippedLabel.Position = UDim2.fromOffset(10, 42)
equippedLabel.Size = UDim2.new(1, -20, 0, 22)
equippedLabel.Font = Enum.Font.Gotham
equippedLabel.Text = "Equipped: None"
equippedLabel.TextColor3 = Color3.fromRGB(155, 148, 170)
equippedLabel.TextSize = 8
equippedLabel.TextWrapped = true
equippedLabel.TextXAlignment = Enum.TextXAlignment.Left
equippedLabel.Parent = teamTop

local reductionSection = makeSection(TeamsPage, "REDUCTION TEAM", 72, 58)
local reductionLabel = Instance.new("TextLabel")
reductionLabel.BackgroundTransparency = 1
reductionLabel.Position = UDim2.fromOffset(10, 23)
reductionLabel.Size = UDim2.new(1, -20, 0, 29)
reductionLabel.Font = Enum.Font.Gotham
reductionLabel.Text = "Birb  •  Rainbow Birb  •  Mimic Octopus"
reductionLabel.TextColor3 = Color3.fromRGB(205, 199, 215)
reductionLabel.TextSize = 8
reductionLabel.TextWrapped = true
reductionLabel.TextXAlignment = Enum.TextXAlignment.Left
reductionLabel.TextYAlignment = Enum.TextYAlignment.Center
reductionLabel.Parent = reductionSection

local koiSection = makeSection(TeamsPage, "KOI TEAM", 134, 58)
local koiLabel = Instance.new("TextLabel")
koiLabel.BackgroundTransparency = 1
koiLabel.Position = UDim2.fromOffset(10, 23)
koiLabel.Size = UDim2.new(1, -20, 0, 29)
koiLabel.Font = Enum.Font.Gotham
koiLabel.Text = "1× Koi  •  Ruby Squid fills remaining slots"
koiLabel.TextColor3 = Color3.fromRGB(205, 199, 215)
koiLabel.TextSize = 8
koiLabel.TextWrapped = true
koiLabel.TextXAlignment = Enum.TextXAlignment.Left
koiLabel.TextYAlignment = Enum.TextYAlignment.Center
koiLabel.Parent = koiSection

-- Settings page.
local settingsHeader = makeSection(SettingsPage, "TRANSFER SETTINGS", 0, 30)

local settingsScroll = Instance.new("ScrollingFrame")
settingsScroll.BackgroundTransparency = 1
settingsScroll.Position = UDim2.fromOffset(0, 36)
settingsScroll.Size = UDim2.new(1, 0, 1, -36)
settingsScroll.BorderSizePixel = 0
settingsScroll.ScrollBarThickness = 3
settingsScroll.CanvasSize = UDim2.fromOffset(0, 0)
settingsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
settingsScroll.Parent = SettingsPage

local settingsContent = Instance.new("Frame")
settingsContent.BackgroundTransparency = 1
settingsContent.Size = UDim2.new(1, -6, 0, 260)
settingsContent.Parent = settingsScroll

local fastPlacementToggle = makeToggle(
    settingsContent, 0, "Fast Egg Placement", CONFIG.FAST_PLACEMENT,
    function(value)
        CONFIG.FAST_PLACEMENT = value
    end
)

local middleEggToggle = makeToggle(
    settingsContent, 32, "Middle Eggs", CONFIG.MIDDLE_EGGS,
    function(value)
        CONFIG.MIDDLE_EGGS = value
    end
)

local overdriveToggle = makeToggle(
    settingsContent, 64, "Overdrive Mode", CONFIG.OVERDRIVE,
    function(value)
        CONFIG.OVERDRIVE = value
    end
)

local ultraToggle = makeToggle(
    settingsContent, 96, "Ultra Mode", CONFIG.ULTRA,
    function(value)
        CONFIG.ULTRA = value
    end
)

local giftToggle = makeToggle(
    settingsContent, 128, "Fast Gift", State.autoGiftEnabled,
    function(value)
        State.autoGiftEnabled = value
    end
)

local tradeTeamsToggle = makeToggle(
    settingsContent, 160, "Trade Pet Teams", State.tradePetTeamsEnabled,
    function(value)
        State.tradePetTeamsEnabled = value
    end
)

local autoSlotToggle = makeToggle(
    settingsContent, 192, "Auto Pet Slot", State.autoPetSlotEnabled,
    function(value)
        State.autoPetSlotEnabled = value
        if value and State.enabled and not State.autoSlotBusy then
            startAutoPetSlot()
        end
    end
)

-- Intentionally locked OFF to preserve the transfer workflow.
local favToggle = makeToggle(
    settingsContent, 224, "Auto Favorite Hatch", false,
    function(value)
        if value then
            favToggle:Set(false, false)
        end
    end
)

local maxInfo = Instance.new("TextLabel")
maxInfo.BackgroundTransparency = 1
maxInfo.Position = UDim2.fromOffset(10, 258)
maxInfo.Size = UDim2.new(1, -20, 0, 30)
maxInfo.Font = Enum.Font.Gotham
maxInfo.Text = "Night Egg is fixed as default.\nPlacement always targets live MAX farm capacity."
maxInfo.TextColor3 = Color3.fromRGB(150, 142, 165)
maxInfo.TextSize = 8
maxInfo.TextWrapped = true
maxInfo.TextXAlignment = Enum.TextXAlignment.Left
maxInfo.Parent = settingsContent

local function showPage(name)
    for pageName, page in pairs(Pages) do
        page.Visible = pageName == name
    end

    for tabName, button in pairs(TabButtons) do
        local active = tabName == name
        button.BackgroundColor3 = active
            and Color3.fromRGB(76, 44, 99)
            or Color3.fromRGB(35, 30, 44)
        button.TextColor3 = active
            and Color3.fromRGB(238, 224, 255)
            or Color3.fromRGB(165, 155, 180)
    end
end

for name, button in pairs(TabButtons) do
    button.Activated:Connect(function()
        showPage(name)
    end)
end

-- Drag support.
local dragging = false
local dragStart
local startPos

Connections.dragStart = Header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
    then
        dragging = true
        dragStart = input.Position
        startPos = Main.Position
    end
end)

Connections.dragEnd = Header.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
    then
        dragging = false
    end
end)

Connections.dragMove = UserInputService.InputChanged:Connect(function(input)
    if not dragging then
        return
    end

    if input.UserInputType ~= Enum.UserInputType.MouseMovement
        and input.UserInputType ~= Enum.UserInputType.Touch
    then
        return
    end

    local delta = input.Position - dragStart
    Main.Position = UDim2.new(
        startPos.X.Scale,
        startPos.X.Offset + delta.X,
        startPos.Y.Scale,
        startPos.Y.Offset + delta.Y
    )
end)

Connections.close = Close.Activated:Connect(function()
    if getgenv and getgenv().FABLE_TRANSFER_V1_STOP then
        pcall(getgenv().FABLE_TRANSFER_V1_STOP)
    elseif ScreenGui and ScreenGui.Parent then
        ScreenGui:Destroy()
    end
end)

local function petNameFromUUID(uuid)
    local inventory = getPetInventory(getData())
    local entry = inventory and inventory[uuid]
    if entry then
        local level = entry.PetData and tonumber(entry.PetData.Level) or 0
        return string.format("%s Lv.%d", tostring(entry.PetType or "Unknown"), level)
    end
    return "Missing"
end

local function updateTeamPage()
    local teamName = State.currentGardenTeamName or "None"
    teamNameLabel.Text = teamName

    local equipped = {}
    for _, uuid in ipairs(getEquippedPets(getData())) do
        if uuid then
            table.insert(equipped, petNameFromUUID(uuid))
        end
    end

    if #equipped == 0 then
        equippedLabel.Text = "Equipped: None"
    else
        equippedLabel.Text = "Equipped: " .. table.concat(equipped, "  |  ")
    end

    transferTeamLabel[2].Text = teamName
end

local function updateUI()
    if not ScreenGui.Parent then
        return
    end

    autoHatchToggle:Set(State.enabled, false)

    transferModeLabel[2].Text = CONFIG.FAST_PLACEMENT and "FAST" or "NORMAL"
    statusLabel.Text = State.enabled
        and (State.lastStatus or "Transfer running.")
        or "Auto Hatch is OFF — waiting for you."

    local farmCount = getFarmEggCount()
    local maxEggs = getMaxEggCapacity(getData())
    transferMaxLabel[2].Text = string.format("%d/%d", farmCount, maxEggs > 0 and maxEggs or 0)

    transferEggLabel[2].Text = CONFIG.DEFAULT_EGG
    transferTeamLabel[2].Text = State.currentGardenTeamName or "None"

    updateTeamPage()
end

showPage("Transfer")
updateUI()

---------------------------------------------------------------------
-- SHUTDOWN / CLEANUP
---------------------------------------------------------------------

local function cleanup()
    State.shuttingDown = true
    State.enabled = false

    for _, thread in pairs(Threads) do
        if thread then
            pcall(function()
                task.cancel(thread)
            end)
        end
    end
    Threads = {}

    for _, connection in pairs(Connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    Connections = {}

    pcall(function()
        unequipTools()
    end)

    if ScreenGui and ScreenGui.Parent then
        pcall(function()
            ScreenGui:Destroy()
        end)
    end

    if getgenv then
        getgenv().FABLE_TRANSFER_V1 = nil
    end
end

-- Expose a cleanup hook for manual unload/re-execution.
if getgenv then
    getgenv().FABLE_TRANSFER_V1_STOP = cleanup
end

---------------------------------------------------------------------
-- MAIN CONTINUOUS TRANSFER LOOP
---------------------------------------------------------------------

Threads.tradeWatcher = task.spawn(function()
    while not State.shuttingDown do
        if State.enabled and not State.tradeBusy then
            pcall(handleArimabnsTrade)
        end
        task.wait(0.05)
    end
end)

Threads.main = task.spawn(function()
    while not State.shuttingDown do
        if not State.enabled then
            State.cycleBusy = false
            task.wait(0.15)
            continue
        end

        -- Existing Night Egg pets are eligible immediately once Auto Hatch
        -- is enabled, even before the first hatch performed by this instance.
        if State.autoGiftEnabled then
            pcall(fastGiftAllNightEggPets)
        end

        if State.tradeBusy then
            task.wait(0.1)
            continue
        end

        State.cycleBusy = true

        -- Step 1: fill the garden to the live MAX with Night Eggs.
        pcall(placeNightEggsToMax)

        if State.tradeBusy or not State.enabled then
            State.cycleBusy = false
            continue
        end

        -- Step 2: reduction team handles the wait/reduction phase.
        local reductionOK = false
        pcall(function()
            reductionOK = ensureReductionTeam()
        end)

        if reductionOK then
            State.lastStatus = "Egg Reduction active — waiting for Night Eggs."
        else
            State.lastStatus = "Reduction pets missing — waiting for Night Eggs."
        end

        -- Step 3: when any Night Egg is ready, switch to Koi/Ruby and hatch it.
        local readyCount = #getReadyNightEggs()
        if readyCount > 0 then
            local koiOK = false
            pcall(function()
                koiOK = ensureKoiTeam()
            end)

            if not koiOK then
                State.lastStatus = "Koi/Ruby team missing — retrying."
            else
                local hatched = hatchReadyNightEggs()
                if hatched > 0 and State.autoGiftEnabled then
                    -- Step 4: fast-gift ALL Night Egg pets, not only newly hatched.
                    pcall(fastGiftAllNightEggPets)
                end
            end
        else
            State.lastStatus = "Waiting for Night Eggs to finish..."
        end

        -- Step 5: next loop immediately tops the garden back to MAX.
        State.cycleBusy = false
        task.wait(CONFIG.LOOP_IDLE)
    end

    State.cycleBusy = false
    State.lastStatus = "Transfer stopped."
end)

Threads.ui = task.spawn(function()
    while not State.shuttingDown do
        updateUI()
        task.wait(0.1)
    end
end)

State.lastStatus = "Auto Hatch is OFF."
updateUI()
print("[FABLE TRANSFER V1] Loaded — Auto Hatch is OFF. Enable it from the Transfer tab.")
