-- FABLE • SIMPLE 4-TEAM BATCH CYCLE SECURITY v3
-- =================================================
--
-- FIXED:
--   • Inventory picker is fully implemented.
--   • Four teams are separate tabs.
--   • Pets are selected from the REAL PetInventory.Data records.
--   • Whole team is dispatched together for equip/unequip.
--   • Old garden is cleared before new team is equipped.
--   • Garden UUID equality is the security gate.
--   • Cycle cannot advance unless the intended team is actually in garden.
--   • Compact + draggable + mobile/touch friendly.
--
-- CYCLE:
--   REDUCTION → HATCH → BRONTO → SELL → REDUCTION → ...
--
-- This test does NOT hatch or sell.

repeat task.wait() until game:IsLoaded()

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local LP = Players.LocalPlayer
if not LP then return end

local PlayerGui = LP:WaitForChild("PlayerGui")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local PetServices = Modules:WaitForChild("PetServices")

local function requireSafe(module)
    local ok, value = pcall(require, module)
    if ok then return value end
    return nil
end

local DataService = requireSafe(Modules:WaitForChild("DataService"))
local PetsService = requireSafe(PetServices:WaitForChild("PetsService"))
local ActivePetsService = requireSafe(PetServices:WaitForChild("ActivePetsService"))

if not DataService or not PetsService or not ActivePetsService then
    warn("[FABLE TEAM] Missing verified service module.")
    return
end

-- ============================================================
-- CONFIG
-- ============================================================

local TEAM_CYCLE_SECONDS = 0.25
local POLL_INTERVAL = 0.05
local VERIFY_TIMEOUT = 5
local MAX_TEAM_SIZE = 8

local TEAM_ORDER = {
    "Reduction",
    "Hatch",
    "Bronto",
    "Sell",
}

local TEAM_NAME = {
    Reduction = "REDUCTION",
    Hatch = "HATCH",
    Bronto = "BRONTO",
    Sell = "SELL",
}

-- ============================================================
-- STATE
-- ============================================================

local State = {
    Running = false,
    Busy = false,
    Destroyed = false,

    ActiveTeam = "Reduction",
    CycleIndex = 1,

    Teams = {
        Reduction = {},
        Hatch = {},
        Bronto = {},
        Sell = {},
    },

    Inventory = {},
}

-- Forward refs for UI/refresh functions.
local Main
local Header
local Search
local InventoryList
local SelectedList
local SelectedTitle
local RoleLabel
local Status
local Security
local Checks
local StartButton
local VerifyButton

local RoleButtons = {}

-- ============================================================
-- DATA
-- ============================================================

local function getData()
    local ok, data = pcall(function()
        return DataService:GetData()
    end)

    return ok and type(data) == "table" and data or nil
end

local function getInventoryRaw()
    local data = getData()
    local petsData = data and data.PetsData
    local petInventory = petsData and petsData.PetInventory
    local stored = petInventory and petInventory.Data

    return type(stored) == "table" and stored or {}
end

local function rebuildInventory()
    local result = {}

    for uuid, record in pairs(getInventoryRaw()) do
        if type(record) == "table"
            and record.PetType ~= nil
        then
            local petData =
                type(record.PetData) == "table"
                and record.PetData
                or {}

            result[#result + 1] = {
                UUID = tostring(uuid),
                PetType = tostring(record.PetType),
                Level = tonumber(petData.Level) or 1,
                BaseWeight = tonumber(petData.BaseWeight),
            }
        end
    end

    table.sort(result, function(a, b)
        if a.PetType ~= b.PetType then
            return a.PetType < b.PetType
        end
        return a.UUID < b.UUID
    end)

    State.Inventory = result
    return result
end

local function findInventoryPet(uuid)
    uuid = tostring(uuid)

    for _, pet in ipairs(State.Inventory) do
        if pet.UUID == uuid then
            return pet
        end
    end

    rebuildInventory()

    for _, pet in ipairs(State.Inventory) do
        if pet.UUID == uuid then
            return pet
        end
    end

    return nil
end

local function inventoryHas(uuid)
    return findInventoryPet(uuid) ~= nil
end

local function getPetsDataSet()
    local result = {}

    local data = getData()
    local petsData = data and data.PetsData

    if petsData and type(petsData.EquippedPets) == "table" then
        for _, uuid in ipairs(petsData.EquippedPets) do
            result[tostring(uuid)] = true
        end
    end

    return result
end

local function getGardenSet()
    local result = {}

    local ok, data = pcall(function()
        return ActivePetsService:GetPlayerDatastorePetData(LP.Name)
    end)

    if ok
        and type(data) == "table"
        and type(data.EquippedPets) == "table"
    then
        for _, uuid in ipairs(data.EquippedPets) do
            result[tostring(uuid)] = true
        end
    end

    return result
end

local function setCount(set)
    local n = 0
    for _ in pairs(set) do
        n += 1
    end
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

local function desiredSet(team)
    local result = {}

    for _, pet in ipairs(State.Teams[team]) do
        result[pet.UUID] = true
    end

    return result
end

local function missing(expected, actual)
    local out = {}

    for uuid in pairs(expected) do
        if not actual[uuid] then
            out[#out + 1] = uuid
        end
    end

    table.sort(out)
    return out
end

local function extras(expected, actual)
    local out = {}

    for uuid in pairs(actual) do
        if not expected[uuid] then
            out[#out + 1] = uuid
        end
    end

    table.sort(out)
    return out
end

local function short(list)
    if #list == 0 then return "none" end

    local out = {}

    for i = 1, math.min(3, #list) do
        out[#out + 1] = list[i]:sub(-8)
    end

    if #list > 3 then
        out[#out + 1] = "+" .. tostring(#list - 3)
    end

    return table.concat(out, ",")
end

-- ============================================================
-- STATUS
-- ============================================================

local function setStatus(team, step, reason)
    local text = string.format(
        "%s • %s • %s",
        TEAM_NAME[team] or "IDLE",
        step,
        reason
    )

    if Status then
        Status.Text = text
    end
end

local function setSecurity(text, state)
    if not Security then return end

    Security.Text = "SECURITY • " .. tostring(text)

    if state == true then
        Security.TextColor3 = Color3.fromRGB(105,235,150)
    elseif state == false then
        Security.TextColor3 = Color3.fromRGB(240,88,105)
    else
        Security.TextColor3 = Color3.fromRGB(245,195,85)
    end
end

local function refreshVerification()
    local expected = desiredSet(State.ActiveTeam)
    local garden = getGardenSet()
    local petsData = getPetsDataSet()

    local gardenOK = setsEqual(expected, garden)
    local petsOK = setsEqual(expected, petsData)

    Checks.Text = string.format(
        "GARDEN %s • %d/%d\nDATASYNC %s • %d",
        gardenOK and "OK" or "WAIT",
        setCount(garden),
        setCount(expected),
        petsOK and "OK" or "SYNC",
        setCount(petsData)
    )

    Checks.TextColor3 =
        gardenOK
        and Color3.fromRGB(105,235,150)
        or Color3.fromRGB(240,195,90)

    return gardenOK and petsOK
end

-- ============================================================
-- TEAM EDITING
-- ============================================================

local function rebuildTeamFromSet(team, selected)
    local rebuilt = {}

    for uuid in pairs(selected) do
        local pet = findInventoryPet(uuid)

        if pet then
            rebuilt[#rebuilt + 1] = {
                UUID = pet.UUID,
                PetType = pet.PetType,
            }
        end
    end

    table.sort(rebuilt, function(a,b)
        return a.UUID < b.UUID
    end)

    State.Teams[team] = rebuilt
end

local function toggleUUID(team, uuid)
    uuid = tostring(uuid)

    local selected = desiredSet(team)

    if selected[uuid] then
        selected[uuid] = nil
    else
        if setCount(selected) >= MAX_TEAM_SIZE then
            return false, "Team is full (8)."
        end

        if not inventoryHas(uuid) then
            return false, "Pet is no longer in inventory."
        end

        selected[uuid] = true
    end

    rebuildTeamFromSet(team, selected)
    return true
end

-- ============================================================
-- INVENTORY UI
-- ============================================================

local function refreshRoleTabs()
    for team, ui in pairs(RoleButtons) do
        local active = team == State.ActiveTeam

        ui.Button.BackgroundColor3 =
            active
            and Color3.fromRGB(78,48,122)
            or Color3.fromRGB(28,28,36)

        ui.Count.Text = string.format(
            "%d/%d",
            #State.Teams[team],
            MAX_TEAM_SIZE
        )
    end
end

function refreshSelected()
    if not SelectedList then return end

    for _, child in ipairs(SelectedList:GetChildren()) do
        if child:IsA("TextButton") then
            child:Destroy()
        end
    end

    local team = State.Teams[State.ActiveTeam]

    SelectedTitle.Text = string.format(
        "SELECTED • %s • %d/%d",
        TEAM_NAME[State.ActiveTeam],
        #team,
        MAX_TEAM_SIZE
    )

    for _, pet in ipairs(team) do
        local chip = Instance.new("TextButton")
        chip.Size = UDim2.fromOffset(94,29)
        chip.BackgroundColor3 = Color3.fromRGB(47,33,63)
        chip.BorderSizePixel = 0
        chip.Text =
            pet.PetType
            .. "\n..."
            .. pet.UUID:sub(-8)
        chip.TextColor3 = Color3.fromRGB(242,242,248)
        chip.TextSize = 5
        chip.Font = Enum.Font.GothamSemibold
        chip.AutoButtonColor = false
        chip.Parent = SelectedList

        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0,6)
        c.Parent = chip

        chip.Activated:Connect(function()
            toggleUUID(State.ActiveTeam, pet.UUID)
            refreshRoleTabs()
            refreshSelected()
            refreshInventoryList()
            refreshVerification()
        end)
    end

    SelectedList.CanvasSize = UDim2.fromOffset(
        math.max(1, #team * 98),
        0
    )
end

function refreshInventoryList()
    if not InventoryList then return end

    for _, child in ipairs(InventoryList:GetChildren()) do
        if child:IsA("Frame") then
            child:Destroy()
        end
    end

    rebuildInventory()

    local query = string.lower(Search.Text or "")
    local selected = desiredSet(State.ActiveTeam)

    local rowCount = 0

    for _, pet in ipairs(State.Inventory) do
        local matches =
            query == ""
            or string.find(
                string.lower(pet.PetType),
                query,
                1,
                true
            )
            or string.find(
                string.lower(pet.UUID),
                query,
                1,
                true
            )

        if matches then
            rowCount += 1

            local row = Instance.new("Frame")
            row.Size = UDim2.new(1,-6,0,38)
            row.BackgroundColor3 =
                selected[pet.UUID]
                and Color3.fromRGB(52,37,68)
                or Color3.fromRGB(27,27,34)
            row.BorderSizePixel = 0
            row.Parent = InventoryList

            local rc = Instance.new("UICorner")
            rc.CornerRadius = UDim.new(0,6)
            rc.Parent = row

            local title = Instance.new("TextLabel")
            title.Position = UDim2.fromOffset(7,3)
            title.Size = UDim2.new(1,-96,0,13)
            title.BackgroundTransparency = 1
            title.Text = pet.PetType
            title.TextColor3 = Color3.fromRGB(235,235,242)
            title.TextSize = 6
            title.Font = Enum.Font.GothamSemibold
            title.TextXAlignment = Enum.TextXAlignment.Left
            title.Parent = row

            local info = Instance.new("TextLabel")
            info.Position = UDim2.fromOffset(7,18)
            info.Size = UDim2.new(1,-96,0,11)
            info.BackgroundTransparency = 1
            info.Text =
                "Age "
                .. tostring(pet.Level)
                .. " • ..."
                .. pet.UUID:sub(-8)
            info.TextColor3 = Color3.fromRGB(140,140,155)
            info.TextSize = 5
            info.Font = Enum.Font.Code
            info.TextXAlignment = Enum.TextXAlignment.Left
            info.Parent = row

            local button = Instance.new("TextButton")
            button.Position = UDim2.new(1,-84,0,5)
            button.Size = UDim2.fromOffset(77,28)
            button.BackgroundColor3 =
                selected[pet.UUID]
                and Color3.fromRGB(94,62,133)
                or Color3.fromRGB(39,39,48)
            button.BorderSizePixel = 0
            button.Text =
                selected[pet.UUID]
                and "SELECTED"
                or "SELECT"
            button.TextColor3 = Color3.fromRGB(242,242,248)
            button.TextSize = 5
            button.Font = Enum.Font.GothamBold
            button.AutoButtonColor = false
            button.Parent = row

            local bc = Instance.new("UICorner")
            bc.CornerRadius = UDim.new(0,6)
            bc.Parent = button

            button.Activated:Connect(function()
                local ok, err = toggleUUID(
                    State.ActiveTeam,
                    pet.UUID
                )

                if not ok then
                    setStatus(
                        State.ActiveTeam,
                        "BLOCKED",
                        tostring(err)
                    )
                    return
                end

                refreshRoleTabs()
                refreshSelected()
                refreshInventoryList()
                refreshVerification()
            end)
        end
    end

    InventoryList.CanvasSize = UDim2.fromOffset(
        0,
        math.max(1,rowCount * 41)
    )
end

-- ============================================================
-- BATCH ACTIONS
-- ============================================================

local function dispatchWholeTeam(role, operation)
    local uuids = {}

    if operation == "Equip" then
        for uuid in pairs(desiredSet(role)) do
            uuids[#uuids + 1] = uuid
        end
    else
        local garden = getGardenSet()
        local data = getPetsDataSet()

        for uuid in pairs(garden) do
            uuids[#uuids + 1] = uuid
        end

        for uuid in pairs(data) do
            local already = false

            for _, existing in ipairs(uuids) do
                if existing == uuid then
                    already = true
                    break
                end
            end

            if not already then
                uuids[#uuids + 1] = uuid
            end
        end
    end

    if #uuids == 0 then
        return true
    end

    local failed = 0

    -- IMPORTANT:
    -- All calls are scheduled immediately. There is no per-pet wait.
    for _, uuid in ipairs(uuids) do
        task.spawn(function()
            local ok = pcall(function()
                if operation == "Equip" then
                    PetsService:EquipPet(uuid)
                else
                    PetsService:UnequipPet(uuid)
                end
            end)

            if not ok then
                failed += 1
            end
        end)
    end

    -- Give all spawned calls one scheduler turn.
    task.wait()

    if failed > 0 then
        return false,
            tostring(failed)
            .. " "
            .. operation
            .. " call(s) failed."
    end

    return true
end

local function waitGardenEmpty()
    local started = os.clock()
    local consecutive = 0

    while os.clock() - started <= VERIFY_TIMEOUT do
        local garden = getGardenSet()
        local data = getPetsDataSet()

        if next(garden) == nil and next(data) == nil then
            consecutive += 1

            if consecutive >= 2 then
                return true
            end
        else
            consecutive = 0
        end

        task.wait(POLL_INTERVAL)
    end

    return false
end

local function waitGardenExact(role)
    local wanted = desiredSet(role)
    local started = os.clock()
    local consecutive = 0

    while os.clock() - started <= VERIFY_TIMEOUT do
        local garden = getGardenSet()

        if setsEqual(wanted, garden) then
            consecutive += 1

            if consecutive >= 2 then
                return true
            end
        else
            consecutive = 0

            setStatus(
                role,
                "VERIFY",
                "Missing "
                .. short(missing(wanted,garden))
                .. " • Extra "
                .. short(extras(wanted,garden))
            )
        end

        refreshVerification()
        task.wait(POLL_INTERVAL)
    end

    return false
end

-- ============================================================
-- ONE SIMPLE TRANSITION
-- ============================================================

local function transition(role)
    if State.Busy then
        return false, "Already transitioning."
    end

    local wanted = desiredSet(role)

    if next(wanted) == nil then
        return false,
            TEAM_NAME[role] .. " has no selected pets."
    end

    rebuildInventory()

    for uuid in pairs(wanted) do
        if not inventoryHas(uuid) then
            return false,
                "Missing inventory UUID ..."
                .. uuid:sub(-8)
        end
    end

    State.Busy = true
    State.ActiveTeam = role
    RoleLabel.Text = TEAM_NAME[role]
    refreshRoleTabs()
    refreshSelected()

    -- STEP 1: remove everything currently in the garden.
    setStatus(
        role,
        "1/3 CLEAR",
        "Unequip all current garden pets together"
    )
    setSecurity(
        "CLEARING OLD TEAM",
        nil
    )

    local clearOK, clearError = dispatchWholeTeam(
        role,
        "Unequip"
    )

    if not clearOK then
        State.Busy = false
        setSecurity("CLEAR DISPATCH FAILED", false)
        return false, clearError
    end

    -- Hard empty barrier.
    setStatus(
        role,
        "1/3 EMPTY",
        "Waiting for garden = 0"
    )

    if not waitGardenEmpty() then
        State.Busy = false
        setSecurity("BLOCKED • GARDEN NOT EMPTY", false)
        return false,
            "Old garden team did not fully clear."
    end

    -- STEP 2: equip all target pets together.
    setStatus(
        role,
        "2/3 EQUIP",
        "Equip whole team together"
    )
    setSecurity(
        "EMPTY • EQUIPPING",
        true
    )

    local equipOK, equipError = dispatchWholeTeam(
        role,
        "Equip"
    )

    if not equipOK then
        State.Busy = false
        setSecurity("EQUIP DISPATCH FAILED", false)
        return false, equipError
    end

    task.wait(TEAM_CYCLE_SECONDS)

    -- STEP 3: garden is the security gate.
    setStatus(
        role,
        "3/3 VERIFY",
        "Checking exact garden UUIDs"
    )
    setSecurity(
        "VERIFYING " .. TEAM_NAME[role],
        nil
    )

    local exact = waitGardenExact(role)

    if not exact then
        State.Busy = false
        setSecurity(
            "BLOCKED • WRONG TEAM",
            false
        )

        return false,
            "Garden UUIDs do not exactly match "
            .. TEAM_NAME[role] .. "."
    end

    refreshVerification()

    setSecurity(
        "VERIFIED • " .. TEAM_NAME[role],
        true
    )

    setStatus(
        role,
        "VERIFIED",
        "Exact garden team confirmed"
    )

    State.Busy = false

    return true
end

-- ============================================================
-- CYCLE
-- ============================================================

local function getCycleTeams()
    local enabled = {}

    for _, role in ipairs(TEAM_ORDER) do
        if #State.Teams[role] > 0 then
            enabled[#enabled + 1] = role
        end
    end

    return enabled
end

local function stopCycle(reason)
    State.Running = false
    State.Busy = false

    StartButton.Text = "START CYCLE"
    StartButton.BackgroundColor3 = Color3.fromRGB(38,38,48)

    setSecurity("STOPPED", nil)

    setStatus(
        State.ActiveTeam,
        "STOPPED",
        reason or "User requested stop"
    )
end

local function runCycle()
    while State.Running and not State.Destroyed do
        local cycleTeams = getCycleTeams()

        if #cycleTeams == 0 then
            stopCycle("No team has selected pets.")
            return
        end

        rebuildInventory()

        -- Freeze this pass's team order. UI edits cannot mutate the
        -- currently-running pass.
        local pass = {}
        for index, role in ipairs(cycleTeams) do
            pass[index] = role
        end

        for index, role in ipairs(pass) do
            if not State.Running or State.Destroyed then
                return
            end

            State.ActiveTeam = role
            State.CycleIndex = index

            local ok, err = transition(role)

            if not ok then
                stopCycle(
                    TEAM_NAME[role]
                    .. " • "
                    .. tostring(err)
                )
                return
            end
        end
    end
end

StartButton.Activated:Connect(function()
    if State.Running or State.Busy then
        setStatus(
            State.ActiveTeam,
            "RUNNING",
            "Cycle already active"
        )
        return
    end

    local cycleTeams = getCycleTeams()

    if #cycleTeams == 0 then
        setSecurity("START BLOCKED", false)
        setStatus(
            State.ActiveTeam,
            "BLOCKED",
            "Select at least 1 pet in a team."
        )
        return
    end

    rebuildInventory()

    -- Validate every configured UUID immediately before starting.
    for _, role in ipairs(cycleTeams) do
        for _, pet in ipairs(State.Teams[role]) do
            if not inventoryHas(pet.UUID) then
                setSecurity("START BLOCKED", false)
                setStatus(
                    role,
                    "BLOCKED",
                    "UUID missing ..."
                        .. pet.UUID:sub(-8)
                )
                return
            end
        end
    end

    State.Running = true
    State.CycleIndex = 1

    StartButton.Text = "CYCLE RUNNING"
    StartButton.BackgroundColor3 = Color3.fromRGB(78,48,122)

    setSecurity("STARTING • CLEAR-FIRST", nil)
    setStatus(
        State.ActiveTeam,
        "STARTING",
        "Sequential verified team cycle"
    )

    task.spawn(function()
        local ok, runtimeError = pcall(runCycle)

        if not ok then
            stopCycle(
                "RUNTIME ERROR • "
                .. tostring(runtimeError)
            )
        end
    end)
end)

StopButton.Activated:Connect(function()
    stopCycle("User requested stop.")
end)

ApplyButton.Activated:Connect(function()
    if State.Running then
        setStatus(
            State.ActiveTeam,
            "LOCKED",
            "Stop cycle before Apply"
        )
        return
    end

    local ok, err = transition(State.ActiveTeam)
    refreshVerification()

    if not ok then
        setStatus(
            State.ActiveTeam,
            "STOPPED",
            tostring(err)
        )
    end
end)

VerifyButton.Activated:Connect(function()
    if State.Busy then
        setStatus(
            State.ActiveTeam,
            "LOCKED",
            "Transition in progress"
        )
        return
    end

    local ok = refreshVerification()

    if ok then
        setSecurity(
            "VERIFIED • " .. TEAM_NAME[State.ActiveTeam],
            true
        )

        setStatus(
            State.ActiveTeam,
            "VERIFIED",
            "Exact garden UUID set"
        )
    else
        setSecurity(
            "WAIT • WRONG GARDEN",
            false
        )

        setStatus(
            State.ActiveTeam,
            "VERIFY",
            "Garden does not match target"
        )
    end
end)

Search:GetPropertyChangedSignal("Text"):Connect(
    refreshInventoryList
)

-- ============================================================
-- DRAG WINDOW
-- ============================================================

do
    local dragging = false
    local inputStart
    local startPosition

    Header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch
        then
            dragging = true
            inputStart = input.Position
            startPosition = Main.Position
        end
    end)

    Header.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch
        then
            dragging = false
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end

        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch
        then
            return
        end

        local delta = input.Position - inputStart

        Main.Position = UDim2.new(
            startPosition.X.Scale,
            startPosition.X.Offset + delta.X,
            startPosition.Y.Scale,
            startPosition.Y.Offset + delta.Y
        )
    end)
end

-- ============================================================
-- UI CONSTRUCTION
-- ============================================================

local old = PlayerGui:FindFirstChild(
    "FableSimple4TeamBatchCycleV3"
)

if old then
    old:Destroy()
end

local Gui = Instance.new("ScreenGui")
Gui.Name = "FableSimple4TeamBatchCycleV3"
Gui.ResetOnSpawn = false
Gui.IgnoreGuiInset = true
Gui.DisplayOrder = 2147483647
Gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
Gui.Parent = PlayerGui

Main = Instance.new("Frame")
Main.Size = UDim2.fromOffset(365, 390)
Main.Position = UDim2.new(0.5,-182,0.5,-195)
Main.BackgroundColor3 = Color3.fromRGB(10,10,15)
Main.BorderSizePixel = 0
Main.Active = true
Main.Parent = Gui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0,10)
mainCorner.Parent = Main

local mainStroke = Instance.new("UIStroke")
mainStroke.Color = Color3.fromRGB(62,62,78)
mainStroke.Parent = Main

Header = Instance.new("Frame")
Header.Size = UDim2.new(1,0,0,41)
Header.BackgroundColor3 = Color3.fromRGB(16,16,22)
Header.BorderSizePixel = 0
Header.Active = true
Header.Parent = Main

local title = Instance.new("TextLabel")
title.Position = UDim2.fromOffset(9,5)
title.Size = UDim2.new(1,-18,0,16)
title.BackgroundTransparency = 1
title.Text = "FABLE • BATCH TEAM CYCLE"
title.TextColor3 = Color3.fromRGB(242,242,248)
title.TextSize = 9
title.Font = Enum.Font.GothamBold
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = Header

local sub = Instance.new("TextLabel")
sub.Position = UDim2.fromOffset(9,22)
sub.Size = UDim2.new(1,-18,0,11)
sub.BackgroundTransparency = 1
sub.Text = "CLEAR ALL → EMPTY → EQUIP ALL → VERIFY"
sub.TextColor3 = Color3.fromRGB(145,145,160)
sub.TextSize = 5
sub.Font = Enum.Font.Code
sub.TextXAlignment = Enum.TextXAlignment.Left
sub.Parent = Header

local Tabs = Instance.new("Frame")
Tabs.Position = UDim2.fromOffset(7,46)
Tabs.Size = UDim2.new(1,-14,0,29)
Tabs.BackgroundTransparency = 1
Tabs.Parent = Main

for index, role in ipairs(TEAM_ORDER) do
    local button = Instance.new("TextButton")
    button.Position = UDim2.new((index-1)*0.25,2,0,0)
    button.Size = UDim2.new(0.25,-4,1,0)
    button.BackgroundColor3 =
        role == State.ActiveTeam
        and Color3.fromRGB(78,48,122)
        or Color3.fromRGB(28,28,36)
    button.BorderSizePixel = 0
    button.Text = TEAM_NAME[role]
    button.TextColor3 = Color3.fromRGB(242,242,248)
    button.TextSize = 5
    button.Font = Enum.Font.GothamBold
    button.AutoButtonColor = false
    button.Parent = Tabs

    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0,6)
    c.Parent = button

    local countText = Instance.new("TextLabel")
    countText.Position = UDim2.new(1,-34,0,7)
    countText.Size = UDim2.fromOffset(30,13)
    countText.BackgroundTransparency = 1
    countText.Text = "0/8"
    countText.TextColor3 = Color3.fromRGB(155,155,168)
    countText.TextSize = 5
    countText.Font = Enum.Font.Code
    countText.TextXAlignment = Enum.TextXAlignment.Right
    countText.Parent = button

    RoleButtons[role] = {
        Button = button,
        Count = countText,
    }

    button.Activated:Connect(function()
        if State.Running then
            setStatus(
                State.ActiveTeam,
                "LOCKED",
                "Stop cycle before editing"
            )
            return
        end

        State.ActiveTeam = role
        RoleLabel.Text = TEAM_NAME[role]

        refreshRoleTabs()
        refreshSelected()
        refreshInventoryList()
        refreshVerification()
    end)
end

RoleLabel = Instance.new("TextLabel")
RoleLabel.Position = UDim2.fromOffset(8,78)
RoleLabel.Size = UDim2.new(1,-16,0,13)
RoleLabel.BackgroundTransparency = 1
RoleLabel.Text = TEAM_NAME[State.ActiveTeam]
RoleLabel.TextColor3 = Color3.fromRGB(180,180,194)
RoleLabel.TextSize = 6
RoleLabel.Font = Enum.Font.Code
RoleLabel.TextXAlignment = Enum.TextXAlignment.Left
RoleLabel.Parent = Main

Search = Instance.new("TextBox")
Search.Position = UDim2.fromOffset(8,95)
Search.Size = UDim2.new(1,-16,0,26)
Search.BackgroundColor3 = Color3.fromRGB(24,24,32)
Search.BorderSizePixel = 0
Search.Text = ""
Search.PlaceholderText = "Search REAL PET INVENTORY / UUID..."
Search.PlaceholderColor3 = Color3.fromRGB(105,105,118)
Search.TextColor3 = Color3.fromRGB(242,242,248)
Search.TextSize = 7
Search.Font = Enum.Font.Gotham
Search.ClearTextOnFocus = false
Search.Parent = Main

local searchCorner = Instance.new("UICorner")
searchCorner.CornerRadius = UDim.new(0,6)
searchCorner.Parent = Search

InventoryList = Instance.new("ScrollingFrame")
InventoryList.Position = UDim2.fromOffset(8,126)
InventoryList.Size = UDim2.new(1,-16,0,126)
InventoryList.BackgroundColor3 = Color3.fromRGB(17,17,22)
InventoryList.BorderSizePixel = 0
InventoryList.ScrollBarThickness = 3
InventoryList.CanvasSize = UDim2.fromOffset(0,0)
InventoryList.Parent = Main

local invCorner = Instance.new("UICorner")
invCorner.CornerRadius = UDim.new(0,7)
invCorner.Parent = InventoryList

local invLayout = Instance.new("UIListLayout")
invLayout.Padding = UDim.new(0,3)
invLayout.Parent = InventoryList

SelectedList = Instance.new("ScrollingFrame")
SelectedList.Position = UDim2.fromOffset(8,254)
SelectedList.Size = UDim2.new(1,-16,0,41)
SelectedList.BackgroundColor3 = Color3.fromRGB(18,18,24)
SelectedList.BorderSizePixel = 0
SelectedList.ScrollBarThickness = 2
SelectedList.CanvasSize = UDim2.fromOffset(0,0)
SelectedList.Parent = Main

local selectedCorner = Instance.new("UICorner")
selectedCorner.CornerRadius = UDim.new(0,7)
selectedCorner.Parent = SelectedList

SelectedTitle = Instance.new("TextLabel")
SelectedTitle.Position = UDim2.fromOffset(8,-17)
SelectedTitle.Size = UDim2.new(1,-16,0,14)
SelectedTitle.BackgroundTransparency = 1
SelectedTitle.Text = "SELECTED"
SelectedTitle.TextColor3 = Color3.fromRGB(205,205,218)
SelectedTitle.TextSize = 5
SelectedTitle.Font = Enum.Font.GothamBold
SelectedTitle.TextXAlignment = Enum.TextXAlignment.Left
SelectedTitle.Parent = SelectedList

local selectedLayout = Instance.new("UIListLayout")
selectedLayout.FillDirection = Enum.FillDirection.Horizontal
selectedLayout.Padding = UDim.new(0,3)
selectedLayout.Parent = SelectedList

local Actions = Instance.new("Frame")
Actions.Position = UDim2.fromOffset(8,304)
Actions.Size = UDim2.new(1,-16,0,55)
Actions.BackgroundColor3 = Color3.fromRGB(18,18,24)
Actions.BorderSizePixel = 0
Actions.Parent = Main

local actionCorner = Instance.new("UICorner")
actionCorner.CornerRadius = UDim.new(0,7)
actionCorner.Parent = Actions

ApplyButton = Instance.new("TextButton")
ApplyButton.Position = UDim2.fromOffset(6,6)
ApplyButton.Size = UDim2.fromOffset(70,25)
ApplyButton.BackgroundColor3 = Color3.fromRGB(78,48,122)
ApplyButton.BorderSizePixel = 0
ApplyButton.Text = "APPLY"
ApplyButton.TextColor3 = Color3.fromRGB(242,242,248)
ApplyButton.TextSize = 6
ApplyButton.Font = Enum.Font.GothamBold
ApplyButton.AutoButtonColor = false
ApplyButton.Parent = Actions

local applyCorner = Instance.new("UICorner")
applyCorner.CornerRadius = UDim.new(0,6)
applyCorner.Parent = ApplyButton

StartButton = Instance.new("TextButton")
StartButton.Position = UDim2.fromOffset(82,6)
StartButton.Size = UDim2.fromOffset(103,25)
StartButton.BackgroundColor3 = Color3.fromRGB(38,38,48)
StartButton.BorderSizePixel = 0
StartButton.Text = "START CYCLE"
StartButton.TextColor3 = Color3.fromRGB(242,242,248)
StartButton.TextSize = 6
StartButton.Font = Enum.Font.GothamBold
StartButton.AutoButtonColor = false
StartButton.Parent = Actions

local startCorner = Instance.new("UICorner")
startCorner.CornerRadius = UDim.new(0,6)
startCorner.Parent = StartButton

local StopButton = Instance.new("TextButton")
StopButton.Position = UDim2.fromOffset(191,6)
StopButton.Size = UDim2.fromOffset(55,25)
StopButton.BackgroundColor3 = Color3.fromRGB(55,38,44)
StopButton.BorderSizePixel = 0
StopButton.Text = "STOP"
StopButton.TextColor3 = Color3.fromRGB(242,242,248)
StopButton.TextSize = 6
StopButton.Font = Enum.Font.GothamBold
StopButton.AutoButtonColor = false
StopButton.Parent = Actions

local stopCorner = Instance.new("UICorner")
stopCorner.CornerRadius = UDim.new(0,6)
stopCorner.Parent = StopButton

VerifyButton = Instance.new("TextButton")
VerifyButton.Position = UDim2.fromOffset(252,6)
VerifyButton.Size = UDim2.fromOffset(95,25)
VerifyButton.BackgroundColor3 = Color3.fromRGB(38,38,48)
VerifyButton.BorderSizePixel = 0
VerifyButton.Text = "VERIFY GARDEN"
VerifyButton.TextColor3 = Color3.fromRGB(242,242,248)
VerifyButton.TextSize = 5
VerifyButton.Font = Enum.Font.GothamBold
VerifyButton.AutoButtonColor = false
VerifyButton.Parent = Actions

local verifyCorner = Instance.new("UICorner")
verifyCorner.CornerRadius = UDim.new(0,6)
verifyCorner.Parent = VerifyButton

Security = Instance.new("TextLabel")
Security.Position = UDim2.fromOffset(6,35)
Security.Size = UDim2.new(0.47,0,0,13)
Security.BackgroundTransparency = 1
Security.Text = "SECURITY • READY"
Security.TextColor3 = Color3.fromRGB(245,195,85)
Security.TextSize = 5
Security.Font = Enum.Font.GothamBold
Security.TextXAlignment = Enum.TextXAlignment.Left
Security.Parent = Actions

Checks = Instance.new("TextLabel")
Checks.Position = UDim2.new(0.47,0,0,33)
Checks.Size = UDim2.new(0.53,-6,0,19)
Checks.BackgroundTransparency = 1
Checks.Text = "GARDEN -- • 0/0\nDATASYNC -- • 0"
Checks.TextColor3 = Color3.fromRGB(160,160,174)
Checks.TextSize = 5
Checks.Font = Enum.Font.Code
Checks.TextXAlignment = Enum.TextXAlignment.Right
Checks.Parent = Actions

Status = Instance.new("TextLabel")
Status.Position = UDim2.fromOffset(8,366)
Status.Size = UDim2.new(1,-16,0,12)
Status.BackgroundTransparency = 1
Status.Text = "STATUS • Ready"
Status.TextColor3 = Color3.fromRGB(145,145,160)
Status.TextSize = 5
Status.Font = Enum.Font.Code
Status.TextXAlignment = Enum.TextXAlignment.Left
Status.Parent = Main

-- ============================================================
-- STARTUP
-- ============================================================

rebuildInventory()
refreshRoleTabs()
refreshSelected()
refreshInventoryList()
refreshVerification()

setSecurity("READY • SELECT TEAM", nil)
setStatus(
    State.ActiveTeam,
    "READY",
    "Pets from inventory are selectable"
)

print("======================================================")
print(" FABLE • SIMPLE 4-TEAM BATCH CYCLE SECURITY v3")
print("======================================================")
print("Inventory source:", "DataService:GetData().PetsData.PetInventory.Data")
print("Cycle:", "Reduction → Hatch → Bronto → Sell")
print("Batch actions:", "concurrent EquipPet / UnequipPet dispatch")
print("Cycle wait:", TEAM_CYCLE_SECONDS)
print("Security:", "garden UUID set must exactly match target before advance")
print("======================================================")
