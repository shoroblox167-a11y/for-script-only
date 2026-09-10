--[[
    FABLE TRANSFER V15

    Dedicated egg-transfer automation.
    This script intentionally contains NO pet-selling system.

    V5 additions:
      • V52 Trade Pet Teams workflow restored for arimabns
      • V52 TradeRequest ticket accept path restored
      • V52 in-trade accept/confirm path restored
      • Trade watchers operate independently of Auto Hatch

    V6 additions:
      • V52-style Status Board wired to the real Transfer state
      • V52-sized 720x600 main GUI
      • Anti-idle + best-effort client-side anti-kick protection
      • Live selected-pet panels for both 8-slot transfer teams

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

-- V13 compiler fix: top-level bindings are intentionally non-local because
-- the previous build exceeded Luau's per-function local register limit.

-- V12 startup recovery. A previous run can crash before cleanup and leave
-- the global flag set. Never return silently: stop stale instance, clear
-- the marker, and continue initialization.
if getgenv then
    local previousStop = getgenv().FABLE_TRANSFER_V15_STOP
    if previousStop then
        pcall(previousStop)
        task.wait()
    end
    getgenv().FABLE_TRANSFER_V15 = nil
    getgenv().FABLE_TRANSFER_V15_STOP = nil
    getgenv().FABLE_TRANSFER_V15 = true
end

if not game:IsLoaded() then
    game.Loaded:Wait()
end

Players = game:GetService("Players")
ReplicatedStorage = game:GetService("ReplicatedStorage")
RunService = game:GetService("RunService")
CoreGui = game:GetService("CoreGui")
UserInputService = game:GetService("UserInputService")
VirtualUser = game:GetService("VirtualUser")

LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    warn("[FABLE TRANSFER V15] LocalPlayer is not available.")
    if getgenv then getgenv().FABLE_TRANSFER_V15 = nil end
    return
end

-- Same game gate used by the working Fable code.
if tostring(game.GameId) ~= "7436755782" then
    warn("[FABLE TRANSFER V15] Unsupported game: " .. tostring(game.GameId))
    if getgenv then getgenv().FABLE_TRANSFER_V15 = nil end
    return
end

---------------------------------------------------------------------
-- SERVICES / MODULES
---------------------------------------------------------------------

GameEvents = ReplicatedStorage:WaitForChild("GameEvents")
PetsService = GameEvents:WaitForChild("PetsService")
PetEggService = GameEvents:WaitForChild("PetEggService")
AddItemRemote = GameEvents:WaitForChild("TradeEvents"):WaitForChild("AddItem")
UnlockSlotRemote = GameEvents:WaitForChild("UnlockSlotFromPet")
FavoriteItemRemote = GameEvents:FindFirstChild("Favorite_Item")
PetCooldownsUpdatedRemote = GameEvents:FindFirstChild("PetCooldownsUpdated")

-- V52 exact trade-warning remote.
TradeEvents = GameEvents:FindFirstChild("TradeEvents")
SetUnfairTradeWarningRemote =
    TradeEvents and TradeEvents:FindFirstChild("SetUnfairTradeWarning")

okPetUtilities, PetUtilities = pcall(function()
    return require(ReplicatedStorage.Modules.PetServices.PetUtilities)
end)
if not okPetUtilities then
    PetUtilities = nil
end

okData, DataService = pcall(function()
    return require(ReplicatedStorage.Modules.DataService)
end)
if not okData or not DataService then
    warn("[FABLE TRANSFER V15] Failed to require DataService.")
    if getgenv then getgenv().FABLE_TRANSFER_V15 = nil end
    return
end

okGift, PetGiftingService = pcall(function()
    return require(ReplicatedStorage.Modules.PetServices.PetGiftingService)
end)
if not okGift or not PetGiftingService then
    warn("[FABLE TRANSFER V15] Failed to require PetGiftingService.")
    if getgenv then getgenv().FABLE_TRANSFER_V15 = nil end
    return
end

---------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------

CONFIG = {
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
    -- Both transfer teams are built to a maximum of 8 pets.
    TEAM_SLOTS = 8,

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

State = {
    enabled = false,
    shuttingDown = false,

    -- V2 UI-connected controls.
    autoGiftEnabled = true,
    autoPetSlotEnabled = true,
    tradePetTeamsEnabled = true,

    -- V52-derived display toggles, kept independent from transfer logic.
    playerStatsEnabled = true,
    activePetsUIEnabled = true,

    playerStatsGui = nil,
    playerStatsLabels = {},
    activePetsGui = nil,
    activePetsLabel = nil,

    autoAssignTeamsEnabled = true,
    reductionTeam = {},
    koiTeam = {},
    hatching = false,
    cooldownPets = {},
    activePetsCacheUI = {},

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

    -- V6 anti-idle / best-effort client kick protection.
    antiIdleEnabled = true,
    antiKickEnabled = true,

    -- V6 Status Board state.
    statusStartedAt = os.clock(),
    statusLastMessage = "",
    statusFeedLines = {},
    statusLatest = "Fable Status initialized",

    -- Live selected team labels.
    reductionSelectedLabels = {},
    koiSelectedLabels = {},
}

Connections = {}
Threads = {}

---------------------------------------------------------------------
-- V6 ANTI-IDLE / BEST-EFFORT CLIENT KICK PROTECTION
---------------------------------------------------------------------

-- Roblox fires LocalPlayer.Idled after prolonged inactivity. This keeps the
-- client active without moving the character or touching the transfer flow.
Connections.antiIdle = LocalPlayer.Idled:Connect(function()
    if not State.antiIdleEnabled or State.shuttingDown then
        return
    end

    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new(0, 0))
    end)
end)

-- This only covers client-side Player:Kick()/LocalPlayer:Kick() namecalls.
-- A server-side kick cannot be reliably blocked from a client script.
if hookmetamethod and newcclosure and getnamecallmethod and getgenv then
    pcall(function()
        getgenv().__FABLE_V6_ANTIKICK_CONTROLLER = {
            enabled = true,
            player = LocalPlayer,
        }

        if not getgenv().__FABLE_V6_ANTIKICK_HOOKED then
            getgenv().__FABLE_V6_ANTIKICK_HOOKED = true

            local oldNamecall
            oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
                local method = getnamecallmethod()
                local controller = getgenv().__FABLE_V6_ANTIKICK_CONTROLLER

                if controller
                    and controller.enabled
                    and controller.player
                    and self == controller.player
                    and method == "Kick"
                then
                    return nil
                end

                return oldNamecall(self, ...)
            end))
        end
    end)
end

---------------------------------------------------------------------
-- CHARACTER / INVENTORY HELPERS
---------------------------------------------------------------------

function refreshCharacterRefs()
    State.character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    State.humanoid = State.character:FindFirstChildOfClass("Humanoid")
    State.backpack = LocalPlayer:FindFirstChildOfClass("Backpack") or LocalPlayer:WaitForChild("Backpack")
end

refreshCharacterRefs()

Connections.character = LocalPlayer.CharacterAdded:Connect(function()
    task.wait(0.25)
    refreshCharacterRefs()
end)

function getData()
    local ok, result = pcall(function()
        return DataService:GetData()
    end)
    if ok and type(result) == "table" then
        return result
    end
    return nil
end

function getPetsData(data)
    if not data then
        return nil
    end
    return data.PetsData or data
end

function getPetInventory(data)
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

function getEquippedPets(data)
    local petsData = getPetsData(data)
    if not petsData then
        return {}
    end

    if type(petsData.EquippedPets) == "table" then
        return petsData.EquippedPets
    end
    return {}
end

function getMaxEggCapacity(data)
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

function getMaxEquippedPets(data)
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

function getToolByPetUUID(uuid)
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

function equipTool(tool)
    refreshCharacterRefs()
    if not tool or not tool.Parent or not State.humanoid then
        return false
    end

    local ok = pcall(function()
        State.humanoid:EquipTool(tool)
    end)
    return ok
end

function unequipTools()
    refreshCharacterRefs()
    if State.humanoid then
        pcall(function()
            State.humanoid:UnequipTools()
        end)
    end
end

function getEquippedTool()
    local character = State.character
    if not character then
        return nil
    end
    return character:FindFirstChildOfClass("Tool")
end

---------------------------------------------------------------------
-- FARM / EGG HELPERS
---------------------------------------------------------------------

function findMyFarm()
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

function refreshFarmRefs()
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

function getFarmEggModels()
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

function getFarmEggCount()
    return #getFarmEggModels()
end

function getReadyNightEggs()
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

function getNightEggTool()
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

function getEggToolUses(tool)
    if not tool then
        return 0
    end
    return tonumber(tool:GetAttribute("e")) or 0
end

function getTakenEggPositions()
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
function makeMiddleEggPositions(center, blockedList)
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

function getTeamSlotCapacity(data)
    local accountMax = getMaxEquippedPets(data)
    if accountMax > 0 then
        return math.min(CONFIG.TEAM_SLOTS, accountMax)
    end
    return CONFIG.TEAM_SLOTS
end

function collectUUIDsByPetNames(inventory, allowedNames)
    local matches = {}

    for uuid, entry in pairs(inventory or {}) do
        local petType = entry and entry.PetType
        local petData = entry and entry.PetData

        if petType and allowedNames[petType] and petData then
            table.insert(matches, {
                uuid = uuid,
                petType = petType,
                level = tonumber(petData.Level) or 0,
            })
        end
    end

    -- Deterministic ordering only; every matching copy qualifies regardless
    -- of level, mutation, or weight.
    table.sort(matches, function(a, b)
        if a.petType ~= b.petType then
            return a.petType < b.petType
        end
        if a.level ~= b.level then
            return a.level < b.level
        end
        return tostring(a.uuid) < tostring(b.uuid)
    end)

    return matches
end

function buildReductionTeam()
    local data = getData()
    local inventory = getPetInventory(data)
    local maxPets = getTeamSlotCapacity(data)

    local allowed = {}
    for _, petName in ipairs(CONFIG.REDUCTION_PETS) do
        allowed[petName] = true
    end

    local matches = collectUUIDsByPetNames(inventory, allowed)
    local team = {}

    -- Fill all 8 available team slots with any inventory copies whose
    -- names are Birb / Rainbow Birb / Mimic Octopus.
    for _, match in ipairs(matches) do
        if #team >= maxPets then
            break
        end
        table.insert(team, match.uuid)
    end

    return team
end

function buildKoiTeam()
    local data = getData()
    local inventory = getPetInventory(data)
    local maxPets = getTeamSlotCapacity(data)

    local koiMatches = collectUUIDsByPetNames(inventory, {
        ["Koi"] = true,
    })

    local rubyMatches = collectUUIDsByPetNames(inventory, {
        ["Ruby Squid"] = true,
    })

    local team = {}

    -- Requested Koi pattern: one Koi first, then Ruby Squid fills the
    -- remaining slots. If there is no Koi, Ruby Squid can still fill all
    -- available slots.
    if koiMatches[1] then
        table.insert(team, koiMatches[1].uuid)
    end

    for _, match in ipairs(rubyMatches) do
        if #team >= maxPets then
            break
        end
        table.insert(team, match.uuid)
    end

    return team
end

---------------------------------------------------------------------
-- V52 FAVORITE HELPER
---------------------------------------------------------------------

function isPetFavorite(tool)
    return tool and tool:GetAttribute("d") == true
end

function togglePetFavorite(tool)
    if not tool or not FavoriteItemRemote then
        return false
    end
    return pcall(function()
        FavoriteItemRemote:FireServer(tool)
    end)
end

---------------------------------------------------------------------
-- V52 BYPASS TRADE WARNING — ALWAYS ON
---------------------------------------------------------------------

function forceBypassTradeWarning()
    if not SetUnfairTradeWarningRemote then
        return false
    end

    -- V52 enabled state sends false to SetUnfairTradeWarning.
    return pcall(function()
        SetUnfairTradeWarningRemote:FireServer(false)
    end)
end

-- Enable immediately on startup.
forceBypassTradeWarning()

function unfavoriteTransferTeamsBeforeTrade()
    pcall(refreshAutoAssignedTeams)

    local teams = { State.reductionTeam, State.koiTeam }
    local tools = {}
    local seen = {}

    -- First collect the live favorite tools.
    for _, team in ipairs(teams) do
        if type(team) == "table" then
            for _, uuid in ipairs(team) do
                if uuid and not seen[uuid] then
                    seen[uuid] = true

                    local petTool = getToolByPetUUID(uuid)
                    if petTool and isPetFavorite(petTool) then
                        table.insert(tools, petTool)
                    end
                end
            end
        end
    end

    -- No per-pet 100ms sleep. Fire all required V52 Favorite_Item
    -- toggles in the same scheduler turn.
    for _, petTool in ipairs(tools) do
        task.defer(function()
            togglePetFavorite(petTool)
        end)
    end

    return #tools
end

function unequipAllGardenPets()
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

function equipGardenTeam(team, teamName)
    if type(team) ~= "table" or #team == 0 then
        State.currentGardenTeamName = teamName
        State.currentGardenTeam = {}
        return false
    end

    unequipAllGardenPets()

    local data = getData()
    local maxPets = getTeamSlotCapacity(data)
    if maxPets <= 0 then
        maxPets = math.min(CONFIG.TEAM_SLOTS, #team)
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

function refreshAutoAssignedTeams()
    if not State.autoAssignTeamsEnabled then
        return State.reductionTeam, State.koiTeam
    end

    State.reductionTeam = buildReductionTeam()
    State.koiTeam = buildKoiTeam()
    return State.reductionTeam, State.koiTeam
end

function ensureReductionTeam()
    refreshAutoAssignedTeams()
    local team = State.reductionTeam
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

function ensureKoiTeam()
    refreshAutoAssignedTeams()
    local team = State.koiTeam
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

Threads.autoAssignTeams = task.spawn(function()
    while not State.shuttingDown do
        if State.autoAssignTeamsEnabled then
            pcall(refreshAutoAssignedTeams)
        end
        task.wait(0.5)
    end
end)

---------------------------------------------------------------------
-- V52 AUTO-HATCH CORE (TRANSFER VERSION)
-- The workflow below intentionally follows the V52 Auto Hatch sequencing.
-- Pet selling is deliberately omitted.

function GetSafePing()
    local minPing = 0.0001

    local ok, result = pcall(function()
        local rawPing = (LocalPlayer and LocalPlayer:GetNetworkPing()) or 0
        return math.clamp(rawPing, minPing, 7)
    end)

    return ok and result or minPing
end

function GetFastHatchMode()
    -- Transfer's "Overdrive" switch maps to V52's fast-hatch mode.
    return CONFIG.OVERDRIVE == true
end

function GetUltraMode()
    return CONFIG.OVERDRIVE == true and CONFIG.ULTRA == true
end

function getV52EggPositions(center, blockedList)
    if CONFIG.MIDDLE_EGGS then
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
            local distA = (a - center).X ^ 2 + (a - center).Z ^ 2
            local distB = (b - center).X ^ 2 + (b - center).Z ^ 2
            return distA < distB
        end)

        return positions
    end

    -- Exact V52 non-middle position generation.
    local positions = {}

    local OUTER_WIDTH = 70
    local OUTER_DEPTH = 50
    local INNER_WIDTH = 14
    local INNER_DEPTH = 60
    local SPACING = 5

    local halfOuterW = OUTER_WIDTH / 2
    local halfOuterD = OUTER_DEPTH / 2
    local halfInnerW = INNER_WIDTH / 2
    local halfInnerD = INNER_DEPTH / 2

    for x = center.X - halfOuterW, center.X + halfOuterW, SPACING do
        for z = center.Z - halfOuterD, center.Z + halfOuterD, SPACING do
            if math.abs(x - center.X) > halfInnerW
                or math.abs(z - center.Z) > halfInnerD
            then
                table.insert(positions, Vector3.new(x, center.Y, z))
            end
        end
    end

    -- V52 shuffles the non-middle layout before placement.
    math.randomseed(tick())
    math.random()
    math.random()

    for i = #positions, 2, -1 do
        local j = math.random(i)
        positions[i], positions[j] = positions[j], positions[i]
    end

    return positions
end

function placeNightEggsToMax()
    if not State.enabled or State.tradeBusy then
        return false
    end

    if not State.objectsPhysical or not State.centerPart then
        if not refreshFarmRefs() then
            return false
        end
    end

    local data = getData()
    local userMaxEggs = tonumber(CONFIG.MAX_EGG_TARGET) or 0

    if userMaxEggs <= 0 then
        userMaxEggs = getMaxEggCapacity(data)
    end

    if userMaxEggs <= 0 then
        State.lastStatus = "Unable to read MaxEggsInFarm."
        return false
    end

    local farmEggCount = getFarmEggCount()

    if farmEggCount >= userMaxEggs then
        State.lastStatus = "✅ Farm is full."
        return true
    end

    local center = State.centerPart.Position
    local availablePositions = getV52EggPositions(center, getTakenEggPositions())

    local maxTime = os.clock()
    local placedAny = false

    -- Exact V52-style outer loop: poll every 0.1s and stop after 10s.
    while true do
        task.wait(0.1 + GetSafePing())

        if not State.enabled or State.tradeBusy then
            break
        end

        if os.clock() - maxTime >= 10 then
            break
        end

        if getFarmEggCount() >= userMaxEggs then
            State.lastStatus = "✅ Farm is full."
            return true
        end

        local tool = getNightEggTool()

        if not tool then
            State.lastStatus = "🔴 Out of Night Eggs."
            break
        end

        local toolUses = getEggToolUses(tool)
        if toolUses <= 0 then
            State.lastStatus = "🔴 Night Egg tool has no uses."
            break
        end

        if #availablePositions == 0 then
            availablePositions = getV52EggPositions(
                center,
                getTakenEggPositions()
            )

            if #availablePositions == 0 then
                State.lastStatus = "🔴 No valid egg positions."
                break
            end
        end

        if not getEquippedTool() or getEquippedTool() ~= tool then
            unequipTools()
            task.wait(0.2)
            if not equipTool(tool) then
                State.lastStatus = "🔴 Failed to equip Night Egg."
                break
            end
        end

        local placePos = table.remove(availablePositions, 1)
        if not placePos then
            break
        end

        local startEggCount = getFarmEggCount()

        State.lastStatus = string.format(
            "🥚 Placing Night Egg %d/%d...",
            math.min(startEggCount + 1, userMaxEggs),
            userMaxEggs
        )

        -- This is the same direct CreateEgg call used by V52.
        local fired = pcall(function()
            PetEggService:FireServer("CreateEgg", placePos)
        end)

        if not fired then
            State.lastStatus = "🔴 CreateEgg failed."
            break
        end

        placedAny = true

        -- V52 waits for the live farm count to actually increment.
        local waitAmount = os.clock()

        while true do
            task.wait(0.1 + GetSafePing())

            if not State.enabled or State.tradeBusy then
                break
            end

            if os.clock() - waitAmount >= 3 then
                break
            end

            local endEggCount = getFarmEggCount()

            if endEggCount > startEggCount then
                if endEggCount >= userMaxEggs then
                    State.lastStatus = "✅ Farm is full."
                end
                break
            end

            if endEggCount >= userMaxEggs then
                State.lastStatus = "✅ Farm is full."
                break
            end
        end
    end

    unequipTools()
    return placedAny or getFarmEggCount() >= userMaxEggs
end

function hatchReadyNightEggs()
    if not State.enabled or State.tradeBusy then
        return 0
    end

    -- V52 HatchAllEggsAvailable(): ready means TimeToHatch == 0 and
    -- Name == "PetEgg".
    local ready = {}

    for _, eggModel in ipairs(getFarmEggModels()) do
        if eggModel:IsA("Model")
            and eggModel.Name == "PetEgg"
            and tonumber(eggModel:GetAttribute("TimeToHatch")) == 0
            and eggModel:GetAttribute("EggName") == CONFIG.DEFAULT_EGG
        then
            table.insert(ready, eggModel)
        end
    end

    local countReady = #ready

    if countReady <= 0 then
        return 0
    end

    State.lastStatus = string.format(
        "♻️ Hatching all available Night Eggs... (%d)",
        countReady
    )

    -- Match V52: fire HatchPet directly for each ready egg, one after another.
    for _, eggModel in ipairs(ready) do
        if not State.enabled or State.tradeBusy then
            break
        end

        if eggModel and eggModel.Parent then
            pcall(function()
                PetEggService:FireServer("HatchPet", eggModel)
            end)
        end
    end

    -- Match V52: allow server-side consumption of the ready egg models,
    -- with a short timeout rather than launching parallel HatchPet threads.
    local timeout = os.clock()

    while true do
        task.wait(0.3 + GetSafePing())

        if not State.enabled then
            break
        end

        local remainingReady = 0

        for _, eggModel in ipairs(getFarmEggModels()) do
            if eggModel:IsA("Model")
                and eggModel.Name == "PetEgg"
                and tonumber(eggModel:GetAttribute("TimeToHatch")) == 0
                and eggModel:GetAttribute("EggName") == CONFIG.DEFAULT_EGG
            then
                remainingReady += 1
            end
        end

        if remainingReady == 0 then
            break
        end

        if os.clock() - timeout > 2 then
            warn("Timeout: Some eggs were not hatched.")
            break
        end
    end

    return countReady
end

-- NIGHT EGG PET GIFTING
---------------------------------------------------------------------

function collectNightEggPetEntries()
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

function findGiftTarget()
    -- Hard-locked target.
    return Players:FindFirstChild(CONFIG.TARGET_GIFT_PLAYER)
end

function fastGiftAllNightEggPets()
    if State.autoGiftBusy or State.tradeBusy then
        return
    end

    if State.hatching or not State.enabled or not State.autoGiftEnabled then
        return
    end

    local target = findGiftTarget()
    if not target then
        return
    end

    State.autoGiftBusy = true

    local ok, err = pcall(function()
        while State.enabled
            and State.autoGiftEnabled
            and not State.tradeBusy
            and not State.hatching
            and not State.shuttingDown
        do
            local pets = collectNightEggPetEntries()
            if #pets == 0 then
                break
            end

            for _, pet in ipairs(pets) do
                if not State.enabled or State.tradeBusy or State.hatching then
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

                unequipTools()
                if not equipTool(tool) then
                    continue
                end

                State.lastStatus = "⚡ Rapid Gift → "
                    .. CONFIG.TARGET_GIFT_PLAYER
                    .. " • " .. tostring(pet.petType)

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
        warn("[FABLE TRANSFER V15] Gift error:", err)
    end

    State.autoGiftBusy = false
end

Threads.rapidGift = task.spawn(function()
    while not State.shuttingDown do
        -- V52 GiftSystem is gated by the actual hatching flag, not by the
        -- outer hatch-loop/cycle flag. This keeps Rapid Gift alive while
        -- eggs are reducing/waiting, but stops it during the hatch phase.
        if State.enabled
            and State.autoGiftEnabled
            and not State.hatching
            and not State.tradeBusy
            and not State.autoGiftBusy
        then
            pcall(fastGiftAllNightEggPets)
        end
        task.wait(0.1)
    end
end)

---------------------------------------------------------------------
---------------------------------------------------------------------
-- AUTO PET SLOT
---------------------------------------------------------------------

function getPurchasedSlotCount(data)
    local petsData = getPetsData(data)
    return tonumber(petsData and petsData.PurchasedEquipSlots) or 0
end

function findLowestQualifyingPetUUID(inventory, requiredLevel)
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

function startAutoPetSlot()
    if State.autoSlotBusy or not State.autoPetSlotEnabled or State.shuttingDown then
        return
    end

    State.autoSlotBusy = true

    Threads.autoPetSlot = task.spawn(function()
        while State.autoPetSlotEnabled and not State.shuttingDown do
            local data = getData()

            if not data then
                State.lastStatus = "Auto Pet Slot: waiting for DataService..."
                task.wait(0.5)
                continue
            end

            -- The game's PetEquipSlots UI reads this exact value from
            -- Data.PetsData.PurchasedEquipSlots.
            local purchased = getPurchasedSlotCount(data)
            local stage = purchased + 1
            local requiredLevel = CONFIG.AUTO_SLOT_REQUIREMENTS[stage]

            if not requiredLevel then
                State.lastStatus = "Auto Pet Slot: all 5 slots unlocked."
                break
            end

            local inventory = getPetInventory(data)
            local uuid, level, petName =
                findLowestQualifyingPetUUID(inventory, requiredLevel)

            if not uuid then
                State.lastStatus = string.format(
                    "Auto Pet Slot: waiting for Common/Uncommon pet Lv.%d+",
                    requiredLevel
                )
                task.wait(0.5)
                continue
            end

            -- Verified game implementation:
            -- GameEvents.UnlockSlotFromPet:FireServer(UUID, CurrentMode)
            -- For the pet-slot UI CurrentMode is "Pet".
            State.lastStatus = string.format(
                "Auto Pet Slot: %s Lv.%d -> %d+",
                tostring(petName),
                tonumber(level) or 0,
                requiredLevel
            )

            local before = purchased
            local ok, err = pcall(function()
                UnlockSlotRemote:FireServer(tostring(uuid), "Pet")
            end)

            if not ok then
                State.lastStatus = "Auto Pet Slot error: " .. tostring(err)
                task.wait(1)
                continue
            end

            -- Give the server time to replicate the purchase. If it does not
            -- advance, retry the stage on the next pass instead of getting
            -- stuck permanently.
            local deadline = os.clock() + 3
            local unlocked = false

            while State.autoPetSlotEnabled
                and not State.shuttingDown
                and os.clock() < deadline
            do
                task.wait(0.15)

                local freshData = getData()
                local fresh = getPurchasedSlotCount(freshData)

                if fresh > before then
                    unlocked = true
                    State.lastStatus = string.format(
                        "Auto Pet Slot: unlocked slot %d/5.",
                        fresh
                    )
                    break
                end
            end

            if not unlocked then
                State.lastStatus =
                    "Auto Pet Slot: unlock not confirmed; retrying..."
                task.wait(0.5)
            end
        end

        State.autoSlotBusy = false
        Threads.autoPetSlot = nil
    end)
end

---------------------------------------------------------------------
-- TRADE DETECTION / ACCEPT
---------------------------------------------------------------------

function textContainsTarget(root, target)
    if not root then
        return false
    end

    local wanted = tostring(target):lower()

    if root:IsA("TextLabel") or root:IsA("TextButton") or root:IsA("TextBox") then
        if tostring(root.Text or ""):lower():find(wanted, 1, true) then
            return true
        end
    end

    for _, obj in ipairs(root:GetDescendants()) do
        if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
            if tostring(obj.Text or ""):lower():find(wanted, 1, true) then
                return true
            end
        end
    end

    return false
end

function getPlayerGui()
    return LocalPlayer:FindFirstChild("PlayerGui")
end

function getTradingUI()
    local gui = getPlayerGui()
    return gui and gui:FindFirstChild("TradingUI")
end

-- V52 TradeSystem.IsTradeActive()
function isTradeUIActive()
    local ui = getTradingUI()
    return ui ~= nil and ui.Enabled == true
end

-- V52 TradeSystem.OtherPlayerReady()
function otherPlayerReady()
    local ui = getTradingUI()
    if not ui then
        return false
    end

    local liveTrade = ui:FindFirstChild("LiveTrade")
    local other = liveTrade and liveTrade:FindFirstChild("OtherPlr")
    local ready = other and other:FindFirstChild("Ready")

    if not ready then
        return false
    end

    local transparency = tonumber(ready.BackgroundTransparency)
    return transparency ~= nil and transparency < 1
end

-- V52 TradeSystem.MyAddedItemsCount()
function myTradeItemCount()
    local ui = getTradingUI()
    local liveTrade = ui and ui:FindFirstChild("LiveTrade")
    local myPlr = liveTrade and liveTrade:FindFirstChild("MyPlr")
    local scroll = myPlr and myPlr:FindFirstChild("ScrollingFrame")

    if not scroll then
        return 0
    end

    local count = 0
    for _, item in ipairs(scroll:GetChildren()) do
        if item:IsA("ImageButton") and item.Name == "ItemTemplate" then
            count += 1
        end
    end

    return count
end

-- V52 exact ticket path:
-- Gift_Notification -> Frame -> TradeRequest -> Wrapper -> Canvas ->
-- Segment -> Buttons -> ACCEPT_BUTTON -> Main -> SENSOR
function isArimabnsTradeRequestVisible()
    local gui = getPlayerGui()
    if not gui then
        return false
    end

    local notif = gui:FindFirstChild("Gift_Notification")
    if not notif or not notif.Enabled then
        return false
    end

    local frame = notif:FindFirstChild("Frame")
    if not frame then
        return false
    end

    local tradeReq = frame:FindFirstChild("TradeRequest")
    if not tradeReq then
        return false
    end

    return textContainsTarget(tradeReq, CONFIG.TARGET_TRADE_PLAYER)
end

function clickTradeRequestAccept()
    local gui = getPlayerGui()
    if not gui then
        return false
    end

    local notif = gui:FindFirstChild("Gift_Notification")
    if not notif or not notif.Enabled then
        return false
    end

    local frame = notif:FindFirstChild("Frame")
    local tradeReq = frame and frame:FindFirstChild("TradeRequest")
    if not tradeReq then
        return false
    end

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

-- V52 exact in-trade Accept path:
-- TradingUI -> LiveTrade -> Options -> Accept
function clickTradeAccept()
    local ui = getTradingUI()
    if not ui or not ui.Enabled then
        return false
    end

    local liveTrade = ui:FindFirstChild("LiveTrade")
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

function isActiveTradeArimabns()
    local ui = getTradingUI()
    if not ui then
        return false
    end

    if textContainsTarget(ui, CONFIG.TARGET_TRADE_PLAYER) then
        return true
    end

    return State.acceptedArimabnsRequest and ui.Enabled == true
end

-- The transfer has two garden teams. Preserve V52's ordering:
-- Egg Reduction -> Koi. Add up to the game's 12-trade-item limit.
function getTradeTeamUUIDs()
    local seen = {}
    local result = {}

    refreshAutoAssignedTeams()
    local orderedTeams = {
        State.reductionTeam,
        State.koiTeam,
    }

    for _, team in ipairs(orderedTeams) do
        if type(team) == "table" then
            for _, uuid in ipairs(team) do
                if uuid and not seen[uuid] then
                    seen[uuid] = true
                    table.insert(result, uuid)

                    if #result >= 12 then
                        return result
                    end
                end
            end
        end
    end

    return result
end

-- V52 Trade Pet Teams: add the assigned team pets to the active trade,
-- one by one, checking for the live inventory tool before AddItem.
function addTradePetTeams()
    if myTradeItemCount() >= 12 then
        return
    end

    for _, uuid in ipairs(getTradeTeamUUIDs()) do
        if myTradeItemCount() >= 12 then
            break
        end

        if not getToolByPetUUID(uuid) then
            continue
        end

        pcall(function()
            AddItemRemote:FireServer("Pet", uuid)
        end)

        task.wait(0.1)
    end
end

-- Full V52-style arimabns trade lifecycle, specialized to this project:
-- ticket -> unfavorite transfer pets -> unequip garden team -> accept ticket ->
-- add transfer teams -> target ready -> accept/confirm -> restore garden team.
function handleArimabnsTrade()
    if State.tradeBusy or not isArimabnsTradeRequestVisible() then
        return false
    end

    State.tradeBusy = true
    State.lastStatus = "🎟️ arimabns trade ticket detected."

    local savedTeamName = State.currentGardenTeamName
    local savedTeam = table.clone(State.currentGardenTeam)

    -- V11: unfavorite transfer-team pets first, using the fast path.
    local unfavoritedCount = 0
    pcall(function()
        unfavoritedCount = unfavoriteTransferTeamsBeforeTrade()
    end)

    -- Let deferred Favorite_Item calls run, then reassert the V52
    -- warning-bypass state before ticket acceptance.
    task.wait()
    forceBypassTradeWarning()

    -- User-required ordering: team is unequipped BEFORE ticket acceptance.
    pcall(unequipAllGardenPets)
    State.currentGardenTeamName = nil
    State.currentGardenTeam = {}
    task.wait(0.1)

    -- Ticket acceptance is hard-locked by isArimabnsTradeRequestVisible().
    local acceptedTicket = clickTradeRequestAccept()
    if not acceptedTicket then
        State.lastStatus = "❌ Failed to accept arimabns trade ticket."
        State.tradeBusy = false

        if savedTeamName and #savedTeam > 0 then
            pcall(function()
                equipGardenTeam(savedTeam, savedTeamName)
            end)
        end

        return false
    end

    State.acceptedArimabnsRequest = true
    State.lastStatus = string.format(
        "✅ arimabns ticket accepted • %d transfer pets unfavorited",
        unfavoritedCount
    )

    -- Wait for the live TradingUI.
    local waitDeadline = os.clock() + 6
    while os.clock() < waitDeadline do
        if isTradeUIActive() and isActiveTradeArimabns() then
            break
        end
        task.wait(0.08)
    end

    if not (isTradeUIActive() and isActiveTradeArimabns()) then
        State.lastStatus = "❌ TradingUI not detected after arimabns ticket."
        State.acceptedArimabnsRequest = false
        State.tradeBusy = false

        if savedTeamName and #savedTeam > 0 then
            pcall(function()
                equipGardenTeam(savedTeam, savedTeamName)
            end)
        end

        return false
    end

    State.lastStatus = "🤝 Adding Transfer Pet Teams to arimabns..."
    pcall(addTradePetTeams)

    -- V52: once the other player is ready, press the in-trade Accept.
    local confirmDeadline = os.clock() + 30
    while isTradeUIActive()
        and isActiveTradeArimabns()
        and os.clock() < confirmDeadline
    do
        if otherPlayerReady() then
            pcall(clickTradeAccept)
            break
        end

        task.wait(0.1)
    end

    -- V52's trade loop performs another accept after the items have been added.
    task.wait(1)
    if isTradeUIActive() and isActiveTradeArimabns() then
        pcall(clickTradeAccept)
    end

    -- Wait briefly for the trade to close/complete before restoring the team.
    local closeDeadline = os.clock() + 5
    while isTradeUIActive() and os.clock() < closeDeadline do
        task.wait(0.1)
    end

    State.acceptedArimabnsRequest = false
    State.lastTradeHandledAt = os.clock()

    if savedTeamName and #savedTeam > 0 then
        pcall(function()
            equipGardenTeam(savedTeam, savedTeamName)
        end)
    end

    State.tradeBusy = false
    State.lastStatus = "✅ arimabns trade handled. Resuming transfer."
    return true
end

-- V52-style independent ticket watcher. This stays alive even when the
-- Auto Hatch toggle is OFF.
Threads.tradeTicketWatcher = task.spawn(function()
    while not State.shuttingDown do
        task.wait(0.15)

        if not State.tradeBusy and isArimabnsTradeRequestVisible() then
            pcall(handleArimabnsTrade)
        end
    end
end)

-- Independent final accept/confirm watcher.
Threads.tradeConfirmWatcher = task.spawn(function()
    while not State.shuttingDown do
        task.wait(0.1)

        if not State.tradeBusy
            and isTradeUIActive()
            and isActiveTradeArimabns()
        then
            pcall(function()
                if otherPlayerReady() then
                    clickTradeAccept()
                end
            end)
        end
    end
end)

---------------------------------------------------------------------

---------------------------------------------------------------------
-- V52 PLAYER STATS + ACTIVE PETS UI
---------------------------------------------------------------------

PLAYER_SECRETS = {
    "EggRecoveryChance",
    "PetSellEggRefundChance",
    "PetEggHatchAgeBonus",
    "PetEggHatchSizeBonus",
    "PetPassiveBonus",
    "SessionTime",
    "SellSilverFruitRewardChance",
    "Grow_Amount",
}

function shortNameNoDots(str, max)
    str = tostring(str or "")
    max = max or 3
    if #str > max then
        return str:sub(1, max)
    end
    return str
end

function fmtTimeV52(secs)
    secs = math.max(0, tonumber(secs) or 0)
    return string.format("%02d:%02d", math.floor(secs / 60), math.floor(secs % 60))
end

function getRealPetWeightV52(baseWeight, level)
    if not PetUtilities then
        return tonumber(baseWeight) or 0
    end
    local ok, result = pcall(function()
        return PetUtilities:CalculateWeight(baseWeight or 1, level or 1)
    end)
    if ok then
        return tonumber(result) or tonumber(baseWeight) or 0
    end
    return tonumber(baseWeight) or 0
end

function getPetEntryV5(uuid, data)
    local inventory = getPetInventory(data)
    return inventory and inventory[uuid]
end

if PetCooldownsUpdatedRemote then
    Connections.petCooldowns = PetCooldownsUpdatedRemote.OnClientEvent:Connect(function(petId, cooldowns)
        if type(petId) ~= "string" or type(cooldowns) ~= "table" then
            return
        end

        local entry = getPetEntryV5(petId, getData())
        local petName = entry and entry.PetType
        if not petName then
            return
        end

        local spells = {}
        for _, datax in ipairs(cooldowns) do
            if type(datax) == "table" then
                table.insert(spells, {
                    Name = petName,
                    Passive = tostring(datax.Passive),
                    Time = tonumber(datax.Time) or 0,
                })
            end
        end
        State.cooldownPets[petId] = spells
    end)
end

function getSkillCooldownTextV52(uuid)
    local textValue = ""
    local petInfo = State.cooldownPets[uuid]
    if type(petInfo) ~= "table" then
        return textValue
    end

    for _, info in ipairs(petInfo) do
        if info.Name and info.Passive and info.Time ~= nil then
            textValue = textValue .. " " .. string.format(
                '%s:<font color="#A6FF00">%s</font>',
                shortNameNoDots(info.Passive, 4),
                fmtTimeV52(info.Time)
            )
        end
    end
    return textValue
end

function destroyPlayerStatsGui()
    if State.playerStatsGui and State.playerStatsGui.Parent then
        pcall(function() State.playerStatsGui:Destroy() end)
    end
    State.playerStatsGui = nil
    State.playerStatsLabels = {}
end

function updatePlayerStatusUIV52()
    if not State.playerStatsEnabled then
        destroyPlayerStatsGui()
        return
    end

    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if not playerGui then return end

    if not State.playerStatsGui or not State.playerStatsGui.Parent then
        State.playerStatsLabels = {}

        local gui = Instance.new("ScreenGui")
        gui.Name = "SecretStatsGui"
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 2

        local mainFrame = Instance.new("Frame", gui)
        mainFrame.Name = "MainFrame"
        mainFrame.AnchorPoint = Vector2.new(0, 0.5)
        mainFrame.Position = UDim2.new(0, 15, 0.3, 0)
        mainFrame.BackgroundColor3 = Color3.new(0.1, 0.1, 0.1)
        mainFrame.BackgroundTransparency = 1
        mainFrame.BorderSizePixel = 0
        mainFrame.AutomaticSize = Enum.AutomaticSize.Y
        Instance.new("UICorner", mainFrame).CornerRadius = UDim.new(0, 8)

        local padding = Instance.new("UIPadding", mainFrame)
        padding.PaddingLeft = UDim.new(0, 10)
        padding.PaddingRight = UDim.new(0, 10)
        padding.PaddingTop = UDim.new(0, 10)
        padding.PaddingBottom = UDim.new(0, 10)

        local listLayout = Instance.new("UIListLayout", mainFrame)
        listLayout.SortOrder = Enum.SortOrder.LayoutOrder
        listLayout.Padding = UDim.new(0, 4)

        for order, key in ipairs(PLAYER_SECRETS) do
            local label = Instance.new("TextLabel", mainFrame)
            label.Name = key
            label.Text = key .. ": 0.00"
            label.Font = Enum.Font.SourceSans
            label.TextSize = 17
            label.TextColor3 = Color3.new(1, 1, 1)
            label.TextXAlignment = Enum.TextXAlignment.Left
            label.BackgroundTransparency = 1
            label.Size = UDim2.new(1, 0, 0, 18)
            label.RichText = true
            label.LayoutOrder = order

            local outline = Instance.new("UIStroke", label)
            outline.Color = Color3.new(0, 0, 0)
            outline.Thickness = 1

            State.playerStatsLabels[key] = label
        end

        gui.Parent = playerGui
        State.playerStatsGui = gui
    end

    for _, key in ipairs(PLAYER_SECRETS) do
        local label = State.playerStatsLabels[key]
        if label then
            local value = LocalPlayer:GetAttribute(key)
            if value == nil then value = 0 end

            local formattedValue = typeof(value) == "number"
                and string.format("%.2f", value)
                or tostring(value)

            if key == "SessionTime" then
                formattedValue = fmtTimeV52(value)
            end

            if formattedValue == "0.00" then
                label.Text = key .. ": " .. formattedValue
            else
                label.Text = key .. ': <b><font color="#FF7800">'
                    .. formattedValue .. "</font></b>"
            end
        end
    end
end

function destroyActivePetsGui()
    if State.activePetsGui and State.activePetsGui.Parent then
        pcall(function() State.activePetsGui:Destroy() end)
    end
    State.activePetsGui = nil
    State.activePetsLabel = nil
end

function makeActivePetUiV52(data)
    local activeList = getEquippedPets(data)
    local now = os.time()
    local currentUUIDs = {}

    for _, uuid in ipairs(activeList) do
        currentUUIDs[uuid] = true
    end

    for _, uuid in ipairs(activeList) do
        local entry = getPetEntryV5(uuid, data)
        if entry and entry.PetData then
            local petData = entry.PetData
            local petType = entry.PetType or "Unknown"
            local level = tonumber(petData.Level) or 1
            local baseWeight = tonumber(petData.BaseWeight) or 0
            local realWeight = getRealPetWeightV52(baseWeight, 1)
            local skillInfo = getSkillCooldownTextV52(uuid)

            local levelColor = level >= 100 and "#FFD700"
                or (level >= 50 and "#66BB6A" or "#FF1100")

            local levelDisplay = string.format('<font color="%s">Lv.%d</font>', levelColor, level)

            local info = string.format(
                '<stroke th="1" joins="round" sizing="fixed" color="#000000"><font color="#E800FF">[%.2fKG]</font></stroke> ' ..
                '<stroke th="0.9" joins="round" sizing="fixed" color="#000000">%s <font color="#FFFFFF">%s</font> %s</stroke>',
                realWeight, levelDisplay, shortNameNoDots(petType, 9), skillInfo
            )

            State.activePetsCacheUI[uuid] = {
                info = info,
                removedAt = nil,
                sortLevel = level,
                sortName = petType,
            }
        end
    end

    for uuid, cacheEntry in pairs(State.activePetsCacheUI) do
        if not currentUUIDs[uuid] and not cacheEntry.removedAt then
            cacheEntry.removedAt = now
        end
    end

    local removeList = {}
    local sortingList = {}

    for uuid, cacheEntry in pairs(State.activePetsCacheUI) do
        local shouldShow = false
        local finalString = ""

        if cacheEntry.removedAt then
            if now - cacheEntry.removedAt > 2 then
                table.insert(removeList, uuid)
            else
                finalString = '<font color="#FF2A00">' .. cacheEntry.info .. "</font>"
                shouldShow = true
            end
        else
            finalString = cacheEntry.info
            shouldShow = true
        end

        if shouldShow then
            table.insert(sortingList, {
                str = finalString,
                lvl = cacheEntry.sortLevel or 0,
                name = cacheEntry.sortName or "",
            })
        end
    end

    table.sort(sortingList, function(a, b)
        if a.lvl ~= b.lvl then return a.lvl > b.lvl end
        return a.name < b.name
    end)

    for _, uuid in ipairs(removeList) do
        State.activePetsCacheUI[uuid] = nil
    end

    local lines = {}
    for _, item in ipairs(sortingList) do
        table.insert(lines, item.str)
    end
    return lines
end

function updateActivePetsUIV52(data)
    if not State.activePetsUIEnabled then
        destroyActivePetsGui()
        return
    end

    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if not playerGui then return end

    if not State.activePetsGui or not State.activePetsGui.Parent then
        local gui = Instance.new("ScreenGui")
        gui.Name = "ActivePetsUI"
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 2

        local frame = Instance.new("Frame", gui)
        frame.Name = "ActivePets"
        frame.AnchorPoint = Vector2.new(1, 0)
        frame.Position = UDim2.new(1, -15, 0.18, 0)
        frame.Size = UDim2.fromOffset(260, 32)
        frame.BackgroundTransparency = 1
        frame.BorderSizePixel = 0
        frame.AutomaticSize = Enum.AutomaticSize.Y

        local label = Instance.new("TextLabel", frame)
        label.Name = "ActivePetsText"
        label.BackgroundTransparency = 1
        label.Size = UDim2.new(1, 0, 0, 20)
        label.AutomaticSize = Enum.AutomaticSize.Y
        label.Font = Enum.Font.SourceSans
        label.TextSize = 17
        label.TextColor3 = Color3.new(1, 1, 1)
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.TextYAlignment = Enum.TextYAlignment.Top
        label.TextWrapped = true
        label.RichText = true

        local outline = Instance.new("UIStroke", label)
        outline.Color = Color3.new(0, 0, 0)
        outline.Thickness = 1

        gui.Parent = playerGui
        State.activePetsGui = gui
        State.activePetsLabel = label
    end

    local lines = makeActivePetUiV52(data)
    State.activePetsLabel.Text = (#lines > 0) and table.concat(lines, "\n") or ""
    State.activePetsLabel.Visible = #lines > 0
end

Threads.v52StatsUI = task.spawn(function()
    while not State.shuttingDown do
        task.wait(0.5)
        pcall(updatePlayerStatusUIV52)
        local data = getData()
        if data then
            pcall(function() updateActivePetsUIV52(data) end)
        end
    end
end)

---------------------------------------------------------------------
-- COMPACT FABLE TAB UI
---------------------------------------------------------------------

function getUIParent()
    if gethui then
        local ok, hui = pcall(gethui)
        if ok and hui then
            return hui
        end
    end

    return CoreGui
end

uiParent = getUIParent()

oldUI = uiParent:FindFirstChild("FableTransferV15")
if oldUI then
    pcall(function()
        oldUI:Destroy()
    end)
end

ScreenGui = nil
okGui, guiErr = pcall(function()
    ScreenGui = Instance.new("ScreenGui")
    ScreenGui.Name = "FableTransferV15"
    ScreenGui.ResetOnSpawn = false
    ScreenGui.IgnoreGuiInset = true
    ScreenGui.DisplayOrder = 9999
    ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    ScreenGui.Parent = uiParent
end)

if not okGui or not ScreenGui then
    warn("[FABLE TRANSFER V15] GUI creation failed: " .. tostring(guiErr))
    if getgenv then getgenv().FABLE_TRANSFER_V15 = nil end
    return
end

print("[FABLE TRANSFER V15] GUI creation started.")

Main = Instance.new("Frame")
Main.Name = "Main"
Main.Size = UDim2.fromOffset(600, 480)
Main.AnchorPoint = Vector2.new(0.5, 0.5)
Main.Position = UDim2.fromScale(0.5, 0.5)
Main.BackgroundColor3 = Color3.fromRGB(11, 9, 18)
Main.BackgroundTransparency = 0.04
Main.BorderSizePixel = 0
Main.Parent = ScreenGui

MainScale = Instance.new("UIScale")
MainScale.Name = "V52CompactScale"
MainScale.Scale = 0.78
MainScale.Parent = Main

MainCorner = Instance.new("UICorner")
MainCorner.CornerRadius = UDim.new(0, 4)
MainCorner.Parent = Main

MainStroke = Instance.new("UIStroke")
MainStroke.Thickness = 1.25
MainStroke.Color = Color3.fromRGB(178, 105, 248)
MainStroke.Transparency = 0.12
MainStroke.Parent = Main

Header = Instance.new("Frame")
Header.BackgroundTransparency = 1
Header.Position = UDim2.fromOffset(190, 8)
Header.Size = UDim2.new(1, -200, 0, 58)
Header.Parent = Main

Title = Instance.new("TextLabel")
Title.BackgroundTransparency = 1
Title.Position = UDim2.fromOffset(0, 0)
Title.Size = UDim2.new(1, -250, 0, 26)
Title.Font = Enum.Font.Code
Title.Text = "Status"
Title.TextColor3 = Color3.fromRGB(245, 243, 252)
Title.TextSize = 16
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Parent = Header

Subtitle = Instance.new("TextLabel")
Subtitle.BackgroundTransparency = 1
Subtitle.Position = UDim2.fromOffset(0, 25)
Subtitle.Size = UDim2.new(1, -250, 0, 24)
Subtitle.Font = Enum.Font.Code
Subtitle.Text = "Live Fable status feed"
Subtitle.TextColor3 = Color3.fromRGB(145, 136, 160)
Subtitle.TextSize = 11
Subtitle.TextXAlignment = Enum.TextXAlignment.Left
Subtitle.Parent = Header

SearchBox = Instance.new("TextBox")
SearchBox.Name = "Search"
SearchBox.Position = UDim2.new(1, -190, 0, 0)
SearchBox.Size = UDim2.fromOffset(180, 40)
SearchBox.BackgroundColor3 = Color3.fromRGB(11, 9, 18)
SearchBox.BackgroundTransparency = 0.04
SearchBox.BorderSizePixel = 0
SearchBox.ClearTextOnFocus = false
SearchBox.Font = Enum.Font.Code
SearchBox.PlaceholderText = "⌕  Search all settings..."
SearchBox.PlaceholderColor3 = Color3.fromRGB(120, 112, 136)
SearchBox.Text = ""
SearchBox.TextColor3 = Color3.fromRGB(235, 231, 242)
SearchBox.TextSize = 11
SearchBox.TextXAlignment = Enum.TextXAlignment.Left
SearchBox.Parent = Header

SearchCorner = Instance.new("UICorner")
SearchCorner.CornerRadius = UDim.new(0, 9)
SearchCorner.Parent = SearchBox

SearchStroke = Instance.new("UIStroke")
SearchStroke.Color = Color3.fromRGB(178, 105, 248)
SearchStroke.Thickness = 1
SearchStroke.Transparency = 0.12
SearchStroke.Parent = SearchBox

Close = Instance.new("TextButton")
Close.Name = "Close"
Close.Size = UDim2.fromOffset(26, 24)
Close.Position = UDim2.new(1, -28, 0, 43)
Close.BackgroundTransparency = 1
Close.BorderSizePixel = 0
Close.AutoButtonColor = false
Close.Text = "×"
Close.TextColor3 = Color3.fromRGB(175, 165, 190)
Close.Font = Enum.Font.GothamBold
Close.TextSize = 18
Close.Parent = Header

Close.MouseButton1Click:Connect(function()
    if ScreenGui then
        ScreenGui.Enabled = false
    end
end)

Sidebar = Instance.new("Frame")
Sidebar.Name = "Sidebar"
Sidebar.Position = UDim2.fromOffset(0, 0)
Sidebar.Size = UDim2.fromOffset(180, 500)
Sidebar.BackgroundColor3 = Color3.fromRGB(8, 7, 13)
Sidebar.BackgroundTransparency = 0.02
Sidebar.BorderSizePixel = 0
Sidebar.Parent = Main

SidebarStroke = Instance.new("UIStroke")
SidebarStroke.Color = Color3.fromRGB(178, 105, 248)
SidebarStroke.Thickness = 1
SidebarStroke.Transparency = 0.35
SidebarStroke.Parent = Sidebar

SidebarTitle = Instance.new("TextLabel")
SidebarTitle.BackgroundTransparency = 1
SidebarTitle.Position = UDim2.fromOffset(20, 24)
SidebarTitle.Size = UDim2.new(1, -40, 0, 30)
SidebarTitle.Font = Enum.Font.Code
SidebarTitle.Text = "FABLE"
SidebarTitle.TextColor3 = Color3.fromRGB(245, 243, 252)
SidebarTitle.TextSize = 18
SidebarTitle.TextXAlignment = Enum.TextXAlignment.Center
SidebarTitle.Parent = Sidebar

TabHolder = Instance.new("Frame")
TabHolder.BackgroundTransparency = 1
TabHolder.Position = UDim2.fromOffset(8, 70)
TabHolder.Size = UDim2.new(1, -16, 1, -82)
TabHolder.Parent = Sidebar

TabLayout = Instance.new("UIListLayout")
TabLayout.SortOrder = Enum.SortOrder.LayoutOrder
TabLayout.Padding = UDim.new(0, 5)
TabLayout.Parent = TabHolder

TabNames = {"Status Board", "Transfer", "Pet Teams", "Settings"}
TabButtons = {}
Pages = {}

TabMeta = {
    ["Status Board"] = {"∿", "Status"},
    ["Transfer"] = {"⌁", "Automation"},
    ["Pet Teams"] = {"♧", "Teams"},
    ["Settings"] = {"⚙", "Settings"},
}

function makeTabButton(name, index)
    local button = Instance.new("TextButton")
    button.Name = name:gsub("%s+", "") .. "Tab"
    button.Size = UDim2.new(1, 0, 0, 42)
    button.LayoutOrder = index
    button.BackgroundColor3 = Color3.fromRGB(15, 13, 22)
    button.BorderSizePixel = 0
    button.AutoButtonColor = false
    button.Text = ""
    button.Parent = TabHolder

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = button

    local icon = Instance.new("TextLabel")
    icon.Name = "Icon"
    icon.BackgroundTransparency = 1
    icon.Position = UDim2.fromOffset(12, 0)
    icon.Size = UDim2.fromOffset(26, 42)
    icon.Font = Enum.Font.Gotham
    icon.Text = TabMeta[name][1]
    icon.TextColor3 = Color3.fromRGB(105, 96, 120)
    icon.TextSize = 17
    icon.Parent = button

    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromOffset(44, 0)
    label.Size = UDim2.new(1, -54, 1, 0)
    label.Font = Enum.Font.Code
    label.Text = TabMeta[name][2]
    label.TextColor3 = Color3.fromRGB(145, 136, 160)
    label.TextSize = 12
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = button

    TabButtons[name] = button
    return button
end

for index, name in ipairs(TabNames) do
    makeTabButton(name, index)
end

PagesHolder = Instance.new("Frame")
PagesHolder.BackgroundTransparency = 1
PagesHolder.Position = UDim2.fromOffset(190, 74)
PagesHolder.Size = UDim2.new(1, -200, 1, -84)
PagesHolder.Parent = Main

---------------------------------------------------------------------
-- V52-STYLE FLOATING F TOGGLE
---------------------------------------------------------------------

FloatingToggle = Instance.new("TextButton")
FloatingToggle.Name = "FableToggle"
FloatingToggle.AnchorPoint = Vector2.new(0, 0)
FloatingToggle.Position = UDim2.fromScale(0.012, 0.16)
FloatingToggle.Size = UDim2.fromOffset(56, 56)
FloatingToggle.BackgroundColor3 = Color3.fromRGB(10, 9, 15)
FloatingToggle.BackgroundTransparency = 0.04
FloatingToggle.BorderSizePixel = 0
FloatingToggle.AutoButtonColor = false
FloatingToggle.Text = ""
FloatingToggle.ZIndex = 100
FloatingToggle.Parent = ScreenGui

floatingCorner = Instance.new("UICorner")
floatingCorner.CornerRadius = UDim.new(1, 0)
floatingCorner.Parent = FloatingToggle

floatingStroke = Instance.new("UIStroke")
floatingStroke.Thickness = 2
floatingStroke.Transparency = 0.05
floatingStroke.Color = Color3.fromRGB(178, 105, 248)
floatingStroke.Parent = FloatingToggle

floatingInner = Instance.new("Frame")
floatingInner.AnchorPoint = Vector2.new(0.5, 0.5)
floatingInner.Position = UDim2.fromScale(0.5, 0.5)
floatingInner.Size = UDim2.fromScale(0.74, 0.74)
floatingInner.BackgroundColor3 = Color3.fromRGB(28, 22, 37)
floatingInner.BorderSizePixel = 0
floatingInner.ZIndex = 101
floatingInner.Parent = FloatingToggle

floatingInnerCorner = Instance.new("UICorner")
floatingInnerCorner.CornerRadius = UDim.new(1, 0)
floatingInnerCorner.Parent = floatingInner

floatingBrand = Instance.new("TextLabel")
floatingBrand.BackgroundTransparency = 1
floatingBrand.Size = UDim2.fromScale(1, 1)
floatingBrand.Font = Enum.Font.GothamBlack
floatingBrand.Text = "F"
floatingBrand.TextColor3 = Color3.fromRGB(191, 145, 255)
floatingBrand.TextScaled = true
floatingBrand.ZIndex = 102
floatingBrand.Parent = floatingInner

function setMainVisible(visible)
    Main.Visible = visible
    FloatingToggle.Visible = true
end

FloatingToggle.Activated:Connect(function()
    setMainVisible(not Main.Visible)
end)

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then
        return
    end

    if input.KeyCode == Enum.KeyCode.RightControl then
        setMainVisible(not Main.Visible)
    end
end)

function makePage(name)
    local page = Instance.new("Frame")
    page.Name = name:gsub("%s+", "") .. "Page"
    page.BackgroundTransparency = 1
    page.Size = UDim2.fromScale(1, 1)
    page.Visible = false
    page.Parent = PagesHolder
    Pages[name] = page
    return page
end

StatusPage = makePage("Status Board")
TransferPage = makePage("Transfer")
TeamsPage = makePage("Pet Teams")
SettingsPage = makePage("Settings")

function makeSection(parent, titleText, y, height)
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

function makeLine(parent, y, leftText, rightText)
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

function makeToggle(parent, y, labelText, defaultValue, callback)
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

-- Status Board page.
-- V7 ports the V52 visual composition instead of recreating its
-- two-column field layout: one STATUS BOARD group on the left,
-- LIVE FEED on the right, and LATEST MESSAGE inside the left group.

statusLeft = makeSection(StatusPage, "STATUS BOARD", 0, 444)
statusLeft.Size = UDim2.new(0.56, -4, 0, 444)

statusRight = makeSection(StatusPage, "LIVE FEED", 0, 444)
statusRight.Position = UDim2.new(0.56, 4, 0, 0)
statusRight.Size = UDim2.new(0.44, -4, 0, 444)

statusStateLabel = Instance.new("TextLabel")
statusStateLabel.BackgroundTransparency = 1
statusStateLabel.Position = UDim2.fromOffset(12, 24)
statusStateLabel.Size = UDim2.new(1, -24, 0, 24)
statusStateLabel.Font = Enum.Font.GothamBold
statusStateLabel.Text = "🛑 STOP  •  @" .. tostring(LocalPlayer.Name)
statusStateLabel.TextColor3 = Color3.fromRGB(255, 84, 98)
statusStateLabel.TextSize = 16
statusStateLabel.TextXAlignment = Enum.TextXAlignment.Left
statusStateLabel.Parent = statusLeft

statusDetails = Instance.new("TextLabel")
statusDetails.BackgroundTransparency = 1
statusDetails.Position = UDim2.fromOffset(12, 62)
statusDetails.Size = UDim2.new(1, -24, 0, 250)
statusDetails.Font = Enum.Font.GothamBold
statusDetails.Text = ""
statusDetails.TextColor3 = Color3.fromRGB(245, 243, 252)
statusDetails.TextSize = 11
statusDetails.TextWrapped = true
statusDetails.TextXAlignment = Enum.TextXAlignment.Left
statusDetails.TextYAlignment = Enum.TextYAlignment.Top
statusDetails.RichText = true
statusDetails.Parent = statusLeft

statusDivider = Instance.new("Frame")
statusDivider.BorderSizePixel = 0
statusDivider.BackgroundColor3 = Color3.fromRGB(178, 105, 248)
statusDivider.BackgroundTransparency = 0.25
statusDivider.Position = UDim2.fromOffset(12, 322)
statusDivider.Size = UDim2.new(1, -24, 0, 1)
statusDivider.Parent = statusLeft

statusLatestTitle = Instance.new("TextLabel")
statusLatestTitle.BackgroundTransparency = 1
statusLatestTitle.Position = UDim2.fromOffset(12, 338)
statusLatestTitle.Size = UDim2.new(1, -24, 0, 20)
statusLatestTitle.Font = Enum.Font.GothamBold
statusLatestTitle.Text = "LATEST MESSAGE"
statusLatestTitle.TextColor3 = Color3.fromRGB(177, 136, 255)
statusLatestTitle.TextSize = 10
statusLatestTitle.TextXAlignment = Enum.TextXAlignment.Left
statusLatestTitle.Parent = statusLeft

statusLatestLabel = Instance.new("TextLabel")
statusLatestLabel.BackgroundTransparency = 1
statusLatestLabel.Position = UDim2.fromOffset(12, 360)
statusLatestLabel.Size = UDim2.new(1, -24, 0, 66)
statusLatestLabel.Font = Enum.Font.GothamBold
statusLatestLabel.Text = "[--:--:--]  Waiting for Fable activity..."
statusLatestLabel.TextColor3 = Color3.fromRGB(245, 243, 252)
statusLatestLabel.TextSize = 10
statusLatestLabel.TextWrapped = true
statusLatestLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLatestLabel.TextYAlignment = Enum.TextYAlignment.Top
statusLatestLabel.RichText = true
statusLatestLabel.Parent = statusLeft

statusFeedLabel = Instance.new("TextLabel")
statusFeedLabel.BackgroundTransparency = 1
statusFeedLabel.Position = UDim2.fromOffset(12, 30)
statusFeedLabel.Size = UDim2.new(1, -24, 1, -42)
statusFeedLabel.Font = Enum.Font.Code
statusFeedLabel.Text = "[--:--:--]  Waiting for Fable activity..."
statusFeedLabel.TextColor3 = Color3.fromRGB(214, 209, 224)
statusFeedLabel.TextSize = 10
statusFeedLabel.TextWrapped = true
statusFeedLabel.TextXAlignment = Enum.TextXAlignment.Left
statusFeedLabel.TextYAlignment = Enum.TextYAlignment.Top
statusFeedLabel.RichText = true
statusFeedLabel.Parent = statusRight

statusFields = {
    {"Current Stage", "IDLE"},
    {"Sub Task", "Waiting for Auto Hatch..."},
    {"Eggs on Farm", "0 / 0"},
    {"Ready Eggs", "0"},
    {"Pets in Inventory", "0 / 0"},
    {"Selected Egg", "Night Egg × 0"},
    {"Hatch Team", "None"},
    {"Next Action", "Enable Auto Hatch"},
    {"Uptime", "00:00:00"},
}

statusValues = {}
for _, pair in ipairs(statusFields) do
    statusValues[pair[1]] = pair[2]
end

function renderStatusDetails()
    local order = {
        "Current Stage",
        "Sub Task",
        "Eggs on Farm",
        "Ready Eggs",
        "Pets in Inventory",
        "Selected Egg",
        "Hatch Team",
        "Next Action",
        "Uptime",
    }

    local output = {}

    for _, key in ipairs(order) do
        local value = tostring(statusValues[key] or "")

        local valueColor = "#F5F3FC"
        if key == "Current Stage"
            or key == "Selected Egg"
            or key == "Hatch Team"
        then
            valueColor = "#AB60FF"
        end

        output[#output + 1] =
            "<b>" .. key .. "</b>  •  "
            .. "<font color='" .. valueColor .. "'>"
            .. value
            .. "</font>"
    end

    statusDetails.Text = table.concat(output, "\n")
end

renderStatusDetails()

function statusFormatUptime(seconds)
    local elapsed = math.max(0, math.floor(seconds or 0))
    local hours = math.floor(elapsed / 3600)
    elapsed %= 3600
    local minutes = math.floor(elapsed / 60)
    local secs = elapsed % 60
    return string.format("%02d:%02d:%02d", hours, minutes, secs)
end

function statusGetStage()
    if not State.enabled then
        return "IDLE"
    end

    if State.tradeBusy then
        return "TRADE"
    end

    if State.hatching then
        return "HATCH"
    end

    if State.currentGardenTeamName == "Reduction" then
        return "REDUCTION"
    end

    if State.currentGardenTeamName == "Koi" then
        return "KOI"
    end

    if getFarmEggCount() >= (getMaxEggCapacity(getData()) or 0) then
        return "MAX"
    end

    return "PLACE"
end

function statusGetNextAction(stage)
    if not State.enabled then
        return "Enable Auto Hatch"
    end

    if State.tradeBusy then
        return "Handling arimabns trade..."
    end

    if stage == "REDUCTION" then
        return "Waiting for Night Eggs..."
    elseif stage == "HATCH" then
        return "Processing ready Night Eggs..."
    elseif stage == "KOI" then
        return "Applying Koi/Ruby team..."
    elseif stage == "MAX" then
        return "Waiting for eggs to finish..."
    elseif stage == "PLACE" then
        return "Filling garden to MAX..."
    end

    return "Continue transfer cycle..."
end

function statusPush(message)
    message = tostring(message or "")
    if message == "" or message == State.statusLastMessage then
        return
    end

    State.statusLastMessage = message
    local timestamp = os.date("%H:%M:%S")
    local line = string.format("[%s]  %s", timestamp, message)

    table.insert(State.statusFeedLines, 1, line)
    while #State.statusFeedLines > 10 do
        table.remove(State.statusFeedLines)
    end

    State.statusLatest = line
end

function statusRebuildFeed()
    if #State.statusFeedLines == 0 then
        statusFeedLabel.Text = "[--:--:--]  Waiting for Fable activity..."
        return
    end

    local output = {}
    for _, line in ipairs(State.statusFeedLines) do
        local stamp, body = line:match("^%[([^%]]+)%]%s+(.*)$")
        if stamp then
            output[#output + 1] = string.format(
                '<font color="#9C97B0">[%s]</font>  %s',
                stamp,
                body
            )
        else
            output[#output + 1] = line
        end
    end

    statusFeedLabel.Text = table.concat(output, "\n")
end

function updateStatusBoard()
    local data = getData()
    local inventory = getPetInventory(data)
    local farmCount = getFarmEggCount()
    local maxEggs = getMaxEggCapacity(data)
    local readyCount = #getReadyNightEggs()
    local inventoryCount = 0
    for _ in pairs(inventory or {}) do
        inventoryCount += 1
    end

    local maxInventory = 0
    pcall(function()
        local petsData = getPetsData(data)
        local stats = petsData and petsData.MutableStats
        if type(stats) == "table" then
            maxInventory = tonumber(stats.MaxPetsInInventory) or 0
        end
    end)

    local eggTool = getNightEggTool()
    local eggUses = getEggToolUses(eggTool)
    local stage = statusGetStage()
    local latest = State.statusLatest

    statusValues["Current Stage"] = stage
    statusValues["Sub Task"] = State.lastStatus or "Working..."
    statusValues["Eggs on Farm"] = string.format("%d / %d", farmCount, maxEggs)
    statusValues["Ready Eggs"] = tostring(readyCount)
    statusValues["Pets in Inventory"] = string.format("%d / %d", inventoryCount, maxInventory)
    statusValues["Selected Egg"] = string.format("%s × %d", CONFIG.DEFAULT_EGG, eggUses)
    statusValues["Hatch Team"] = State.currentGardenTeamName or "None"
    statusValues["Next Action"] = statusGetNextAction(stage)
    statusValues["Uptime"] = statusFormatUptime(os.clock() - State.statusStartedAt)

    local running = State.enabled
    statusStateLabel.Text = running
        and ("● RUNNING  •  @" .. tostring(LocalPlayer.Name))
        or ("🛑 STOP  •  @" .. tostring(LocalPlayer.Name))
    statusStateLabel.TextColor3 = running
        and Color3.fromRGB(40, 238, 145)
        or Color3.fromRGB(255, 84, 98)

    statusLatestLabel.Text = latest
    renderStatusDetails()
    statusPush(State.lastStatus)
    statusRebuildFeed()
end

Threads.statusBoard = task.spawn(function()
    while not State.shuttingDown do
        pcall(updateStatusBoard)
        task.wait(0.25)
    end
end)

statusPush("Fable Status initialized")
statusRebuildFeed()

-- Auto Pet Slot is an independent feature. It must not depend on the
-- Auto Hatch / Transfer toggle being enabled.
task.spawn(function()
    task.wait(1)
    if State.autoPetSlotEnabled and not State.autoSlotBusy and not State.shuttingDown then
        startAutoPetSlot()
    end
end)

-- Transfer page.
transferSection = makeSection(TransferPage, "TRANSFER", 0, 185)

autoHatchToggle = makeToggle(
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

transferEggLabel = makeLine(transferSection, 61, "Egg", CONFIG.DEFAULT_EGG)
transferModeLabel = makeLine(transferSection, 82, "Placement", CONFIG.FAST_PLACEMENT and "FAST" or "NORMAL")
transferMaxLabel = makeLine(transferSection, 103, "Garden", "MAX")
transferTeamLabel = makeLine(transferSection, 124, "Team", "None")

statusSection = makeSection(TransferPage, "STATUS", 193, 86)

statusLabel = Instance.new("TextLabel")
statusLabel.BackgroundTransparency = 1
statusLabel.Position = UDim2.fromOffset(10, 25)
statusLabel.Size = UDim2.new(1, -20, 0, 48)
statusLabel.Font = Enum.Font.GothamMedium
statusLabel.Text = "Auto Hatch is OFF"
statusLabel.TextColor3 = Color3.fromRGB(225, 220, 235)
statusLabel.TextSize = 10
statusLabel.TextWrapped = true
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextYAlignment = Enum.TextYAlignment.Center
statusLabel.Parent = statusSection

updateTeamPage = nil

-- Pet Teams page.
teamTop = makeSection(TeamsPage, "AUTO ASSIGN TEAMS", 0, 42)

autoAssignToggle = makeToggle(
    teamTop, 22, "Auto Assign Teams", State.autoAssignTeamsEnabled,
    function(value)
        State.autoAssignTeamsEnabled = value
        if value then
            refreshAutoAssignedTeams()
        end
        updateTeamPage()
    end
)

teamColumns = Instance.new("Frame")
teamColumns.BackgroundTransparency = 1
teamColumns.Position = UDim2.fromOffset(0, 48)
teamColumns.Size = UDim2.new(1, 0, 0, 318)
teamColumns.Parent = TeamsPage

reductionFrame = makeSection(teamColumns, "EGG REDUCTION", 0, 318)
reductionFrame.Size = UDim2.new(0.5, -3, 1, 0)

reductionDescription = Instance.new("TextLabel")
reductionDescription.BackgroundTransparency = 1
reductionDescription.Position = UDim2.fromOffset(8, 22)
reductionDescription.Size = UDim2.new(1, -16, 0, 16)
reductionDescription.Font = Enum.Font.Gotham
reductionDescription.Text = "Birb • Rainbow Birb • Mimic Octopus"
reductionDescription.TextColor3 = Color3.fromRGB(150, 142, 165)
reductionDescription.TextSize = 7
reductionDescription.TextXAlignment = Enum.TextXAlignment.Left
reductionDescription.Parent = reductionFrame

reductionSelect = Instance.new("TextButton")
reductionSelect.Size = UDim2.new(0.62, -10, 0, 22)
reductionSelect.Position = UDim2.fromOffset(8, 42)
reductionSelect.BackgroundColor3 = Color3.fromRGB(38, 30, 48)
reductionSelect.BorderSizePixel = 0
reductionSelect.Font = Enum.Font.GothamSemibold
reductionSelect.Text = "Select All Detected"
reductionSelect.TextColor3 = Color3.fromRGB(225, 220, 235)
reductionSelect.TextSize = 7
reductionSelect.Parent = reductionFrame
Instance.new("UICorner", reductionSelect).CornerRadius = UDim.new(0, 6)

reductionEquip = Instance.new("TextButton")
reductionEquip.Size = UDim2.new(0.38, -10, 0, 22)
reductionEquip.Position = UDim2.new(0.62, 2, 0, 42)
reductionEquip.BackgroundColor3 = Color3.fromRGB(38, 30, 48)
reductionEquip.BorderSizePixel = 0
reductionEquip.Font = Enum.Font.GothamSemibold
reductionEquip.Text = "Equip"
reductionEquip.TextColor3 = Color3.fromRGB(225, 220, 235)
reductionEquip.TextSize = 7
reductionEquip.Parent = reductionFrame
Instance.new("UICorner", reductionEquip).CornerRadius = UDim.new(0, 6)

reductionLiveTitle = Instance.new("TextLabel")
reductionLiveTitle.BackgroundTransparency = 1
reductionLiveTitle.Position = UDim2.fromOffset(8, 70)
reductionLiveTitle.Size = UDim2.new(1, -16, 0, 16)
reductionLiveTitle.Font = Enum.Font.GothamBold
reductionLiveTitle.Text = "LIVE SELECTED 0/8"
reductionLiveTitle.TextColor3 = Color3.fromRGB(177, 136, 255)
reductionLiveTitle.TextSize = 7
reductionLiveTitle.TextXAlignment = Enum.TextXAlignment.Left
reductionLiveTitle.Parent = reductionFrame

reductionRows = {}
for i = 1, CONFIG.TEAM_SLOTS do
    local row = Instance.new("TextLabel")
    row.BackgroundTransparency = 1
    row.Position = UDim2.fromOffset(8, 91 + ((i - 1) * 25))
    row.Size = UDim2.new(1, -16, 0, 23)
    row.Font = Enum.Font.GothamMedium
    row.Text = string.format("%d. Empty", i)
    row.TextColor3 = Color3.fromRGB(190, 183, 205)
    row.TextSize = 7
    row.TextXAlignment = Enum.TextXAlignment.Left
    row.TextYAlignment = Enum.TextYAlignment.Center
    row.TextTruncate = Enum.TextTruncate.AtEnd
    row.Parent = reductionFrame
    reductionRows[i] = row
end

koiFrame = makeSection(teamColumns, "KOI / RUBY", 0, 318)
koiFrame.Position = UDim2.new(0.5, 3, 0, 0)
koiFrame.Size = UDim2.new(0.5, -3, 1, 0)

koiDescription = Instance.new("TextLabel")
koiDescription.BackgroundTransparency = 1
koiDescription.Position = UDim2.fromOffset(8, 22)
koiDescription.Size = UDim2.new(1, -16, 0, 16)
koiDescription.Font = Enum.Font.Gotham
koiDescription.Text = "1× Koi • Ruby Squid fills remaining slots"
koiDescription.TextColor3 = Color3.fromRGB(150, 142, 165)
koiDescription.TextSize = 7
koiDescription.TextXAlignment = Enum.TextXAlignment.Left
koiDescription.Parent = koiFrame

koiSelect = Instance.new("TextButton")
koiSelect.Size = UDim2.new(0.62, -10, 0, 22)
koiSelect.Position = UDim2.fromOffset(8, 42)
koiSelect.BackgroundColor3 = Color3.fromRGB(38, 30, 48)
koiSelect.BorderSizePixel = 0
koiSelect.Font = Enum.Font.GothamSemibold
koiSelect.Text = "Select All Detected"
koiSelect.TextColor3 = Color3.fromRGB(225, 220, 235)
koiSelect.TextSize = 7
koiSelect.Parent = koiFrame
Instance.new("UICorner", koiSelect).CornerRadius = UDim.new(0, 6)

koiEquip = Instance.new("TextButton")
koiEquip.Size = UDim2.new(0.38, -10, 0, 22)
koiEquip.Position = UDim2.new(0.62, 2, 0, 42)
koiEquip.BackgroundColor3 = Color3.fromRGB(38, 30, 48)
koiEquip.BorderSizePixel = 0
koiEquip.Font = Enum.Font.GothamSemibold
koiEquip.Text = "Equip"
koiEquip.TextColor3 = Color3.fromRGB(225, 220, 235)
koiEquip.TextSize = 7
koiEquip.Parent = koiFrame
Instance.new("UICorner", koiEquip).CornerRadius = UDim.new(0, 6)

koiLiveTitle = Instance.new("TextLabel")
koiLiveTitle.BackgroundTransparency = 1
koiLiveTitle.Position = UDim2.fromOffset(8, 70)
koiLiveTitle.Size = UDim2.new(1, -16, 0, 16)
koiLiveTitle.Font = Enum.Font.GothamBold
koiLiveTitle.Text = "LIVE SELECTED 0/8"
koiLiveTitle.TextColor3 = Color3.fromRGB(177, 136, 255)
koiLiveTitle.TextSize = 7
koiLiveTitle.TextXAlignment = Enum.TextXAlignment.Left
koiLiveTitle.Parent = koiFrame

koiRows = {}
for i = 1, CONFIG.TEAM_SLOTS do
    local row = Instance.new("TextLabel")
    row.BackgroundTransparency = 1
    row.Position = UDim2.fromOffset(8, 91 + ((i - 1) * 25))
    row.Size = UDim2.new(1, -16, 0, 23)
    row.Font = Enum.Font.GothamMedium
    row.Text = string.format("%d. Empty", i)
    row.TextColor3 = Color3.fromRGB(190, 183, 205)
    row.TextSize = 7
    row.TextXAlignment = Enum.TextXAlignment.Left
    row.TextYAlignment = Enum.TextYAlignment.Center
    row.TextTruncate = Enum.TextTruncate.AtEnd
    row.Parent = koiFrame
    koiRows[i] = row
end

teamStatus = makeSection(TeamsPage, "LIVE TEAM", 372, 42)

teamStatusLabel = Instance.new("TextLabel")
teamStatusLabel.BackgroundTransparency = 1
teamStatusLabel.Position = UDim2.fromOffset(8, 18)
teamStatusLabel.Size = UDim2.new(1, -16, 0, 18)
teamStatusLabel.Font = Enum.Font.GothamSemibold
teamStatusLabel.Text = "Reduction 0/8 • Koi 0/8 • Active: None"
teamStatusLabel.TextColor3 = Color3.fromRGB(205, 199, 215)
teamStatusLabel.TextSize = 7
teamStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
teamStatusLabel.Parent = teamStatus

function getLiveSelectedTeam(team, fallbackBuilder)
    if type(team) == "table" and #team > 0 then
        return team
    end

    local ok, result = pcall(fallbackBuilder)
    if ok and type(result) == "table" then
        return result
    end

    return {}
end

function updateCompactSelectedRows(rows, titleLabel, team, fallbackBuilder, data)
    local inventory = getPetInventory(data)
    local liveTeam = getLiveSelectedTeam(team, fallbackBuilder)

    local shown = math.min(#liveTeam, CONFIG.TEAM_SLOTS)
    titleLabel.Text = string.format("LIVE SELECTED %d/8", shown)

    for i = 1, CONFIG.TEAM_SLOTS do
        local uuid = liveTeam[i]
        local row = rows[i]

        if not uuid then
            row.Text = string.format("%d. Empty", i)
            row.TextColor3 = Color3.fromRGB(120, 114, 135)
        else
            local entry = inventory and inventory[uuid]
            local petData = entry and entry.PetData

            if entry then
                local petType = tostring(entry.PetType or "Unknown")
                local level = tonumber(petData and petData.Level) or 0
                local mutation = tostring(
                    petData and (
                        petData.MutationType
                        or petData.Mutation
                        or petData.mutation
                        or ""
                    )
                    or ""
                )

                if mutation == "" then
                    mutation = "Normal"
                end

                row.Text = string.format(
                    "%d. %s • Lv.%d • %s",
                    i,
                    petType,
                    level,
                    mutation
                )
                row.TextColor3 = Color3.fromRGB(214, 209, 224)
            else
                row.Text = string.format("%d. Missing", i)
                row.TextColor3 = Color3.fromRGB(255, 125, 125)
            end
        end
    end
end

function selectAllDetectedReductionPets()
    State.reductionTeam = buildReductionTeam()
    State.lastStatus = string.format("✅ Reduction selected: %d/8", #State.reductionTeam)
    updateTeamPage()
end

function selectAllDetectedKoiPets()
    State.koiTeam = buildKoiTeam()
    State.lastStatus = string.format("✅ Koi/Ruby selected: %d/8", #State.koiTeam)
    updateTeamPage()
end

reductionSelect.Activated:Connect(selectAllDetectedReductionPets)
koiSelect.Activated:Connect(selectAllDetectedKoiPets)

reductionEquip.Activated:Connect(function()
    refreshAutoAssignedTeams()
    if #State.reductionTeam > 0 then
        equipGardenTeam(State.reductionTeam, "Reduction")
        State.lastStatus = "✅ Reduction team equipped."
    else
        State.lastStatus = "❌ No Birb/Rainbow Birb/Mimic Octopus detected."
    end
    updateTeamPage()
end)

koiEquip.Activated:Connect(function()
    refreshAutoAssignedTeams()
    if #State.koiTeam > 0 then
        equipGardenTeam(State.koiTeam, "Koi")
        State.lastStatus = "✅ Koi/Ruby team equipped."
    else
        State.lastStatus = "❌ No Koi/Ruby Squid detected."
    end
    updateTeamPage()
end)

-- Settings page.
settingsHeader = makeSection(
    SettingsPage,
    "V52-STYLE SETTINGS • FIXED TRANSFER TARGETS",
    0,
    30
)

settingsContent = Instance.new("Frame")
settingsContent.BackgroundTransparency = 1
settingsContent.Position = UDim2.fromOffset(0, 36)
settingsContent.Size = UDim2.new(1, 0, 1, -36)
settingsContent.Parent = SettingsPage

function makeGridToggle(parent, x, y, width, labelText, defaultValue, callback)
    local control = makeToggle(parent, y, labelText, defaultValue, callback)
    control.Button.Position = UDim2.fromOffset(x, y)
    control.Button.Size = UDim2.fromOffset(width, 28)
    return control
end

gap = 6
halfWidth = math.floor((360 - gap) / 2)

makeGridToggle(settingsContent, 0, 0, halfWidth, "Fast Egg Placement", CONFIG.FAST_PLACEMENT, function(v) CONFIG.FAST_PLACEMENT = v end)
makeGridToggle(settingsContent, halfWidth + gap, 0, halfWidth, "Middle Eggs", CONFIG.MIDDLE_EGGS, function(v) CONFIG.MIDDLE_EGGS = v end)
makeGridToggle(settingsContent, 0, 32, halfWidth, "Overdrive Mode", CONFIG.OVERDRIVE, function(v) CONFIG.OVERDRIVE = v end)
makeGridToggle(settingsContent, halfWidth + gap, 32, halfWidth, "Ultra Mode", CONFIG.ULTRA, function(v) CONFIG.ULTRA = v end)

makeGridToggle(settingsContent, 0, 64, halfWidth, "Rapid Gift → mysto_sailor", true, function(v) State.autoGiftEnabled = v end)
tradeTeamsToggle = nil
tradeTeamsToggle = makeGridToggle(settingsContent, halfWidth + gap, 64, halfWidth, "Trade Pet Teams", true, function(_v)
    State.tradePetTeamsEnabled = true
    if tradeTeamsToggle then
        tradeTeamsToggle:Set(true, false)
    end
end)

tradeAcceptToggle = nil
tradeAcceptToggle = makeGridToggle(settingsContent, 0, 96, halfWidth, "Accept Ticket → arimabns", true, function(_v)
    if tradeAcceptToggle then
        tradeAcceptToggle:Set(true, false)
    end
end)

autoSlotToggle = makeGridToggle(settingsContent, halfWidth + gap, 96, halfWidth, "Auto Pet Slot", State.autoPetSlotEnabled, function(v)
    State.autoPetSlotEnabled = v

    if v and not State.autoSlotBusy then
        startAutoPetSlot()
    end
end)

makeGridToggle(settingsContent, 0, 128, halfWidth, "Player Stats", State.playerStatsEnabled, function(v) State.playerStatsEnabled = v end)
makeGridToggle(settingsContent, halfWidth + gap, 128, halfWidth, "Active Pets UI", State.activePetsUIEnabled, function(v) State.activePetsUIEnabled = v end)

makeGridToggle(settingsContent, 0, 160, halfWidth, "Auto Assign Pet Teams", State.autoAssignTeamsEnabled, function(v)
    State.autoAssignTeamsEnabled = v
    if v then refreshAutoAssignedTeams() end
    updateTeamPage()
end)

favToggle = nil
favToggle = makeGridToggle(settingsContent, halfWidth + gap, 160, halfWidth, "Auto Favorite Hatch", false, function(_v)
    if favToggle then
        favToggle:Set(false, false)
    end
end)

antiIdleToggle = makeGridToggle(
    settingsContent, 0, 192, halfWidth,
    "Anti Kick / Idle", true,
    function(value)
        State.antiIdleEnabled = value
        State.antiKickEnabled = value

        if getgenv and getgenv().__FABLE_V6_ANTIKICK_CONTROLLER then
            getgenv().__FABLE_V6_ANTIKICK_CONTROLLER.enabled = value
        end
    end
)

targetInfo = Instance.new("TextLabel")
targetInfo.BackgroundTransparency = 1
targetInfo.Position = UDim2.fromOffset(4, 226)
targetInfo.Size = UDim2.new(1, -8, 0, 28)
targetInfo.Font = Enum.Font.Gotham
targetInfo.Text = "🎁 Gift: mysto_sailor   •   🎟️ Ticket: arimabns"
targetInfo.TextColor3 = Color3.fromRGB(170, 162, 185)
targetInfo.TextSize = 8
targetInfo.TextXAlignment = Enum.TextXAlignment.Center
targetInfo.Parent = settingsContent

capacityInfo = Instance.new("TextLabel")
capacityInfo.BackgroundTransparency = 1
capacityInfo.Position = UDim2.fromOffset(4, 252)
capacityInfo.Size = UDim2.new(1, -8, 0, 28)
capacityInfo.Font = Enum.Font.Gotham
capacityInfo.Text = "Teams: 8 slots each • Night Egg only • No pet selling"
capacityInfo.TextColor3 = Color3.fromRGB(150, 142, 165)
capacityInfo.TextSize = 8
capacityInfo.TextXAlignment = Enum.TextXAlignment.Center
capacityInfo.Parent = settingsContent

function showPage(name)
    for pageName, page in pairs(Pages) do
        page.Visible = pageName == name
    end

    local meta = TabMeta[name]
    if meta then
        Title.Text = meta[2]
        Subtitle.Text =
            name == "Status Board" and "Live Fable status feed"
            or name == "Transfer" and "Egg transfer automation"
            or name == "Pet Teams" and "Automatic pet team assignment"
            or "Fable transfer settings"
    end

    for tabName, button in pairs(TabButtons) do
        local active = tabName == name

        button.BackgroundColor3 = active
            and Color3.fromRGB(48, 31, 62)
            or Color3.fromRGB(15, 13, 22)

        local icon = button:FindFirstChild("Icon")
        local label = button:FindFirstChild("Label")

        if icon then
            icon.TextColor3 = active
                and Color3.fromRGB(178, 105, 248)
                or Color3.fromRGB(105, 96, 120)
        end

        if label then
            label.TextColor3 = active
                and Color3.fromRGB(238, 224, 255)
                or Color3.fromRGB(145, 136, 160)
        end
    end
end

for name, button in pairs(TabButtons) do
    button.Activated:Connect(function()
        showPage(name)
    end)
end

-- Drag support.
dragging = false
dragStart = nil
startPos = nil

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
    if getgenv and getgenv().FABLE_TRANSFER_V15_STOP then
        pcall(getgenv().FABLE_TRANSFER_V15_STOP)
    elseif ScreenGui and ScreenGui.Parent then
        ScreenGui:Destroy()
    end
end)

function petNameFromUUID(uuid)
    local inventory = getPetInventory(getData())
    local entry = inventory and inventory[uuid]
    if entry then
        local level = entry.PetData and tonumber(entry.PetData.Level) or 0
        return string.format("%s Lv.%d", tostring(entry.PetType or "Unknown"), level)
    end
    return "Missing"
end

updateTeamPage = function()
    if State.autoAssignTeamsEnabled then
        pcall(refreshAutoAssignedTeams)
    end

    local data = getData()

    local reductionLive = getLiveSelectedTeam(
        State.reductionTeam,
        buildReductionTeam,
        data
    )

    local koiLive = getLiveSelectedTeam(
        State.koiTeam,
        buildKoiTeam,
        data
    )

    teamStatusLabel.Text = string.format(
        "Reduction %d/8 • Koi %d/8 • Active: %s",
        math.min(#reductionLive, CONFIG.TEAM_SLOTS),
        math.min(#koiLive, CONFIG.TEAM_SLOTS),
        State.currentGardenTeamName or "None"
    )

    updateCompactSelectedRows(
        reductionRows,
        reductionLiveTitle,
        reductionLive,
        buildReductionTeam,
        data
    )

    updateCompactSelectedRows(
        koiRows,
        koiLiveTitle,
        koiLive,
        buildKoiTeam,
        data
    )

    if transferTeamLabel and State.currentGardenTeamName then
        transferTeamLabel[2].Text = State.currentGardenTeamName
    end
end

function updateUI()
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

    local currentData = getData()
    updateTeamPage()
    pcall(updateStatusBoard)
end

showPage("Status Board")
updateUI()

Threads.teamLiveUI = task.spawn(function()
    while not State.shuttingDown do
        task.wait(0.25)

        if ScreenGui
            and ScreenGui.Parent
            and Main.Visible
        then
            pcall(updateTeamPage)
        end
    end
end)

---------------------------------------------------------------------
-- SHUTDOWN / CLEANUP
---------------------------------------------------------------------

function cleanup()
    State.shuttingDown = true
    State.enabled = false
    State.antiIdleEnabled = false
    State.antiKickEnabled = false

    if getgenv and getgenv().__FABLE_V6_ANTIKICK_CONTROLLER then
        getgenv().__FABLE_V6_ANTIKICK_CONTROLLER.enabled = false
    end

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

    destroyPlayerStatsGui()
    destroyActivePetsGui()
    State.cooldownPets = {}
    State.activePetsCacheUI = {}

    if FloatingToggle and FloatingToggle.Parent then
        pcall(function()
            FloatingToggle:Destroy()
        end)
    end

    if ScreenGui and ScreenGui.Parent then
        pcall(function()
            ScreenGui:Destroy()
        end)
    end

    if getgenv then
        getgenv().FABLE_TRANSFER_V15 = nil
    end
end

-- Expose a cleanup hook for manual unload/re-execution.
if getgenv then
    getgenv().FABLE_TRANSFER_V15_STOP = cleanup
end

---------------------------------------------------------------------
-- MAIN CONTINUOUS TRANSFER LOOP
---------------------------------------------------------------------

Threads.main = task.spawn(function()
    while not State.shuttingDown do
        if not State.enabled then
            State.hatching = false
            State.cycleBusy = false
            task.wait(0.15)
            continue
        end

        if State.tradeBusy then
            State.hatching = false
            task.wait(0.1)
            continue
        end

        State.cycleBusy = true

        -- =========================================================
        -- V52 CYCLE PHASE 1: FILL THE GARDEN FIRST.
        -- This is the missing first step from V14. If the garden is
        -- empty, we must create the selected Night Eggs before we
        -- can wait for them to become ready.
        -- =========================================================
        State.hatching = false
        State.lastStatus = "🥚 Filling Garden to MAX..."

        local farmMax = tonumber(CONFIG.MAX_EGG_TARGET) or 0
        if farmMax <= 0 then
            farmMax = tonumber(getMaxEggCapacity(getData())) or 0
        end

        local farmBefore = getFarmEggCount()
        local placementOK = false

        if farmMax <= 0 or farmBefore < farmMax then
            placementOK = pcall(function()
                return placeNightEggsToMax()
            end)
        else
            placementOK = true
            State.lastStatus = "✅ Garden already full."
        end

        if not State.enabled or State.tradeBusy then
            State.cycleBusy = false
            continue
        end

        local farmAfterPlacement = getFarmEggCount()

        -- If the garden was empty and no egg was placed, do not sit for
        -- five minutes waiting for a ready egg that cannot exist.
        if farmBefore == 0 and farmAfterPlacement == 0 then
            State.lastStatus = "🔴 No Night Eggs placed."
            State.cycleBusy = false
            task.wait(0.75)
            continue
        end

        -- =========================================================
        -- V52 CYCLE PHASE 2: REDUCTION TEAM + WAIT FOR READY EGGS.
        -- =========================================================
        local isReadyHatch = (#getReadyNightEggs() > 0)

        if not isReadyHatch then
            local reductionOK = false

            pcall(function()
                reductionOK = ensureReductionTeam()
            end)

            if reductionOK then
                State.lastStatus = "🔄 Egg Reduction team active."
            else
                State.lastStatus = "⚠️ Reduction pets missing."
            end
        end

        local hatchWaitStart = os.clock()
        local hatchTimeout = 5 * 60

        while State.enabled
            and not State.tradeBusy
            and #getReadyNightEggs() == 0
        do
            -- While waiting, keep the farm topped up. This preserves the
            -- "always max placement" behavior instead of waiting with holes.
            if CONFIG.FAST_PLACEMENT then
                pcall(placeNightEggsToMax)
            end

            task.wait(0.5 + GetSafePing())

            if os.clock() - hatchWaitStart >= hatchTimeout then
                State.lastStatus = "♻️ Hatch wait timed out; restarting phase."
                break
            end

            State.lastStatus = "⏳ Waiting for Night Eggs to finish..."
        end

        if not State.enabled or State.tradeBusy then
            State.cycleBusy = false
            continue
        end

        -- =========================================================
        -- V52 CYCLE PHASE 3: KOI/RUBY TEAM + HATCH.
        -- =========================================================
        local readyCount = #getReadyNightEggs()

        if readyCount > 0 then
            State.hatching = true

            local koiOK = false

            pcall(function()
                koiOK = ensureKoiTeam()
            end)

            if not koiOK then
                State.hatching = false
                State.lastStatus = "⚠️ Koi/Ruby team missing."
                State.cycleBusy = false
                task.wait(0.5 + GetSafePing())
                continue
            end

            State.lastStatus = "⏳ Waiting for hatch buffs..."

            -- Same timing already used by the verified V52 transfer core.
            task.wait(
                GetFastHatchMode()
                    and (GetUltraMode() and (0.5 + GetSafePing())
                        or (2.5 + GetSafePing()))
                    or (4 + GetSafePing())
            )

            if State.tradeBusy or not State.enabled then
                State.hatching = false
                State.cycleBusy = false
                continue
            end

            -- Hatch every ready Night Egg.
            local hatched = hatchReadyNightEggs()

            -- The gift watcher is intentionally separate from the hatch
            -- phase; run the direct post-hatch gift pass as V52 did.
            if hatched > 0 and State.autoGiftEnabled then
                pcall(fastGiftAllNightEggPets)
            end

            State.hatching = false

            -- =====================================================
            -- V52 CYCLE PHASE 4: REFILL IMMEDIATELY AFTER HATCH.
            -- =====================================================
            if State.enabled
                and not State.tradeBusy
                and CONFIG.FAST_PLACEMENT
            then
                State.lastStatus = "🥚 Refilling Garden to MAX..."
                pcall(placeNightEggsToMax)
            end
        else
            State.hatching = false
        end

        -- Auto Pet Slot stays a separate helper.
        if State.autoPetSlotEnabled and not State.autoSlotBusy then
            pcall(startAutoPetSlot)
        end

        State.cycleBusy = false

        -- Match the existing V52 fast/non-fast cadence.
        if GetFastHatchMode() then
            task.wait(0.5 + GetSafePing())
        else
            task.wait(1.5 + GetSafePing())
        end
    end

    State.cycleBusy = false
    State.lastStatus = "Transfer stopped."
end)

Threads.tradeWarningBypass = task.spawn(function()
    while not State.shuttingDown do
        forceBypassTradeWarning()
        task.wait(2)
    end
end)

Threads.ui = task.spawn(function()
    while not State.shuttingDown do
        updateUI()
        task.wait(0.1)
    end
end)

pcall(refreshAutoAssignedTeams)
State.lastStatus = "Auto Hatch is OFF."
statusPush(State.lastStatus)
updateUI()
print("[FABLE TRANSFER V15] Loaded — Auto Hatch OFF. V52 status board/UI/trade mechanics copied; anti-idle enabled; Rapid Gift locked to mysto_sailor; no pet selling.")
