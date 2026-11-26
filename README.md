# Upgrade All

A Total War: Warhammer III campaign mod that manages your settlements' buildings
for you when you click End Turn, so you can spend your attention elsewhere.
It supports High Elves and Dark Elves, single-player only.

When you click End Turn it spends the gold you didn't use (down to a floor) on:

1. main settlement upgrades,
2. new buildings in empty slots, following a capital or minor-settlement layout,
3. upgrades to existing buildings: income first, then growth, then the rest.

Provinces are worked in priority order: worst public order first (while it's
negative), then highest income to lowest, then provinces with no income.

At the start of your next turn a summary pops up, headed by any commandments to
set ("Set Tribute to the Phoenix King in: …" / "Set Enforce Tribute Payments in: …")
and, for High Elves, provinces where Banish Corruption is still on with nothing
left to banish.

## What it does

- **Layouts.** High Elf capital: Homestead, Plaza, Elven Gardens, Stone Walls,
  resource building, Elven Craftsman, landmark, City Tunnels, Elven Embassy,
  Dragon's Lair. Minor: Homestead, Elven Craftsman, resource building, Watchtower,
  City Tunnels. Dark Elf equivalents: Manors, Torture Posts, Slave Pens, Slave
  Gate, resource, Artisan's House, landmark, City Tunnels, Altar of Khaine,
  Sorceress' Abode / Manors, Artisan's House, resource, Watchtowers, City Tunnels.
  Slow-build (uninhabitable climate) minors swap the industry building and City Tunnels.
- **Protected province.** High Elves: Eataine is never touched. Dark Elves: the
  lord's starting province is found on the first run and never touched.
- **Settings button.** A "UA" button next to the search button in the top menu
  bar lists your provinces; uncheck one to have the mod skip it. Saved with the campaign.
- **Demolition.** Anything that doesn't belong in a settlement's slots is
  demolished, except landmarks and special buildings, lord-specific buildings
  (Aesanar Camp, Handmaidens' Gallery, Cult of Pleasure…), the main settlement,
  ports and anything under construction. Once a province is fully grown,
  Homesteads / Manors make way for the next item.
- **Landmarks** get the last slot, in the version made for your faction or culture.
- **Crash safety.** The game crashes instead of refusing another culture's building,
  so only your own culture's buildings (culture tag as a whole word in the key)
  and landmarks vetted from the game data are ever queued.

## Repository layout

| Path | What it is |
|---|---|
| `src/engine.lua` | The mod's logic, including `CONFIG` at the top |
| `tools/data_block.lua` | Generated tables from the game data (do not edit by hand) |
| `tools/gen_data.py` | Generates `data_block.lua` from the RPFM exports |
| `exports/` | RPFM table exports the generator reads |
| `build.py` | Builds `script/campaign/mod/upgrade_all.lua` = data + engine |
| `script/campaign/mod/upgrade_all.lua` | The built mod file that goes in the `.pack` |
| `run_tests.py`, `tests/` | Test suite: a fake campaign that imitates the game's API |
| `tools/mutate.py` | Mutation checks: breaks each rule in turn and confirms a test catches it |

## Building, testing, packaging

Requires Python 3 and `lupa` (`pip install lupa`), which provides Lua 5.1 — the
same Lua version the game uses.

```sh
python3 build.py          # build script/campaign/mod/upgrade_all.lua
python3 run_tests.py      # run the test suite
python3 tools/mutate.py   # optional: confirm every safeguard is tested (a few minutes)
```

Then, in RPFM, put `script/campaign/mod/upgrade_all.lua` into your mod `.pack`
at the same path.

## After a game patch

1. In RPFM, regenerate the dependencies cache and export the tables listed at the
   top of `tools/gen_data.py` into `exports/`.
2. `python3 -I tools/gen_data.py exports tools/data_block.lua`
3. `python3 build.py && python3 run_tests.py`

## Lessons from the real game (enforced by the tests)

- `string.find`, `gsub` and `gmatch` misbehaved in-game: the mod never calls them.
- Queueing another culture's building crashes the game.
- No slot reads or construction inside the turn-start event; the popup there only
  reads main settlement slots and commandments.
- A timer started from inside another timer never fires.
- UI: no `LockPriority` / `RegisterTopMost`, never reuse a dying component's name.
