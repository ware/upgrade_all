--[[
    Upgrade All — empire builder for Total War: Warhammer III
    (High Elves and Dark Elves)

    When you click End Turn, spends the gold you didn't use (down to a floor) on:
      1. Main settlement upgrades,
      2. New buildings in empty slots, following your capital / minor layouts,
      3. Upgrades to existing buildings: income first, then growth, then the rest.
    Provinces are worked in this order: worst public order first (while it's
    negative), then highest income to lowest, then provinces with no income.

    One province is never touched: Eataine for High Elves, the lord's starting
    province for Dark Elves. Aislinn's colonies get upgrades only. Buildings
    with more than one upgrade path are left for you. A summary pops up at the
    start of your next turn.

    Single-player only. Edit CONFIG below, then rebuild the .pack in RPFM.

    Copyright (C) 2026 Ryan Ware

    This program is free software; you can redistribute it and/or modify it
    under the terms of the GNU General Public License, version 2 only, as
    published by the Free Software Foundation. It is distributed WITHOUT ANY
    WARRANTY; see the LICENSE file in the source repository for details.
]]

local CONFIG = {
    -- Test mode only surveys your settlements and builds nothing.
    -- Set to false to go live.
    test_mode           = false,
    -- Which diagnostic steps test mode runs (all at once, one popup at the end):
    --   1 = read building slots, 2 = region climate, 3 = province climate, 4 = names
    test_steps          = { 1, 2, 3, 4 },

    -- When to build: "turn_end" (when you click End Turn, using whatever gold
    -- you didn't spend) or "turn_start" (2 seconds into each turn).
    run_at              = "turn_end",
    -- Write a breadcrumb before every slot call (slow; for finding crashes).
    trace_slot_calls    = false,

    gold_floor          = 0,     -- never spend the treasury below this
    max_queued_per_turn = 2000,  -- safety cap on construction orders per turn
    max_passes          = 5,     -- repeat passes so refunded gold gets spent too
    max_log_lines_per_turn = 20000, -- trace file limit; resets every turn
    initial_cost_guess  = 1500,  -- assumed cost until a real one has been seen
    pending_timeout     = 15,    -- turns to wait on a queued building before retrying that slot
    -- Each turn's summary is written to upgrade_all_summary.txt, and shown in a
    -- popup at the end of End Turn. Set popup = false if the popup causes trouble.
    popup               = true,
    log                 = true,  -- script log output
    -- Extra trace lines for every region, slot and commandment read. Off by
    -- default (the trace gets very long); turn on to find where a crash happens.
    detailed_trace      = false,

    -- A "UA" button in the top menu bar to choose which provinces are managed.
    settings_button     = true,

    -- High Elves: provinces whose key contains this text are never touched.
    -- (Dark Elves: the lord's starting province is never touched, found
    -- automatically when the mod first runs in a campaign.)
    protected_province  = "eataine",

    -- Minor settlements with doubled build times swap Elven Craftsman and City
    -- Tunnels. These are found automatically from uninhabitable-climate effects;
    -- list extra provinces here (text matched against the province key) if needed.
    slow_provinces      = {},

    -- Landmark for each region: region key -> landmark building key. It must be
    -- one of your culture's buildings or a landmark from the game data; anything
    -- else is refused by the crash guard.
    landmarks           = {},

    -- Demolish buildings that don't belong in a settlement's slots (not in its
    -- layout, or ranked too low to fit), except the item right after the next
    -- one to build. Never touches landmarks/special buildings, the main
    -- settlement, ports, or anything under construction.
    allow_demolish      = true,

    -- Internal key of the "Tribute to the Phoenix King" commandment. When set,
    -- the summary lists fully grown provinces that don't have it active.
    -- Set to nil to turn the reminder off (commandments are then never read).
    phoenix_tribute_key = "wh2_main_edict_hef_tribute_for_the_king",

    -- Internal key of the "Banish Corruption" commandment. When set, the
    -- summary warns about provinces still using it with no corruption left.
    -- Set to nil to turn the warning off (corruption is then never read).
    banish_corruption_key = "wh2_main_edict_hef_banish_corruption",

    -- Dark Elves: internal key of the "Enforce Tribute Payments" commandment,
    -- reminded in fully grown provinces like Tribute is for High Elves.
    enforce_tribute_key = "wh2_main_edict_def_enforce_tribute",
}

if UPGRADE_ALL_CONFIG_OVERRIDE then -- test hook; never set in the game
    for k, v in pairs(UPGRADE_ALL_CONFIG_OVERRIDE) do CONFIG[k] = v end
end

-- Substring test in plain Lua (string.sub only). string.find did not behave
-- as expected inside the game, so nothing here uses the pattern functions
-- (find, match, gsub, gmatch).
local function contains(hay, needle)
    if type(hay) ~= "string" or type(needle) ~= "string" then return false end
    local n, h = #needle, #hay
    if n == 0 then return true end
    for i = 1, h - n + 1 do
        if string.sub(hay, i, i + n - 1) == needle then return true end
    end
    return false
end

-- Everything after the first occurrence of `marker` (nil if absent or nothing
-- follows it). Plain Lua, no patterns.
local function after(text, marker)
    if type(text) ~= "string" or type(marker) ~= "string" then return nil end
    local n = #marker
    for i = 1, #text - n + 1 do
        if string.sub(text, i, i + n - 1) == marker then
            local rest = string.sub(text, i + n)
            if rest ~= "" then return rest end
            return nil
        end
    end
    return nil
end

-- Splits on a single-character separator (plain Lua, no patterns).
local function split(text, sep)
    local parts, start = {}, 1
    if type(text) ~= "string" or text == "" then return parts end
    for i = 1, #text do
        if string.sub(text, i, i) == sep then
            if i > start then parts[#parts + 1] = string.sub(text, start, i - 1) end
            start = i + 1
        end
    end
    if start <= #text then parts[#parts + 1] = string.sub(text, start) end
    return parts
end

-- "chain_12" -> "chain"; leaves keys without a numeric suffix alone.
local function strip_level(key)
    local i = #key
    while i > 0 and string.sub(key, i, i) >= "0" and string.sub(key, i, i) <= "9" do i = i - 1 end
    if i < #key and i > 0 and string.sub(key, i, i) == "_" then return string.sub(key, 1, i - 1) end
    return key
end

-- Replaces every "_" with a space.
local function underscores_to_spaces(text)
    local out = {}
    for i = 1, #text do
        local c = string.sub(text, i, i)
        out[i] = (c == "_") and " " or c
    end
    return table.concat(out)
end

-- Rules for each culture the mod builds for. Layouts: "RESOURCE" and
-- "LANDMARK" are resolved per region. `tag` is the culture's word in building
-- keys ("_hef_"), which the crash guard requires as a whole word.
local CULTURE_RULES = {
    wh2_main_hef_high_elves = {
        tag = "hef", name = "High Elves", adj = "High Elf",
        farm = "wh2_main_hef_farm",                                  -- Homestead
        capital = { "wh2_main_hef_farm",                             -- Homestead
                    "wh2_main_hef_order",                            -- Plaza
                    "wh2_main_hef_court",                            -- Elven Gardens
                    "wh2_main_hef_defence_major",                    -- Stone Walls
                    "RESOURCE",
                    "wh2_main_hef_industry",                         -- Elven Craftsman
                    "LANDMARK",
                    "wh2_main_foreign_slot_discovery_hef",           -- City Tunnels
                    "wh2_main_hef_embassy",                          -- Elven Embassy
                    "wh2_main_hef_dragons" },                        -- Dragon's Lair
        minor = { "wh2_main_hef_farm", "wh2_main_hef_industry", "RESOURCE",
                  "wh2_main_hef_defence_minor",                      -- Watchtower
                  "wh2_main_foreign_slot_discovery_hef" },
        slow_minor = { "wh2_main_hef_farm", "wh2_main_foreign_slot_discovery_hef", "RESOURCE",
                       "wh2_main_hef_defence_minor", "wh2_main_hef_industry" },
        tribute_key = CONFIG.phoenix_tribute_key, tribute_name = "Tribute to the Phoenix King",
        banish_key = CONFIG.banish_corruption_key,
        protect = "config",       -- CONFIG.protected_province (Eataine)
    },
    wh2_main_def_dark_elves = {
        tag = "def", name = "Dark Elves", adj = "Dark Elf",
        farm = "wh2_main_def_farm",                                  -- Dark Elf Manors
        capital = { "wh2_main_def_farm",                             -- Dark Elf Manors
                    "wh2_main_def_order",                            -- Torture Posts
                    "wh2_main_def_slaves",                           -- Slave Pens
                    "wh2_main_def_defence_major",                    -- Slave Gate (walls)
                    "RESOURCE",
                    "wh2_main_def_industry",                         -- Artisan's House
                    "LANDMARK",
                    "wh2_main_foreign_slot_discovery_def",           -- City Tunnels
                    "wh2_main_def_worship",                          -- Altar of Khaine
                    "wh2_main_def_sorcery" },                        -- Sorceress' Abode
        minor = { "wh2_main_def_farm", "wh2_main_def_industry", "RESOURCE",
                  "wh2_main_def_defence_minor",                      -- Watchtowers
                  "wh2_main_foreign_slot_discovery_def" },
        slow_minor = { "wh2_main_def_farm", "wh2_main_foreign_slot_discovery_def", "RESOURCE",
                       "wh2_main_def_defence_minor", "wh2_main_def_industry" },
        tribute_key = CONFIG.enforce_tribute_key, tribute_name = "Enforce Tribute Payments",
        banish_key = nil,
        protect = "start",        -- the lord's starting province
    },
}
-- The rules in use (set when the campaign loads; High Elves until then).
local RULES = CULTURE_RULES.wh2_main_hef_high_elves
local FARM, LAYOUT_CAPITAL, LAYOUT_MINOR, LAYOUT_SLOW_MINOR
local PROTECTED = CONFIG.protected_province  -- text matched against province keys
local starting_province = ""                 -- Dark Elves: saved with the campaign

-- A culture tag as a whole word: "_def_" or a trailing "_def". (A plain "def"
-- would also match other races' "defence" buildings, which crash the game.)
local function has_tag(key, tag)
    if type(key) ~= "string" then return false end
    local t = "_" .. tag
    return contains(key, t .. "_") or string.sub(key, -#t) == t
end
local function other_culture_key(key)
    for _, r in pairs(CULTURE_RULES) do
        if r ~= RULES and has_tag(key, r.tag) then return true end
    end
    return false
end

-- Every race's tag (the same list as tools/gen_data.py). A key with none of
-- these is culture-neutral: an "_other" landmark variant, a special port...
local CULTURE_TAGS = { "hef", "def", "dwf", "nor", "emp", "grn", "vmp", "tmb", "skv", "lzd", "wef", "brt", "chs",
                       "kho", "nur", "sla", "tze", "dae", "ogr", "ksl", "cth", "chd", "cst", "woc", "nag", "bst", "kul", "den" }
local function any_culture_tag(key)
    for _, t in ipairs(CULTURE_TAGS) do if has_tag(key, t) then return true end end
    return false
end

-- NEVER queue a building from another culture: the game crashes instead of
-- rejecting it. Only the player's culture's keys and vetted landmarks reach the queue.

local MOD = "[UpgradeAll]"
local SAVE_KEY = "upgrade_all_v2"

local pending = {}           -- slot id -> { target, turn }
local refused_landmarks = {} -- "region|landmark" -> true: the game refused it there
local skipped_provinces = {} -- lower-case province key -> true: unchecked in the settings panel
-- The player's faction and culture (set when the campaign loads).
local HIGH_ELVES = "wh2_main_hef_high_elves"
local PLAYER = { faction = "", culture = HIGH_ELVES, sub = "wh2_main_sc_hef_high_elves" }
local max_cost_seen = CONFIG.initial_cost_guess
local stored_summary = ""    -- shown at the next turn start

local trace -- defined below; log() writes to the same file
local function log(msg) if CONFIG.log and trace then trace(msg) end end
-- Step-by-step reading lines: only with detailed_trace = true (for chasing a crash).
local function detail(msg) if CONFIG.detailed_trace and trace then trace(msg) end end

-- Where the log files go: the game's working folder, plus, on a Mac, your home
-- folder (the Mac port didn't produce files in its working folder).
local OUTPUT_DIRS = { "" }
pcall(function()
    local home = os.getenv("HOME")
    if type(home) == "string" and string.sub(home, 1, 7) == "/Users/" then
        OUTPUT_DIRS[#OUTPUT_DIRS + 1] = home .. "/"
    end
end)
local function each_output(name, fn)
    for _, dir in ipairs(OUTPUT_DIRS) do pcall(fn, dir .. name) end
end

-- Crash breadcrumbs: each step is appended to a small file. If the game dies
-- mid-step, the last line shows where. Best effort; ignored if io fails.
local TRACE_FILE = "upgrade_all_trace.txt"
local trace_lines = 0
function trace(step) -- assigns the local declared above
    if trace_lines > CONFIG.max_log_lines_per_turn then return end -- keep each turn's log a sane size
    trace_lines = trace_lines + 1
    local line
    pcall(function()
        line = string.format("[%s t%s %.2f] %s\n", os.date("%H:%M:%S"), tostring(cm:turn_number()), os.clock(), step)
    end)
    if not line then return end
    each_output(TRACE_FILE, function(path)
        local f = io.open(path, "a")
        if f then f:write(line); f:close() end
    end)
end

---------------------------------------------------------------------------
-- Summary file (no popups: game dialogs crashed the game on Windows)
---------------------------------------------------------------------------
local SUMMARY_FILE = "upgrade_all_summary.txt"

-- Writes the latest summary to a text file (overwritten each turn).
local last_summary = ""
local function write_summary(text)
    last_summary = text or ""
    local body
    pcall(function()
        body = string.format("Turn %s  (%s)\n\n%s\n", tostring(cm:turn_number()), os.date("%Y-%m-%d %H:%M"), text)
    end)
    if not body then return end
    each_output(SUMMARY_FILE, function(path)
        local f = io.open(path, "w")
        if f then f:write(body); f:close() end
    end)
end

---------------------------------------------------------------------------
-- Summary popup, shown a moment after your next turn starts.
-- Lessons from earlier testing: no LockPriority / RegisterTopMost, a fresh
-- name every time, only react to OK inside our own popup, and any failure is
-- logged and ignored (the summary file is always written first).
---------------------------------------------------------------------------
local popup_seq = 0
local open_popup = nil

local function destroy_popup(name)
    trace("popup " .. name .. ": closing")
    pcall(function()
        local box = find_uicomponent(core:get_ui_root(), name)
        if box then box:Destroy() end
    end)
    if open_popup == name then open_popup = nil end
end

local function show_popup(text)
    if open_popup then
        core:remove_listener("upgrade_all_popup_close")
        destroy_popup(open_popup)
    end
    local ok, err = pcall(function()
        popup_seq = popup_seq + 1
        local name = "upgrade_all_popup_" .. popup_seq
        trace("popup " .. name .. ": creating")
        local box = core:get_or_create_component(name, "ui/common ui/dialogue_box")
        open_popup = name
        trace("popup " .. name .. ": created")
        box:SetVisible(true)
        local t = find_uicomponent(box, "DY_text")
        if t then t:SetStateText(text) end
        local both, okg = find_uicomponent(box, "both_group"), find_uicomponent(box, "ok_group")
        if both and okg then both:SetVisible(false); okg:SetVisible(true) end
        core:remove_listener("upgrade_all_popup_close")
        core:add_listener("upgrade_all_popup_close", "ComponentLClickUp",
            function(c)
                if c.string ~= "button_tick" and c.string ~= "button_cancel" then return false end
                local ok2, inside = pcall(function() return uicomponent_descended_from(UIComponent(c.component), name) end)
                return ok2 and inside == true
            end,
            function() cm:callback(function() destroy_popup(name) end, 0.1) end,
            false)
        trace("popup " .. name .. ": shown")
    end)
    if not ok then trace("popup failed: " .. tostring(err)) end
end

---------------------------------------------------------------------------
-- Save / load
---------------------------------------------------------------------------
local function serialize_pending()
    local parts = {}
    for id, p in pairs(pending) do parts[#parts + 1] = id .. "=" .. p.target .. "=" .. p.turn end
    return table.concat(parts, "|")
end
local function deserialize_pending(s)
    local t = {}
    for _, e in ipairs(split(s or "", "|")) do
        local f = split(e, "=")
        if #f == 3 and tonumber(f[3]) then t[f[1]] = { target = f[2], turn = tonumber(f[3]) } end
    end
    return t
end

cm:add_saving_game_callback(function(context)
    cm:save_named_value(SAVE_KEY .. "_pending", serialize_pending(), context)
    cm:save_named_value(SAVE_KEY .. "_maxcost", max_cost_seen, context)
    cm:save_named_value(SAVE_KEY .. "_summary", stored_summary, context)
    local parts = {}
    for k in pairs(refused_landmarks) do parts[#parts + 1] = k end
    cm:save_named_value(SAVE_KEY .. "_refused_landmarks", table.concat(parts, ","), context)
    local skipped = {}
    for k in pairs(skipped_provinces) do skipped[#skipped + 1] = k end
    table.sort(skipped)
    cm:save_named_value(SAVE_KEY .. "_skipped_provinces", table.concat(skipped, ","), context)
    cm:save_named_value(SAVE_KEY .. "_starting_province", starting_province, context)
end)
cm:add_loading_game_callback(function(context)
    pending = deserialize_pending(cm:load_named_value(SAVE_KEY .. "_pending", "", context))
    max_cost_seen = cm:load_named_value(SAVE_KEY .. "_maxcost", CONFIG.initial_cost_guess, context)
    stored_summary = cm:load_named_value(SAVE_KEY .. "_summary", "", context)
    refused_landmarks = {}
    for _, k in ipairs(split(cm:load_named_value(SAVE_KEY .. "_refused_landmarks", "", context) or "", ",")) do
        refused_landmarks[k] = true
    end
    skipped_provinces = {}
    for _, k in ipairs(split(cm:load_named_value(SAVE_KEY .. "_skipped_provinces", "", context) or "", ",")) do
        skipped_provinces[k] = true
    end
    starting_province = cm:load_named_value(SAVE_KEY .. "_starting_province", "", context) or ""
end)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function chain_of(key)
    if not key then return nil end
    return UA_DATA.chain[key] or strip_level(key)
end

local function score(key)
    local s = UA_DATA.score[key]
    return s and s[1] or 0, s and s[2] or 0, s and s[3] or 0
end

-- The next level of each building according to the game data: "chain_2" ->
-- "chain_3". Built once. Levels with several keys (branching chains such as
-- the dragonship's _3a/_3b) are left out: those are the multi-path buildings
-- the mod never chooses for you.
local NEXT_LEVEL = {}
do
    local by_chain = {}  -- chain -> level -> key (false = more than one key)
    for key, t in pairs(UA_DATA.tier) do
        local c = UA_DATA.chain[key]
        if c then
            by_chain[c] = by_chain[c] or {}
            by_chain[c][t[1]] = (by_chain[c][t[1]] == nil) and key or false
        end
    end
    for key, t in pairs(UA_DATA.tier) do
        local c = UA_DATA.chain[key]
        local nxt = c and by_chain[c][t[1] + 1]
        if nxt and by_chain[c][t[1]] ~= false then NEXT_LEVEL[key] = nxt end
    end
end

-- The one upgrade a building can take, or nil if it has none or several.
-- The game's own list is used first. If it lists nothing for a building that
-- the data says isn't at its top level, the data's next level is tried
-- instead: if the game really can't build it, it refuses at no cost.
local function single_upgrade(key)
    local ups = cm:get_building_level_upgrades(key)
    local found, count = nil, 0
    if type(ups) == "table" then
        for _, k in pairs(ups) do count = count + 1; found = k end
    end
    if count == 1 then return found end
    if count == 0 and NEXT_LEVEL[key] then
        log(key .. ": the game lists no upgrade but the data has " .. NEXT_LEVEL[key] .. "; trying it")
        return NEXT_LEVEL[key]
    end
    return nil
end

-- True if a building has no further upgrade (its chain's highest level):
-- the game lists none, and the data doesn't know of a higher level either.
local function is_maxed(key)
    if not key then return false end
    if NEXT_LEVEL[key] then return false end
    local ups = cm:get_building_level_upgrades(key)
    return type(ups) == "table" and next(ups) == nil
end

-- True if a settlement's main building is at its highest level, or its
-- final upgrade is already under construction.
local function settlement_done(info)
    local p = info.primary
    if not p or not p.current then return false end
    if p.waiting then return is_maxed(p.target) end
    return is_maxed(p.current)
end

local function is_protected(region)
    if not PROTECTED or PROTECTED == "" then return false end
    return contains(string.lower(region:province_name() or ""), PROTECTED)
end

-- Unchecked in the settings panel: skipped like the protected province.
local function is_skipped(region)
    return skipped_provinces[string.lower(region:province_name() or "")] == true
end

-- Crash guard: only the player's own culture's buildings (tag as a whole word)
-- or landmarks from the data may be queued; never another culture's. A landmark
-- configured by hand gets no special pass: it must be one of these too (a
-- hand-typed Tomb Kings "defence" building would otherwise crash the game).
local function is_safe_key(key)
    if type(key) ~= "string" then return false end
    if UA_DATA.wrong_culture and UA_DATA.wrong_culture[key] then return false end
    if other_culture_key(key) then return false end
    if has_tag(key, RULES.tag) then return true end
    if UA_DATA.landmark_ok and UA_DATA.landmark_ok[key] then return true end
    return false
end

local function has_bundle(region, key)
    local ok, yes = pcall(function() return region:has_effect_bundle(key) end)
    if ok and yes then return true end
    ok, yes = pcall(function() return region:faction_province_has_effect_bundle(key) end)
    return ok and yes or false
end

-- Doubled build times: an uninhabitable-climate effect, or a listed province.
local slow_cache = {}  -- region key -> true/false, cleared at the start of each run
local function is_slow_province(region)
    local rk = region:name()
    if slow_cache[rk] ~= nil then return slow_cache[rk] end
    local slow = false
    local pk = string.lower(region:province_name() or "")
    for _, needle in ipairs(CONFIG.slow_provinces) do
        if contains(pk, needle) then slow = true end
    end
    if not slow then
        detail("checking climate in " .. rk)
        for _, b in ipairs(UA_DATA.slow_bundles or {}) do
            if has_bundle(region, b) then slow = true; break end
        end
    end
    slow_cache[rk] = slow
    return slow
end

-- Readable name from a key ("wh3_main_combi_province_southern_yvresse" ->
-- "southern yvresse"). Uses no game calls.
local function loc_name(prefix, key)
    local tail = after(key, "region_") or after(key, "province_") or key
    return underscores_to_spaces(tail)
end

-- The province's on-screen name from the game's own text (a key can differ from
-- the name: "...province_vampire_coast" is Jungle of Webs), else from the key.
local function province_label(key)
    local loc
    pcall(function() loc = common.get_localised_string("provinces_onscreen_" .. key) end)
    if type(loc) == "string" and loc ~= "" and loc ~= key and not contains(loc, "MISSING") and not contains(loc, "[[") then
        return loc
    end
    return loc_name("provinces_onscreen_", key)
end

-- Resource name (as it appears in the game's resource key) -> the player's
-- culture's resource chain. Built from the data when the rules are chosen; a
-- few game names differ from the chain names. Checked against the game's slot
-- templates: each resource key's slot permits the building named here
-- (res_rom_oil -> pastures, and so on).
local RESOURCE_ALIASES = { timber = "wood", oil = "pasture", textiles = "pottery", lead = "salt" }
local NOT_RESOURCES = { res_fortress = true, res_location_colony = true }
local RESOURCE_CHAINS = {}
local function build_resource_chains()
    RESOURCE_CHAINS = {}
    for chain in pairs(UA_DATA.first) do
        local name = after(chain, RULES.tag .. "_resource_")
        if name then RESOURCE_CHAINS[#RESOURCE_CHAINS + 1] = { name = name, chain = chain } end
    end
    table.sort(RESOURCE_CHAINS, function(a, b) return #a.name > #b.name end) -- longest name first
end

-- Switches every culture-specific rule over to the given culture's.
local function use_rules(rules)
    RULES = rules
    FARM = rules.farm
    LAYOUT_CAPITAL, LAYOUT_MINOR, LAYOUT_SLOW_MINOR = rules.capital, rules.minor, rules.slow_minor
    PROTECTED = (rules.protect == "config") and CONFIG.protected_province or starting_province
    build_resource_chains()
end
use_rules(RULES)

-- The game doesn't tell scripts whether a slot is under construction, so the
-- mod remembers its own orders. An order counts as overdue (forgotten, so the
-- slot is tried again) once it is well past the building's own build time:
-- that time, doubled in slow-build climates, plus 2 turns' grace. Never longer
-- than pending_timeout; buildings with no known build time use pending_timeout.
local function order_overdue(p, region, turn)
    local age = turn - p.turn
    if age >= CONFIG.pending_timeout then return true end
    local t = UA_DATA.tier[p.target]
    local bt = t and t[4]
    if not bt or bt <= 0 then return false end
    return age > bt * (is_slow_province(region) and 2 or 1) + 2
end

-- Gathers what we need about a region's slots in one pass.
-- Uses only slot calls already proven safe in-game: type, name, active,
-- has_building, building():name(), resource_key.
local function inspect_region(region, turn)
    local info = { region = region, primary = nil, empty = {}, filled = {}, chains = {}, resource = nil, templates = {} }
    local rname = region:name()
    local fine = CONFIG.trace_slot_calls
    local function at(i, what) if fine then trace(rname .. " slot " .. i .. ": " .. what) end end
    if fine then trace(rname .. ": slot_list") end
    local list = region:slot_list()
    for i = 0, list:num_items() - 1 do
        at(i, "item_at");        local slot = list:item_at(i)
        at(i, "is_null_interface")
        if not slot:is_null_interface() then
            at(i, "active")
            if slot:active() then
                local id = rname .. "#" .. i
                at(i, "type");         local kind = slot:type()
                at(i, "has_building (type " .. tostring(kind) .. ")")
                local has = slot:has_building()
                local current = nil
                if has then
                    at(i, "building():name() (type " .. tostring(kind) .. ")")
                    current = slot:building():name()
                end
                local p = pending[id]
                if p and current ~= p.target and order_overdue(p, region, turn) then
                    log(id .. ": ordered " .. p.target .. " on turn " .. p.turn .. " but it never appeared; trying the slot again")
                    pending[id] = nil; p = nil
                elseif p and current == p.target then
                    pending[id] = nil; p = nil
                end
                if p then info.chains[chain_of(p.target)] = true end
                if current then info.chains[chain_of(current)] = true end
                at(i, "resource_key (type " .. tostring(kind) .. ")")
                if kind == "secondary" then
                    local tk = slot:template_key()
                    if tk and tk ~= "" then info.templates[tk] = true end
                end
                local res = slot:resource_key()
                if res and res ~= "" and not NOT_RESOURCES[res] and not info.resource then info.resource = res end
                local entry = { slot = slot, id = id, current = current, waiting = p ~= nil, target = p and p.target, kind = kind }
                if kind == "primary" then info.primary = entry
                elseif current or p then info.filled[#info.filled + 1] = entry
                elseif kind == "secondary" then info.empty[#info.empty + 1] = entry end
            end
        end
    end
    if fine then trace(rname .. ": slots read OK") end
    return info
end

-- Main-settlement level of a region (nil if unknown) and whether a building's
-- settlement-level requirement is met. Unknown data never blocks.
local function main_level(info)
    local key = info.primary and info.primary.current
    local t = key and UA_DATA.tier[key]
    return t and t[1] or nil
end
local function level_ok(info, building_key)
    local lvl, t = main_level(info), UA_DATA.tier[building_key]
    if not lvl or not t then return true end
    return lvl >= t[2]
end

-- How well a landmark candidate fits the player, from the game's culture-variant
-- rows: 1 = made for this faction, 2 = for this culture, 3 = for everyone,
-- nil = not available. The most specific matching row decides (a faction row
-- with "disables" switches a building off for that faction).
local function landmark_rank(rows)
    if #rows == 0 then return 3 end
    local best, disabled
    for _, r in ipairs(rows) do
        local culture, sub, faction, disables = r[1], r[2], r[3], r[4]
        local spec
        if faction ~= "" then spec = (faction == PLAYER.faction) and 1 or nil
        elseif sub ~= "" then spec = (sub == PLAYER.sub) and 2 or nil
        elseif culture ~= "" then spec = (culture == PLAYER.culture) and 2 or nil
        else spec = 3 end
        if spec and (not best or spec < best) then best, disabled = spec, disables
        elseif spec and spec == best and disables then disabled = true end
    end
    if not best or disabled then return nil end
    return best
end

-- The landmark this settlement can build: a configured one, or the best version
-- its slot templates permit for the player's faction. Returns key and rank.
local function landmark_for(info)
    local function ok(k) return k and not refused_landmarks[info.region:name() .. "|" .. k] end
    local configured = CONFIG.landmarks[info.region:name()]
    if configured then return ok(configured) and configured or nil, 1 end
    local found, found_rank, found_named
    for t in pairs(info.templates) do
        for _, c in ipairs((UA_DATA.landmark_candidates or {})[t] or {}) do
            local key, named, rows = c[1], c[2], c[3]
            local rank = ok(key) and not other_culture_key(key) and not (UA_DATA.wrong_culture or {})[key] and landmark_rank(rows)
            if rank then
                local better = not found
                    or rank < found_rank
                    or (rank == found_rank and named and not found_named)
                    or (rank == found_rank and named == found_named and has_tag(key, RULES.tag) and not has_tag(found, RULES.tag))
                    or (rank == found_rank and named == found_named and has_tag(key, RULES.tag) == has_tag(found, RULES.tag) and key < found)
                if better then found, found_rank, found_named = key, rank, named end
            end
        end
    end
    return found, found_rank
end

-- What a building will cost: its real price from the data when known,
-- otherwise the most expensive thing seen so far.
local function expected_cost(key)
    local t = UA_DATA.tier[key]
    if t and t[3] and t[3] > 0 then return t[3] end
    return max_cost_seen
end

-- The layout for a settlement. Once its province no longer needs growth,
-- the Homestead line is dropped and everything below it moves up.
local function layout_for(info)
    local region = info.region
    local base = region:is_province_capital() and LAYOUT_CAPITAL
        or (is_slow_province(region) and LAYOUT_SLOW_MINOR or LAYOUT_MINOR)
    if not info.no_growth then return base end
    local out = {}
    for _, item in ipairs(base) do if item ~= FARM then out[#out + 1] = item end end
    return out
end

-- Fortified settlements (Ulthuan's gates, Empire forts, Cathay bastions) have
-- no economy, so income commandments like Tribute do nothing there.
local function is_fort(info)
    local key = info.primary and info.primary.current
    if not key then return false end
    return contains(key, "fortress_gate") or contains(key, "empire_fort") or contains(key, "bastion")
end

-- Aislinn's colony settlements only (wh3_dlc27_hef_colony_settlement_*). The
-- older Elven Colony settlements like Arnheim (wh2_main_special_settlement_
-- colony_*_hef) take ordinary High Elf buildings and are built normally.
local function is_colony(info)
    return info.primary and info.primary.current and contains(info.primary.current, "hef_colony_settlement")
end


local function resource_chain(resource_key)
    if type(resource_key) ~= "string" or NOT_RESOURCES[resource_key] then return nil end
    local key = string.lower(resource_key)
    for alias, real in pairs(RESOURCE_ALIASES) do
        if contains(key, alias) then key = key .. "_" .. real end
    end
    for _, rc in ipairs(RESOURCE_CHAINS) do
        if contains(key, rc.name) then return rc.chain end
    end
end

-- Groups the faction's regions by province (skipping the protected one), capital
-- first, sorted: unrest first (most negative), then income high to low, then
-- no income.
local function group_provinces(faction)
    local provinces, by_key, skipped, skipped_seen = {}, {}, {}, {}
    local regions = faction:region_list()
    for i = 0, regions:num_items() - 1 do
        local r = regions:item_at(i)
        detail("reading province of region " .. i)
        if is_protected(r) then
            -- never touched
        elseif is_skipped(r) then
            local pk = r:province_name()
            if not skipped_seen[pk] then skipped_seen[pk] = true; skipped[#skipped + 1] = pk end
        else
            local pk = r:province_name()
            local p = by_key[pk]
            if not p then p = { key = pk, regions = {}, gdp = 0, po = nil }; by_key[pk] = p; provinces[#provinces + 1] = p end
            if r:is_province_capital() then table.insert(p.regions, 1, r); p.po = r:public_order()
            else p.regions[#p.regions + 1] = r end
            p.gdp = p.gdp + (r:gdp() or 0)
            if p.po == nil then p.po = r:public_order() end
        end
    end
    table.sort(provinces, function(a, b)
        local ga = a.po < 0 and 1 or (a.gdp > 0 and 2 or 3)
        local gb = b.po < 0 and 1 or (b.gdp > 0 and 2 or 3)
        if ga ~= gb then return ga < gb end
        if ga == 1 and a.po ~= b.po then return a.po < b.po end
        if ga == 2 and a.gdp ~= b.gdp then return a.gdp > b.gdp end
        return a.key < b.key
    end)
    table.sort(skipped)
    return provinces, skipped
end

-- Growth is no longer needed once the capital and every minor settlement in a
-- province are at their highest level (counting final upgrades already queued).
local function province_grown(infos)
    local has_capital, all_done = false, #infos > 0
    for _, info in ipairs(infos) do
        if info.region:is_province_capital() then has_capital = true end
        if not settlement_done(info) then all_done = false end
    end
    return has_capital and all_done
end

-- Commandment checks for one province: adds its name to `tribute` if it's fully
-- grown without Tribute to the Phoenix King, and to `banish` if Banish
-- Corruption is active with no corruption left.
-- Commandments can only be set where you own every settlement in the province.
-- Compares the province's settlement count with how many of them are yours.
-- If the game can't say, the reminder stays on (as before) and the trace says why.
local function owns_whole_province(region, owned)
    local ok, total = pcall(function() return region:province():regions():num_items() end)
    if ok and type(total) == "number" then return owned >= total end
    trace("couldn't count the settlements in " .. tostring(region:province_name()) .. ": " .. tostring(total))
    return true
end

local function check_commandments(prov_key, infos, no_growth, tribute, banish)
    if not (RULES.tribute_key or RULES.banish_key) then return end
    for _, info in ipairs(infos) do
        if info.region:is_province_capital() then
            detail("reading commandment in " .. info.region:name())
            local ok, active = pcall(function() return info.region:get_active_edict_key() end)
            active = ok and tostring(active) or nil
            detail("commandment in " .. info.region:name() .. ": " .. tostring(active))
            local pname = province_label(prov_key)
            if active and no_growth and RULES.tribute_key and active ~= RULES.tribute_key
                and not is_fort(info) and owns_whole_province(info.region, #infos) then
                tribute[#tribute + 1] = pname
            end
            if active and RULES.banish_key and active == RULES.banish_key then
                local total, known = 0, true
                for _, other in ipairs(infos) do
                    detail("reading corruption in " .. other.region:name())
                    local ok2, v = pcall(function() return cm:get_total_corruption_value_in_region(other.region) end)
                    if ok2 and tonumber(v) then total = total + tonumber(v) else known = false end
                end
                if known and total <= 0 then banish[#banish + 1] = pname end
            end
        end
    end
end

-- Read-only look at a region's main settlement slot, for the turn-start
-- re-check: no other slots, and the record of queued buildings is read but
-- never changed (only the End Turn run updates it).
local function primary_info(region, turn)
    local info = { region = region, primary = nil }
    local list = region:slot_list()
    for i = 0, list:num_items() - 1 do
        local slot = list:item_at(i)
        if not slot:is_null_interface() and slot:active() and slot:type() == "primary" then
            local current = slot:has_building() and slot:building():name() or nil
            local p = pending[region:name() .. "#" .. i]
            if p and (current == p.target or order_overdue(p, region, turn)) then p = nil end
            info.primary = { current = current, waiting = p ~= nil, target = p and p.target }
            break
        end
    end
    return info
end

-- Re-reads every province's commandment (used right before the popup, since
-- commandments you changed after End Turn aren't seen by that run).
local function fresh_commandments(faction)
    local tribute, banish = {}, {}
    local turn = cm:turn_number()
    for _, prov in ipairs(group_provinces(faction)) do
        local infos = {}
        for _, r in ipairs(prov.regions) do infos[#infos + 1] = primary_info(r, turn) end
        check_commandments(prov.key, infos, province_grown(infos), tribute, banish)
    end
    return tribute, banish
end

---------------------------------------------------------------------------
-- The turn
---------------------------------------------------------------------------
local function run_turn(faction)
    local fkey = faction:name()
    local turn = cm:turn_number()
    local stats = { new = 0, upgraded = 0, refused = 0, demolished = 0, short = 0, first_short = nil, farms_removed = 0, tribute = {}, banish = {}, tribute_seen = {}, spent = 0, orders = 0, stop = nil, per_province = {}, order = {},
                    refused_orders = {}, refused_total = 0,   -- "slot|key" refused by the game this turn, and how many
                    tier_wait = {}, tier_wait_total = 0 }     -- "slot|key" the data says the settlement is too small for

    -- Queue one building; returns true if the game accepted (charged for) it.
    -- `info` (the settlement, when known) lets the data's main-settlement level
    -- requirement rule a building out without asking the game.
    local function try(entry, key, province, kind, info)
        if stats.stop then return false end
        local order_id = entry.id .. "|" .. key
        -- Refused earlier this turn: nothing that causes a refusal (settlement
        -- level, growth, technology) changes between passes, so don't ask again.
        if stats.refused_orders[order_id] then stats.why = "refused by the game earlier this turn"; return false end
        -- The data knows the main-settlement level each building needs.
        if info and not level_ok(info, key) then
            local t = UA_DATA.tier[key]
            stats.why = "needs main settlement level " .. tostring(t and t[2]) .. " (this one is level " .. tostring(main_level(info)) .. ")"
            if not stats.tier_wait[order_id] then
                stats.tier_wait[order_id] = true
                stats.tier_wait_total = stats.tier_wait_total + 1
            end
            return false
        end
        -- Crash guard. Exception: the next level of a building already in the
        -- slot, when it's the main settlement (special settlements like Gaean
        -- Vale have no "hef" in their keys) or a culture-neutral building (The
        -- Great Desert's "_other" landmark, Copher's special port): the game
        -- gave this faction its level 1, so its chain is safe here. A building
        -- tagged for another culture is never upgraded, whatever sits in the slot.
        local same_chain = entry.current and chain_of(key) == chain_of(entry.current)
        local own_upgrade = same_chain and (entry.kind == "primary" or not any_culture_tag(key))
            and not (UA_DATA.wrong_culture and UA_DATA.wrong_culture[key])
        if not own_upgrade and not is_safe_key(key) then log("Refusing key from another culture: " .. key); stats.why = "not a " .. RULES.adj .. " building"; return false end
        if stats.orders >= CONFIG.max_queued_per_turn then stats.stop = "per-turn cap reached"; stats.why = "per-turn cap reached"; return false end
        local before = cm:get_faction(fkey):treasury()
        local need = expected_cost(key)
        if before - need < CONFIG.gold_floor then
            -- Can't afford this one right now: skip it and keep going with the
            -- next item in priority order, so the gold still gets used.
            stats.short = stats.short + 1
            if not stats.first_short then stats.first_short = string.format("%s, %d gold", key, need) end
            stats.why = string.format("short of gold (%d needed, %d left)", need, before)
            return false
        end
        detail("queueing " .. key .. " at " .. entry.id)
        cm:add_building_to_settlement_queue(entry.slot, key)
        local cost = before - cm:get_faction(fkey):treasury()
        if cost <= 0 then
            stats.refused = stats.refused + 1; stats.why = "refused by the game"
            stats.refused_orders[order_id] = true
            stats.refused_total = stats.refused_total + 1
            log(entry.id .. ": " .. key .. " refused by the game")
            return false
        end
        pending[entry.id] = { target = key, turn = turn }
        entry.waiting = true
        entry.target = key
        stats.orders, stats.spent = stats.orders + 1, stats.spent + cost
        if cost > max_cost_seen then max_cost_seen = cost end
        stats[kind] = stats[kind] + 1
        local pp = stats.per_province[province]
        if not pp then pp = { new = 0, upgraded = 0 }; stats.per_province[province] = pp; stats.order[#stats.order + 1] = province end
        pp[kind] = pp[kind] + 1
        log(string.format("%s: %s (%d gold)", entry.id, key, cost))
        return true
    end

    -- The layout for a region resolved to chain keys, in priority order.
    local function resolved_layout(info)
        local region = info.region
        local layout = layout_for(info)
        local landmark = landmark_for(info)
        local resolved, pos = {}, {}
        for _, item in ipairs(layout) do
            local chain, build
            if item == "RESOURCE" then
                chain = resource_chain(info.resource); build = chain and UA_DATA.first[chain]
            elseif item == "LANDMARK" then
                if landmark then chain = chain_of(landmark); build = landmark end
            else
                chain = item; build = UA_DATA.first[item]
            end
            if chain and build and not pos[chain] then
                resolved[#resolved + 1] = { chain = chain, build = build }
                pos[chain] = #resolved
            end
        end
        return resolved, pos
    end

    -- Demolish every secondary building that doesn't belong in this settlement's
    -- current slots: anything outside the top-N of its layout (N = its slots).
    -- Your exception: the item right after the next one to build is kept, since
    -- it will be wanted as soon as another slot opens. Never special/landmark
    -- buildings, the main settlement, ports, or anything under construction.
    -- The chains that belong in this settlement's slots: the top-N of its layout
    -- (N = its secondary slots), plus the item kept by your exception.
    local function belongs_here(info)
        local resolved = resolved_layout(info)
        local nslots = #info.empty
        for _, e in ipairs(info.filled) do if e.kind == "secondary" then nslots = nslots + 1 end end
        -- A landmark the settlement can build always gets its last slot,
        -- even if it ranks below what fits; it bumps the lowest-ranked item.
        local landmark, lm_rank = landmark_for(info)
        local lm_chain = landmark and chain_of(landmark)
        local top = {}
        for i = 1, math.min(nslots, #resolved) do top[i] = resolved[i] end
        -- Only landmarks made for the player's culture (tagged key, or a faction/
        -- culture row): the game may refuse a neutral one, and a good building
        -- would be lost for nothing.
        if lm_chain and nslots > 0 and #top == nslots and level_ok(info, landmark) and (has_tag(landmark, RULES.tag) or (lm_rank or 3) <= 2) then
            local inside = false
            for _, r in ipairs(top) do if r.chain == lm_chain then inside = true end end
            if not inside then top[nslots] = { chain = lm_chain, build = landmark } end
        end
        local wanted, keep_next = {}, nil
        for _, r in ipairs(top) do wanted[r.chain] = true end
        for i, r in ipairs(top) do
            if not info.chains[r.chain] then
                -- Your exception (keep the next item) doesn't apply to the landmark's slot.
                if r.chain ~= lm_chain then
                    local nxt = top[i + 1] or resolved[i + 1]
                    keep_next = nxt and nxt.chain
                end
                break
            end
        end
        return wanted, keep_next
    end

    local function clear_unwanted(info)
        local wanted, keep_next = belongs_here(info)
        for j = #info.filled, 1, -1 do
            local e = info.filled[j]
            local c = e.current and chain_of(e.current)
            if e.kind == "secondary" and c and not e.waiting and not wanted[c] and c ~= keep_next
                and not contains(e.current, "special") and not contains(c, "special")
                and not (UA_DATA.unique_chain and UA_DATA.unique_chain[c]) then
                trace("demolishing " .. e.current .. " at " .. e.id .. " (not wanted here)")
                cm:region_slot_instantly_dismantle_building(e.slot)
                stats.demolished = stats.demolished + 1
                if c == FARM then stats.farms_removed = stats.farms_removed + 1 end
                info.chains[c] = nil
                e.current = nil
                table.remove(info.filled, j)
                info.empty[#info.empty + 1] = e
            end
        end
    end

    local explain, waiting_on, main_note = {}, {}, {}  -- region -> why slots are empty / main building not upgraded (last pass wins)
    local provinces, skipped = group_provinces(faction)
    stats.skipped = skipped
    trace("provinces grouped: " .. #provinces .. (#skipped > 0 and (", skipped by you: " .. table.concat(skipped, ", ")) or ""))

    -- Repeat passes in priority order until a pass buys nothing more: gold
    -- refunded by demolitions mid-run goes back to the highest priority that
    -- now fits, so the treasury ends each turn as close to 0 as possible.
    for pass = 1, CONFIG.max_passes do
        local orders_before = stats.orders
        stats.short, stats.first_short, stats.refused = 0, nil, 0
        trace("pass " .. pass)
        for _, prov in ipairs(provinces) do
            if stats.stop then break end
            detail("province " .. tostring(prov.key))
            local infos = {}
            for _, r in ipairs(prov.regions) do
                detail("reading slots in " .. r:name())
                infos[#infos + 1] = inspect_region(r, turn)
            end

            -- 1. Main settlement buildings. Whatever stops an upgrade is noted
            -- for the trace (last pass wins), so a settlement that sits at the
            -- same level for turns can be explained.
            for _, info in ipairs(infos) do
                local p = info.primary
                local rk = info.region:name()
                main_note[rk] = nil
                if p and p.current then
                    if p.waiting then
                        local pd = pending[p.id]
                        main_note[rk] = "main building: waiting on " .. tostring(p.target) .. (pd and (" (ordered turn " .. pd.turn .. ")") or "")
                    else
                        local up = single_upgrade(p.current)
                        if up then
                            if not try(p, up, prov.key, "upgraded") then
                                main_note[rk] = "main building " .. p.current .. " -> " .. up .. ": " .. tostring(stats.why)
                            end
                        elseif not is_maxed(p.current) then
                            main_note[rk] = "main building " .. p.current .. ": more than one upgrade path; left for you"
                        end
                    end
                end
            end

        -- Growth is no longer needed once the capital and every minor settlement
            -- here are at their highest level (counting final upgrades just queued).
            local no_growth = province_grown(infos)
            for _, info in ipairs(infos) do info.no_growth = no_growth end

            -- Commandment checks, once per province (only when their keys are set).
            if not stats.tribute_seen[prov.key] then
                stats.tribute_seen[prov.key] = true
                if no_growth then
                    local mains = {}
                    for _, info in ipairs(infos) do
                        local p = info.primary
                        mains[#mains + 1] = info.region:name() .. "=" .. tostring(p and (p.waiting and (p.target .. " (queued)") or p.current))
                    end
                    log(tostring(prov.key) .. ": fully grown, growth buildings no longer needed (" .. table.concat(mains, ", ") .. ")")
                end
                check_commandments(prov.key, infos, no_growth, stats.tribute, stats.banish)
            end

            -- 2. Clear buildings that don't belong, then fill empty slots.
            for _, info in ipairs(infos) do
                if CONFIG.allow_demolish and not is_colony(info) then clear_unwanted(info) end
                explain[info.region:name()] = nil
                if not is_colony(info) and #info.empty > 0 then
                    local key = info.region:name()
                    local layout = layout_for(info)
                    local landmark = landmark_for(info)
                    -- Only hold a slot for a landmark this settlement is big enough to build.
                    local landmark_open = landmark and not info.chains[chain_of(landmark)] and level_ok(info, landmark)
                    -- Only place what demolition would keep (the top-N, plus the item
                    -- right after the next one): anything else would be torn down later.
                    local wanted, keep_next = belongs_here(info)

                    local notes = {}  -- why slots stay empty, written to the trace
                    local function place(building_key)
                        local slot = info.empty[1]
                        if try(slot, building_key, prov.key, "new", info) then
                            table.remove(info.empty, 1)
                            info.chains[chain_of(building_key)] = true
                            return true
                        end
                        notes[#notes + 1] = building_key .. " " .. tostring(stats.why)
                        return false
                    end

                    for _, item in ipairs(layout) do
                        if #info.empty == 0 or stats.stop then break end
                        -- Keep the last free slot for the landmark.
                        if landmark_open and #info.empty == 1 then
                            local refused_before = stats.refused
                            if place(landmark) then landmark_open = false; break end
                            if stats.refused > refused_before then
                                -- The game won't build it here: remember, stop holding the slot.
                                refused_landmarks[info.region:name() .. "|" .. landmark] = true
                                trace("landmark " .. landmark .. " refused at " .. info.region:name() .. "; not trying again")
                                landmark_open = false
                            else
                                notes[#notes + 1] = "last slot held for landmark " .. landmark
                                break -- only short of gold: keep the slot for it
                            end
                        end
                        if item == "LANDMARK" then
                            if landmark_open then
                                local refused_before = stats.refused
                                if place(landmark) then landmark_open = false
                                elseif stats.refused > refused_before then
                                    refused_landmarks[info.region:name() .. "|" .. landmark] = true
                                    trace("landmark " .. landmark .. " refused at " .. info.region:name() .. "; not trying again")
                                    landmark_open = false
                                end
                            end
                        else
                            local chain = item == "RESOURCE" and resource_chain(info.resource) or (item ~= "RESOURCE" and item or nil)
                            if chain and not info.chains[chain] and UA_DATA.first[chain] then
                                if wanted[chain] or chain == keep_next then place(UA_DATA.first[chain])
                                else
                                    detail("not placing " .. chain .. " at " .. key .. " (ranked below what fits)")
                                    notes[#notes + 1] = chain .. " ranked below what fits"
                                end
                            end
                        end
                    end
                    if #info.empty > 0 and not stats.stop then
                        explain[key] = #info.empty .. " empty slot(s) left: " .. (#notes > 0 and table.concat(notes, "; ") or "nothing left in its layout to build")
                    end
                end
                -- Orders the mod is still waiting on in slots that look empty in the game.
                local waits = {}
                for _, e in ipairs(info.filled) do
                    if e.waiting and not e.current and e.kind == "secondary" then
                        local p = pending[e.id]
                        waits[#waits + 1] = tostring(e.target) .. (p and (" (ordered turn " .. p.turn .. ")") or "")
                    end
                end
                waiting_on[info.region:name()] = #waits > 0 and ("waiting on new building(s): " .. table.concat(waits, ", ")) or nil
            end

            -- 3. Upgrades to everything else: income, then growth, then the rest.
            local candidates = {}
            for _, info in ipairs(infos) do
                for _, e in ipairs(info.filled) do
                if e.current and not e.waiting and not (info.no_growth and chain_of(e.current) == FARM) then
                        local up = single_upgrade(e.current)
                        if up then
                            local fi, pi, gi = score(e.current)
                            local fu, pu, gu = score(up)
                            candidates[#candidates + 1] = { entry = e, target = up, info = info, inc = fu - fi, pct = pu - pi, growth = gu - gi }
                        end
                    end
                end
            end
            table.sort(candidates, function(a, b)
                if a.inc ~= b.inc then return a.inc > b.inc end
                if a.pct ~= b.pct then return a.pct > b.pct end
                if a.growth ~= b.growth then return a.growth > b.growth end
                return a.entry.id < b.entry.id
            end)
            for _, c in ipairs(candidates) do
                if stats.stop then break end
                try(c.entry, c.target, prov.key, "upgraded", c.info)
            end
        end

        if stats.stop or stats.orders == orders_before then break end
    end
    -- Once per turn: why any settlement still has empty-looking slots or an
    -- un-upgraded main building.
    for _, tbl in ipairs({ main_note, explain, waiting_on }) do
        local keys = {}
        for k, v in pairs(tbl) do if v then keys[#keys + 1] = k end end
        table.sort(keys)
        for _, k in ipairs(keys) do log(k .. ": " .. tbl[k]) end
    end
    return stats
end

-- Title plus commandment actions first (they're the things you need to do),
-- then the body of the summary.
local function compose_summary(tribute, banish, body)
    local lines = { "Upgrade All", "" }
    if #tribute > 0 then
        lines[#lines + 1] = "Set " .. RULES.tribute_name .. " in: " .. table.concat(tribute, ", ")
    end
    if #banish > 0 then
        lines[#lines + 1] = "Warning: Banish Corruption is still active with no corruption left in: " .. table.concat(banish, ", ")
    end
    if #tribute > 0 or #banish > 0 then lines[#lines + 1] = "" end
    lines[#lines + 1] = body
    return table.concat(lines, "\n")
end

-- Everything in the summary except the title and commandment lines.
local function summary_body(stats, treasury)
    local lines = {}
    local totals = {
        string.format("New buildings: %d", stats.new),
        string.format("Upgrades: %d", stats.upgraded),
        string.format("Gold spent: %d   Treasury: %d", stats.spent, treasury),
        string.format("Waiting on settlement level: %d", stats.tier_wait_total or 0),
        string.format("Refused by the game (growth, tech...): %d", stats.refused_total or 0),
        string.format("Demolished to make room: %d", stats.demolished),
    }
    for _, l in ipairs(totals) do lines[#lines + 1] = l end
    if stats.farms_removed > 0 then
        lines[#lines + 1] = string.format("Homesteads removed (growth no longer needed): %d", stats.farms_removed)
    end
    if stats.short > 0 then
        lines[#lines + 1] = string.format("Waiting on gold: %d (most important: %s)", stats.short, stats.first_short)
    end
    if stats.stop then lines[#lines + 1] = "Stopped: " .. stats.stop end
    if stats.skipped and #stats.skipped > 0 then
        local names = {}
        for i, pk in ipairs(stats.skipped) do names[i] = province_label(pk) end
        lines[#lines + 1] = "Skipped (unchecked in settings): " .. table.concat(names, ", ")
    end
    if #stats.order > 0 then
        lines[#lines + 1] = ""
        for i, pk in ipairs(stats.order) do
            if i > 12 then lines[#lines + 1] = string.format("...and %d more provinces", #stats.order - 12); break end
            local pp = stats.per_province[pk]
            lines[#lines + 1] = string.format("%s: %d new, %d upgraded", province_label(pk), pp.new, pp.upgraded)
        end
    end
    return table.concat(lines, "\n")
end

local function format_summary(stats, treasury)
    return compose_summary(stats.tribute, stats.banish, summary_body(stats, treasury))
end

---------------------------------------------------------------------------
-- Test mode: survey slot templates and resources (queues nothing)
---------------------------------------------------------------------------
-- Runs the steps listed in CONFIG.test_steps all at once, then shows one popup.
local function run_test_mode_staged(faction_key)
    local results = {}
    local function regions()
        local list, t = cm:get_faction(faction_key):region_list(), {}
        for i = 0, list:num_items() - 1 do t[#t + 1] = list:item_at(i) end
        return t
    end
    local steps = {
        { "Step 1: reading building slots", function()
            local n, res_ok, none = 0, 0, {}
            for _, r in ipairs(regions()) do
                local info = inspect_region(r, cm:turn_number())
                n = n + 1
                if info.resource and not NOT_RESOURCES[info.resource] then
                    if resource_chain(info.resource) then res_ok = res_ok + 1
                    else none[tostring(info.resource) .. " (" .. type(info.resource) .. ")"] = true end
                end
            end
            local nl = {}
            for k in pairs(none) do nl[#nl + 1] = k end
            table.sort(nl)
            results[#results + 1] = string.format("Step 1 OK: slots read in %d settlements.\nResource buildings known: %d\nResources with a " .. RULES.adj .. " building: %d",
                n, #RESOURCE_CHAINS, res_ok)
            if #nl > 0 then results[#results + 1] = "No " .. RULES.adj .. " building for: " .. table.concat(nl, ", ") end
        end },
        { "Step 2: checking region climate effects", function()
            local n = 0
            for _, r in ipairs(regions()) do
                for _, b in ipairs(UA_DATA.slow_bundles) do
                    local ok, yes = pcall(function() return r:has_effect_bundle(b) end)
                    if ok and yes then n = n + 1; break end
                end
            end
            results[#results + 1] = string.format("Region climate check: %d slow settlements", n)
        end },
        { "Step 3: checking province climate effects", function()
            local n = 0
            for _, r in ipairs(regions()) do
                for _, b in ipairs(UA_DATA.slow_bundles) do
                    local ok, yes = pcall(function() return r:faction_province_has_effect_bundle(b) end)
                    if ok and yes then n = n + 1; break end
                end
            end
            results[#results + 1] = string.format("Province climate check: %d slow settlements", n)
        end },
        { "Step 4: looking up settlement names", function()
            local slow = {}
            for _, r in ipairs(regions()) do
                if is_slow_province(r) then slow[#slow + 1] = loc_name("regions_onscreen_", r:name()) end
            end
            local shown = {}
            for i = 1, math.min(#slow, 10) do shown[i] = slow[i] end
            results[#results + 1] = "Slow-build settlements: " .. (#slow > 0 and (table.concat(shown, ", ") .. (#slow > 10 and ", ..." or "")) or "none found")
        end },
    }
    local ran = {}
    for _, i in ipairs(CONFIG.test_steps) do
        local step = steps[i]
        if step then
            trace("test step " .. i)
            local ok, err = pcall(step[2])
            if not ok then results[#results + 1] = step[1] .. " FAILED: " .. tostring(err) end
            ran[#ran + 1] = tostring(i)
        end
    end
    trace("steps finished; writing summary")
    write_summary("Upgrade All - TEST MODE (nothing is built)\nRan steps: " .. table.concat(ran, ", ") ..
        "\n\n" .. table.concat(results, "\n\n"))
end

---------------------------------------------------------------------------
-- Settings: a "UA" button in the top menu bar opens a list of your provinces.
-- Checked = managed. Unchecked = skipped, like Eataine. Saved with the game.
-- Uses the same game UI pieces as the version you tested (a round_small_button
-- beside button_search_panel, a script_dummy panel, checkbox_toggle boxes),
-- with the popup's rules: no LockPriority / RegisterTopMost, a fresh panel name
-- every time one is built, no timer started from inside another timer, a
-- checkbox click only updates that checkbox, and every UI call is guarded.
---------------------------------------------------------------------------
local SBUTTON = "upgrade_all_settings_button"
local SLABEL  = "upgrade_all_settings_label"
local SPANEL  = "upgrade_all_settings_panel_"  -- + a new number each time it's built
local SCHECK  = "ua_settings_check_"           -- + row number on the page
local SNAME   = "ua_settings_name_"
local SCLOSE  = "ua_settings_close"
local SPREV   = "ua_settings_prev"
local SNEXT   = "ua_settings_next"
local PAGE_ROWS = 12
local PLAIN_TEXT_INSET = 22  -- where plain text starts, from the piece's left edge (inside its bar)
local PANEL_W = 470

local settings = { seq = 0, open = nil, page = 0, rows = {}, busy = false }

local function ui(what, fn)
    local ok, err = pcall(fn)
    if not ok then trace("settings " .. what .. " failed: " .. tostring(err)) end
    return ok
end

local function set_tip(comp, text)
    if not pcall(function() comp:SetTooltipText(text, "", true) end) then
        pcall(function() comp:SetTooltipText(text, true) end)
    end
end

local function comp_pos(c)
    local x, y
    pcall(function() x, y = c:Position() end)
    if type(x) == "number" and type(y) == "number" then return x, y end
end

local function comp_size(c)
    local w, h
    pcall(function() w, h = c:Width(), c:Height() end)
    return type(w) == "number" and w or 0, type(h) == "number" and h or 0
end

local function child_at(parent, i)
    local c
    pcall(function() c = UIComponent(parent:Find(i)) end)
    return c
end

local function comp_id(c)
    local id
    pcall(function() id = c:Id() end)
    return type(id) == "string" and id or ""
end

-- Creates a child from the first layout the game accepts.
local function new_child(parent, name, layouts)
    for _, layout in ipairs(layouts) do
        local c
        if pcall(function() c = UIComponent(parent:CreateComponent(name, layout)) end) and c then return c end
    end
end

-- Text pieces in your game draw text in two places: their own text (plain,
-- left-aligned at their corner) and a child (txt / text / label / dy_) that
-- shows it inside the blue bar. Setting both printed everything twice.
--   mode "bar":   text only in the child, resized to fill the bar and centred;
--                 the piece's own text is cleared.
--   mode "plain": only the piece's own text (no child text), left-aligned.
--   mode "both":  both (the UA button label, which already looks right).
local function text_child_list(c)
    local out, n = {}, 0
    pcall(function() n = c:ChildCount() end)
    for i = 0, math.min(n, 40) - 1 do
        local k = child_at(c, i)
        local id = k and string.lower(comp_id(k)) or ""
        if contains(id, "txt") or contains(id, "text") or contains(id, "label") or contains(id, "dy_") then out[#out + 1] = k end
    end
    return out
end

local function set_label(c, text, mode)
    if not c then return end
    mode = mode or "both"
    local w, h = comp_size(c)
    local kids = text_child_list(c)
    local own = text
    if mode == "bar" and #kids > 0 then own = "" end
    if mode == "plain" then
        pcall(function() c:SetStateText(own) end)
        -- The piece's own text starts at its corner, but its bar is drawn about
        -- 14 units in from there, so the text is pushed in to start inside the bar.
        pcall(function() c:SetTextHAlign("left"); c:SetTextVAlign("centre"); c:SetTextXOffset(PLAIN_TEXT_INSET, 0); c:SetTextYOffset(0, 0) end)
        -- No second copy in the bar, and hide any part of the piece that isn't
        -- text (in case the blue bar is drawn by a child).
        local is_text = {}
        for _, k in ipairs(kids) do is_text[k] = true; pcall(function() k:SetStateText("") end) end
        local n = 0
        pcall(function() n = c:ChildCount() end)
        for i = 0, math.min(n, 40) - 1 do
            local k = child_at(c, i)
            if k and not is_text[k] then pcall(function() k:SetVisible(false) end) end
        end
        return
    end
    pcall(function() c:SetStateText(own) end)
    pcall(function() c:SetTextHAlign("centre"); c:SetTextVAlign("centre"); c:SetTextXOffset(0, 0); c:SetTextYOffset(0, 0) end)
    for _, k in ipairs(kids) do
        pcall(function()
            k:SetCanResizeWidth(true); k:SetCanResizeHeight(true); k:Resize(w, h)
            k:SetDockingPoint(5); k:SetDockOffset(0, 0)
        end)
        pcall(function() k:SetStateText(text) end)
        pcall(function() k:SetTextHAlign("centre"); k:SetTextVAlign("centre"); k:SetVisible(true); k:SetInteractive(false) end)
    end
end

-- Size and position inside the panel (docked to its top-left corner).
local function fit(c, x, y, w, h, text, mode)
    if not c then return end
    pcall(function()
        c:SetCanResizeWidth(true); c:SetCanResizeHeight(true); c:Resize(w, h)
        c:SetDockingPoint(1); c:SetDockOffset(x, y); c:SetVisible(true)
    end)
    if text then set_label(c, text, mode or "bar") end
end

local function owned_provinces()
    local out, seen = {}, {}
    local regions = cm:get_faction(PLAYER.faction):region_list()
    for i = 0, regions:num_items() - 1 do
        local r = regions:item_at(i)
        local pk = r:province_name()
        if type(pk) == "string" and pk ~= "" and not seen[pk] then
            seen[pk] = true
            out[#out + 1] = { id = string.lower(pk), name = province_label(pk), locked = is_protected(r) }
        end
    end
    table.sort(out, function(a, b) if a.name ~= b.name then return a.name < b.name end return a.id < b.id end)
    return out
end

-- Placed just right of the search button (placing it after the button left of
-- search covered the search button), matching its size and the bar's spacing.
-- Nothing else moves.
local function place_button(button, bar, search)
    local sx, sy = comp_pos(search)
    local rounds = {}
    local n = 0
    pcall(function() n = bar:ChildCount() end)
    for i = 0, math.min(n, 400) - 1 do
        local c = child_at(bar, i)
        local id = c and comp_id(c) or ""
        if c and id ~= SBUTTON and id ~= "button_search_panel" then
            local x, y = comp_pos(c)
            local w, h = comp_size(c)
            if x and w >= 16 and h >= 16 and w <= 80 and h <= 80 and math.abs(w - h) <= 16 then
                rounds[#rounds + 1] = { x = x, y = y, w = w, h = h }
            end
        end
    end
    table.sort(rounds, function(a, b) return a.x < b.x end)
    local gaps = {}
    for i = 1, #rounds - 1 do
        local g = rounds[i + 1].x - (rounds[i].x + rounds[i].w)
        if g >= 0 and g <= 16 then gaps[#gaps + 1] = g end
    end
    table.sort(gaps)
    local spacing = #gaps > 0 and gaps[math.floor((#gaps + 1) / 2)] or 4
    if not sx then return end
    local sw, sh = comp_size(search)
    local bw, bh = sw, sh
    if bw < 16 or bh < 16 then
        local r = rounds[#rounds]
        bw, bh = r and r.w or 36, r and r.h or 36
    end
    local dx = sx + (sw >= 16 and sw or bw) + spacing
    local dy = sy + math.floor(((sh >= 16 and sh or bh) - bh) / 2)
    ui("button placement", function()
        button:SetCanResizeWidth(true); button:SetCanResizeHeight(true); button:Resize(bw, bh)
        button:MoveTo(dx, dy)
    end)
    -- Keep the same spot when the screen size changes (docked like the search button).
    pcall(function()
        local dock = search:DockingPoint()
        local ox, oy = search:GetDockOffset()
        if type(dock) == "number" and type(ox) == "number" and type(oy) == "number" and sx then
            button:SetDockingPoint(dock); button:SetDockOffset(ox - (sx - dx), oy + (dy - sy))
        end
    end)
end

local function ensure_button()
    if not CONFIG.settings_button then return false end
    local bar = find_uicomponent(core:get_ui_root(), "menu_bar", "buttongroup")
    if not bar then return false end
    local search = find_uicomponent(bar, "button_search_panel")
    if not search then return false end
    if find_uicomponent(bar, SBUTTON) then return true end
    local button = new_child(bar, SBUTTON, { "ui/templates/round_small_button" })
    if not button then trace("settings button: could not create"); return false end
    set_tip(button, "Upgrade All||Choose which provinces Upgrade All manages.")
    ui("button setup", function()
        button:SetVisible(true); button:SetInteractive(true); button:SetState("active"); button:PropagatePriority(200)
    end)
    place_button(button, bar, search)
    -- "UA" on the button itself (and any text child it has); a label child is
    -- added only when the button has no text child of its own.
    set_label(button, "UA")
    local has_text = false
    local n = 0
    pcall(function() n = button:ChildCount() end)
    for i = 0, math.min(n, 40) - 1 do
        local id = string.lower(comp_id(child_at(button, i) or {}))
        if contains(id, "txt") or contains(id, "text") or contains(id, "label") or contains(id, "dy_") then has_text = true end
    end
    if not has_text then
        local w, h = comp_size(button)
        local label = new_child(button, SLABEL, { "ui/templates/button_txt", "ui/templates/square_medium_text_button" })
        if label then
            pcall(function()
                label:SetCanResizeWidth(true); label:SetCanResizeHeight(true)
                label:Resize(w > 8 and w or 36, h > 8 and h or 36)
                label:SetDockingPoint(5); label:SetDockOffset(0, 0); label:SetInteractive(false)
            end)
            set_label(label, "UA")
        end
    end
    trace("settings button added")
    return true
end

local function destroy_panel()
    local name = settings.open
    settings.open, settings.rows = nil, {}
    if not name then return end
    ui("panel close", function()
        local p = find_uicomponent(core:get_ui_root(), name)
        if p then p:Destroy() end
    end)
end

-- A row's checkbox and tooltip from the saved choice.
local function show_row(row)
    local managed = not row.locked and not skipped_provinces[row.id]
    pcall(function() row.box:SetState(managed and "selected" or "active") end)
    local tip = row.locked and "Always skipped (protected province)."
        or (managed and "Managed by Upgrade All. Click to skip this province."
        or "Skipped: Upgrade All won't touch it. Click to manage it again.")
    set_tip(row.box, tip)
    if row.label then set_tip(row.label, tip) end
end

-- Writes what a text piece is made of to the trace, once per session, so its
-- blue bar can be identified from a screenshot plus the trace.
local described = false
local function describe_once(c)
    if described or not c then return end
    described = true
    local function line(k, depth)
        local w, h = comp_size(k)
        local x, y = comp_pos(k)
        local state, img = "?", "?"
        pcall(function() state = tostring(k:CurrentState()) end)
        pcall(function() img = tostring(k:GetImagePath(0)) end)
        trace(string.rep("  ", depth) .. comp_id(k) .. " " .. w .. "x" .. h .. " at " .. tostring(x) .. "," .. tostring(y)
            .. " state=" .. state .. " image=" .. img)
    end
    trace("settings: what a name label is made of:")
    line(c, 1)
    local n = 0
    pcall(function() n = c:ChildCount() end)
    for i = 0, math.min(n, 20) - 1 do
        local k = child_at(c, i)
        if k then line(k, 2) end
    end
end

local function build_panel()
    destroy_panel()
    local list = owned_provinces()
    local pages = math.max(1, math.floor((#list + PAGE_ROWS - 1) / PAGE_ROWS))
    settings.page = math.max(0, math.min(settings.page, pages - 1))
    local first = settings.page * PAGE_ROWS + 1
    local last = math.min(#list, first + PAGE_ROWS - 1)
    local shown = math.max(0, last - first + 1)

    settings.seq = settings.seq + 1
    local name = SPANEL .. settings.seq
    local panel
    if not ui("panel", function() panel = core:get_or_create_component(name, "ui/campaign ui/script_dummy") end) or not panel then return end
    settings.open = name
    local height = math.max(176, 88 + shown * 28 + 50)
    ui("panel setup", function()
        panel:SetVisible(true); panel:SetInteractive(true); panel:PropagatePriority(500)
        panel:SetCanResizeWidth(true); panel:SetCanResizeHeight(true); panel:Resize(PANEL_W, height)
    end)
    -- Just under the UA button, kept on screen.
    local ox, oy = 16, 52
    local button = find_uicomponent(core:get_ui_root(), "menu_bar", "buttongroup", SBUTTON)
    if button then
        local x, y = comp_pos(button)
        local _, bh = comp_size(button)
        if x then ox, oy = x, y + (bh > 0 and bh or 36) + 6 end
    end
    local rw, rh = 1920, 1080
    pcall(function() local root = core:get_ui_root(); rw, rh = root:Width(), root:Height() end)
    if type(rw) ~= "number" or rw < 200 then rw = 1920 end
    if type(rh) ~= "number" or rh < 200 then rh = 1080 end
    ox = math.max(8, math.min(ox, rw - PANEL_W - 8))
    oy = math.max(8, math.min(oy, rh - height - 8))
    pcall(function() panel:MoveTo(ox, oy) end)

    local frame = new_child(panel, "ua_settings_frame", { "ui/templates/panel_frame" })
    fit(frame, 0, 0, PANEL_W, height)
    if frame then pcall(function() frame:SetInteractive(false); frame:PropagatePriority(5) end) end
    local title = new_child(panel, "ua_settings_title", { "ui/templates/square_medium_text_button", "ui/templates/panel_title" })
    fit(title, 12, 8, PANEL_W - 24, 26, "Upgrade All")
    if title then pcall(function() title:SetInteractive(false) end) end
    local hint = new_child(panel, "ua_settings_hint", { "ui/templates/square_medium_text_button" })
    fit(hint, 16, 38, PANEL_W - 32, 42, #list == 0 and "No provinces owned."
        or "Checked build automatically. Uncheck to skip", "plain")
    if hint then pcall(function() hint:SetInteractive(false) end) end

    for i = 1, shown do
        local entry = list[first + i - 1]
        local y = 86 + (i - 1) * 28
        local box = new_child(panel, SCHECK .. i, { "ui/templates/checkbox_toggle" })
        if box then
            local bw, bh = comp_size(box)
            if bw < 16 or bw > 32 or bh < 16 or bh > 32 then bw, bh = 24, 24 end
            fit(box, 16, y + math.floor((26 - bh) / 2), bw, bh)
            pcall(function() box:SetDisabled(entry.locked); box:SetInteractive(not entry.locked) end)
            -- The piece whose own text drew the plain names you liked; only that
            -- text is shown. (button_txt covered the panel in black when resized,
            -- and "common ui/text" drew nothing.)
            local label = new_child(panel, SNAME .. i, { "ui/templates/square_medium_text_button" })
            fit(label, 46, y, PANEL_W - 62, 26, entry.name .. (entry.locked and " (always skipped)" or ""), "plain")
            if label then pcall(function() label:SetInteractive(false) end) end
            local row = { id = entry.id, locked = entry.locked, box = box, label = label }
            settings.rows[i] = row
            show_row(row)
        end
    end

    fit(new_child(panel, SCLOSE, { "ui/templates/square_medium_text_button" }), 12, height - 40, 100, 28, "Close")
    if pages > 1 then
        local prev = new_child(panel, SPREV, { "ui/templates/square_medium_text_button" })
        fit(prev, PANEL_W - 230, height - 40, 70, 28, "Prev")
        if prev then pcall(function() prev:SetDisabled(settings.page == 0) end) end
        local pg = new_child(panel, "ua_settings_page", { "ui/templates/square_medium_text_button" })
        fit(pg, PANEL_W - 154, height - 40, 70, 28, (settings.page + 1) .. " / " .. pages)
        if pg then pcall(function() pg:SetInteractive(false) end) end
        local nxt = new_child(panel, SNEXT, { "ui/templates/square_medium_text_button" })
        fit(nxt, PANEL_W - 78, height - 40, 66, 28, "Next")
        if nxt then pcall(function() nxt:SetDisabled(settings.page >= pages - 1) end) end
    end
    trace("settings panel open: " .. #list .. " provinces, page " .. (settings.page + 1) .. " of " .. pages)
    describe_once(find_uicomponent(panel, SNAME .. "1"))
end

local function settings_click(id)
    if id == SBUTTON or id == SLABEL then
        if settings.open then destroy_panel() else settings.page = 0; build_panel() end
    elseif id == SCLOSE then destroy_panel()
    elseif id == SPREV then settings.page = settings.page - 1; build_panel()
    elseif id == SNEXT then settings.page = settings.page + 1; build_panel()
    elseif string.sub(id, 1, #SCHECK) == SCHECK then
        local row = settings.rows[tonumber(string.sub(id, #SCHECK + 1)) or 0]
        if not row then return end
        if not row.locked then
            skipped_provinces[row.id] = (not skipped_provinces[row.id]) or nil
            trace("province " .. row.id .. (skipped_provinces[row.id] and " unchecked (skipped)" or " checked (managed)"))
        end
        show_row(row)
    end
end

local function install_settings_ui(is_player)
    if not CONFIG.settings_button then return end
    core:remove_listener("upgrade_all_settings_click")
    core:add_listener("upgrade_all_settings_click", "ComponentLClickUp",
        function(c)
            local id = c.string
            if id == SBUTTON or id == SLABEL then return true end
            if not settings.open or type(id) ~= "string" then return false end
            if id ~= SCLOSE and id ~= SPREV and id ~= SNEXT and string.sub(id, 1, #SCHECK) ~= SCHECK then return false end
            local ok, inside = pcall(function() return uicomponent_descended_from(UIComponent(c.component), settings.open) end)
            return ok and inside == true
        end,
        function(c)
            -- One click, one action: a duplicate event before it runs is ignored.
            if settings.busy then return end
            settings.busy = true
            local id = c.string
            cm:callback(function()
                settings.busy = false
                ui("click " .. tostring(id), function() settings_click(id) end)
            end, 0.1)
        end,
        true)
    local function soon(delay)
        cm:callback(function() ui("button", ensure_button) end, delay)
    end
    core:remove_listener("upgrade_all_settings_hud")
    core:add_listener("upgrade_all_settings_hud", "PanelOpenedCampaign",
        function(c) return c.string == "hud_campaign" end, function() soon(0.1) end, true)
    core:remove_listener("upgrade_all_settings_turn")
    core:add_listener("upgrade_all_settings_turn", "FactionTurnStart", is_player, function() soon(0.2) end, true)
    -- Two separate tries after loading (never a timer inside a timer).
    soon(0.5)
    soon(2)
end

---------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------
cm:add_first_tick_callback(function()
    if cm:is_multiplayer() then log("Multiplayer campaign; inactive."); return end
    local player = cm:get_local_faction_name(true)
    PLAYER.faction = player or ""
    local culture_read = nil
    pcall(function()
        local f = cm:get_faction(player)
        local c, sc = f:culture(), f:subculture()
        if type(c) == "string" and c ~= "" then PLAYER.culture = c; culture_read = c end
        if type(sc) == "string" and sc ~= "" then PLAYER.sub = sc end
    end)

    each_output(TRACE_FILE, function(path)
        local f = io.open(path, "r")
        if not f then return end
        local lines = {}
        for line in f:lines() do lines[#lines + 1] = line end
        f:close()
        if #lines > 300 then
            local w = io.open(path, "w")
            if w then
                for i = #lines - 299, #lines do w:write(lines[i], "\n") end
                w:close()
            end
        end
    end)
    trace("---- campaign loaded" .. (CONFIG.test_mode and " (TEST MODE)" or "") .. " ----")
    -- High Elves and Dark Elves only: queueing one culture's buildings for any
    -- other culture is the foreign-culture case that crashes the game.
    local rules = culture_read and CULTURE_RULES[culture_read]
    if not rules then
        trace("Upgrade All only runs for High Elves and Dark Elves; this faction's culture is " .. tostring(culture_read) .. ". Inactive.")
        return
    end
    if rules.protect == "start" and starting_province == "" then
        -- First run in this campaign: the lord's home province is the one left alone.
        pcall(function()
            local home = cm:get_faction(player):home_region()
            if home and not home:is_null_interface() then starting_province = string.lower(home:province_name() or "") end
        end)
        trace("starting province (never touched): " .. (starting_province ~= "" and starting_province or "none found"))
    end
    use_rules(rules)
    trace("rules: " .. rules.name)

    local function is_player(c) local f = c:faction(); return f:is_human() and f:name() == player end

    local function do_work(fkey)
        trace_lines = 0
        for k in pairs(slow_cache) do slow_cache[k] = nil end
        trace("work starting")
        if CONFIG.test_mode then
            local ok, err = pcall(run_test_mode_staged, fkey)
            if not ok then write_summary("Upgrade All test mode error:\n" .. tostring(err)) end
            stored_summary = last_summary
            return
        end
        local ok, result = pcall(run_turn, cm:get_faction(fkey))
        trace("done")
        local text
        if ok then
            stored_summary = summary_body(result, cm:get_faction(fkey):treasury())
            text = compose_summary(result.tribute, result.banish, stored_summary)
        else
            log("ERROR: " .. tostring(result))
            stored_summary = "Hit an error:\n" .. tostring(result)
            text = "Upgrade All hit an error:\n" .. tostring(result)
        end
        write_summary(text)
    end

    -- Start of your next turn: re-read commandments (you may have changed some
    -- after the End Turn run), rewrite the summary file, then show the popup.
    -- Runs right inside the turn-start event (the same pattern as the version
    -- you tested), reading only main settlement slots and commandments.
    local function show_turn_summary(fkey, body)
        trace("turn summary: re-reading commandments")
        local text
        if CONFIG.test_mode then
            text = body
        else
            local ok, tribute, banish = pcall(fresh_commandments, cm:get_faction(fkey))
            if ok then
                trace("turn summary: " .. #tribute .. " tribute, " .. #banish .. " banish")
                text = compose_summary(tribute, banish, body)
            else
                trace("commandment re-read failed: " .. tostring(tribute))
                text = compose_summary({}, {}, body .. "\n\n(Couldn't re-read commandments this turn.)")
            end
        end
        write_summary(text)
        if CONFIG.popup then show_popup(text) end
    end

    local last_run_turn = nil
    local function once_per_turn()
        local turn = cm:turn_number()
        if last_run_turn == turn then return false end
        last_run_turn = turn
        return true
    end

    if CONFIG.run_at == "turn_start" then
        -- Fallback: work a couple of seconds after the turn starts, once the
        -- game has finished its own turn-start processing.
        core:add_listener("upgrade_all_turn_start", "FactionTurnStart", is_player, function(context)
            if not once_per_turn() then return end
            local fkey = context:faction():name()
            trace("turn start; work scheduled")
            cm:callback(function() do_work(fkey) end, 2)
        end, true)
    else
        -- Default: when you click End Turn, before the game processes the turn.
        -- You build what you want during your turn (e.g. Eataine); the script
        -- spends whatever is left above the gold floor.
        core:add_listener("upgrade_all_end_turn", "FactionAboutToEndTurn", is_player, function(context)
            if not once_per_turn() then return end
            trace("end turn clicked")
            do_work(context:faction():name())
        end, true)
        core:add_listener("upgrade_all_turn_summary", "FactionTurnStart", is_player, function(context)
            if stored_summary == "" then return end
            local body, fkey = stored_summary, context:faction():name()
            stored_summary = "" -- shown once
            trace("turn start; showing summary")
            local ok, err = pcall(show_turn_summary, fkey, body)
            if not ok then trace("turn summary failed: " .. tostring(err)) end
        end, true)
    end
    install_settings_ui(is_player)
end)
