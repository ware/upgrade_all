"""Mutation checks: break one rule in src/engine.lua at a time and confirm the
test suite catches it. A MISSED line means a rule has no test guarding it.

Usage (from the repository root):  python3 tools/mutate.py
Restores src/engine.lua and the built script afterwards, even on failure.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src/engine.lua"

# (what the mutation breaks, exact text in engine.lua, replacement)
MUTATIONS = [
    # crash safety
    ("crash guard: plain substring culture tag", 'return contains(key, t .. "_") or string.sub(key, -#t) == t', "return contains(key, tag)"),
    ("crash guard: other-culture check removed", "    if other_culture_key(key) then return false end\n", ""),
    ("crash guard: wrong-culture deny list removed", "    if UA_DATA.wrong_culture and UA_DATA.wrong_culture[key] then return false end\n", ""),
    ("crash guard: configured landmarks always allowed",
     "    if UA_DATA.landmark_ok and UA_DATA.landmark_ok[key] then return true end\n    return false",
     "    if UA_DATA.landmark_ok and UA_DATA.landmark_ok[key] then return true end\n    for _, lm in pairs(CONFIG.landmarks) do if lm == key then return true end end\n    return false"),
    ("landmarks: other culture's version allowed", "local rank = ok(key) and not other_culture_key(key) and not (UA_DATA.wrong_culture or {})[key] and landmark_rank(rows)", "local rank = ok(key) and landmark_rank(rows)"),
    ("special main upgrade (Gaean Vale) blocked", "local own_upgrade = same_chain and (entry.kind == \"primary\" or not any_culture_tag(key))", "local own_upgrade = false"),
    ("own-chain upgrade: culture tag check removed", "(entry.kind == \"primary\" or not any_culture_tag(key))", "(entry.kind == \"primary\" or true)"),
    ("culture check removed", "    if not rules then\n", "    if false then\n"),
    ("string.find used", "local function contains(hay, needle)\n    if type(hay) ~= \"string\" or type(needle) ~= \"string\" then return false end",
     "local function contains(hay, needle)\n    if type(hay) ~= \"string\" or type(needle) ~= \"string\" then return false end\n    if string.find(hay, needle, 1, true) then return true end"),
    ("string.match used", "    local tail = after(key, \"region_\") or after(key, \"province_\") or key",
     "    local tail = string.match(key, \"region_(.+)$\") or string.match(key, \"province_(.+)$\") or key"),
    ("readable names: marker not stripped", "            local rest = string.sub(text, i + n)\n", "            local rest = string.sub(text, i)\n"),
    # protection and skipping
    ("Eataine not protected", "    if not PROTECTED or PROTECTED == \"\" then return false end\n    return contains", "    if true then return false end\n    return contains"),
    ("skipped provinces still built", "        elseif is_skipped(r) then", "        elseif false then"),
    ("starting province not saved", '    cm:save_named_value(SAVE_KEY .. "_starting_province", starting_province, context)\n', ""),
    ("starting province recomputed every load", '    if rules.protect == "start" and starting_province == "" then', '    if rules.protect == "start" then'),
    # spending and order
    ("unrest not first", "local ga = a.po < 0 and 1 or (a.gdp > 0 and 2 or 3)", "local ga = (a.gdp > 0 and 2 or 3)"),
    ("stops at first unaffordable item", "            stats.why = string.format(\"short of gold (%d needed, %d left)\", need, before)\n            return false",
     "            stats.why = string.format(\"short of gold (%d needed, %d left)\", need, before)\n            stats.stop = \"out of gold\"\n            return false"),
    ("gold floor ignored", "if before - need < CONFIG.gold_floor then", "if before - need < 0 then"),
    ("single pass only", "        if stats.stop or stats.orders == orders_before then break end", "        break"),
    ("upgrades unranked", "                if a.inc ~= b.inc then return a.inc > b.inc end\n", ""),
    ("multi-path upgrades taken", "    if count == 1 then return found end", "    if count >= 1 then return found end"),
    ("refused build counted as success", "        if cost <= 0 and issued ~= true then\n            stats.refused", "        if false then\n            stats.refused"),
    ("refused order asked again next pass", '        if stats.refused_orders[order_id] then stats.why = "refused by the game earlier this turn"; return false end\n', ""),
    ("tier requirement not checked before asking", "        if info and not level_ok(info, key) then", "        if false then"),
    ("refusals counted per pass, not per turn", "            stats.refused_total = stats.refused_total + 1\n", "            stats.refused_total = stats.refused_total + 2\n"),
    # demolition and slots
    ("keep-next exception removed", " and c ~= keep_next\n", "\n"),
    ("specials demolished", ' and not contains(e.current, "special") and not contains(c, "special")', ""),
    ("lord-specific buildings demolished", "\n                and not (UA_DATA.unique_chain and UA_DATA.unique_chain[c]) then", " then"),
    ("allow_demolish ignored", "if CONFIG.allow_demolish and not is_colony(info) then clear_unwanted(info) end", "if not is_colony(info) then clear_unwanted(info) end"),
    ("slot gap: anything placed", "if wanted[chain] or chain == keep_next then place(UA_DATA.first[chain])", "if true then place(UA_DATA.first[chain])"),
    ("colony check too broad", 'contains(info.primary.current, "hef_colony_settlement")', 'contains(info.primary.current, "colony")'),
    # resources, layouts, growth
    ("resource aliases lost", 'oil = "pasture", textiles = "pottery", lead = "salt" }', "}"),
    ("slow climate ignored", "        or (is_slow_province(region) and LAYOUT_SLOW_MINOR or LAYOUT_MINOR)", "        or LAYOUT_MINOR"),
    ("Homesteads kept when grown", "for _, item in ipairs(base) do if item ~= FARM then out[#out + 1] = item end end", "for _, item in ipairs(base) do out[#out + 1] = item end"),
    ("queued final upgrade not counted", "    if p.waiting then return is_maxed(p.target) end", "    if p.waiting then return false end"),
    ("Araby: data's next level never tried", "    if count == 0 and NEXT_LEVEL[key] then\n", "    if false then\n"),
    ("Araby: game's empty list taken as maxed", "    if NEXT_LEVEL[key] then return false end\n    local ups = cm:get_building_level_upgrades(key)\n    return type(ups)", "    local ups = cm:get_building_level_upgrades(key)\n    return type(ups)"),
    ("main building notes not traced", "    for _, tbl in ipairs({ main_note, explain, waiting_on }) do", "    for _, tbl in ipairs({ explain, waiting_on }) do"),
    ("Dark Elf rules never switched on", "    use_rules(rules)\n    trace(\"rules: \"", "    trace(\"rules: \""),
    # landmarks
    ("refused landmark not remembered", "                                refused_landmarks[info.region:name() .. \"|\" .. landmark] = true\n                                trace(\"landmark \" .. landmark .. \" refused at \" .. info.region:name() .. \"; not trying again\")\n                                landmark_open = false",
     "                                landmark_open = false"),
    ("landmark held while settlement too small", "local landmark_open = landmark and not info.chains[chain_of(landmark)] and level_ok(info, landmark)", "local landmark_open = landmark and not info.chains[chain_of(landmark)]"),
    ("faction rows ignored", "        if faction ~= \"\" then spec = (faction == PLAYER.faction) and 1 or nil", "        if faction ~= \"\" then spec = 1"),
    # commandments and summary
    ("Tribute in partly owned provinces", " and owns_whole_province(info.region, #infos) then", " then"),
    ("Tribute in forts", "\n                and not is_fort(info) and owns_whole_province", "\n                and owns_whole_province"),
    ("Banish ignores corruption", "                if known and total <= 0 then banish", "                if true then banish"),
    ("key-based province names", "    if type(loc) == \"string\" and loc ~= \"\" and loc ~= key", "    if false and loc ~= key"),
    ("popup shown at End Turn too", "            do_work(context:faction():name())\n        end, true)", "            do_work(context:faction():name())\n            show_popup(last_summary)\n        end, true)"),
    ("no turn-start re-read", "local ok, tribute, banish = pcall(fresh_commandments, cm:get_faction(fkey))", "local ok, tribute, banish = true, {}, {}"),
    ("turn-start re-read uses full slot reader", "infos[#infos + 1] = primary_info(r, turn)", "infos[#infos + 1] = inspect_region(r, turn)"),
    ("popup not once per turn", 'stored_summary = "" -- shown once', "local _ = 0"),
    ("popup name reused", "        popup_seq = popup_seq + 1\n", ""),
    # orders
    ("orders never expire early", "    if not bt or bt <= 0 then return false end\n    return age > bt", "    if true then return false end\n    return age > bt"),
    ("no slow doubling for orders", "bt * (is_slow_province(region) and 2 or 1) + 1", "bt + 1"),
    # layouts from roles
    ("layouts: previous lists used instead of derived", "    LAYOUT_CAPITAL, LAYOUT_MINOR, LAYOUT_SLOW_MINOR = layouts.capital, layouts.minor, layouts.slow_minor", "    LAYOUT_CAPITAL, LAYOUT_MINOR, LAYOUT_SLOW_MINOR = rules.previous_capital, rules.previous_minor, rules.previous_slow_minor"),
    ("layouts: comparison always says same", "        elseif previous and same_list(derived, previous) then", "        elseif previous then"),
    ("layouts: override ignored", "            if override then\n                out[#out + 1] = override\n            elseif", "            if false then\n            elseif"),
    ("layouts: report not repeated per turn", '        trace("work starting")\n        for _, line in ipairs(layout_report) do trace(line) end\n', '        trace("work starting")\n'),
    ("cancelled orders not forgotten", '        forget_orders(rname, key, "cancelled")\n', ""),
    ("finished orders not forgotten", '        forget_orders(rname, key, "finished")\n', ""),
    ("forget_orders ignores the region", 'if p.target == key and string.sub(id, 1, #head) == head then', 'if p.target == key then'),
    ("idle slot not retried", "                    if working == false then", "                    if false then"),
    ("working slot retried", "                    if working == false then", "                    if working ~= nil then"),
    ("working slot still on the build-time timer", "                    elseif working == true then\n", "                    elseif false then\n"),
    ("issued event ignored", "        if issued == true and cost <= 0 then", "        if false then"),
    ("issued event trusted before ever seen", "    if not signals.issued_seen then return nil end\n", ""),
    ("issued keys never cleared", "        signals.issued = {}\n", ""),
    ("orders not saved", '    cm:save_named_value(SAVE_KEY .. "_pending", serialize_pending(), context)\n', ""),
    ("stale empty-slot note kept", "                explain[info.region:name()] = nil\n", ""),
    # trace
    ("reading lines always traced", "local function detail(msg) if CONFIG.detailed_trace and trace then trace(msg) end end", "local function detail(msg) if trace then trace(msg) end end"),
    ("trace limit never resets", "        trace_lines = 0\n", ""),
    # settings panel
    ("settings: checkbox rebuilds panel", "        show_row(row)\n    end\nend", "        build_panel()\n    end\nend"),
    ("settings: panel name reused", "    settings.seq = settings.seq + 1\n", "    settings.seq = 1\n"),
    ("settings: duplicate clicks toggle twice", "            if settings.busy then return end\n", ""),
    ("settings: clicks outside the panel accepted", "            return ok and inside == true\n        end,\n        function(c)\n            -- One click", "            return true\n        end,\n        function(c)\n            -- One click"),
    ("settings: timer inside a timer", '        cm:callback(function() ui("button", ensure_button) end, delay)', '        cm:callback(function() ui("button", ensure_button); cm:callback(function() end, 1) end, delay)'),
    ("settings: locked row toggles", "        if not row.locked then\n            skipped_provinces", "        if true then\n            skipped_provinces"),
    ("settings: button covers search", "    local dx = sx + (sw >= 16 and sw or bw) + spacing", "    local dx = sx"),
    ("settings: bar text printed twice", '    if mode == "bar" and #kids > 0 then own = "" end\n', ""),
    ("settings: plain text not inset", "c:SetTextXOffset(PLAIN_TEXT_INSET, 0)", "c:SetTextXOffset(0, 0)"),
    ("settings: button duplicated", "    if find_uicomponent(bar, SBUTTON) then return true end\n", ""),
    ("settings: errors escape", '                ui("click " .. tostring(id), function() settings_click(id) end)', "                settings_click(id)"),
    ("settings: choices not saved", '    cm:save_named_value(SAVE_KEY .. "_skipped_provinces", table.concat(skipped, ","), context)\n', ""),
]


def run(cmd):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)


def main():
    good = SRC.read_text()
    missed, bad = [], []
    try:
        for name, old, new in MUTATIONS:
            if good.count(old) != 1:
                bad.append(name)
                print(f"PATTERN NOT FOUND ({good.count(old)}x): {name}")
                continue
            SRC.write_text(good.replace(old, new))
            run([sys.executable, "build.py"])
            r = run([sys.executable, "run_tests.py"])
            failing = [l for l in r.stdout.splitlines() if "FAIL" in l]
            print(("CAUGHT " if failing else "MISSED ") + f"{name} ({len(failing)} failing)")
            if not failing:
                missed.append(name)
    finally:
        SRC.write_text(good)
        run([sys.executable, "build.py"])
    print(f"\n{len(MUTATIONS) - len(missed) - len(bad)} caught, {len(missed)} missed, {len(bad)} patterns not found")
    sys.exit(1 if (missed or bad) else 0)


if __name__ == "__main__":
    main()
