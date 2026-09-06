-- FABLE AUTOHATCH • CANONICAL REPOSITORY ENTRY
-- ============================================================
-- Single source of truth:
--   shoroblox167-a11y/for-script-only
--
-- UI source:
--   Exact supplied Exo UI library from 9kkinc-sudo/ui_lib.
--   No visual reimplementation or extra styling layer is added.
--   The only UI override is the window title: "Fable".
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

-- Use the exact supplied Exo/Fable UI library.
local Library = loadUI()

-- Only change the window title from the AutoHatch implementation to the
-- requested project name. Everything else from the UI library remains intact.
if not ENV.FableTitleOverrideApplied and type(Library.CreateWindow) == "function" then
    local originalCreateWindow = Library.CreateWindow

    Library.CreateWindow = function(self, info)
        info = type(info) == "table" and info or {}
        info.Title = "Fable"
        return originalCreateWindow(self, info)
    end

    ENV.FableTitleOverrideApplied = true
end

ENV.Library = Library

-- The verified cycle owns all automation behavior. This entry supplies the
-- exact UI library and title override, then executes the canonical cycle.
run("Fable_AutoHatch_Cycle_FINAL.lua")
run("Fable_Simple_Live_Stats.lua")

print("[FABLE] Canonical AutoHatch base loaded.")
print("[FABLE] Exact Exo UI • title: Fable")
print("[FABLE] Verified cycle and live stats loaded from canonical sources.")
