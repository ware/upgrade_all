-- Tests for upgrade_all.lua. Run with: python3 run_tests.py
-- Every test that names a place or a bug comes from something seen in a real
-- campaign; the comments say what went wrong there.

local ROOT = string.sub(SCRIPT, 1, #SCRIPT - #"script/campaign/mod/upgrade_all.lua")
dofile(ROOT .. "tests/harness.lua")

local mkregion, new_world, load, end_turn, start_turn = H.mkregion, H.new_world, H.load, H.end_turn, H.start_turn
local queued_in, joined, has, contains = H.queued_in, H.joined, H.has, H.contains
local MAXED_MAJOR, MAXED_MINOR, GROWING_MAJOR, GROWING_MINOR = H.MAXED_MAJOR, H.MAXED_MINOR, H.GROWING_MAJOR, H.GROWING_MINOR

local function assert_in(text, needle, what)
    if not contains(text, needle) then error((what or "missing") .. ": \"" .. needle .. "\" not in:\n" .. text, 2) end
end
local function assert_not_in(text, needle, what)
    if contains(text, needle) then error((what or "unexpected") .. ": \"" .. needle .. "\" in:\n" .. text, 2) end
end

-- A province whose capital and minor are both at their highest level.
local function grown_province(prov)
    prov = prov or "yvresse"
    return {
        mkregion("cap", prov, { capital = true, gdp = 900, main = MAXED_MAJOR,
            buildings = { "wh2_main_hef_farm_2", "wh2_main_hef_order_1", false } }),
        mkregion("mn", prov, { gdp = 100, main = MAXED_MINOR, buildings = { "wh2_main_hef_farm_1", "wh2_main_hef_industry_1" } }),
    }
end

---------------------------------------------------------------------------
-- Loading and safety
---------------------------------------------------------------------------
test("Loads and runs a turn without errors", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { false } }) })
    load(); end_turn()
    eq(joined("mn"), "wh2_main_hef_farm_1")
end)

test("Never calls string.find, match, gsub or gmatch (pattern functions misbehaved in-game) across a busy turn", function()
    new_world({
        mkregion("cap", "p1", { capital = true, gdp = 500, main = GROWING_MAJOR, resource = "res_rom_oil", resource_slot = 2,
            buildings = { false, false, "wh2_main_hef_barracks_1", false } }),
        mkregion("mn", "p1", { main = GROWING_MINOR, buildings = { "wh2_main_hef_farm_1", false } }),
    })
    W.with_menu_bar = true
    load(); end_turn(); end_turn()
    eq(W.find_calls, 0)
end)

test("Multiplayer campaigns: inactive", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { false } }) })
    W.multiplayer = true
    load(); end_turn()
    eq(#W.queued, 0)
end)

test("Another culture (Empire): the mod does nothing at all", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { "wh2_main_hef_farm_1", false } }) })
    W.culture = "wh_main_emp_empire"
    load(); end_turn(); end_turn()
    eq(#W.queued, 0, "queued"); eq(#W.demolished, 0, "demolished"); eq(#W.dialogs, 0, "popups")
    assert_in(W.trace_file, "only runs for High Elves and Dark Elves")
end)

test("If the culture can't be read, the mod stays off rather than guess", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { false } }) })
    W.culture_error = true
    load(); end_turn()
    eq(#W.queued, 0)
end)

test("Other High Elf factions (Avelorn) run too", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { false } }) })
    W.player = "wh2_main_hef_avelorn"
    load(); end_turn()
    eq(#W.queued, 1)
end)

-- tiranoc_palace_def is a vetted landmark in the game data: only the culture
-- check (not the "is it in the data" check) keeps it away from High Elves.
for _, key in ipairs({ "wh2_main_def_order_1", "wh2_dlc09_tmb_defence_major_1", "wh2_main_special_tiranoc_palace_def" }) do
    test("Crash guard: High Elves never queue " .. key .. ", even when configured by hand", function()
        new_world({ mkregion("mn", "p", { capital = true, main = MAXED_MAJOR, buildings = { "wh2_main_hef_order_1", false } }) })
        load({ landmarks = { mn = key } }); end_turn()
        for _, q in ipairs(W.queued) do if q.key == key then error("queued " .. q.key) end end
        assert_in(W.trace_file, "Refusing key from another culture")
    end)
end

test("An error inside a turn is caught, logged and shown; the game carries on", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { false } }) })
    load()
    W.region_list_error = true
    end_turn()
    assert_in(H.summary(), "Hit an error")
    W.region_list_error = false
    end_turn()
    eq(#W.queued, 1, "next turn works again")
end)

---------------------------------------------------------------------------
-- High Elf layouts
---------------------------------------------------------------------------
test("Capital layout in order: Homestead, Plaza, Gardens, Walls, Craftsman, Tunnels, Embassy, Dragon's Lair", function()
    new_world({
        mkregion("cap", "p", { capital = true, gdp = 900, main = "wh2_main_hef_settlement_major_4",  -- the Lair needs level 4
            buildings = { false, false, false, false, false, false, false, false } }),
        mkregion("mn", "p", { main = GROWING_MINOR, buildings = {} }),
    })
    load(); end_turn()
    eq(joined("cap"), "wh2_main_hef_settlement_major_5,wh2_main_hef_farm_1,wh2_main_hef_order_1,wh2_main_hef_court_1,"
        .. "wh2_main_hef_defence_major_1,wh2_main_hef_industry_1,wh2_main_foreign_slot_discovery_hef_1,"
        .. "wh2_main_hef_embassy_1,wh2_main_hef_dragons_1")
end)

test("Minor layout in order: Homestead, Craftsman, resource, Watchtower, City Tunnels", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, resource = "res_rom_marble", resource_slot = 3,
        buildings = { false, false, false, false, false } }) })
    load(); end_turn()
    eq(joined("mn"), "wh2_main_hef_farm_1,wh2_main_hef_industry_1,wh2_main_hef_resource_marble_1,"
        .. "wh2_main_hef_defence_minor_1,wh2_main_foreign_slot_discovery_hef_1")
end)

test("Slow-build (uninhabitable climate) minors swap Craftsman and City Tunnels", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, bundles = { wh2_main_climate_uninhabitable = true },
        buildings = { false, false } }) })
    load(); end_turn()
    eq(joined("mn"), "wh2_main_hef_farm_1,wh2_main_foreign_slot_discovery_hef_1")
end)

test("Slow-build provinces can also be listed by hand", function()
    new_world({ mkregion("mn", "wh3_main_combi_province_badlands", { main = MAXED_MINOR, buildings = { false, false } }) })
    load({ slow_provinces = { "badlands" } }); end_turn()
    eq(joined("mn"), "wh2_main_hef_farm_1,wh2_main_foreign_slot_discovery_hef_1")
end)

test("Eataine is never touched: no building, no demolition, no reminder", function()
    new_world({
        mkregion("lothern", "wh3_main_combi_province_eataine", { capital = true, gdp = 5000, main = MAXED_MAJOR,
            buildings = { false, "wh2_main_hef_barracks_1" } }),
        mkregion("other", "p", { main = MAXED_MINOR, buildings = { false } }),
    })
    load(); end_turn()
    eq(#queued_in("lothern"), 0, "built in Eataine")
    eq(#W.demolished, 0, "demolished in Eataine")
    eq(#queued_in("other"), 1, "other provinces stopped")
    assert_not_in(H.summary(), "eataine")
end)

test("Main settlement upgrades come first, before new buildings", function()
    new_world({ mkregion("cap", "p", { capital = true, main = GROWING_MAJOR, buildings = { false } }),
                mkregion("mn", "p", { main = GROWING_MINOR, buildings = {} }) })
    load(); end_turn()
    eq(queued_in("cap")[1], "wh2_main_hef_settlement_major_4")
end)

test("Upgrades are ranked by income, then growth, then the rest", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR,
        buildings = { "wh2_main_hef_defence_minor_1", "wh2_main_hef_farm_1", "wh2_main_hef_industry_1" } }) })
    load(); end_turn()
    eq(joined("mn"), "wh2_main_hef_industry_2,wh2_main_hef_farm_2,wh2_main_hef_defence_minor_2")
end)

test("Buildings with more than one upgrade path are left for you", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { "wh2_main_hef_industry_1" } }) })
    W.upgrades = { wh2_main_hef_industry_1 = { "wh2_main_hef_industry_2a", "wh2_main_hef_industry_2b" } }
    load(); end_turn()
    eq(#W.queued, 0)
end)

---------------------------------------------------------------------------
-- Resources (checked against the game's slot templates)
---------------------------------------------------------------------------
local RESOURCE_TO_CHAIN = {
    res_animals = "animals", res_dyes = "dyes", res_gems = "gems", res_gold = "gold", res_ivory = "ivory",
    res_medicine = "medicine", res_obsidian = "obsidian", res_spices = "spices", res_rom_furs = "furs",
    res_rom_iron = "iron", res_rom_marble = "marble", res_rom_wine = "wine", res_rom_timber = "wood",
    res_rom_oil = "pasture", res_rom_textiles = "pottery", res_rom_lead = "salt",
}
for res, name in pairs(RESOURCE_TO_CHAIN) do
    test("Resource " .. res .. " gets the High Elf " .. name .. " building", function()
        new_world({ mkregion("mn", "p", { main = MAXED_MINOR, resource = res, resource_slot = 3,
            buildings = { "wh2_main_hef_farm_1", "wh2_main_hef_industry_1", false } }) })
        load(); end_turn()
        local want = "hef_resource_" .. name .. "_1"
        local found = false
        for _, k in ipairs(queued_in("mn")) do if string.sub(k, -#want) == want then found = true end end
        if not found then error(joined("mn")) end
    end)
end

test("An existing pasture building on an oil resource is kept and upgraded, not demolished", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, resource = "res_rom_oil", resource_slot = 3,
        buildings = { "wh2_main_hef_farm_1", "wh2_main_hef_industry_1", "wh2_main_hef_resource_pasture_2" } }) })
    load(); end_turn()
    eq(#W.demolished, 0)
    assert(has(queued_in("mn"), "wh2_main_hef_resource_pasture_3"), joined("mn"))
end)

---------------------------------------------------------------------------
-- Province order and spending
---------------------------------------------------------------------------
test("Province order: worst public order first, then income high to low, then no income", function()
    new_world({
        mkregion("none", "p_none", { gdp = 0, main = MAXED_MINOR, buildings = { false } }),
        mkregion("rich", "p_rich", { gdp = 900, main = MAXED_MINOR, buildings = { false } }),
        mkregion("mid", "p_mid", { gdp = 300, main = MAXED_MINOR, buildings = { false } }),
        mkregion("riot", "p_riot", { gdp = 50, po = -40, main = MAXED_MINOR, buildings = { false } }),
        mkregion("unrest", "p_unrest", { gdp = 950, po = -5, main = MAXED_MINOR, buildings = { false } }),
    })
    load(); end_turn()
    local order = {}
    for _, q in ipairs(W.queued) do order[#order + 1] = q.region end
    eq(table.concat(order, ","), "riot,unrest,rich,mid,none")
end)

test("Spend down to 0: an unaffordable item is skipped and lower provinces still spend", function()
    new_world({
        -- rich: Plaza (1500) and its level-4 upgrade (10000) are out of reach with 1200 gold
        mkregion("rich", "p1", { capital = true, gdp = 900, main = GROWING_MAJOR, buildings = { "wh2_main_hef_farm_3", false } }),
        mkregion("poor", "p2", { gdp = 100, main = MAXED_MINOR, buildings = { false } }),
    }, 1200)
    load(); end_turn()
    eq(joined("poor"), "wh2_main_hef_farm_1", "lower province didn't spend")
    assert_in(H.summary(), "Waiting on gold")
end)

test("Never spends below the gold floor", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { false, false } }) }, 2500)
    load({ gold_floor = 1000 }); end_turn()
    eq(#W.queued, 1)
    assert(W.treasury >= 1000)
end)

test("Repeat passes: gold refunded by a demolition goes to a higher-priority slot on the next pass", function()
    new_world({
        mkregion("poor", "unrest", { po = -10, main = MAXED_MINOR, buildings = { false } }),
        mkregion("rich", "calm", { gdp = 500, main = MAXED_MINOR,
            buildings = { "wh2_main_hef_barracks_1", "wh2_main_hef_farm_1", "wh2_main_hef_industry_1" } }),
    }, 500)
    W.demolish_refund = 2500
    load(); end_turn()
    assert(has(queued_in("poor"), "wh2_main_hef_farm_1"), "refund not used on a later pass")
    assert_not_in(W.trace_file, "poor: 1 empty slot", "stale empty-slot note")
end)

test("Per-turn order cap stops the run and says so", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { false, false, false } }) })
    load({ max_queued_per_turn = 2 }); end_turn()
    eq(#W.queued, 2)
    assert_in(H.summary(), "Stopped: per-turn cap reached")
end)

test("A building the game refuses costs nothing and is tried again next turn", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { false, false } }) }, 5000)
    W.invalid["wh2_main_hef_farm_1"] = true
    load(); end_turn()
    eq(joined("mn"), "wh2_main_hef_industry_1", "turn 1")
    eq(W.treasury, 4000, "charged for the refused building")
    W.invalid = {}
    W.queued = {}
    end_turn()
    eq(joined("mn"), "wh2_main_hef_farm_1", "turn 2")
end)

-- Turn 237 of the Dark Elf campaign: 87 refusals in the final pass, the same
-- orders asked again in every pass, and only the main-building ones named.
test("A refused order is asked once per turn, named in the trace, and counted once in the summary", function()
    new_world({
        mkregion("poor", "unrest", { po = -10, main = MAXED_MINOR, buildings = { false } }),
        mkregion("rich", "calm", { gdp = 500, main = MAXED_MINOR,
            buildings = { "wh2_main_hef_barracks_1", "wh2_main_hef_farm_1", "wh2_main_hef_industry_1" } }),
    }, 20000)                          -- plenty of gold, so pass 1 buys things and pass 2 runs
    W.invalid["wh2_main_hef_farm_2"] = true
    load(); end_turn()
    eq(H.attempts_for("wh2_main_hef_farm_2"), 1, "asked the game again on the next pass")
    eq(H.count(W.trace_file, "rich#2: wh2_main_hef_farm_2 refused by the game"), 1, "trace")
    assert_in(H.summary(), "Refused by the game (growth, tech...): 1")
    assert_in(W.trace_file, "pass 2", "the second pass didn't run, so nothing was tested")
end)

test("A building the settlement is too small for is never asked for: the data's level requirement decides", function()
    -- A level-1 minor: Homestead and Craftsman need level 1; the Watchtower and
    -- City Tunnels need level 2 (building_levels).
    new_world({ mkregion("mn", "p", { main = "wh2_main_hef_settlement_minor_1", buildings = { false, false, false, false } }) })
    W.upgrades = { wh2_main_hef_settlement_minor_1 = {} }      -- keep it at level 1 this turn
    W.invalid["wh2_main_hef_settlement_minor_2"] = true
    load(); end_turn()
    eq(joined("mn"), "wh2_main_hef_farm_1,wh2_main_hef_industry_1")
    eq(H.attempts_for("wh2_main_hef_defence_minor_1"), 0, "asked the game for the Watchtower")
    eq(H.attempts_for("wh2_main_foreign_slot_discovery_hef_1"), 0, "asked the game for City Tunnels")
    assert_in(H.summary(), "Waiting on settlement level: 2")
    assert_in(W.trace_file, "wh2_main_hef_defence_minor_1 needs main settlement level 2 (this one is level 1)")
end)

test("Upgrades the settlement is too small for are not asked for either", function()
    -- Homestead II needs a level-2 settlement; this minor is level 1.
    new_world({ mkregion("mn", "p", { main = "wh2_main_hef_settlement_minor_1", buildings = { "wh2_main_hef_farm_1" } }) })
    W.upgrades = { wh2_main_hef_settlement_minor_1 = {} }
    W.invalid["wh2_main_hef_settlement_minor_2"] = true
    load(); end_turn()
    eq(H.attempts_for("wh2_main_hef_farm_2"), 0)
    assert_in(H.summary(), "Waiting on settlement level: 1")
end)

test("Unknown settlement levels never block: a special main building with no data still gets its layout", function()
    new_world({ mkregion("odd", "p", { main = "wh3_main_special_settlement_nowhere_3", buildings = { false } }) })
    load(); end_turn()
    eq(joined("odd"), "wh2_main_hef_farm_1")
end)

---------------------------------------------------------------------------
-- Demolition
---------------------------------------------------------------------------
test("A building outside the layout is demolished and the slot refilled", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { "wh2_main_hef_barracks_1" } }) })
    load(); end_turn()
    eq(table.concat(W.demolished, ","), "wh2_main_hef_barracks_1")
    eq(joined("mn"), "wh2_main_hef_farm_1")
end)

test("Your exception: the item right after the next one to build is kept", function()
    -- 2 slots: Homestead (missing, next to build) and Craftsman. Watchtower ranks
    -- 4th; Craftsman (right after Homestead) must not be demolished.
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { "wh2_main_hef_industry_1", false } }) })
    W.invalid["wh2_main_hef_farm_1"] = true
    load(); end_turn()
    eq(#W.demolished, 0)
end)

test("Never demolished: landmarks/special buildings, the main settlement, ports, or anything under construction", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, port = "wh2_main_hef_port_1",
        buildings = { "wh2_main_special_tower_of_hoeth_1", false } }) })
    load(); end_turn()
    eq(#W.demolished, 0, table.concat(W.demolished, ","))
end)

test("allow_demolish = false: nothing is demolished", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { "wh2_main_hef_barracks_1" } }) })
    load({ allow_demolish = false }); end_turn()
    eq(#W.demolished, 0)
end)

for _, b in ipairs({ "wh2_dlc10_hef_aesanar_camp", "wh2_dlc10_hef_handmaidens", "wh2_dlc10_hef_handmaidens_alarielle",
                     "wh2_dlc15_hef_field_hq_2", "wh3_dlc27_hef_colony_dragonship_supplies_income_1" }) do
    test("Lord-specific building never demolished: " .. b, function()
        new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { b, false, false, false, false } }) })
        load(); end_turn()
        eq(#W.demolished, 0, table.concat(W.demolished, ","))
    end)
end

test("An ordinary chain one lord merely renames (the Grove) can still be demolished", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { "wh2_main_hef_hunters_2", false, false, false, false } }) })
    load(); end_turn()
    eq(table.concat(W.demolished, ","), "wh2_main_hef_hunters_2")
end)

test("Slot gap: a cheap item ranked below what fits doesn't take the slot of an unaffordable one", function()
    new_world({ mkregion("cap", "p", { capital = true, gdp = 900, main = MAXED_MAJOR, buildings = { false, false, false } }) }, 2500)
    load(); end_turn()   -- Plaza (1500) fits; Gardens and Walls (2000) don't; Craftsman (1000) ranks 5th
    eq(joined("cap"), "wh2_main_hef_order_1")
    eq(W.treasury, 1000, "gold left for other provinces")
end)

test("Slot gap: the held slots get Gardens and Walls once there's gold, and nothing is demolished", function()
    new_world({ mkregion("cap", "p", { capital = true, gdp = 900, main = MAXED_MAJOR, buildings = { false, false, false } }) }, 2500)
    load(); end_turn()
    H.region("cap").slots[2].b = "wh2_main_hef_order_1"
    W.treasury = 4000
    end_turn()
    assert(has(queued_in("cap"), "wh2_main_hef_court_1") and has(queued_in("cap"), "wh2_main_hef_defence_major_1"), joined("cap"))
    eq(#W.demolished, 0)
end)

test("Slot gap: a building the game refuses still lets the next item in", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { false } }) })
    W.invalid["wh2_main_hef_farm_1"] = true
    load(); end_turn()
    eq(joined("mn"), "wh2_main_hef_industry_1")
end)

test("Your Chrace screenshot: 100,000 gold fills every empty slot in one End Turn", function()
    new_world({
        mkregion("tor_achare", "chrace", { capital = true, gdp = 900, main = "wh2_main_hef_settlement_major_4",
            buildings = { "wh2_main_hef_defence_major_3", false, false, false, false }, locked = 2 }),
        mkregion("elisia", "chrace", { main = "wh2_main_hef_settlement_minor_3", port = "wh2_main_hef_port_3",
            resource = "res_rom_timber", resource_slot = 1, buildings = { "wh2_main_hef_resource_wood_3", false } }),
    }, 100000)
    load(); end_turn()
    for _, r in ipairs(W.regions) do
        for _, sl in ipairs(r.slots) do
            if sl.active_ and not sl.b then
                local filled = false
                for _, q in ipairs(W.queued) do if q.slot == sl.id then filled = true end end
                if not filled then error(sl.id .. " left empty: " .. joined(r.key)) end
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Growth done: Homesteads go
---------------------------------------------------------------------------
test("Once the capital and every minor are maxed, Homesteads are removed province-wide", function()
    new_world(grown_province())
    load(); end_turn()
    table.sort(W.demolished)
    eq(table.concat(W.demolished, ","), "wh2_main_hef_farm_1,wh2_main_hef_farm_2")
    assert_in(H.summary(), "Homesteads removed (growth no longer needed): 2")
end)

test("A queued final main-settlement upgrade counts as maxed", function()
    new_world({ mkregion("cap", "p", { capital = true, main = "wh2_main_hef_settlement_major_4",
        buildings = { "wh2_main_hef_farm_1", "wh2_main_hef_order_1" } }) })
    load(); end_turn()
    assert(has(W.demolished, "wh2_main_hef_farm_1"), "Homestead kept")
end)

test("A growing minor keeps every Homestead in the province", function()
    local regions = grown_province()
    regions[2] = mkregion("mn", "yvresse", { main = GROWING_MINOR, buildings = { "wh2_main_hef_farm_1" } })
    new_world(regions)
    load(); end_turn()
    eq(#W.demolished, 0)
end)

-- Great Desert of Araby: a Dark Elf minor settlement sat at the same level
-- for turns while the summary asked for Enforce Tribute Payments, as if the
-- province were fully grown. The one state that produces both at once is the
-- game listing no upgrade for a main building that isn't at its top level.
test("Great Desert of Araby: if the game lists no upgrade for a main building below its top level, the data's next level is tried", function()
    new_world({
        mkregion("cap", "araby", { capital = true, gdp = 500, main = H.DEF_MAJOR_MAX, buildings = { "wh2_main_def_order_1" } }),
        mkregion("mn", "araby", { main = "wh2_main_def_settlement_minor_1", buildings = { "wh2_main_def_farm_1" } }),
    })
    W.culture = "wh2_main_def_dark_elves"; W.player = "wh2_main_def_naggarond"
    W.upgrades = { wh2_main_def_settlement_minor_1 = {} }   -- the game says: nothing
    load(); end_turn()
    assert(has(queued_in("mn"), "wh2_main_def_settlement_minor_2"), "main building not upgraded: " .. joined("mn"))
    assert_in(W.trace_file, "wh2_main_def_settlement_minor_1: the game lists no upgrade but the data has wh2_main_def_settlement_minor_2")
    assert_not_in(H.summary(), "Enforce Tribute", "province treated as fully grown")
    eq(#W.demolished, 0, "Manors demolished as if the province were grown")
end)

test("Great Desert of Araby: when the data's next level is refused too, the province still isn't treated as grown", function()
    new_world({
        mkregion("cap", "araby", { capital = true, gdp = 500, main = H.DEF_MAJOR_MAX, buildings = { "wh2_main_def_order_1" } }),
        mkregion("mn", "araby", { main = "wh2_main_def_settlement_minor_1", buildings = { "wh2_main_def_farm_1" } }),
    })
    W.culture = "wh2_main_def_dark_elves"; W.player = "wh2_main_def_naggarond"
    W.upgrades = { wh2_main_def_settlement_minor_1 = {} }
    W.invalid["wh2_main_def_settlement_minor_2"] = true
    load(); end_turn()
    assert(not has(queued_in("mn"), "wh2_main_def_settlement_minor_2"), "refused order counted as queued")
    assert_not_in(H.summary(), "Enforce Tribute")
    eq(#W.demolished, 0)
    assert_in(W.trace_file, "mn: main building wh2_main_def_settlement_minor_1 -> wh2_main_def_settlement_minor_2: refused by the game")
end)

-- What the trace actually showed for the Great Desert: a single-settlement
-- province whose only settlement is a level-3 minor (the top level), holding
-- the culture-neutral "_other" version of The Great Desert landmark. The mod
-- refused to upgrade the landmark every turn ("Refusing key from another
-- culture"), because "_other" has no culture tag and isn't in landmark_ok.
test("Great Desert of Araby: the owned '_other' landmark is upgraded, and the lone maxed minor makes the province grown", function()
    new_world({ mkregion("wh3_main_combi_region_great_desert_of_araby", "wh3_main_combi_province_great_desert_of_araby",
        { capital = true, main = H.DEF_MINOR_MAX, buildings = { "wh3_main_special_the_great_desert_other_1" } }) })
    W.culture = "wh2_main_def_dark_elves"; W.player = "wh2_main_def_naggarond"
    load(); end_turn()
    eq(joined("wh3_main_combi_region_great_desert_of_araby"), "wh3_main_special_the_great_desert_other_2")
    assert_not_in(W.trace_file, "Refusing key")
    eq(#W.demolished, 0)
    assert_in(H.summary(), "Set Enforce Tribute Payments in: great desert of araby")
end)

test("Copher: the special port already owned is upgraded along its own chain", function()
    new_world({ mkregion("copher", "coast_of_araby", { main = H.DEF_MINOR_MAX, port = "wh2_dlc14_special_copher_port_1", buildings = {} }) })
    W.culture = "wh2_main_def_dark_elves"; W.player = "wh2_main_def_naggarond"
    load(); end_turn()
    eq(joined("copher"), "wh2_dlc14_special_copher_port_2")
end)

test("A leftover building tagged for another culture is never upgraded, even along its own chain", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { "wh2_dlc09_tmb_special_mortuary_cult_1", false } }) })
    load(); end_turn()
    assert(not has(queued_in("mn"), "wh2_dlc09_tmb_special_mortuary_cult_2"), joined("mn"))
    assert_in(W.trace_file, "Refusing key from another culture: wh2_dlc09_tmb_special_mortuary_cult_2")
end)

test("A main building at its top level in the data is still maxed without asking twice", function()
    new_world(grown_province())
    load(); end_turn()
    assert_in(H.summary(), "Set Tribute to the Phoenix King in: yvresse")
    assert_in(W.trace_file, "yvresse: fully grown, growth buildings no longer needed (cap=wh2_main_hef_settlement_major_5, mn=wh2_main_hef_settlement_minor_4)")
end)

test("The trace says why a main building wasn't upgraded: waiting on an order, or more than one path", function()
    new_world({
        mkregion("cap", "p", { capital = true, main = "wh2_main_hef_settlement_major_3", buildings = {} }),
        mkregion("forked", "p", { main = GROWING_MINOR, buildings = {} }),
    })
    W.upgrades = { wh2_main_hef_settlement_minor_2 = { "wh2_main_hef_settlement_minor_3", "wh2_main_hef_settlement_minor_3_alt" } }
    load(); end_turn()
    assert_in(W.trace_file, "forked: main building wh2_main_hef_settlement_minor_2: more than one upgrade path; left for you")
    end_turn()
    assert_in(W.trace_file, "cap: main building: waiting on wh2_main_hef_settlement_major_4 (ordered turn 1)")
end)

---------------------------------------------------------------------------
-- Landmarks
---------------------------------------------------------------------------
test("Shrine of Khaine: High Elves build the High Elf version", function()
    new_world({ mkregion("shrine", "p", { main = MAXED_MINOR, template = "wh2_main_special_shrine_of_khaine_secondary",
        buildings = { "wh2_main_hef_farm_1", false } }) })
    load(); end_turn()
    assert(has(queued_in("shrine"), "wh2_main_special_shrine_of_khaine_hef_base"), joined("shrine"))
end)

test("Gaean Vale: Eataine builds the Court of the Everqueen (the version open to everyone)", function()
    new_world({ mkregion("vale", "avelorn", { capital = true, main = "wh2_main_special_settlement_gaean_vale_5",
        template = "wh2_dlc10_special_gaean_vale_secondary", buildings = { "wh2_main_hef_order_1", false } }) })
    load(); end_turn()
    assert(has(queued_in("vale"), "wh2_main_special_everqueen_court"), joined("vale"))
end)

test("Gaean Vale: Avelorn builds its own version of the Court", function()
    new_world({ mkregion("vale", "avelorn", { capital = true, main = "wh2_main_special_settlement_gaean_vale_5",
        template = "wh2_dlc10_special_gaean_vale_secondary", buildings = { "wh2_main_hef_order_1", false } }) })
    W.player = "wh2_main_hef_avelorn"
    load(); end_turn()
    assert(has(queued_in("vale"), "wh2_main_special_everqueen_court_hef") or has(queued_in("vale"), "wh2_dlc10_special_world_root_entrance_1"),
        joined("vale"))
    assert(not has(queued_in("vale"), "wh2_main_special_everqueen_court"), "picked the version Avelorn can't build")
end)

test("Gaean Vale: its special main building (no 'hef' in the key) is still upgraded", function()
    new_world({ mkregion("vale", "avelorn", { capital = true, main = "wh2_main_special_settlement_gaean_vale_3",
        template = "wh2_dlc10_special_gaean_vale_secondary", buildings = {} }) })
    load(); end_turn()
    eq(joined("vale"), "wh2_main_special_settlement_gaean_vale_4")
end)

test("A landmark isn't held for while the settlement is too small for it", function()
    new_world({ mkregion("vale", "avelorn", { capital = true, main = "wh2_main_special_settlement_gaean_vale_3",
        template = "wh2_dlc10_special_gaean_vale_secondary", buildings = { false, false } }) })
    W.invalid["wh2_main_special_settlement_gaean_vale_4"] = true  -- can't grow yet
    load(); end_turn()
    -- (the game refuses a level-5 landmark here; the mock doesn't check levels)
    assert(not has(queued_in("vale"), "wh2_main_special_everqueen_court"), "tried the level-5 landmark: " .. joined("vale"))
    eq(#queued_in("vale"), 2, "slot held for a level-5 landmark: " .. joined("vale"))
end)

test("Shrine of Kurnous: a refused neutral landmark is remembered and the slot used for the layout", function()
    new_world({ mkregion("kurnous", "p", { main = MAXED_MINOR, template = "wh3_dlc24_special_shrine_of_kurnous_secondary",
        buildings = { "wh2_main_hef_farm_1", "wh2_main_hef_industry_1", false } }) })
    W.invalid["wh3_dlc24_special_ecstatic_hunt"] = true
    load(); end_turn(); end_turn()
    local tries = 0
    for _, q in ipairs(W.queued) do if q.key == "wh3_dlc24_special_ecstatic_hunt" then tries = tries + 1 end end
    eq(tries, 0, "neutral landmark forced into a slot")
    assert(#queued_in("kurnous") > 0, "slot left empty")
end)

test("A refused landmark stays remembered after save and load", function()
    new_world({ mkregion("shrine", "p", { main = MAXED_MINOR, template = "wh2_main_special_shrine_of_khaine_secondary",
        buildings = { "wh2_main_hef_farm_1", false } }) })
    W.invalid["wh2_main_special_shrine_of_khaine_hef_base"] = true
    load(); end_turn()
    local saved = H.reload()
    assert_in(saved["upgrade_all_v2_refused_landmarks"], "shrine|wh2_main_special_shrine_of_khaine_hef_base")
end)

test("Arnheim (Elven Colony main building): empty slots are filled, with Walls of Arnheim last", function()
    new_world({ mkregion("arnheim", "bleak_coast", { capital = true, gdp = 800, main = "wh2_main_special_settlement_colony_major_hef_4",
        template = "wh3_dlc27_special_arnheim_secondary", port = "wh2_main_hef_port_3",
        buildings = { "wh2_main_hef_farm_3", false, false, false } }) })
    load(); end_turn()
    local k = queued_in("arnheim")
    assert(has(k, "wh2_main_special_settlement_colony_major_hef_5"), "main not upgraded: " .. joined("arnheim"))
    assert(has(k, "wh2_main_hef_order_1") and has(k, "wh3_dlc27_hef_special_colony_arnheim"), joined("arnheim"))
end)

test("Aislinn's own colony settlements get upgrades only: nothing new, nothing demolished", function()
    new_world({ mkregion("col", "p", { capital = true, main = "wh3_dlc27_hef_colony_settlement_major_3",
        buildings = { "wh2_main_hef_barracks_1", false } }) })
    load(); end_turn()
    eq(#W.demolished, 0)
    eq(joined("col"), "wh3_dlc27_hef_colony_settlement_major_4,wh2_main_hef_barracks_2")
end)

test("Tor Anroc: if the game refuses the neutral palace, High Elves never fall back to the Dark Elf one", function()
    new_world({ mkregion("anroc", "p", { capital = true, main = MAXED_MAJOR, template = "wh2_main_special_tor_anroc_secondary",
        buildings = { "wh2_main_hef_order_1", false, false, false, false, false, false, false } }) })
    -- level 5 and enough free slots that the layout reaches its landmark line
    W.invalid["wh2_main_special_tiranoc_palace"] = true
    load(); end_turn(); end_turn(); end_turn()
    for _, q in ipairs(W.queued) do assert(q.key ~= "wh2_main_special_tiranoc_palace_def", "queued the Dark Elf palace") end
    assert_not_in(W.trace_file, "Refusing key from another culture", "Dark Elf palace was even chosen")
end)

---------------------------------------------------------------------------
-- Commandment reminders
---------------------------------------------------------------------------
test("Tribute reminder for a fully grown province, listed first after the title", function()
    new_world(grown_province())
    W.loc = { provinces_onscreen_yvresse = "Yvresse" }
    load(); end_turn()
    local l = H.lines(H.popup())
    eq(l[1], "Upgrade All"); eq(l[2], "")
    eq(l[3], "Set Tribute to the Phoenix King in: Yvresse")
end)

test("No Tribute reminder where Tribute is already set", function()
    local regions = grown_province()
    regions[1].opts.edict = H.TRIBUTE
    new_world(regions)
    load(); end_turn()
    assert_not_in(H.popup(), "Tribute")
end)

test("No Tribute reminder in a growing province", function()
    local regions = grown_province()
    regions[2] = mkregion("mn", "yvresse", { main = GROWING_MINOR, buildings = {} })
    new_world(regions)
    load(); end_turn()
    assert_not_in(H.popup(), "Tribute")
end)

test("No Tribute reminder for gates and forts (no economy)", function()
    new_world({ mkregion("gate", "eagle_gate", { capital = true, main = "wh2_main_hef_fortress_gate_eagle_3", buildings = {} }) })
    W.upgrades = { wh2_main_hef_fortress_gate_eagle_3 = {} }
    load(); end_turn()
    assert_not_in(H.popup(), "Tribute")
end)

test("Titan Peaks: one settlement owned by someone else, so no Tribute reminder", function()
    new_world(grown_province())
    W.not_owned = { yvresse = 1 }
    load(); end_turn()
    assert_not_in(H.popup(), "Tribute")
    assert_not_in(H.summary(), "Tribute")
    assert(#W.queued > 0, "building stopped in a partly owned province")
end)

test("If the game can't count a province's settlements, the reminder stays on and the trace says why", function()
    new_world(grown_province())
    W.province_count_error = true
    load(); end_turn()
    assert_in(H.popup(), "Set Tribute to the Phoenix King in: yvresse")
    assert_in(W.trace_file, "couldn't count the settlements")
end)

test("Banish Corruption warning when there's no corruption left", function()
    new_world({ mkregion("cap", "clean", { capital = true, main = GROWING_MAJOR, edict = H.BANISH, corruption = 0, buildings = { false } }) })
    load(); end_turn()
    assert_in(H.popup(), "Warning: Banish Corruption is still active with no corruption left in: clean")
end)

test("No Banish warning while corruption remains in any settlement of the province", function()
    new_world({
        mkregion("cap", "dirty", { capital = true, main = GROWING_MAJOR, edict = H.BANISH, corruption = 0, buildings = {} }),
        mkregion("mn", "dirty", { main = GROWING_MINOR, corruption = 12, buildings = {} }),
    })
    load(); end_turn()
    assert_not_in(H.popup(), "Banish")
end)

test("Commandment reminders off: commandments and corruption are never read", function()
    new_world(grown_province())
    load({ phoenix_tribute_key = false, banish_corruption_key = false }); end_turn()
    assert_not_in(H.popup(), "Tribute")
    eq(W.corruption_reads or 0, 0)
end)

test("Jungle of Webs (key ...vampire_coast): summary lines use the on-screen province name", function()
    new_world({ mkregion("cap", "wh3_main_combi_province_vampire_coast", { capital = true, main = GROWING_MAJOR,
        edict = H.BANISH, corruption = 0, buildings = { false } }) })
    W.loc = { provinces_onscreen_wh3_main_combi_province_vampire_coast = "Jungle of Webs" }
    load(); end_turn()
    assert_in(H.popup(), "no corruption left in: Jungle of Webs")
    assert_in(H.popup(), "Jungle of Webs: 1 new")
    assert_not_in(H.popup(), "vampire coast")
end)

---------------------------------------------------------------------------
-- Summary and popup
---------------------------------------------------------------------------
test("No popup during End Turn; it appears inside the next turn's start event", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { false } }) })
    load()
    H.fire("FactionAboutToEndTurn"); H.settle()
    eq(#W.dialogs, 0, "popup at End Turn")
    H.fire("FactionTurnEnd"); W.turn = W.turn + 1
    H.fire("FactionTurnStart")
    eq(#W.dialogs, 1, "popups")
    assert_in(W.dialogs[1], "New buildings: 1")
end)

test("Summary file written at End Turn, rewritten at turn start, then the popup", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { false } }) })
    load(); end_turn()
    eq(table.concat(W.sequence, ","), "file,file,popup")
end)

test("The popup is shown once per turn, however many turn-start events arrive", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { false } }) })
    load()
    H.fire("FactionAboutToEndTurn"); H.settle()
    W.turn = W.turn + 1
    H.fire("FactionTurnStart"); H.fire("FactionTurnStart"); H.settle()
    eq(#W.dialogs, 1)
end)

test("A summary saved with the game still shows at the next turn start", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { false } }) })
    load()
    H.fire("FactionAboutToEndTurn"); H.settle()
    H.reload()
    start_turn()
    eq(#W.dialogs, 1)
    assert_in(W.dialogs[1], "New buildings: 1")
end)

test("popup = false: no popup, but the summary file is still written", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { false } }) })
    load({ popup = false }); end_turn()
    eq(#W.dialogs, 0)
    assert_in(H.summary(), "New buildings: 1")
end)

test("The popup's OK closes it; each popup gets a fresh name", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { false, false } }) }, 1000)
    load(); end_turn()
    local box = W.ui.comps["upgrade_all_popup_1"]
    assert(box, "no popup")
    H.click(find_uicomponent(box, "button_tick"))
    assert(box.destroyed, "OK didn't close it")
    W.treasury = 1000
    end_turn()
    assert(W.ui.comps["upgrade_all_popup_2"], "second popup not under a fresh name")
end)

test("Tribute set after End Turn: the popup no longer asks for it", function()
    local regions = grown_province()
    new_world(regions)
    load()
    H.fire("FactionAboutToEndTurn"); H.settle()
    assert_in(H.summary(), "Set Tribute to the Phoenix King in: yvresse", "End Turn file")
    regions[1].opts.edict = H.TRIBUTE
    H.fire("FactionTurnEnd"); start_turn()
    assert_not_in(H.popup(), "Tribute")
    assert_not_in(H.summary(), "Tribute", "file not refreshed")
    assert_in(H.popup(), "Homesteads removed", "rest of the summary lost")
end)

test("Commandment changed away from Tribute after End Turn: the popup asks again", function()
    local regions = grown_province()
    regions[1].opts.edict = H.TRIBUTE
    new_world(regions)
    load()
    H.fire("FactionAboutToEndTurn"); H.settle()
    regions[1].opts.edict = "something_else"
    start_turn()
    assert_in(H.popup(), "Set Tribute to the Phoenix King in: yvresse")
end)

test("Turn-start re-check reads only main slots and leaves the queued-building record alone", function()
    local regions = grown_province()
    regions[1] = mkregion("cap", "yvresse", { capital = true, gdp = 900, main = "wh2_main_hef_settlement_major_4",
        buildings = { "wh2_main_hef_farm_2", "wh2_main_hef_order_1" } })
    new_world(regions)
    load()
    H.fire("FactionAboutToEndTurn"); H.settle()
    local before = H.save()["upgrade_all_v2_pending"]
    assert_in(before, "settlement_major_5", "upgrade not recorded")
    regions[1].primary.b = "wh2_main_hef_settlement_major_5"  -- finished overnight
    start_turn()
    eq(H.save()["upgrade_all_v2_pending"], before, "record changed at turn start")
    assert_in(H.popup(), "Set Tribute to the Phoenix King in: yvresse")
end)

test("If the turn-start re-check fails, the popup still shows the summary", function()
    new_world(grown_province())
    load()
    H.fire("FactionAboutToEndTurn"); H.settle()
    W.region_list_error = true
    start_turn()
    eq(#W.dialogs, 1)
    assert_in(H.popup(), "Homesteads removed")
    assert_in(H.popup(), "Couldn't re-read commandments")
end)

test("Test mode surveys and builds nothing", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, resource = "res_rom_oil", resource_slot = 1, buildings = { false } }) })
    load({ test_mode = true }); end_turn()
    eq(#W.queued, 0)
    assert_in(H.summary(), "TEST MODE")
    assert_in(H.summary(), "Resources with a High Elf building: 1")
end)

test("run_at = turn_start: works two seconds into the turn", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { false } }) })
    load({ run_at = "turn_start" })
    H.fire("FactionAboutToEndTurn"); H.settle()
    eq(#W.queued, 0, "ran at End Turn")
    start_turn()
    eq(#W.queued, 1)
end)

---------------------------------------------------------------------------
-- Orders that never appear (Monument of the Moon), and why slots stay empty
---------------------------------------------------------------------------
-- Timer fallback: the slot still says it is working (the game never told us
-- otherwise), so only the turn count can give the order up.
test("Monument of the Moon: a Homestead that never appeared is ordered again after its build time + 1", function()
    new_world({ mkregion("moon", "p", { main = MAXED_MINOR, buildings = { false } }) })
    load(); end_turn()                          -- turn 1: ordered (1-turn build)
    eq(joined("moon"), "wh2_main_hef_farm_1")
    W.queued = {}
    end_turn(); end_turn()                      -- up to 2 turns old: still waiting
    eq(#W.queued, 0, "re-ordered too early")
    end_turn()                                  -- 3 turns old: overdue
    eq(joined("moon"), "wh2_main_hef_farm_1", "not re-ordered")
    assert_in(W.trace_file, "never appeared; trying the slot again")
end)

test("Slow-build climates get double the time before an order is given up on", function()
    new_world({ mkregion("moon", "p", { main = MAXED_MINOR, buildings = { false }, bundles = { wh2_main_climate_uninhabitable = true } }) })
    load(); end_turn()
    W.queued = {}
    for _ = 1, 3 do end_turn() end              -- 1 x 2 + 1 = 3 turns: still waiting
    eq(#W.queued, 0, "re-ordered too early")
    end_turn()
    eq(#W.queued, 1, "not re-ordered")
end)

---------------------------------------------------------------------------
-- What the game says about orders comes before the timer (A2)
---------------------------------------------------------------------------
test("An order the game cancels is retried next turn, not after the timer", function()
    new_world({ mkregion("cap", "p", { capital = true, main = "wh2_main_hef_settlement_major_4", buildings = {} }) })
    load(); end_turn()                          -- level 5: 7-turn build
    eq(joined("cap"), "wh2_main_hef_settlement_major_5")
    W.queued = {}
    H.cancel("cap", 0)
    assert_in(W.trace_file, "cap#0: wh2_main_hef_settlement_major_5 cancelled (game event)")
    end_turn()
    eq(joined("cap"), "wh2_main_hef_settlement_major_5", "not re-ordered after the cancel")
    assert_not_in(W.trace_file, "never appeared")
end)

test("A finished building reported by the game clears its order at once", function()
    new_world({ mkregion("moon", "p", { main = MAXED_MINOR, buildings = { false } }) })
    load(); end_turn()
    W.queued = {}
    H.complete("moon", 1)
    assert_in(W.trace_file, "moon#1: wh2_main_hef_farm_1 finished (game event)")
    local saved = H.save()
    eq(saved["upgrade_all_v2_pending"], "", "order still remembered")
    end_turn()
    eq(joined("moon"), "wh2_main_hef_farm_2")
end)

test("An order that silently vanished is retried as soon as the slot is seen idle", function()
    new_world({ mkregion("cap", "p", { capital = true, main = "wh2_main_hef_settlement_major_4", buildings = {} }) })
    load(); end_turn()
    W.queued = {}
    H.lose("cap", 0)
    end_turn()
    eq(joined("cap"), "wh2_main_hef_settlement_major_5", "not re-ordered from the idle slot")
    assert_in(W.trace_file, "the slot is idle; the order is gone, trying the slot again")
end)

test("A slot the game says is still working is left alone until the timer", function()
    new_world({ mkregion("cap", "p", { capital = true, main = "wh2_main_hef_settlement_major_4", buildings = {} }) })
    load(); end_turn()
    W.queued = {}
    for _ = 1, 8 do end_turn() end              -- up to 8 turns old: 7 + 1 grace
    eq(#W.queued, 0, "re-ordered while the slot was working")
    end_turn()
    eq(#W.queued, 1, "timer fallback did not fire")
end)

test("Without slot:is_working the timer still works and the trace says so once", function()
    new_world({ mkregion("moon", "p", { main = MAXED_MINOR, buildings = { false } }),
                mkregion("sun", "q", { main = MAXED_MINOR, buildings = { false } }) })
    for _, r in ipairs(W.regions) do for _, s in ipairs(r.slots) do s.is_working = nil end end
    load(); end_turn()
    W.queued = {}
    end_turn(); end_turn()
    eq(#W.queued, 0, "re-ordered too early")
    end_turn()
    eq(#W.queued, 2, "timer fallback did not fire")
    eq(H.count(W.trace_file, "game signal slot:is_working unavailable"), 1)
end)

test("Events for a region with no orders, or a broken context, change nothing", function()
    new_world({ mkregion("moon", "p", { main = MAXED_MINOR, buildings = { false } }) })
    load(); end_turn()
    W.queued = {}
    H.fire_ctx("BuildingCompleted", { building = function() error("no building") end })
    H.fire_ctx("RegionBuildingCancelled", { key = function() return "wh2_main_hef_farm_1" end,
        slot = function() return { region = function() return H.region("nowhere") end } end })
    assert_in(W.trace_file, "game signal BuildingCompleted unavailable")
    end_turn()
    eq(#W.queued, 0, "order forgotten")
end)

test("When the game reports issued orders, a refusal is one it did not report", function()
    new_world({ mkregion("moon", "p", { main = MAXED_MINOR, buildings = { false, false } }) }, 20000)
    W.issued_events = true
    W.invalid["wh2_main_hef_farm_1"] = true
    load(); end_turn()
    assert_in(W.trace_file, "wh2_main_hef_farm_1 refused by the game")
    assert(not has(queued_in("moon"), "wh2_main_hef_farm_1"), "refused order was counted")
    assert(#queued_in("moon") >= 1, "accepted orders were not counted")
end)

test("An order the game reports issued counts even if the treasury did not move (trainer gold)", function()
    new_world({ mkregion("moon", "p", { main = MAXED_MINOR, buildings = { false } }) })
    W.issued_events, W.free_orders = true, true
    load(); end_turn()
    eq(joined("moon"), "wh2_main_hef_farm_1")
    assert_in(W.trace_file, "issued by the game but the treasury did not drop; trusting the game")
    assert_not_in(W.trace_file, "refused by the game")
    W.queued = {}
    end_turn()
    eq(#W.queued, 0, "order not remembered")
end)

test("A cancel in one region leaves the same order in another alone", function()
    new_world({ mkregion("moon", "p", { main = MAXED_MINOR, buildings = { false } }),
                mkregion("sun", "q", { main = MAXED_MINOR, buildings = { false } }) })
    load(); end_turn()
    W.queued = {}
    H.cancel("moon", 1)
    end_turn()
    eq(joined("moon"), "wh2_main_hef_farm_1", "cancelled order not retried")
    eq(#queued_in("sun"), 0, "sun's order was forgotten too")
end)

test("An issued report from an earlier order does not vouch for a later one", function()
    new_world({ mkregion("moon", "p", { main = MAXED_MINOR, buildings = { false } }) }, 20000)
    W.issued_events = true
    W.invalid["wh2_main_hef_farm_1"] = true
    load()
    H.fire_ctx("BuildingConstructionIssued", { building_key = function() return "wh2_main_hef_farm_1" end })
    end_turn()
    assert_in(W.trace_file, "wh2_main_hef_farm_1 refused by the game")
end)

test("Until the game has ever reported an issued order, the treasury alone is trusted without comment", function()
    new_world({ mkregion("moon", "p", { main = MAXED_MINOR, buildings = { false } }) })
    load(); end_turn()
    eq(joined("moon"), "wh2_main_hef_farm_1")
    assert_not_in(W.trace_file, "reported no issued order")
end)

test("A charge with no issued event is still an order, and noted", function()
    new_world({ mkregion("moon", "p", { main = MAXED_MINOR, buildings = { false } }) })
    load()
    H.fire_ctx("BuildingConstructionIssued", { building_key = function() return "something_you_built" end })
    end_turn()
    eq(joined("moon"), "wh2_main_hef_farm_1")
    assert_in(W.trace_file, "charged 1000 gold but the game reported no issued order; trusting the treasury")
end)

test("A long upgrade isn't given up on while it could still be building", function()
    new_world({ mkregion("cap", "p", { capital = true, main = "wh2_main_hef_settlement_major_4", buildings = {} }) })
    load(); end_turn()                          -- level 5: 7-turn build
    eq(joined("cap"), "wh2_main_hef_settlement_major_5")
    W.queued = {}
    for _ = 1, 8 do end_turn() end              -- up to 9 turns: 7 + 2
    eq(#W.queued, 0)
end)

test("A finished building clears its order at once, and the next step follows", function()
    new_world({ mkregion("moon", "p", { main = MAXED_MINOR, buildings = { false } }) })
    load(); end_turn()
    H.region("moon").slots[2].b = "wh2_main_hef_farm_1"
    W.queued = {}
    end_turn()
    assert_not_in(W.trace_file, "never appeared")
    eq(joined("moon"), "wh2_main_hef_farm_2")
end)

test("Orders are remembered across save and load", function()
    new_world({ mkregion("moon", "p", { main = MAXED_MINOR, buildings = { false } }) })
    load(); end_turn()
    H.reload()
    W.queued = {}
    end_turn()
    eq(#W.queued, 0, "forgot its order and queued again")
end)

test("pending_timeout is a hard cap: a long build is given up on at the timeout even if it could still be building", function()
    new_world({ mkregion("cap", "p", { capital = true, main = "wh2_main_hef_settlement_major_4", buildings = {} }) })
    load({ pending_timeout = 3 }); end_turn()   -- level 5: 7-turn build, but a 3-turn timeout
    eq(joined("cap"), "wh2_main_hef_settlement_major_5")
    W.queued = {}
    end_turn(); end_turn()                      -- 1 and 2 turns old: still waiting
    eq(#W.queued, 0, "re-ordered before the timeout")
    end_turn()                                  -- 3 turns old: timed out
    eq(joined("cap"), "wh2_main_hef_settlement_major_5", "not re-ordered at the timeout")
end)

test("max_passes = 1: refunded gold is not re-spent in the same turn", function()
    new_world({
        mkregion("poor", "unrest", { po = -10, main = MAXED_MINOR, buildings = { false } }),
        mkregion("rich", "calm", { gdp = 500, main = MAXED_MINOR,
            buildings = { "wh2_main_hef_barracks_1", "wh2_main_hef_farm_1", "wh2_main_hef_industry_1" } }),
    }, 500)
    W.demolish_refund = 2500
    load({ max_passes = 1 }); end_turn()
    eq(#W.demolished, 1, "barracks not demolished")
    eq(#queued_in("poor"), 0, "a second pass ran")
end)

test("The most expensive cost seen is saved, and prices unknown buildings after a load", function()
    new_world({
        mkregion("a", "p", { main = MAXED_MINOR, buildings = { false } }),
        mkregion("b", "q", { main = MAXED_MINOR, buildings = { false } }),
    }, 3000)
    W.costs.wh2_main_hef_farm_1 = 3000
    load(); end_turn()
    eq(joined("a"), "wh2_main_hef_farm_1"); eq(#queued_in("b"), 0, "b should be short of gold")
    local saved = H.reload({ landmarks = { b = "wh2_main_hef_unknown_landmark_1" } })
    eq(saved["upgrade_all_v2_maxcost"], 3000, "max cost not saved")
    W.treasury = 2500
    W.queued = {}
    end_turn()
    -- An unknown key is priced at the saved maximum (3000), not the initial guess (1500).
    assert_in(W.trace_file, "wh2_main_hef_unknown_landmark_1 short of gold (3000 needed, 2500 left)")
    eq(#W.queued, 0)
end)

test("A new popup replaces one still open, without touching the dying name", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { false, false } }) }, 1000)
    load(); end_turn()
    local first = W.ui.comps["upgrade_all_popup_1"]
    assert(first, "no first popup")
    W.treasury = 1000
    end_turn()                                  -- OK never clicked on the first one
    assert(first.destroyed, "first popup left open")
    assert(W.ui.comps["upgrade_all_popup_2"], "second popup missing")
    eq(#W.dialogs, 2)
end)

test("Readable names from keys: the text after region_ / province_, underscores as spaces", function()
    new_world({ mkregion("wh3_main_combi_region_tor_yvresse", "wh3_main_combi_province_southern_yvresse",
        { main = MAXED_MINOR, buildings = { false } }) })
    load(); end_turn()
    assert_in(H.summary(), "southern yvresse: 1 new")
end)

test("Empty slots are explained once per turn in the trace: short of gold", function()
    new_world({ mkregion("moon", "p", { main = MAXED_MINOR, buildings = { false } }) }, 500)
    load(); end_turn()
    assert_in(W.trace_file, "moon: 1 empty slot(s) left: wh2_main_hef_farm_1 short of gold (1000 needed, 500 left)")
    eq(H.count(W.trace_file, "empty slot(s) left"), 1)
end)

test("Empty slots are explained: refused by the game", function()
    new_world({ mkregion("moon", "p", { main = MAXED_MINOR, buildings = { false } }) })
    W.invalid["wh2_main_hef_farm_1"] = true; W.invalid["wh2_main_hef_industry_1"] = true
    load(); end_turn()
    assert_in(W.trace_file, "wh2_main_hef_farm_1 refused by the game")
end)

test("Orders still in progress are listed as waiting", function()
    new_world({ mkregion("moon", "p", { main = MAXED_MINOR, buildings = { false } }) })
    load(); end_turn(); end_turn()
    assert_in(W.trace_file, "moon: waiting on new building(s): wh2_main_hef_farm_1 (ordered turn 1)")
end)

---------------------------------------------------------------------------
-- Trace file
---------------------------------------------------------------------------
local function big_empire()
    local regions = {}
    for n = 1, 150 do
        regions[n] = mkregion("r" .. n, "p" .. math.floor((n + 2) / 3), { capital = (n % 3 == 1), gdp = n,
            main = (n % 3 == 1) and GROWING_MAJOR or GROWING_MINOR,
            buildings = { "wh2_main_hef_barracks_1", false, "wh2_main_hef_industry_1" } })
    end
    new_world(regions, 50000)
end

test("Default trace keeps results and leaves out the per-region reading lines", function()
    big_empire(); load(); end_turn()
    for _, gone in ipairs({ "reading slots in", "reading province of region", "checking climate in", "reading commandment in", "queueing " }) do
        assert_not_in(W.trace_file, gone)
    end
    for _, kept in ipairs({ "end turn clicked", "work starting", "pass 1", "demolishing ", "done", "popup " }) do
        assert_in(W.trace_file, kept)
    end
end)

test("detailed_trace = true brings the reading lines back; the default is a fraction of its size", function()
    big_empire(); load(); end_turn()
    local quiet = H.count(W.trace_file, "\n")
    big_empire(); load({ detailed_trace = true }); end_turn()
    local loud = H.count(W.trace_file, "\n")
    for _, back in ipairs({ "reading slots in", "reading province of region", "reading commandment in", "queueing " }) do
        assert_in(W.trace_file, back)
    end
    assert(quiet * 3 < loud, quiet .. " vs " .. loud)
end)

test("The trace stops at its per-turn limit and starts again next turn", function()
    big_empire(); load({ detailed_trace = true, max_log_lines_per_turn = 50 }); end_turn()
    local first = H.count(W.trace_file, "\n")
    assert(first < 80, "limit ignored: " .. first)
    end_turn()
    assert(H.count(W.trace_file, "\n") > first, "didn't start again next turn")
end)

---------------------------------------------------------------------------
-- Settings: the UA button and province panel
---------------------------------------------------------------------------
local function ui_find(...) return find_uicomponent(W.root, ...) end
local function current_panel()
    for name, c in pairs(W.ui.comps) do
        if string.sub(name, 1, #"upgrade_all_settings_panel_") == "upgrade_all_settings_panel_" and not c.destroyed then return c end
    end
end
local function open_panel()
    H.click(ui_find("menu_bar", "buttongroup", "upgrade_all_settings_button"))
    return current_panel()
end
local function row_named(panel, text)
    for i = 1, 12 do
        local label = find_uicomponent(panel, "ua_settings_name_" .. i)
        if label and label.text and contains(label.text, text) then return find_uicomponent(panel, "ua_settings_check_" .. i), label end
    end
end
local function box_named(panel, text) return (row_named(panel, text)) end

local function settings_world(extra)
    local regions = {
        mkregion("lothern", "wh3_main_combi_province_eataine", { capital = true, gdp = 2000, main = GROWING_MAJOR, buildings = { false } }),
        mkregion("tor_yvresse", "wh3_main_combi_province_yvresse", { capital = true, gdp = 900, main = GROWING_MAJOR, buildings = { false } }),
        mkregion("elisia", "wh3_main_combi_province_chrace", { capital = true, gdp = 500, main = GROWING_MAJOR, buildings = { false } }),
    }
    for _, r in ipairs(extra or {}) do regions[#regions + 1] = r end
    new_world(regions)
    W.with_menu_bar = true
end
local function many_provinces()
    local extra = {}
    for n = 1, 27 do
        extra[n] = mkregion("x" .. n, "wh3_main_combi_province_p" .. string.format("%02d", n),
            { capital = true, main = GROWING_MAJOR, buildings = { false } })
    end
    return extra
end

test("A UA button appears just right of the search button, sized like it", function()
    settings_world(); load()
    local b = ui_find("menu_bar", "buttongroup", "upgrade_all_settings_button")
    local search = ui_find("menu_bar", "buttongroup", "button_search_panel")
    assert(b, "no button")
    eq(b.layout, "ui/templates/round_small_button")
    eq(b.w, 36); eq(b.h, 36)
    assert(b.x >= search.x + search.w, "covers the search button")
    eq(b.y, search.y)
    eq(search.x, 1120, "search button moved")
    assert(b.tip and contains(b.tip, "Upgrade All"), "no tooltip")
end)

test("The UA label is centred on the button", function()
    settings_world(); load()
    local b = ui_find("menu_bar", "buttongroup", "upgrade_all_settings_button")
    local label = find_uicomponent(b, "upgrade_all_settings_label")
    eq(label.dock, 5); eq(label.w, b.w)
    eq(label.children[1].text, "UA"); eq(label.children[1].dock, 5)
end)

test("The button isn't duplicated when the HUD reopens or turns pass", function()
    settings_world(); load()
    H.fire("PanelOpenedCampaign", "hud_campaign"); H.settle()
    end_turn(); end_turn()
    local n = 0
    for _, k in ipairs(ui_find("menu_bar", "buttongroup").children) do
        if k.name == "upgrade_all_settings_button" then n = n + 1 end
    end
    eq(n, 1)
end)

test("If the HUD is rebuilt without the button, it comes back", function()
    settings_world(); load()
    local group = ui_find("menu_bar", "buttongroup")
    for i, k in ipairs(group.children) do if k.name == "upgrade_all_settings_button" then table.remove(group.children, i) break end end
    H.fire("PanelOpenedCampaign", "hud_campaign"); H.settle()
    assert(ui_find("menu_bar", "buttongroup", "upgrade_all_settings_button"))
end)

test("The panel lists your provinces by on-screen name, sorted; Eataine is shown but locked", function()
    settings_world()
    W.loc = { provinces_onscreen_wh3_main_combi_province_chrace = "Chrace",
              provinces_onscreen_wh3_main_combi_province_eataine = "Eataine",
              provinces_onscreen_wh3_main_combi_province_yvresse = "Yvresse" }
    load()
    local p = open_panel()
    eq(find_uicomponent(p, "ua_settings_name_1").text, "Chrace")
    local eb, el = row_named(p, "Eataine")
    eq(el.text, "Eataine (always skipped)")
    eq(eb.state, "active"); eq(eb.disabled, true)
    eq(box_named(p, "Yvresse").state, "selected")
end)

test("Unchecking a province skips it: nothing built, and the summary lists it", function()
    settings_world(); load()
    local yb = box_named(open_panel(), "yvresse")
    H.click(yb)
    eq(yb.state, "active")
    end_turn()
    eq(#queued_in("tor_yvresse"), 0)
    assert(#queued_in("elisia") > 0, "other provinces stopped")
    assert_in(H.popup(), "Skipped (unchecked in settings): yvresse")
end)

test("Skipped provinces get no demolitions or commandment reminders either", function()
    new_world(grown_province()); W.with_menu_bar = true
    load()
    H.click(box_named(open_panel(), "yvresse"))
    end_turn()
    eq(#W.demolished, 0)
    assert_not_in(H.popup(), "Tribute")
end)

test("Checking it again brings it back", function()
    settings_world(); load()
    local yb = box_named(open_panel(), "yvresse")
    H.click(yb); H.click(yb)
    eq(yb.state, "selected")
    end_turn()
    assert(#queued_in("tor_yvresse") > 0)
end)

test("Choices are saved with the campaign and restored on load", function()
    settings_world(); load()
    H.click(box_named(open_panel(), "yvresse"))
    local saved = H.reload()
    eq(saved["upgrade_all_v2_skipped_provinces"], "wh3_main_combi_province_yvresse")
    end_turn()
    eq(#queued_in("tor_yvresse"), 0, "forgotten after load")
    eq(box_named(open_panel(), "yvresse").state, "active", "panel shows it managed")
end)

test("A checkbox click changes only that box: the panel isn't rebuilt", function()
    settings_world(); load()
    local p = open_panel()
    H.click(box_named(p, "yvresse"))
    assert(not p.destroyed, "panel rebuilt")
    eq(current_panel(), p)
end)

test("A duplicate click event toggles once, not twice", function()
    settings_world(); load()
    local yb = box_named(open_panel(), "yvresse")
    H.click(yb, 2)
    eq(yb.state, "active")
end)

test("Clicking the locked Eataine row changes nothing and saves nothing", function()
    settings_world(); load()
    local eb = box_named(open_panel(), "eataine")
    H.click(eb)
    eq(eb.state, "active")
    eq(H.save()["upgrade_all_v2_skipped_provinces"], "")
end)

test("Pages of 12: Next and Prev build a new panel under a fresh name", function()
    settings_world(many_provinces()); load()
    local p1 = open_panel()
    eq(find_uicomponent(p1, "ua_settings_prev").disabled, true)
    eq(find_uicomponent(p1, "ua_settings_page").children[1].text, "1 / 3")
    H.click(find_uicomponent(p1, "ua_settings_next"))
    local p2 = current_panel()
    assert(p2 and p2 ~= p1 and p1.destroyed, "page 2 not a fresh panel")
    eq(find_uicomponent(p2, "ua_settings_page").children[1].text, "2 / 3")
    H.click(find_uicomponent(p2, "ua_settings_next"))
    local p3 = current_panel()
    eq(find_uicomponent(p3, "ua_settings_next").disabled, true)
    assert(find_uicomponent(p3, "ua_settings_check_6") and not find_uicomponent(p3, "ua_settings_check_7"), "30 provinces: 6 on page 3")
    H.click(find_uicomponent(p3, "ua_settings_prev"))
    eq(find_uicomponent(current_panel(), "ua_settings_page").children[1].text, "2 / 3")
end)

test("Unchecking on page 2 skips the right province", function()
    settings_world(many_provinces()); load()
    H.click(find_uicomponent(open_panel(), "ua_settings_next"))
    H.click(box_named(current_panel(), "p15"))
    end_turn()
    eq(#queued_in("x15"), 0)
    assert(#queued_in("x14") > 0 and #queued_in("x16") > 0, "neighbours affected")
end)

test("Close and the UA button both close the panel", function()
    settings_world(); load()
    local p = open_panel()
    H.click(find_uicomponent(p, "ua_settings_close"))
    assert(p.destroyed)
    local p2 = open_panel()
    H.click(ui_find("menu_bar", "buttongroup", "upgrade_all_settings_button"))
    assert(p2.destroyed)
end)

test("Game buttons that happen to share a name are ignored", function()
    settings_world(); load()
    local p = open_panel()
    local stranger = H.mkcomp("ua_settings_close", H.mkcomp("some_game_panel"))
    H.click(stranger)
    assert(not p.destroyed)
end)

test("Province names and the hint are plain text, printed once, inset into the bar", function()
    settings_world(); load()
    local p = open_panel()
    local label = find_uicomponent(p, "ua_settings_name_2")
    eq(label.text, "eataine (always skipped)"); eq(label.halign, "left")
    eq(label.children[1].text, "", "printed a second time in the bar")
    assert((label.xoff or 0) >= 14, "starts before the bar")
    local hint = find_uicomponent(p, "ua_settings_hint")
    eq(hint.text, "Checked build automatically. Uncheck to skip")
    eq(hint.children[1].text, "")
end)

test("A non-text part inside a name label (the bar) is hidden", function()
    settings_world(); load()
    W.ui.extra_bar_child = true
    local label = find_uicomponent(open_panel(), "ua_settings_name_1")
    eq(find_uicomponent(label, "bar_image").visible, false)
    assert(label.children[1].visible ~= false, "text child hidden")
end)

test("Blue-bar text (title, Close, Prev, Next, page) is printed once and centred", function()
    settings_world(many_provinces()); load()
    local p = open_panel()
    for _, name in ipairs({ "ua_settings_close", "ua_settings_title", "ua_settings_prev", "ua_settings_next", "ua_settings_page" }) do
        local c = find_uicomponent(p, name)
        local txt = c.children[1]
        eq(c.text, "", name .. " printed twice")
        assert(txt.text and txt.text ~= "", name .. " has no text")
        eq(txt.w, c.w, name); eq(txt.h, c.h, name); eq(txt.dock, 5, name); eq(txt.halign, "centre", name)
    end
end)

test("The trace describes a name label once per session", function()
    settings_world(); load()
    open_panel()
    H.click(ui_find("menu_bar", "buttongroup", "upgrade_all_settings_button"))
    open_panel()
    eq(H.count(W.trace_file, "what a name label is made of"), 1)
end)

test("An error while building the panel stays inside the panel", function()
    settings_world(); load()
    W.region_list_error = true
    open_panel()
    assert_in(W.trace_file, "settings click")
    W.region_list_error = false
    end_turn()
    assert(#queued_in("tor_yvresse") > 0)
end)

test("A broken settings UI never affects building", function()
    settings_world(); W.ui.fail_settings = true
    load(); end_turn()
    assert(#queued_in("tor_yvresse") > 0)
end)

test("settings_button = false: no button and no click listener", function()
    settings_world(); load({ settings_button = false })
    eq(ui_find("menu_bar", "buttongroup", "upgrade_all_settings_button"), nil)
    for _, l in ipairs(W.listeners) do assert(l.name ~= "upgrade_all_settings_click") end
end)

test("No settings button for other cultures", function()
    settings_world(); W.culture = "wh_main_emp_empire"
    load()
    eq(ui_find("menu_bar", "buttongroup", "upgrade_all_settings_button"), nil)
end)

---------------------------------------------------------------------------
-- Dark Elves
---------------------------------------------------------------------------
local DEF_MAJOR_MAX, DEF_MINOR_MAX = H.DEF_MAJOR_MAX, H.DEF_MINOR_MAX
local function def_world(regions, home)
    new_world(regions)
    W.culture = "wh2_main_def_dark_elves"; W.player = "wh2_main_def_naggarond"; W.home = home or "nowhere"
end

test("Dark Elf capital layout in order (Manors, Torture Posts, Slave Pens, Slave Gate, Artisan's House, Tunnels, Altar, Sorceress)", function()
    def_world({
        mkregion("cap", "p", { capital = true, gdp = 900, main = "wh2_main_def_settlement_major_4",
            buildings = { false, false, false, false, false, false, false, false } }),
        mkregion("mn", "p", { main = "wh2_main_def_settlement_minor_1", buildings = {} }),   -- still growing
    })
    load(); end_turn()
    eq(joined("cap"), "wh2_main_def_settlement_major_5,wh2_main_def_farm_1,wh2_main_def_order_1,wh2_main_def_slaves_1,"
        .. "wh2_main_def_defence_major_1,wh2_main_def_industry_1,wh2_main_foreign_slot_discovery_def_1,"
        .. "wh2_main_def_worship_1,wh2_main_def_sorcery_1")
end)

test("Dark Elf minor layout: Manors, Artisan's House, resource, Watchtowers, Tunnels", function()
    def_world({ mkregion("mn", "p", { main = DEF_MINOR_MAX, resource = "res_rom_marble", resource_slot = 3,
        buildings = { false, false, false, false, false } }) })
    load(); end_turn()
    eq(joined("mn"), "wh2_main_def_farm_1,wh2_main_def_industry_1,wh2_main_def_resource_marble_1,"
        .. "wh2_main_def_defence_minor_1,wh2_main_foreign_slot_discovery_def_1")
end)

---------------------------------------------------------------------------
-- Layouts derived from roles (C3): must equal the hand-written lists
---------------------------------------------------------------------------
local HEF_CAPITAL = "wh2_main_hef_farm, wh2_main_hef_order, wh2_main_hef_court, wh2_main_hef_defence_major, RESOURCE, "
    .. "wh2_main_hef_industry, LANDMARK, wh2_main_foreign_slot_discovery_hef, wh2_main_hef_embassy, wh2_main_hef_dragons"
local HEF_MINOR = "wh2_main_hef_farm, wh2_main_hef_industry, RESOURCE, wh2_main_hef_defence_minor, wh2_main_foreign_slot_discovery_hef"
local HEF_SLOW = "wh2_main_hef_farm, wh2_main_foreign_slot_discovery_hef, RESOURCE, wh2_main_hef_defence_minor, wh2_main_hef_industry"
local DEF_CAPITAL = "wh2_main_def_farm, wh2_main_def_order, wh2_main_def_slaves, wh2_main_def_defence_major, RESOURCE, "
    .. "wh2_main_def_industry, LANDMARK, wh2_main_foreign_slot_discovery_def, wh2_main_def_worship, wh2_main_def_sorcery"
local DEF_MINOR = "wh2_main_def_farm, wh2_main_def_industry, RESOURCE, wh2_main_def_defence_minor, wh2_main_foreign_slot_discovery_def"
local DEF_SLOW = "wh2_main_def_farm, wh2_main_foreign_slot_discovery_def, RESOURCE, wh2_main_def_defence_minor, wh2_main_def_industry"

test("High Elf layouts derived from the data equal the previous hand-written lists, and the trace says so", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { false } }) })
    load()
    assert_in(W.trace_file, "layout capital: derived from roles, same as before (" .. HEF_CAPITAL .. ")")
    assert_in(W.trace_file, "layout minor: derived from roles, same as before (" .. HEF_MINOR .. ")")
    assert_in(W.trace_file, "layout slow_minor: derived from roles, same as before (" .. HEF_SLOW .. ")")
    assert_not_in(W.trace_file, "CHANGED")
    assert_not_in(W.trace_file, "more than one chain")
end)

test("Dark Elf layouts derived from the data equal the previous hand-written lists", function()
    def_world({ mkregion("mn", "p", { main = DEF_MINOR_MAX, buildings = { false } }) })
    load()
    assert_in(W.trace_file, "layout capital: derived from roles, same as before (" .. DEF_CAPITAL .. ")")
    assert_in(W.trace_file, "layout minor: derived from roles, same as before (" .. DEF_MINOR .. ")")
    assert_in(W.trace_file, "layout slow_minor: derived from roles, same as before (" .. DEF_SLOW .. ")")
    assert_not_in(W.trace_file, "CHANGED")
end)

test("The layout report is repeated every turn, so it is always in the trimmed trace", function()
    new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { false } }) })
    load(); end_turn(); end_turn()
    eq(H.count(W.trace_file, "layout capital: derived from roles"), 3, "load + 2 turns")
end)

test("A roles_override changes the derived layout, the trace says CHANGED with before and after, and the override is built", function()
    new_world({ mkregion("cap", "p", { capital = true, gdp = 900, main = MAXED_MAJOR, buildings = { false, false } }) })
    load({ roles_override = { order = "wh2_main_hef_mages" } }); end_turn()
    assert_in(W.trace_file, "layout capital CHANGED: now wh2_main_hef_farm, wh2_main_hef_mages, wh2_main_hef_court")
    assert_in(W.trace_file, "; before " .. HEF_CAPITAL)
    assert_in(W.trace_file, "layout minor: derived from roles, same as before")
    eq(joined("cap"), "wh2_main_hef_mages_1,wh2_main_hef_court_1")  -- fully grown: no Homestead
end)

test("Dark Elf slow-build minors swap Artisan's House and City Tunnels", function()
    def_world({ mkregion("mn", "p", { main = DEF_MINOR_MAX, bundles = { wh2_main_climate_uninhabitable = true }, buildings = { false, false } }) })
    load(); end_turn()
    eq(joined("mn"), "wh2_main_def_farm_1,wh2_main_foreign_slot_discovery_def_1")
end)

test("Dark Elf resources map to Dark Elf buildings (oil -> pasture, lead -> salt)", function()
    def_world({
        mkregion("a", "p1", { main = DEF_MINOR_MAX, resource = "res_rom_oil", resource_slot = 3, buildings = { "wh2_main_def_farm_1", "wh2_main_def_industry_1", false } }),
        mkregion("b", "p2", { main = DEF_MINOR_MAX, resource = "res_rom_lead", resource_slot = 3, buildings = { "wh2_main_def_farm_1", "wh2_main_def_industry_1", false } }),
    })
    load(); end_turn()
    assert(has(queued_in("a"), "wh2_main_def_resource_pasture_1"), joined("a"))
    assert(has(queued_in("b"), "wh2_main_def_resource_salt_1"), joined("b"))
end)

test("The lord's starting province is never touched", function()
    def_world({
        mkregion("naggarond", "wh3_main_combi_province_naggaroth", { capital = true, gdp = 5000, main = "wh2_main_def_settlement_major_3", buildings = { false, false } }),
        mkregion("other", "wh3_main_combi_province_the_black_flood", { capital = true, gdp = 100, main = "wh2_main_def_settlement_major_3", buildings = { false } }),
    }, "naggarond")
    load(); end_turn()
    eq(#queued_in("naggarond"), 0)
    assert(#queued_in("other") > 0)
    assert_in(W.trace_file, "starting province (never touched): wh3_main_combi_province_naggaroth")
end)

test("The starting province is remembered in the save, even after the capital moves", function()
    def_world({
        mkregion("naggarond", "wh3_main_combi_province_naggaroth", { capital = true, main = "wh2_main_def_settlement_major_3", buildings = { false } }),
        mkregion("other", "wh3_main_combi_province_the_black_flood", { capital = true, main = "wh2_main_def_settlement_major_3", buildings = { false } }),
    }, "naggarond")
    load()
    W.home = "other"
    local saved = H.reload()
    eq(saved["upgrade_all_v2_starting_province"], "wh3_main_combi_province_naggaroth")
    end_turn()
    eq(#queued_in("naggarond"), 0, "original starting province touched")
    assert(#queued_in("other") > 0, "new capital province wrongly protected")
end)

test("No home region at all: nothing is protected, and the trace says so", function()
    def_world({ mkregion("x", "p", { capital = true, main = "wh2_main_def_settlement_major_3", buildings = { false } }) })
    load(); end_turn()
    assert(#queued_in("x") > 0)
    assert_in(W.trace_file, "starting province (never touched): none found")
end)

-- silent_sanctum_def_boost_0: "def" here means defence; it belongs to another
-- culture and only the wrong-culture list stops it (level 2, so it fits a minor).
for _, key in ipairs({ "wh2_main_hef_court_1", "wh2_dlc09_tmb_defence_major_1", "wh2_dlc17_silent_sanctum_def_boost_0" }) do
    test("Crash guard: Dark Elves never queue " .. key, function()
        def_world({ mkregion("mn", "p", { main = DEF_MINOR_MAX, buildings = { "wh2_main_def_farm_1", false } }) })
        load({ landmarks = { mn = key } }); end_turn()
        for _, q in ipairs(W.queued) do assert(q.key ~= key, "queued " .. key) end
    end)
end

test("Shrine of Khaine: Dark Elves build the Dark Elf version", function()
    def_world({ mkregion("shrine", "p", { main = DEF_MINOR_MAX, template = "wh2_main_special_shrine_of_khaine_secondary",
        buildings = { "wh2_main_def_farm_1", false } }) })
    load(); end_turn()
    assert(has(queued_in("shrine"), "wh2_main_special_shrine_of_khaine_def_base"), joined("shrine"))
end)

test("Tor Anroc: Dark Elves pick the Dark Elf palace (level 5 capital)", function()
    def_world({ mkregion("anroc", "p", { capital = true, main = DEF_MAJOR_MAX, template = "wh2_main_special_tor_anroc_secondary",
        buildings = { "wh2_main_def_order_1", false } }) })
    load(); end_turn()
    assert(has(queued_in("anroc"), "wh2_main_special_tiranoc_palace_def"), joined("anroc"))
end)

test("Enforce Tribute Payments reminder in fully grown Dark Elf provinces", function()
    def_world({
        mkregion("cap", "wh3_main_combi_province_the_road_of_skulls", { capital = true, gdp = 900, main = DEF_MAJOR_MAX, edict = "something_else",
            buildings = { "wh2_main_def_order_1" } }),
        mkregion("mn", "wh3_main_combi_province_the_road_of_skulls", { main = DEF_MINOR_MAX, buildings = { "wh2_main_def_industry_1" } }),
    })
    W.loc = { provinces_onscreen_wh3_main_combi_province_the_road_of_skulls = "The Road of Skulls" }
    load(); end_turn()
    assert_in(H.popup(), "Set Enforce Tribute Payments in: The Road of Skulls")
    assert_not_in(H.popup(), "Phoenix King")
end)

test("No reminder where Enforce Tribute Payments is already set", function()
    def_world({ mkregion("cap", "p", { capital = true, main = DEF_MAJOR_MAX, edict = H.ENFORCE, buildings = { "wh2_main_def_order_1" } }) })
    load(); end_turn()
    assert_not_in(H.popup(), "Enforce Tribute")
end)

test("Dark Elves: no Banish warning, and corruption is never read", function()
    def_world({ mkregion("cap", "p", { capital = true, main = DEF_MAJOR_MAX, edict = H.BANISH, buildings = { "wh2_main_def_order_1" } }) })
    load(); end_turn()
    assert_not_in(H.popup(), "Banish")
    eq(W.corruption_reads or 0, 0)
end)

test("Dark Elves: once a province is fully grown, Manors make way for the next item", function()
    def_world({ mkregion("cap", "p", { capital = true, main = DEF_MAJOR_MAX, buildings = { "wh2_main_def_farm_3", "wh2_main_def_order_1" } }) })
    load(); end_turn()
    assert(has(W.demolished, "wh2_main_def_farm_3"))
end)

test("Dark Elves: Cult of Pleasure and House of Assassins buildings are never demolished", function()
    def_world({ mkregion("mn", "p", { main = DEF_MINOR_MAX,
        buildings = { "wh2_main_def_pleasure_cult_1", "wh2_main_def_murder_1", false, false } }) })
    load(); end_turn()
    eq(#W.demolished, 0, table.concat(W.demolished, ","))
end)

test("Dark Elves: an ordinary building outside the layout is demolished to make room", function()
    def_world({ mkregion("mn", "p", { main = DEF_MINOR_MAX, buildings = { "wh2_main_def_barracks_1" } }) })
    load(); end_turn()
    eq(table.concat(W.demolished, ","), "wh2_main_def_barracks_1")
    eq(joined("mn"), "wh2_main_def_farm_1")
end)

test("Dark Elves: the settings panel locks the starting province and skipping works", function()
    def_world({
        mkregion("naggarond", "wh3_main_combi_province_naggaroth", { capital = true, main = "wh2_main_def_settlement_major_3", buildings = { false } }),
        mkregion("other", "wh3_main_combi_province_the_black_flood", { capital = true, main = "wh2_main_def_settlement_major_3", buildings = { false } }),
    }, "naggarond")
    W.with_menu_bar = true
    W.loc = { provinces_onscreen_wh3_main_combi_province_naggaroth = "Naggaroth",
              provinces_onscreen_wh3_main_combi_province_the_black_flood = "The Black Flood" }
    load()
    local p = open_panel()
    local _, label = row_named(p, "Naggaroth")
    assert(label and contains(label.text, "always skipped"), "starting province not locked")
    H.click(box_named(p, "The Black Flood"))
    end_turn()
    eq(#W.queued, 0)
    assert_in(H.popup(), "Skipped (unchecked in settings): The Black Flood")
end)

H.finish_later = true

H.finish()
