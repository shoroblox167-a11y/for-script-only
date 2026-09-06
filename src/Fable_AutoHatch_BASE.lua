-- FABLE AUTOHATCH • CANONICAL REPOSITORY ENTRY
-- ============================================================
-- Single repository entry point for the Fable AutoHatch project.
--
-- Repository:
--   shoroblox167-a11y/for-script-only
--
-- The repository is the source of truth. Future revisions should be
-- committed here instead of creating independent copies.
--
-- Current verified components in this repository:
--   1) Fable_Simple_4Team_Batch_Cycle_SECURITY_TEST_v3.lua
--      - UUID-based inventory team picker
--      - whole-team equip/unequip
--      - garden-empty transition
--      - exact garden UUID security gate
--   2) Fable_Simple_Live_Stats.lua
--      - live player-attribute stats block
--
-- IMPORTANT:
-- This entry intentionally does not recreate or guess any missing
-- AutoHatch/egg logic. Those pieces must be merged from the approved
-- Fable base source as they become repository files.
--
-- Future rule:
--   Update the repository files, then update this entry only when the
--   canonical file layout changes.
-- ============================================================

repeat task.wait() until game:IsLoaded()

local BASE = "https://raw.githubusercontent.com/shoroblox167-a11y/for-script-only/main/src/"

local function run(path)
    local source = game:HttpGet(BASE .. path)
    return loadstring(source)()
end

-- Verified team/security foundation.
run("Fable_Simple_4Team_Batch_Cycle_SECURITY_TEST_v3.lua")

-- Verified live stats component.
run("Fable_Simple_Live_Stats.lua")

print("[FABLE] Canonical repository entry loaded.")
print("[FABLE] Source: shoroblox167-a11y/for-script-only")
