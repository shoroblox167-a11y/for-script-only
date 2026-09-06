# Fable AutoHatch Workbench

Single repository for the Fable/Garden automation work.

## Locked / verified components

- `src/Fable_Simple_Live_Stats.lua` — approved compact live-stat block. Reads the working player attributes and refreshes automatically.
- `src/Fable_Simple_4Team_Batch_Cycle_SECURITY_TEST_v3.lua` — latest team UI/test baseline with working inventory picker and search. Equip/unequip use the verified PetsService methods.

## Team-cycle rule

The intended cycle is state-driven, not a blind timer:

`CLEAR ALL CURRENT GARDEN → WAIT GARDEN EMPTY → EQUIP TARGET TEAM → VERIFY EXACT GARDEN UUIDS → NEXT STAGE`

Brontosaurus is part of the HATCH stage conditionally, based on the approved Egg ESP's ready-egg BaseWeight. It is not a separate cycle stage.

## Development rule

Use this repository as the single source of truth. Do not create parallel versions in different repositories. Update the relevant file on each iteration and preserve working pieces unless a concrete bug requires changing them.
