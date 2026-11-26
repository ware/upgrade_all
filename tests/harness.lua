-- Test harness: a fake Total War: Warhammer III campaign for upgrade_all.lua.
--
-- It imitates exactly the game calls the mod makes, and turns every behaviour
-- that crashed or misbehaved in the real game into a test failure:
--   * string.find / match / gsub / gmatch called by the mod (fatal in-game)
--   * another culture's building queued (crashes the game)
--   * slots read or buildings queued inside FactionTurnStart
--   * a timer started from inside another timer (never fires in-game)
--   * LockPriority / RegisterTopMost, reusing a dying UI name
--
-- Lua 5.1, run through run_tests.py (lupa). Loaded by tests/test_upgrade_all.lua.

H = {}            -- harness API used by the tests
W = nil           -- the current fake world

---------------------------------------------------------------------------
-- Plain-Lua helpers (the harness itself never uses string.find, so the
-- string.find trap only ever catches the mod)
---------------------------------------------------------------------------
function H.contains(hay, needle)
    if type(hay) ~= "string" then return false end
    for i = 1, #hay - #needle + 1 do
        if string.sub(hay, i, i + #needle - 1) == needle then return true end
    end
    return false
end
local contains = H.contains

function H.count(hay, needle)
    local n, i = 0, 1
    while i <= #hay - #needle + 1 do
        if string.sub(hay, i, i + #needle - 1) == needle then n = n + 1; i = i + #needle else i = i + 1 end
    end
    return n
end

function H.lines(text)
    local out, cur = {}, {}
    for i = 1, #text do
        local c = string.sub(text, i, i)
        if c == "\n" then out[#out + 1] = table.concat(cur); cur = {} else cur[#cur + 1] = c end
    end
    out[#out + 1] = table.concat(cur)
    return out
end

local function has_tag(key, tag)
    local t = "_" .. tag
    return contains(key, t .. "_") or string.sub(key, -#t) == t
end

-- "chain_3" -> "chain", 3
local function split_level(key)
    local i = #key
    while i > 0 and string.sub(key, i, i) >= "0" and string.sub(key, i, i) <= "9" do i = i - 1 end
    if i < #key and string.sub(key, i, i) == "_" then
        return string.sub(key, 1, i - 1), tonumber(string.sub(key, i + 1))
    end
    return key, nil
end
H.split_level = split_level

---------------------------------------------------------------------------
-- Highest level of each chain (for get_building_level_upgrades). Chains not
-- listed have 3 levels; keys without a level number never upgrade.
---------------------------------------------------------------------------
H.MAX_TIER = {
    wh2_main_hef_settlement_major = 5, wh2_main_hef_settlement_minor = 4,
    wh2_main_def_settlement_major = 5, wh2_main_def_settlement_minor = 3,
    wh2_main_special_settlement_colony_major_hef = 5, wh3_dlc27_hef_colony_settlement_major = 5,
    wh2_main_special_settlement_gaean_vale = 5,
    wh2_main_hef_order = 3, wh2_main_hef_court = 3, wh2_main_hef_farm = 3, wh2_main_hef_industry = 3,
    wh2_main_hef_port = 3, wh2_main_hef_defence_major = 3, wh2_main_hef_defence_minor = 2,
    wh2_main_hef_embassy = 3, wh2_main_hef_dragons = 3, wh2_main_foreign_slot_discovery_hef = 3,
    wh2_main_def_farm = 3, wh2_main_def_order = 3, wh2_main_def_industry = 3, wh2_main_def_slaves = 2,
}
H.MAXED_MAJOR = "wh2_main_hef_settlement_major_5"
H.MAXED_MINOR = "wh2_main_hef_settlement_minor_4"
H.GROWING_MAJOR = "wh2_main_hef_settlement_major_3"
H.GROWING_MINOR = "wh2_main_hef_settlement_minor_2"
H.DEF_MAJOR_MAX = "wh2_main_def_settlement_major_5"
H.DEF_MINOR_MAX = "wh2_main_def_settlement_minor_3"
H.TRIBUTE = "wh2_main_edict_hef_tribute_for_the_king"
H.BANISH = "wh2_main_edict_hef_banish_corruption"
H.ENFORCE = "wh2_main_edict_def_enforce_tribute"

-- Real gold costs (building_levels) for the buildings the tests price; others cost 1000.
H.REAL_COST = {
    wh2_main_hef_order_1 = 1500, wh2_main_hef_court_1 = 2000, wh2_main_hef_defence_major_1 = 2000,
    wh2_main_hef_industry_1 = 1000, wh2_main_foreign_slot_discovery_hef_1 = 2000, wh2_main_hef_embassy_1 = 2500,
    wh2_main_hef_dragons_1 = 6000, wh2_main_hef_farm_1 = 1000,
}

---------------------------------------------------------------------------
-- Slots and regions
---------------------------------------------------------------------------
local function mkslot(region, index, kind, building, opts)
    opts = opts or {}
    local s = { region = region, index = index, kind = kind, b = building or nil,
                active_ = opts.active ~= false, resource = opts.resource, template = opts.template }
    s.id = region.key .. "#" .. index
    function s:is_null_interface() return false end
    function s:active() return self.active_ end
    function s:type()
        if W.in_event == "FactionTurnEnd" then W.crashes[#W.crashes + 1] = "slot read during FactionTurnEnd" end
        return self.kind
    end
    function s:has_building()
        if W.in_event == "FactionTurnStart" and self.kind ~= "primary" then
            W.crashes[#W.crashes + 1] = "read a non-main slot during FactionTurnStart"
        end
        return self.b ~= nil
    end
    function s:building()
        local slot = self
        return { name = function() return slot.b end }
    end
    function s:template_key() return self.template or "" end
    function s:resource_key() return self.resource or "" end
    return s
end

-- mkregion(key, province, opts)
--   capital, gdp, po, main (main building), buildings = { key or false, ... }
--   (secondary slots), port = port building key (its own "port" slot),
--   locked = number of inactive slots, resource + resource_slot (1-based
--   secondary slot carrying the resource), template (secondary slot template),
--   bundles = { bundle = true }, edict, corruption
function H.mkregion(key, province, opts)
    opts = opts or {}
    local r = { key = key, prov = province, capital = opts.capital or false, gdp_ = opts.gdp or 0,
                po = opts.po or 5, bundles = opts.bundles or {}, opts = opts, slots = {} }
    local idx = 0
    if opts.main ~= false then
        r.primary = mkslot(r, idx, "primary", opts.main or (r.capital and H.GROWING_MAJOR or H.GROWING_MINOR))
        r.slots[#r.slots + 1] = r.primary
        idx = idx + 1
    end
    if opts.port then
        r.slots[#r.slots + 1] = mkslot(r, idx, "port", opts.port)
        idx = idx + 1
    end
    for i, b in ipairs(opts.buildings or {}) do
        local res = (opts.resource_slot == i) and opts.resource or nil
        r.slots[#r.slots + 1] = mkslot(r, idx, "secondary", b or nil, { resource = res, template = opts.template })
        idx = idx + 1
    end
    if opts.resource and not opts.resource_slot then r.primary.resource = opts.resource end
    for _ = 1, (opts.locked or 0) do
        r.slots[#r.slots + 1] = mkslot(r, idx, "secondary", nil, { active = false, template = opts.template })
        idx = idx + 1
    end

    function r:name() return self.key end
    function r:province_name() return self.prov end
    function r:is_province_capital() return self.capital end
    function r:public_order() return self.po end
    function r:gdp() return self.gdp_ end
    function r:is_null_interface() return false end
    function r:slot_list()
        if W.in_event == "FactionTurnEnd" then W.crashes[#W.crashes + 1] = "slot_list during FactionTurnEnd" end
        local slots = self.slots
        return { num_items = function() return #slots end, item_at = function(_, i) return slots[i + 1] end }
    end
    function r:has_effect_bundle(b) return self.bundles[b] == true end
    function r:faction_province_has_effect_bundle(b) return false end
    function r:get_active_edict_key()
        if W.edict_error then error("no edict interface") end
        return self.opts.edict or ""
    end
    function r:province()
        local prov = self.prov
        return { regions = function()
            if W.province_count_error then error("no province interface") end
            local n = (W.not_owned and W.not_owned[prov]) or 0
            for _, other in ipairs(W.regions) do if other.prov == prov then n = n + 1 end end
            return { num_items = function() return n end }
        end }
    end
    return r
end

function H.region(key)
    for _, r in ipairs(W.regions) do if r.key == key then return r end end
end

-- Keys queued in a region this test (in order).
function H.queued_in(region_key)
    local out = {}
    for _, q in ipairs(W.queued) do if q.region == region_key then out[#out + 1] = q.key end end
    return out
end
function H.has(list, value)
    for _, v in ipairs(list) do if v == value then return true end end
    return false
end
function H.joined(region_key) return table.concat(H.queued_in(region_key), ",") end

---------------------------------------------------------------------------
-- UI: generic components (settings panel, menu bar) and dialogue boxes (popup)
---------------------------------------------------------------------------
local function mkcomp(name, parent, layout, x, y, w, h)
    local c = { name = name, parent_ = parent, layout = layout, children = {}, state = "active",
                x = x or 0, y = y or 0, w = w or 30, h = h or 30, visible = true }
    local m = {}
    function m.Id() return c.name end
    function m.Parent() return c.parent_ end
    function m.ChildCount() return #c.children end
    function m.Find(_, i) return c.children[i + 1] end
    function m.CreateComponent(_, n, lay)
        if W.ui.fail_settings then error("CreateComponent failed") end
        for _, k in ipairs(c.children) do
            if k.name == n then W.crashes[#W.crashes + 1] = "duplicate child " .. n end
        end
        local k = mkcomp(n, c, lay, 0, 0, (lay == "ui/templates/round_small_button") and 30 or 24, 24)
        c.children[#c.children + 1] = k
        if lay == "ui/templates/square_medium_text_button" or lay == "ui/templates/button_txt" then
            -- like the game: the visible text lives in a child that keeps its own size
            k.children[1] = mkcomp("button_txt", k, nil, 20, 0, 60, 20)
            if W.ui.extra_bar_child then k.children[2] = mkcomp("bar_image", k, nil, 20, 0, 60, 20) end
        end
        return k
    end
    function m.Position() return c.x, c.y end
    function m.Width() return c.w end
    function m.Height() return c.h end
    function m.Resize(_, a, b) c.w, c.h = a, b end
    function m.MoveTo(_, a, b) c.x, c.y = a, b end
    function m.SetState(_, st) c.state = st end
    function m.CurrentState() return c.state end
    function m.SetStateText(_, t) c.text = t end
    function m.GetStateText() return c.text end
    function m.SetTextHAlign(_, v) c.halign = v end
    function m.SetTextXOffset(_, l) c.xoff = l end
    function m.SetDockingPoint(_, v) c.dock = v end
    function m.SetDisabled(_, d) c.disabled = d end
    function m.SetVisible(_, v) c.visible = v end
    function m.SetTooltipText(_, t) c.tip = t end
    function m.DockingPoint() return 6 end
    function m.GetDockOffset() return -100, 10 end
    function m.LockPriority() W.crashes[#W.crashes + 1] = "LockPriority " .. c.name end
    function m.RegisterTopMost() W.crashes[#W.crashes + 1] = "RegisterTopMost " .. c.name end
    function m.Destroy()
        if c.destroyed then W.crashes[#W.crashes + 1] = "double destroy " .. c.name end
        c.destroyed = true
        if c.parent_ and c.parent_.children then
            for i, k in ipairs(c.parent_.children) do if k == c then table.remove(c.parent_.children, i) break end end
        end
        if W.ui.comps[c.name] == c then W.ui.comps[c.name] = nil; W.ui.dying[c.name] = true end
    end
    return setmetatable(c, { __index = function(_, k)
        if m[k] then return m[k] end
        local first = string.sub(k, 1, 1)
        if first >= "A" and first <= "Z" then return function() end end -- other UI methods: no-op
        return nil
    end })
end
H.mkcomp = mkcomp

local function search_children(parent, name, depth)
    for _, k in ipairs(parent.children or {}) do if k.name == name then return k end end
    if depth > 6 then return nil end
    for _, k in ipairs(parent.children or {}) do
        local f = search_children(k, name, depth + 1)
        if f then return f end
    end
end

local function make_root()
    local root = mkcomp("root", nil, nil, 0, 0, 1920, 1080)
    if W.with_menu_bar then
        local bar = mkcomp("menu_bar", root, nil, 900, 0, 400, 50)
        local group = mkcomp("buttongroup", bar, nil, 900, 5, 300, 40)
        bar.children = { group }
        group.children = {
            mkcomp("button_missions", group, nil, 1000, 8, 36, 36),
            mkcomp("button_diplomacy", group, nil, 1040, 8, 36, 36),
            mkcomp("button_search_panel", group, nil, 1120, 8, 36, 36),
        }
        root.children = { bar }
    end
    return root
end

-- A dialogue box (the summary popup): its DY_text records what was shown.
local function make_dialogue(name, root)
    local box = mkcomp(name, root, "ui/common ui/dialogue_box", 0, 0, 400, 300)
    local text = mkcomp("DY_text", box)
    local old = getmetatable(text).__index
    setmetatable(text, { __index = function(t, k)
        if k == "SetStateText" then
            return function(_, s) W.dialogs[#W.dialogs + 1] = s; W.sequence[#W.sequence + 1] = "popup"; text.text = s end
        end
        return old(t, k)
    end })
    local both = mkcomp("both_group", box)
    local ok = mkcomp("ok_group", box)
    local tick = mkcomp("button_tick", ok)
    ok.children = { tick }
    box.children = { text, both, ok }
    return box
end

---------------------------------------------------------------------------
-- The world
---------------------------------------------------------------------------
-- new_world(regions, treasury): a fresh campaign. Set fields on W before
-- H.load() to change the faction (W.culture, W.player, W.home), add a menu
-- bar (W.with_menu_bar), localised names (W.loc), and so on.
function H.new_world(regions, treasury)
    W = {
        regions = regions or {}, treasury = treasury or 100000, turn = 1,
        culture = "wh2_main_hef_high_elves", player = "wh2_main_hef_eataine", home = nil,
        queued = {}, demolished = {}, listeners = {}, timers = {}, save_cbs = {}, load_cbs = {},
        invalid = {}, costs = {}, files = {}, trace_file = "", summaries = {}, dialogs = {}, sequence = {},
        crashes = {}, dropped_timers = 0, find_calls = 0, multiplayer = false,
        ui = { comps = {}, dying = {} }, loc = {},
    }
    W.cost = function(k) return W.costs[k] or H.REAL_COST[k] or 1000 end
    return W
end

local function faction()
    local f = {}
    function f:name() return W.player end
    function f:treasury() return W.treasury end
    function f:is_human() return true end
    function f:is_null_interface() return false end
    function f:culture() if W.culture_error then error("culture failed") end return W.culture end
    function f:subculture()
        if W.subculture then return W.subculture end
        return (W.culture == "wh2_main_def_dark_elves") and "wh2_main_sc_def_dark_elves" or "wh2_main_sc_hef_high_elves"
    end
    function f:region_list()
        if W.region_list_error then error("region list failed") end
        local rs = W.regions
        return { num_items = function() return #rs end, item_at = function(_, i) return rs[i + 1] end }
    end
    function f:home_region()
        for _, r in ipairs(W.regions) do if r.key == W.home then return r end end
        return { is_null_interface = function() return true end }
    end
    return f
end

local running_timer = false

local function install_globals()
    local f = faction()
    W.faction = f
    W.root = make_root()
    cm = {
        is_multiplayer = function() return W.multiplayer end,
        get_local_faction_name = function() return W.player end,
        get_faction = function() return f end,
        turn_number = function() return W.turn end,
        add_saving_game_callback = function(_, cb) W.save_cbs[#W.save_cbs + 1] = cb end,
        add_loading_game_callback = function(_, cb) W.load_cbs[#W.load_cbs + 1] = cb end,
        add_first_tick_callback = function(_, cb) W.first_tick = cb end,
        save_named_value = function(_, k, v) W.saved = W.saved or {}; W.saved[k] = v end,
        load_named_value = function(_, k, d) return d end,
        callback = function(_, fn, delay)
            if running_timer then W.dropped_timers = W.dropped_timers + 1; return end -- never fires in-game
            W.timers[#W.timers + 1] = { fn = fn, delay = delay or 0 }
        end,
        get_building_level_upgrades = function(_, key)
            if W.upgrades and W.upgrades[key] then return W.upgrades[key] end
            local chain, lvl = split_level(key)
            if not lvl then return {} end
            local max = H.MAX_TIER[chain] or 3
            if lvl >= max then return {} end
            return { chain .. "_" .. (lvl + 1) }
        end,
        add_building_to_settlement_queue = function(_, slot, key)
            if W.in_event == "FactionTurnStart" then W.crashes[#W.crashes + 1] = "queued during FactionTurnStart" end
            -- As in the game: another culture's building crashes it.
            local own = (W.culture == "wh2_main_def_dark_elves") and "def" or "hef"
            -- Recorded as well as raised: the mod's own error handling must not hide it.
            local function crash(msg) W.crashes[#W.crashes + 1] = msg; error("GAME CRASH: " .. msg) end
            for _, tag in ipairs({ "hef", "def", "emp", "tmb", "vmp", "dwf", "wef", "lzd", "skv", "cst", "nag", "chd" }) do
                if tag ~= own and has_tag(key, tag) then crash("queued another culture's building " .. key) end
            end
            if string.sub(key, 1, #"wh2_dlc17_silent_sanctum_def_boost") == "wh2_dlc17_silent_sanctum_def_boost" then crash("queued " .. key) end
            if W.invalid[key] then return end -- the game refuses: nothing charged
            W.treasury = W.treasury - W.cost(key)
            W.queued[#W.queued + 1] = { slot = slot.id, key = key, region = slot.region.key }
        end,
        region_slot_instantly_dismantle_building = function(_, slot)
            if W.in_event == "FactionTurnStart" then W.crashes[#W.crashes + 1] = "demolished during FactionTurnStart" end
            W.demolished[#W.demolished + 1] = slot.b
            slot.b = nil
            if W.demolish_refund then W.treasury = W.treasury + W.demolish_refund end
        end,
        get_total_corruption_value_in_region = function(_, region)
            W.corruption_reads = (W.corruption_reads or 0) + 1
            return region.opts.corruption or 0
        end,
    }
    core = {
        add_listener = function(_, name, ev, cond, cb, persist)
            W.listeners[#W.listeners + 1] = { name = name, ev = ev, cond = cond, cb = cb, persist = persist }
        end,
        remove_listener = function(_, name)
            local keep = {}
            for _, l in ipairs(W.listeners) do if l.name ~= name then keep[#keep + 1] = l end end
            W.listeners = keep
        end,
        get_ui_root = function() return W.root end,
        get_or_create_component = function(_, name, layout)
            if W.ui.dying[name] then W.crashes[#W.crashes + 1] = "recreated dying name " .. name end
            if W.ui.comps[name] then return W.ui.comps[name] end
            if W.ui.fail_settings and layout == "ui/campaign ui/script_dummy" then error("panel failed") end
            local c
            if layout == "ui/common ui/dialogue_box" then c = make_dialogue(name, W.root)
            else c = mkcomp(name, W.root, layout, 0, 0, 10, 10) end
            W.ui.comps[name] = c
            return c, true
        end,
    }
    common = { get_localised_string = function(k) return W.loc[k] or "" end }
    UIComponent = function(x) return x end
    find_uicomponent = function(parent, ...)
        local cur = parent
        for _, name in ipairs({ ... }) do
            if cur == W.root then
                if W.ui.dying[name] then W.crashes[#W.crashes + 1] = "touched dying " .. name end
                cur = W.ui.comps[name] or search_children(W.root, name, 0)
            else
                cur = search_children(cur, name, 0)
            end
            if not cur then return nil end
        end
        return cur
    end
    uicomponent_descended_from = function(u, name)
        local cur = u
        while cur do
            if cur:Id() == name then return true end
            cur = cur:Parent()
        end
        return false
    end
    out = function() end
end

---------------------------------------------------------------------------
-- Files: the trace and summary files land in W instead of on disk
---------------------------------------------------------------------------
local real_io_open = io.open
-- The mod writes to the working folder and (on a Mac) to $HOME; both are
-- caught here by filename so a test run never touches real game logs.
local function ends_with(s, tail) return type(s) == "string" and string.sub(s, -#tail) == tail end
local discard = { write = function() end, close = function() end, lines = function() return function() return nil end end }
io.open = function(path, mode)
    local is_log = ends_with(path, "upgrade_all_trace.txt") or ends_with(path, "upgrade_all_summary.txt")
    if not is_log then return real_io_open(path, mode) end
    if path ~= "upgrade_all_trace.txt" and path ~= "upgrade_all_summary.txt" then
        -- the $HOME copy: swallowed, so the recorded trace isn't doubled
        if mode == "r" then return nil end
        return discard
    end
    local buf = {}
    local handle = {}
    function handle:write(...) for _, s in ipairs({ ... }) do buf[#buf + 1] = s end end
    function handle:lines()
        local ls = H.lines(W.trace_file)
        local i = 0
        return function() i = i + 1; if i < #ls then return ls[i] end end
    end
    function handle:close()
        local text = table.concat(buf)
        if path == "upgrade_all_trace.txt" then
            if mode == "w" then W.trace_file = text else W.trace_file = W.trace_file .. text end
        elseif mode == "w" then
            W.summaries[#W.summaries + 1] = text
            W.sequence[#W.sequence + 1] = "file"
        end
    end
    if mode == "r" and path == "upgrade_all_trace.txt" and W.trace_file == "" then return nil end
    return handle
end

---------------------------------------------------------------------------
-- Running the mod: the string.find trap is on whenever mod code runs
---------------------------------------------------------------------------
local real_find, real_match, real_gsub, real_gmatch = string.find, string.match, string.gsub, string.gmatch
local function trapped(fn, ...)
    string.find = function(...) W.find_calls = W.find_calls + 1; return real_find(...) end
    string.match = function(...) W.find_calls = W.find_calls + 1; return real_match(...) end
    string.gsub = function(...) W.find_calls = W.find_calls + 1; return real_gsub(...) end
    string.gmatch = function(...) W.find_calls = W.find_calls + 1; return real_gmatch(...) end
    local ok, err = pcall(fn, ...)
    string.find, string.match, string.gsub, string.gmatch = real_find, real_match, real_gsub, real_gmatch
    if not ok then error(err, 0) end
end

-- Runs every timer that's due; a timer started from inside another is dropped.
function H.settle()
    for _ = 1, 50 do
        if #W.timers == 0 then return end
        local ts = W.timers
        W.timers = {}
        for _, t in ipairs(ts) do
            running_timer = true
            local ok, err = pcall(trapped, t.fn)
            running_timer = false
            if not ok then error(err, 0) end
        end
    end
end

-- Loads the mod into the current world, as the game does: the script runs,
-- a saved campaign's values are loaded (H.load{ saved = {...} }), then the
-- first tick. cfg sets CONFIG values.
function H.load(cfg, saved)
    install_globals()
    UPGRADE_ALL_CONFIG_OVERRIDE = cfg or {}
    local f = assert(loadfile(SCRIPT))
    trapped(f)
    UPGRADE_ALL_CONFIG_OVERRIDE = nil
    if saved then
        cm.load_named_value = function(_, k, d) if saved[k] ~= nil then return saved[k] end return d end
        for _, cb in ipairs(W.load_cbs) do trapped(cb, {}) end
    end
    if W.first_tick then trapped(W.first_tick) end
    H.settle()
end

-- Everything the mod would save right now.
function H.save()
    local saved = {}
    local real = cm.save_named_value
    cm.save_named_value = function(_, k, v) saved[k] = v end
    for _, cb in ipairs(W.save_cbs) do trapped(cb, {}) end
    cm.save_named_value = real
    return saved
end

-- Save, then load into a fresh game session (same world).
function H.reload(cfg)
    local saved = H.save()
    W.listeners, W.save_cbs, W.load_cbs, W.timers = {}, {}, {}, {}
    W.ui = { comps = {}, dying = {} }
    H.load(cfg, saved)
    return saved
end

function H.fire(ev, str)
    local ctx = { faction = function() return W.faction end, string = str }
    W.in_event = ev
    local ls = {}
    for _, l in ipairs(W.listeners) do ls[#ls + 1] = l end
    for _, l in ipairs(ls) do
        if l.ev == ev and (l.cond == true or l.cond(ctx)) then trapped(l.cb, ctx) end
    end
    W.in_event = nil
end

function H.end_turn()
    H.fire("FactionAboutToEndTurn"); H.settle()
    H.fire("FactionTurnEnd")
    W.turn = W.turn + 1
    H.fire("FactionTurnStart"); H.settle()
end

function H.start_turn()
    W.turn = W.turn + 1
    H.fire("FactionTurnStart"); H.settle()
end

-- Clicks a UI component (fires ComponentLClickUp), then runs timers.
-- dupes > 1 fires the same click event more than once.
function H.click(comp, dupes)
    local ctx = { string = comp:Id(), component = comp }
    for _ = 1, (dupes or 1) do
        local ls = W.listeners
        W.listeners = {}
        for _, l in ipairs(ls) do
            if l.ev == "ComponentLClickUp" and (l.cond == true or l.cond(ctx)) then
                trapped(l.cb, ctx)
                if l.persist then W.listeners[#W.listeners + 1] = l end
            else
                W.listeners[#W.listeners + 1] = l
            end
        end
    end
    H.settle()
end

-- The latest summary file / popup text.
function H.summary() return W.summaries[#W.summaries] or "" end
function H.popup() return W.dialogs[#W.dialogs] or "" end

---------------------------------------------------------------------------
-- Test runner
---------------------------------------------------------------------------
local results = { passed = 0, failed = {} }
H.results = results

function test(name, fn)
    local ok, err = pcall(function()
        fn()
        if W then
            if W.find_calls > 0 then error("the mod called string.find/match/gsub/gmatch " .. W.find_calls .. " times") end
            if W.dropped_timers > 0 then error("the mod started a timer inside a timer " .. W.dropped_timers .. " times") end
            if #W.crashes > 0 and not W.crashes_expected then error("game crash conditions: " .. table.concat(W.crashes, "; ")) end
        end
    end)
    if ok then
        results.passed = results.passed + 1
    else
        results.failed[#results.failed + 1] = name .. ": " .. tostring(err)
        print("  FAIL " .. name .. ": " .. tostring(err))
    end
    W = nil
end

function eq(actual, expected, what)
    if actual ~= expected then
        error((what and (what .. ": ") or "") .. "expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

function H.finish()
    print(string.format("%d passed, %d failed", results.passed, #results.failed))
    TEST_FAILURES = #results.failed
end
