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

test("Never calls string.find, gsub or gmatch (they crashed the game) across a busy turn", function()
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

for _, key in ipairs({ "wh2_main_def_order_1", "wh2_dlc09_tmb_defence_major_1" }) do
    test("Crash guard: High Elves never queue " .. key .. ", even when configured by hand", function()
        new_world({ mkregion("mn", "p", { main = MAXED_MINOR, buildings = { "wh2_main_hef_farm_1", false } }) })
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
        mkregion("cap", "p", { capital = true, gdp = 900, main = GROWING_MAJOR,
            buildings = { false, false, false, false, false, false, false, false } }),
        mkregion("mn", "p", { main = GROWING_MINOR, buildings = {} }),
    })
    load(); end_turn()
    eq(joined("cap"), "wh2_main_hef_settlement_major_4,wh2_main_hef_farm_1,wh2_main_hef_order_1,wh2_main_hef_court_1,"
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
    W.upgrades = { wh2_main_special_settlement_gaean_vale_3 = {} }
    load(); end_turn()
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
    new_world({ mkregion("anroc", "p", { main = MAXED_MINOR, template = "wh2_main_special_tor_anroc_secondary",
        buildings = { "wh2_main_hef_farm_1", false } }) })
    W.invalid["wh2_main_special_tiranoc_palace"] = true
    load(); end_turn(); end_turn(); end_turn()
    for _, q in ipairs(W.queued) do assert(q.key ~= "wh2_main_special_tiranoc_palace_def", "queued the Dark Elf palace") end
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

H.finish_later = true

H.finish()
