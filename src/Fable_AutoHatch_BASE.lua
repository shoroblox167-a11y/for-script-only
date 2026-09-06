-- FABLE • UI BASE TEST
-- ============================================================
-- Uses the exact supplied Exo UI source (exoui(3).lua matches the
-- 9kkinc-sudo/ui_lib source used here).
-- This step intentionally tests ONLY the UI so we can verify the
-- window opens before attaching AutoHatch again.
--
-- UI title: Fable
-- No AutoHatch logic is changed here.
-- ============================================================

repeat task.wait() until game:IsLoaded()

local ENV = (type(getgenv) == "function" and getgenv()) or _G
local UI_URL = "https://raw.githubusercontent.com/9kkinc-sudo/ui_lib/main/source.lua"

-- Remove a previously loaded UI instance so re-execution always gets a
-- clean library instead of reusing a stale/destroyed Library table.
if type(ENV.Library) == "table" and type(ENV.Library.Unload) == "function" then
    pcall(function()
        ENV.Library:Unload()
    end)
end
ENV.Library = nil

local source = game:HttpGet(UI_URL)
local loader, err = loadstring(source)
if not loader then
    error(err or "Exo UI source failed to compile", 2)
end

local Library = loader()
if type(Library) ~= "table" or type(Library.CreateWindow) ~= "function" then
    error("Exo UI library did not return a valid Library", 2)
end

ENV.Library = Library

local Window = Library:CreateWindow({
    Title = "Fable",
    Footer = "Fable",
    AutoShow = true,
    Center = true,
    Resizable = true,
    Size = UDim2.fromOffset(720, 600),
    SearchbarSize = UDim2.fromScale(1, 1),
    CornerRadius = 4,
    NotifySide = "Right",
    Font = Enum.Font.Code,
    ToggleKeybind = Enum.KeyCode.RightControl,
    MobileButtonsSide = "Left",
})

local Home = Window:AddTab({
    Name = "Home",
    Description = "Fable UI base test.",
})

local Left = Home:AddLeftGroupbox("Fable")
Left:AddLabel({
    Text = "Fable UI loaded successfully.",
    DoesWrap = true,
})

print("[FABLE] UI BASE TEST loaded.")
print("[FABLE] Exact Exo UI source • title: Fable")
print("[FABLE] AutoHatch logic is intentionally not loaded in this UI test.")
