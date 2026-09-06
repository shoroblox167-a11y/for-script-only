-- FABLE • SIMPLE LIVE STATS
-- Matches the simple top-left stat style from the reference.
-- No panels, no passive parser, no extra UI.
-- Reads the game's live Player attributes directly.
-- Automatically refreshes whenever an attribute changes + every 0.25s.

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    return
end

local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local GUI_NAME = "FableSimpleLiveStats"

local old = PlayerGui:FindFirstChild(GUI_NAME)
if old then
    old:Destroy()
end

local Gui = Instance.new("ScreenGui")
Gui.Name = GUI_NAME
Gui.ResetOnSpawn = false
Gui.IgnoreGuiInset = true
Gui.DisplayOrder = 999999
Gui.Parent = PlayerGui

local Stats = Instance.new("TextLabel")
Stats.Name = "Stats"
Stats.Position = UDim2.fromOffset(8, 128)
Stats.Size = UDim2.fromOffset(430, 170)
Stats.BackgroundTransparency = 1
Stats.BorderSizePixel = 0
Stats.Font = Enum.Font.GothamBold
Stats.TextSize = 13
Stats.TextColor3 = Color3.fromRGB(255, 255, 255)
Stats.TextStrokeTransparency = 0
Stats.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
Stats.TextXAlignment = Enum.TextXAlignment.Left
Stats.TextYAlignment = Enum.TextYAlignment.Top
Stats.TextWrapped = false
Stats.RichText = false
Stats.Parent = Gui

local function numberAttribute(name)
    local value = LocalPlayer:GetAttribute(name)

    if type(value) == "number" then
        return value
    end

    return 0
end

local function formatNumber(name)
    return string.format(
        "%.2f",
        numberAttribute(name)
    )
end

local startedAt = os.clock()

local function getSessionTime()
    local attribute = LocalPlayer:GetAttribute("SessionTime")

    if type(attribute) == "number" then
        return math.floor(attribute)
    end

    return math.floor(os.clock() - startedAt)
end

local function refresh()
    if not Gui.Parent then
        return
    end

    Stats.Text = table.concat({
        "PetSellEggRefundChance: " .. formatNumber("PetSellEggRefundChance"),
        "PetPassiveBonus: " .. formatNumber("PetPassiveBonus"),
        "PetEggHatchAgeBonus: " .. formatNumber("PetEggHatchAgeBonus"),
        "SessionTime: " .. tostring(getSessionTime()) .. "s",
        "SellSilverFruitRewardChance: " .. formatNumber("SellSilverFruitRewardChance"),
        "EggRecoveryChance: " .. formatNumber("EggRecoveryChance"),
        "Grow_Amount: " .. formatNumber("Grow_Amount"),
        "PetEggHatchSizeBonus: " .. formatNumber("PetEggHatchSizeBonus"),
    }, "\n")
end

-- Exact live refresh when any of the tracked stats changes.
local trackedAttributes = {
    "PetSellEggRefundChance",
    "PetPassiveBonus",
    "PetEggHatchAgeBonus",
    "SessionTime",
    "SellSilverFruitRewardChance",
    "EggRecoveryChance",
    "Grow_Amount",
    "PetEggHatchSizeBonus",
}

for _, attributeName in ipairs(trackedAttributes) do
    LocalPlayer:GetAttributeChangedSignal(attributeName):Connect(refresh)
end

-- Fallback refresh catches state changes that are not signaled the way
-- we expect, while staying extremely lightweight.
task.spawn(function()
    while Gui.Parent do
        refresh()
        task.wait(0.25)
    end
end)

refresh()
