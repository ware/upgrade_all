"""Generate tools/data_block.lua (the UA_DATA tables) from RPFM exports.

Usage (from the repository root):
    python3 -I tools/gen_data.py exports tools/data_block.lua

`exports` must hold these RPFM TSV exports (names as in this repository):
    building_levels.tsv                        db/building_levels_tables
    building_effects_junction.tsv              db/building_effects_junction_tables
    effect_bundles_to_effects_junction.tsv     db/effect_bundles_to_effects_junction_tables
    slot_template_permitted_building_chains.tsv db/slot_template_permitted_building_chains_tables
    building_chain_set_items.tsv               db/building_chain_set_items_tables
    building_chains.tsv                        db/building_chains_tables
    building_culture_variants.tsv              db/building_culture_variants_tables

Re-run after a game patch, then `python3 build.py` and `python3 run_tests.py`.
"""
import csv
import re
import sys
import collections
import pathlib

# Cultures the mod builds for, by the tag in their building keys. A tag counts
# only as a whole word ("_def_" or a trailing "_def"): a plain "def" substring
# would also match other races' "defence" buildings.
OUR_TAGS = ["hef", "def"]
OWN_CULTURE = {"hef": "wh2_main_hef_high_elves", "def": "wh2_main_def_dark_elves"}

# Other races' tags. Landmark versions for these are never candidates:
# "..._tmb_1", "..._other" (suffix), or "..._sla_special_..." (mid-key, when
# reached through a chain set or super chain rather than named explicitly).
OTHER_CODES = ("dwf nor emp grn vmp tmb skv lzd wef brt chs kho nur sla tze dae ogr "
               "ksl cth chd cst woc nag bst kul den "
               # the original game's races also key buildings by full name
               "EMPIRE DWARFS DWARF BRETONNIA VAMPIRES GREENSKINS GREENSKIN SAVAGEORC NORSCA CHAOS BEASTMEN HUMAN TEB").split()

# Every culture's key and the words that mark its buildings, for the role
# table (UA_DATA.roles). Only High Elves and Dark Elves are built for today;
# the rest are there so a future layout can be derived and checked.
CULTURE_WORDS = {
    "wh2_main_hef_high_elves": ["hef"], "wh2_main_def_dark_elves": ["def"],
    "wh_main_emp_empire": ["emp", "EMPIRE"], "wh_main_dwf_dwarfs": ["dwf", "DWARFS", "DWARF"],
    "wh_main_brt_bretonnia": ["brt", "BRETONNIA"], "wh_main_vmp_vampire_counts": ["vmp", "VAMPIRES"],
    "wh_main_grn_greenskins": ["grn", "GREENSKINS", "GREENSKIN", "SAVAGEORC"], "wh_main_chs_chaos": ["chs", "CHAOS"],
    "wh_dlc08_nor_norsca": ["nor", "NORSCA"], "wh_dlc05_wef_wood_elves": ["wef"], "wh_dlc03_bst_beastmen": ["bst"],
    "wh2_main_lzd_lizardmen": ["lzd"], "wh2_main_skv_skaven": ["skv"], "wh2_dlc09_tmb_tomb_kings": ["tmb"],
    "wh2_dlc11_cst_vampire_coast": ["cst"], "wh3_main_ksl_kislev": ["ksl"], "wh3_main_cth_cathay": ["cth"],
    "wh3_main_kho_khorne": ["kho"], "wh3_main_nur_nurgle": ["nur"], "wh3_main_sla_slaanesh": ["sla"],
    "wh3_main_tze_tzeentch": ["tze"], "wh3_main_dae_daemons": ["dae"], "wh3_main_ogr_ogre_kingdoms": ["ogr"],
    "wh3_dlc23_chd_chaos_dwarfs": ["chd"], "wh3_dlc29_nag_undead_legions": ["nag"],
}

# Layout roles -> fragments of the game's building_superchain key. The same
# superchains are used by every race, so a role resolves to each culture's
# own chain for it (High Elves: growth -> wh2_main_hef_farm; Dark Elves:
# growth -> wh2_main_def_farm; Empire: growth -> wh_main_EMPIRE_farm_basic).
ROLES = [
    ("growth",      ["infrastructure1_farm"]),
    ("order",       ["infrastructure3_order"]),
    ("income2",     ["infrastructure4_energy"]),
    ("walls_major", ["defence_major", "_walls"]),
    ("industry",    ["infrastructure2_industry"]),
    ("explore",     ["foreign_slot_discovery"]),
    ("trade",       ["infrastructure5_tradingspying"]),
    ("walls_minor", ["defence_minor", "human_garrison"]),
    ("worship",     ["support2_worship"]),
    ("wizards",     ["support3_wizards"]),
    ("special",     ["support4_other"]),
]



def has_tag(key, tag):
    return ("_" + tag + "_") in key or key.endswith("_" + tag)


def ours(key):
    return any(has_tag(key, t) for t in OUR_TAGS)


def load(path):
    with open(path, encoding="utf-8", newline="") as f:
        rows = list(csv.reader(f, delimiter="\t"))
    header = rows[0]
    # row 2 is RPFM's "#table;version" line
    return [dict(zip(header, r)) for r in rows[2:] if r and any(r)]


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def num(v):
    f = float(v or 0)
    return int(f) if f == int(f) else f


def main(exports, out_path):
    ex = pathlib.Path(exports)
    levels = load(ex / "building_levels.tsv")
    effects = load(ex / "building_effects_junction.tsv")
    bundles = load(ex / "effect_bundles_to_effects_junction.tsv")
    permitted = load(ex / "slot_template_permitted_building_chains.tsv")
    set_items = load(ex / "building_chain_set_items.tsv")
    chains_tbl = load(ex / "building_chains.tsv")
    variants = load(ex / "building_culture_variants.tsv")

    chain_of, level_of, req_of, cost, build_time = {}, {}, {}, {}, {}
    by_chain = collections.defaultdict(list)
    for r in levels:
        k = r["level_name"]
        chain_of[k] = r["chain"]
        level_of[k] = int(r["level"] or 0)
        req_of[k] = int(r["primary_slot_building_building_level_requirement"] or 0)
        cost[k] = int(r["create_cost"] or 0)
        build_time[k] = int(r["create_time"] or 0)
        by_chain[r["chain"]].append(k)

    def first_level(chain):
        ks = sorted(by_chain.get(chain, []), key=lambda k: level_of[k])
        return ks[0] if ks else None

    out = []
    out.append("-- GENERATED by tools/gen_data.py from your RPFM exports. Do not edit by hand.")
    out.append("local UA_DATA = {}")

    # first: chain -> tier-1 building, for our cultures' chains
    out.append("-- chain key -> tier-1 building key")
    out.append("UA_DATA.first = {")
    for c in sorted(by_chain):
        if not ours(c):
            continue   # only High Elf and Dark Elf chains are ever newly constructed
        out.append(f"  [{lua_str(c)}] = {lua_str(first_level(c))},")
    out.append("}")

    out.append("-- building key -> chain key (High Elf, Dark Elf and special buildings)")
    out.append("UA_DATA.chain = {")
    for k in sorted(chain_of):
        if ours(k) or "special" in k:
            out.append(f"  [{lua_str(k)}] = {lua_str(chain_of[k])},")
    out.append("}")

    out.append("-- building key -> { level in its chain, main-settlement level it requires, gold cost, build turns } (High Elf, Dark Elf and special)")
    out.append("UA_DATA.tier = {")
    for k in sorted(level_of):
        if ours(k) or "special" in k:
            out.append(f"  [{lua_str(k)}] = {{{level_of[k]}, {req_of[k]}, {cost[k]}, {build_time[k]}}},")
    out.append("}")

    # score: flat income, % income, growth
    flat = collections.defaultdict(dict)
    pct = collections.defaultdict(dict)
    growth = collections.defaultdict(dict)
    for e in effects:
        if e["context_requirement"]:
            continue  # conditional bonuses (only for some factions/regions) don't count
        b, key, v = e["building"], e["effect"], float(e["value"] or 0)
        if "economy_gdp_mod" in key:
            pct[b][key] = pct[b].get(key, 0) + v
        elif "economy_gdp" in key:
            flat[b][key] = flat[b].get(key, 0) + v
        elif "growth" in key:
            growth[b][key] = growth[b].get(key, 0) + v
    out.append("-- building key -> { flat income, % income, growth } (only buildings with any of these)")
    out.append("UA_DATA.score = {")
    for k in sorted(set(flat) | set(pct) | set(growth)):
        f, p, g = sum(flat[k].values()), sum(pct[k].values()), sum(growth[k].values())
        if f or p or g:
            out.append(f"  [{lua_str(k)}] = {{{num(f)}, {num(p)}, {num(g)}}},")
    out.append("}")

    out.append("-- climate bundles that double construction time (+100% all buildings)")
    out.append("UA_DATA.slow_bundles = {")
    slow = sorted({b["effect_bundle_key"] for b in bundles
                   if "climate" in b["effect_bundle_key"]
                   and "construction_time" in b["effect_key"] and float(b["value"] or 0) >= 100})
    for k in slow:
        out.append(f"  {lua_str(k)},")
    out.append("}")

    # landmark candidates per slot template
    set_members = collections.defaultdict(list)
    for r in set_items:
        set_members[r["set"]].append(r["chain"])
    super_members = collections.defaultdict(list)
    for r in chains_tbl:
        if r["building_superchain"]:
            super_members[r["building_superchain"]].append(r["key"])
    rows_of = collections.defaultdict(list)
    for v in variants:
        rows_of[v["building"]].append(v)

    suffix_re = re.compile(r"_(%s|other)(_\d+|_base)?$" % "|".join(OTHER_CODES))

    def suffixed(c):
        return suffix_re.search(c) is not None

    def mid_tagged(c):
        return any("_" + cd + "_" in c for cd in OTHER_CODES)

    by_template = collections.defaultdict(list)
    for r in permitted:
        if r["remove"] == "true":
            continue
        by_template[r["slot_template"]].append(r)

    candidates = {}
    for t in sorted(by_template):
        if "primary" in t:
            continue
        tnorm = t.replace("_secondary", "")
        found = {}
        for r in by_template[t]:
            explicit = bool(r["chain"])
            if r["chain"]:
                src = [(r["chain"], False)]
            elif r["super_chain"]:
                src = [(c, r["super_chain"] in tnorm) for c in super_members[r["super_chain"]]]
            elif r["chain_set"] and "landmark" in r["chain_set"]:
                named = r["chain_set"].split("landmark_", 1)[1] in tnorm
                src = [(c, named) for c in set_members[r["chain_set"]]]
            else:
                src = []
            for c, named in src:
                if suffixed(c) or (not explicit and mid_tagged(c)):
                    continue  # other races' versions are never ours
                k = first_level(c)
                if k:
                    found[k] = found.get(k, False) or named
        if found:
            candidates[t] = list(found.items())  # in the order the game's tables list them

    out.append("-- slot template -> candidate landmarks { key, named after this settlement, culture rows }")
    out.append("-- culture rows: { culture, subculture, faction, disables } from building_culture_variants")
    out.append("UA_DATA.landmark_candidates = {")
    landmark_levels = set()
    for t, cands in candidates.items():
        out.append(f"  [{lua_str(t)}] = {{")
        for k, named in cands:
            rows = rows_of.get(k, [])
            rs = ", ".join("{%s, %s, %s, %s}" % (lua_str(v["culture"]), lua_str(v["subculture"]), lua_str(v["faction"]),
                                                  "true" if v["disables"] == "true" else "false") for v in rows)
            out.append(f"    {{ {lua_str(k)}, {'true' if named else 'false'}, {{ {rs} }} }},")
            landmark_levels.update(by_chain[chain_of[k]])
        out.append("  },")
    out.append("}")

    out.append("-- every level of those landmark chains (allowed through the crash guard)")
    out.append("UA_DATA.landmark_ok = {")
    for k in sorted(landmark_levels):
        out.append(f"  [{lua_str(k)}] = true,")
    out.append("}")

    # Lord-specific chains: a faction-only row and no level open to everyone.
    faction_chains = {chain_of[v["building"]] for v in variants
                      if v["faction"] and ours(v["building"]) and v["building"] in chain_of}
    open_chains = {chain_of[v["building"]] for v in variants
                   if not (v["culture"] or v["subculture"] or v["faction"]) and v["building"] in chain_of}
    out.append("-- lord-specific High Elf / Dark Elf chains (faction-only culture variants): never demolished")
    out.append("UA_DATA.unique_chain = {")
    for c in sorted(faction_chains - open_chains):
        out.append(f"  [{lua_str(c)}] = true,")
    out.append("}")

    # Tagged keys whose culture rows name only other cultures
    # (silent_sanctum_def_boost: "def" there is "defence").
    cultures_of = collections.defaultdict(set)
    for v in variants:
        if v["culture"]:
            cultures_of[v["building"]].add(v["culture"])
    wrong = sorted(k for k in chain_of for t in OUR_TAGS
                   if has_tag(k, t) and cultures_of.get(k) and OWN_CULTURE[t] not in cultures_of[k])
    out.append("-- tagged keys that belong to another culture: never queued")
    out.append("UA_DATA.wrong_culture = {")
    for k in wrong:
        out.append(f"  [{lua_str(k)}] = true,")
    out.append("}")

    # Roles: culture -> role -> chains, from building_superchain. Faction-only
    # (lord-specific) chains, horde chains, specials and the prologue are left
    # out; what remains is the ordinary chain each culture has for the role.
    # More than one chain is kept in table order so the engine can report it.
    all_faction_chains = {chain_of[v["building"]] for v in variants if v["faction"] and v["building"] in chain_of}
    unique_any = all_faction_chains - open_chains
    superchain = {r["key"]: r["building_superchain"] for r in chains_tbl}
    horde_chain = {r["key"] for r in chains_tbl if r["optional_required_horde_commander"]}
    roles_out = {}
    for culture, words in CULTURE_WORDS.items():
        found = collections.defaultdict(list)
        for c in sorted(superchain):
            if not (set(c.split("_")) & set(words)):
                continue
            if c in unique_any or c in horde_chain or "special" in c or "prologue" in c:
                continue
            for role, frags in ROLES:
                if any(f in superchain[c] for f in frags):
                    found[role].append(c)
        if found:
            roles_out[culture] = found
    out.append("-- culture -> layout role -> { chain, ... } from building_superchain (see ROLES in gen_data.py)")
    out.append("UA_DATA.roles = {")
    for culture in sorted(roles_out):
        out.append(f"  [{lua_str(culture)}] = {{")
        for role, _ in ROLES:
            cs = roles_out[culture].get(role)
            if cs:
                out.append(f"    {role} = {{ {', '.join(lua_str(c) for c in cs)} }},")
        out.append("  },")
    out.append("}")

    pathlib.Path(out_path).write_text("\n".join(out) + "\n")
    print(f"wrote {out_path}: {len(candidates)} landmark templates, "
          f"{len(faction_chains - open_chains)} lord-specific chains, {len(wrong)} wrong-culture keys")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
