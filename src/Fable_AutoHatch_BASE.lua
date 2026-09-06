-- FABLE • CANONICAL AUTOHATCH BASE
-- Uses the exact Exo UI source supplied as exoui(3).lua.
-- Only project title is changed to: Fable.

repeat task.wait() until game:IsLoaded()

local ENV = (type(getgenv) == "function" and getgenv()) or _G
local BASE = "https://raw.githubusercontent.com/shoroblox167-a11y/for-script-only/main/src/"
local EXO_UI_URL = "https://raw.githubusercontent.com/9kkinc-sudo/ui_lib/main/source.lua"

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

-- Load the exact Exo library used by the supplied exoui(3).lua.
local source = game:HttpGet(EXO_UI_URL)
local factory, loadErr = loadstring(source)
if not factory then
    error(loadErr or "Failed to load Exo UI", 2)
end

local Library = factory()
if type(Library) ~= "table" or type(Library.CreateWindow) ~= "function" then
    error("Exo UI library loaded but CreateWindow is unavailable", 2)
end

ENV.Library = Library

-- Create the real Exo window FIRST. This means the UI itself can open even
-- if a later AutoHatch dependency has an issue.
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

-- Fable_AutoHatch_Cycle_FINAL.lua already contains its own CreateWindow call.
-- Reuse this exact window instead of creating another one.
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

-- Existing verified AutoHatch implementation; its hatch logic is untouched.
run("Fable_AutoHatch_Cycle_FINAL.lua")
run("Fable_Simple_Live_Stats.lua")

print("[FABLE] Exact Exo UI loaded.")
print("[FABLE] Window title: Fable")
