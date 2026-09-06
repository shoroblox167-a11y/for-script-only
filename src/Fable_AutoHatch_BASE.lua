-- FABLE AUTOHATCH • CANONICAL REPOSITORY ENTRY
-- ============================================================
-- Single source of truth:
--   shoroblox167-a11y/for-script-only
--
-- Loads the integrated AutoHatch cycle, approved Egg ESP, and the
-- unchanged final live-stat component from this repository.
--
-- Cycle:
--   REDUCTION -> READY -> conditional HATCH/BRONTO -> SELL -> repeat
--
-- Team security:
--   UNEQUIP ALL -> GARDEN EMPTY -> EQUIP TARGET -> EXACT UUID CHECK
-- ============================================================

repeat task.wait() until game:IsLoaded()

local BASE = "https://raw.githubusercontent.com/shoroblox167-a11y/for-script-only/main/src/"

local function run(path)
    local source = game:HttpGet(BASE .. path)
    local fn, err = loadstring(source)
    if not fn then error(err or ("loadstring failed: " .. path), 2) end
    return fn()
end

-- Integrated canonical UI + AutoHatch state machine.
run("Fable_AutoHatch_Cycle_v2.lua")

-- Final approved simple live stats block. This component remains unchanged.
run("Fable_Simple_Live_Stats.lua")

print("[FABLE] Canonical AutoHatch repository entry loaded.")
print("[FABLE] Source: shoroblox167-a11y/for-script-only")
