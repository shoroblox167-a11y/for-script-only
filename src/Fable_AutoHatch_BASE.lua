-- FABLE • CANONICAL AUTOHATCH BASE
-- Uses the exact Exo UI source vendored in this repository as Fable_ExoUI.lua.
-- Only project title is changed to: Fable.

repeat task.wait() until game:IsLoaded()

local ENV = (type(getgenv) == "function" and getgenv()) or _G
local BASE = "https://raw.githubusercontent.com/shoroblox167-a11y/for-script-only/main/src/"
local EXO_UI_URL = BASE .. "Fable_ExoUI.lua"

-- Stop/unload the previous Fable instance on re-execution.
pcall(function()
    if type(ENV.FableAutoHatch) == "table" and type(ENV.FableAutoHatch.Stop) == "function" then
        ENV.FableAutoHatch.Stop()
    end
end)

pcall(function()
    if type(ENV.Library) == "table" and type(ENV.Library.Unload) == "function" then
        ENV.Library:Unload()
    end
end)

-- Load the exact Exo library vendored in this repository.
local source = game:HttpGet(EXO_UI_URL)
local factory, loadErr = loadstring(source)
if not factory then
    error(loadErr or "Failed to load Fable_ExoUI.lua", 2)
end

local Library = factory()
if type(Library) ~= "table" or type(Library.CreateWindow) ~= "function" then
    error("Fable_ExoUI.lua loaded but CreateWindow is unavailable", 2)
end

ENV.Library = Library

-- Create the real Exo window FIRST. The rest of AutoHatch reuses this exact window.
local Window = Library:CreateWindow({
    Title = "Fable",
    Footer = "Fable",
    Size = UDim2.fromOffset(720, 600),
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

ENV.FableAutoHatchWindow = Window

-- Fable_AutoHatch_Cycle_FINAL.lua already calls CreateWindow.
-- Return our already-created Exo window so it does not create a second UI.
local OriginalCreateWindow = Library.CreateWindow
Library.CreateWindow = function(self, info)
    return ENV.FableAutoHatchWindow or OriginalCreateWindow(self, info)
end

local function run(path)
    local body = game:HttpGet(BASE .. path)
    local fn, err = loadstring(body)
    if not fn then
        error(err or ("Failed to load " .. path), 2)
    end
    return fn()
end

-- Existing verified AutoHatch implementation; hatch logic is not rewritten here.
run("Fable_AutoHatch_Cycle_FINAL.lua")
run("Fable_Simple_Live_Stats.lua")

print("[FABLE] Vendored Exo UI loaded from Fable_ExoUI.lua.")
print("[FABLE] Window title: Fable")
