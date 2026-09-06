-- FABLE AUTOHATCH • CANONICAL REPOSITORY ENTRY
-- ============================================================
-- Single source of truth:
--   shoroblox167-a11y/for-script-only
--
-- This entry intentionally styles the existing Exo/Fable UI before loading
-- the verified AutoHatch cycle. The hatch logic itself is NOT rewritten here.
--
-- Verified components loaded by this entry:
--   Fable_AutoHatch_Cycle_FINAL.lua
--   Fable_EggESP_v6_1_ReexecutionFix.lua  (approved, unchanged)
--   Fable_Simple_Live_Stats.lua            (approved, unchanged)
--   Fable_AutoHatch_Positions.json         (approved 13-position map)
--
-- Cycle remains:
--   REDUCTION -> READY -> conditional HATCH/BRONTO -> SELL -> repeat
--
-- Team security remains:
--   UNEQUIP ALL -> GARDEN EMPTY -> EQUIP TARGET -> EXACT UUID CHECK
-- ============================================================

repeat task.wait() until game:IsLoaded()

local BASE = "https://raw.githubusercontent.com/shoroblox167-a11y/for-script-only/main/src/"
local UI_URL = "https://raw.githubusercontent.com/9kkinc-sudo/ui_lib/main/source.lua"
local ENV = (type(getgenv) == "function" and getgenv()) or _G

local function run(path)
    local source = game:HttpGet(BASE .. path)
    local fn, err = loadstring(source)
    if not fn then
        error(err or ("loadstring failed: " .. path), 2)
    end
    return fn()
end

local function loadUI()
    local Library = ENV.Library
    if not Library or type(Library.CreateWindow) ~= "function" then
        local source = game:HttpGet(UI_URL)
        local fn, err = loadstring(source)
        if not fn then
            error(err or "Exo UI source failed to load", 2)
        end
        Library = fn()
        ENV.Library = Library
    end
    return Library
end

-- ------------------------------------------------------------
-- EXO/FABLE VISUAL PROFILE
-- ------------------------------------------------------------
-- The supplied UI library already uses the same purple accent seen in the
-- reference screenshots. Keep the library's controls and behavior intact;
-- only the window/card presentation is tightened here.
local Library = loadUI()

if Library.Scheme then
    Library.Scheme.AccentColor = Color3.fromRGB(125, 85, 255)
    Library.Scheme.BackgroundColor = Color3.fromRGB(15, 15, 15)
    Library.Scheme.MainColor = Color3.fromRGB(25, 25, 25)
    Library.Scheme.OutlineColor = Color3.fromRGB(40, 40, 40)
end

if not ENV.FableExoUIProfileApplied and type(Library.CreateWindow) == "function" then
    local originalCreateWindow = Library.CreateWindow

    Library.CreateWindow = function(self, info)
        info = type(info) == "table" and info or {}

        -- Compact centered panel matching the supplied reference UI.
        info.Size = UDim2.fromOffset(820, 560)
        info.Center = true
        info.AutoShow = true
        info.Resizable = true
        info.SearchbarSize = UDim2.fromScale(1, 1)
        info.CornerRadius = 8
        info.Footer = "Fable • AutoHatch"
        info.NotifySide = "Right"
        info.Font = Enum.Font.Code
        info.MobileButtonsSide = "Left"

        return originalCreateWindow(self, info)
    end

    ENV.FableExoUIProfileApplied = true
end

ENV.Library = Library

-- The verified cycle owns all automation behavior. This entry only supplies
-- the visual profile and then executes the canonical cycle unchanged.
run("Fable_AutoHatch_Cycle_FINAL.lua")
run("Fable_Simple_Live_Stats.lua")

print("[FABLE] Canonical AutoHatch UI profile loaded.")
print("[FABLE] Purple Exo/Fable theme • compact cards • sidebar tabs • search • full footer")
print("[FABLE] Verified hatch logic remains in Fable_AutoHatch_Cycle_FINAL.lua")
