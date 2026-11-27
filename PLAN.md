# Upgrade All — open items

Working list from the 26 Nov 2026 review. Each item has a status and, where a
decision is needed, a **Decision:** line for Ryan to fill in. Items are
numbered for reference in conversation; the order within a section is the
suggested priority.

Status key: `open` · `decided` · `in progress` · `done` · `dropped`

---

## A. Things the trace shows

### A1. ~90 orders refused by the game every End Turn — `done`

Done 26 Nov: every refused order is named once in the trace; refused
`slot|key` pairs are not asked for again within the turn; the data's
main-settlement level requirement rules out placements and upgrades before
the game is asked; the summary reads "Waiting on settlement level: N" /
"Refused by the game (growth, tech...): M".

Result, turn 238: **82 waiting on settlement level, 5 refused by the game**,
and all 5 are settlement upgrades (`major_5` ×4, Zvorak `minor_3`) blocked on
growth. No technology refusals this turn, so **step 5 is deferred**: it only
shows that none of the buildings eligible *this turn* were tech-gated, not
that the tech tree has no building gates (Ryan has not researched most of
it). The signal to revisit is a `refused by the game` trace line for a
non-settlement building. The remaining 5 per turn are harmless; retrying
them less often belongs with A2.

Latest run (turn 237): **87 refused** in the final pass. The loop stops when a
pass places nothing new, so with a trainer it runs 2 passes (the trace shows
`pass 1`, `pass 2`, `done`): roughly 175 refused orders per End Turn, each
one retried once for no reason.

Why it's there: the game has no "can I build this?" call, so "queue it and
see if the treasury dropped" became the universal oracle; new game calls were
avoided during the crash hunt; the summary labels the count "Not allowed yet
(tier, growth, tech)", which framed it as normal; `level_ok` was added only to
fix one landmark case; and the multi-pass loop was designed around gold
changing between passes, not around refusals being the stable outcome.
Only the 5 main-building refusals are visible in the trace (4 capitals at
`settlement_major_4 → 5`, Zvorak `minor_2 → 3`); the other ~82 are
secondary-building upgrades that are counted but never named.

Proposal, in order:

1. **See them.** Log every refused order once per turn at the default trace
   level (`region#slot: key refused by the game`), deduplicated across passes.
2. **Stop retrying within a turn.** Nothing that causes a refusal changes
   between pass 1 and pass 5; remember refused `slot|key` pairs for the turn.
   Cuts orders placed by ~80%, zero risk.
3. **Don't ask when the data already says no.** `UA_DATA.tier[key][2]` is the
   main-settlement level a building needs; `level_ok()` checks it but only for
   landmarks. Apply it to every placement and upgrade.
4. **Report by reason.** Split "Not allowed yet: 87" into "Waiting on
   settlement level: N" (known from data, never attempted) and "Refused by the
   game: M" (growth, tech, unknown).
5. **Later, optional: technology.** Needs a new export
   (`building_level_required_technology_junction_tables`) and a new game call
   (`faction:has_technology()`). Decide after step 1 shows the mix. If the
   remaining refusals are growth-gated capitals, the answer is "retry every
   few turns" rather than a new API.

**Decision:** 1–4 approved and shipped. Step 5 deferred until a tech-gated
refusal appears in the trace.

### A2. Main-building orders that "never appeared" are held too long — `done, awaiting in-game confirmation`

`vulture_mountain` and `tlaqua` held `settlement_major_5` orders from turn
223 for ten turns, then were refused immediately on retry. Ryan's memory:
the pending mechanism was added because, rarely, an order was never really
accepted. Listening to the game's events was never tried before.

**Decision:** keep the turn-count timer but make it the fallback. Shipped:
1. Game events (CA docs: `BuildingCompleted`, `RegionBuildingCancelled`,
   `BuildingConstructionIssued`, `BuildingConstructionIssuedByPlayer`).
   Completed/cancelled clear the order at once; "issued" confirms an order
   was accepted (treasury drop is still accepted on its own, and the trace
   notes when the two disagree, e.g. trainer gold landing mid-call).
2. `slot:is_working()` (also in the CA docs): an idle slot that still lacks
   its ordered building has lost the order; retried next turn.
3. Timer grace tightened from build time + 2 to + 1; `pending_timeout` cap
   unchanged.
Every new game call is in `pcall`; one that fails is switched off for the
session with a single `game signal ... unavailable` trace line.

**To check in the next trace:** whether `issued`/`finished`/`cancelled
(game event)` lines appear, whether any `game signal ... unavailable` line
appears, and whether any "charged ... but the game reported no issued order"
line appears (that would mean script orders don't raise the issued event).

### A3. Commandment reminder in one-settlement provinces — `closed, no change`

Great Desert of Araby is "fully grown" at `settlement_minor_3` (top level for
Dark Elf minors) and will ask for Enforce Tribute Payments until it's set.
Correct by the rules. If the game won't let a commandment be set in such
provinces, the reminder needs an exception like `is_fort`.

**Decision:** Ryan was able to set Enforce Tribute Payments there, so the
reminder was right and one-settlement provinces need no exception.

### A4. Fixed today — `done`
- `string.match` removed; harness traps all pattern functions.
- Data-driven `NEXT_LEVEL`: a main building the data says isn't at top level
  is never treated as maxed, and the data's next level is tried when the game
  lists none.
- Owned culture-neutral buildings (`_other` landmarks, Copher's port) upgraded
  along their own chain; previously refused by the crash guard every turn.
- Trace explains every un-upgraded main building and every "fully grown"
  province at the default level.
- Harness no longer overwrites the real log files in `$HOME`.
- `run_tests.py` fails if the built script or data block is stale.

---

## B. Things the Opus transcript changes

### B1. The "lessons" rest on thinner evidence than the README implies — `done`

Most of the crash hunt ran on a save the game flagged as from an older
version; Opus concluded the save was the underlying problem. Rules derived
with that confounder present:
- Popups crash on Windows (later re-added; work on the Mac).
- No slot reads inside the turn-start event.
- A timer started inside a timer never fires.

The `string.find` finding **was** reproduced on the fresh campaign (the
diagnostic call crashed step 1), so it stands.

The harness enforces all of them. Keeping them costs nothing but constrains
contributors; the README presents them as established.

**Decision:** keep every rule enforced. Ryan: "we were chasing the wrong
problem at the time, but all of the code related to hardening against those
issues is still valuable." README "Lessons" section now says which rules
were reproduced on a fresh campaign and which came from the old-save hunt
(this also covers E1). Status: `done`.

### B2. Two demolition guardrails were lost in the rebuild — `closed, no change`

Opus described, when demolition was added:
- "Only demolish when the replacement can be built right now: the treasury is
  above your floor, and the settlement tier is high enough for it."
- "At most 2 demolitions per settlement per turn (`max_demolish_per_settlement`)."

Neither is in `src/engine.lua` today. `clear_unwanted` demolishes anything
outside the wanted set unconditionally; there is no such CONFIG key. The
slot-gap tests cover part of the intent but not these rules. The gold check
is moot with a trainer; the tier check and the cap aren't.

**Decision:** neither comes back. Ryan: if a building is going to be
demolished, demolish it now; no waiting on gold or settlement tier, no
per-settlement cap. The unconditional `clear_unwanted` is the intended
behaviour and the existing demolition tests already pin it.

### B3. Gold floor default — `done` (revisit with settings)

Opus's live version used `gold_floor = 1000`; the rebuilt code has `0`.
Irrelevant with a trainer, but one of them should be the documented default.

**Decision:** `0` stays the documented default (code and README already
agree). Revisit if a settings UI for CONFIG values is added: a gold floor is
the obvious first setting to expose. **Bring this up again when Ryan asks
about reordering his existing priorities.**

### B4. Log file location is wrong in the README — `done`

Opus added `$HOME` because "the Mac version never produced files in its
working folder." Today the game wrote only to
`…/Total War WARHAMMER III/TotalWarhammer3Data/` and nothing to `$HOME`.
Either the game's working directory changed between versions or the claim
was wrong. The README's log-location paragraph is incorrect for this setup.

**Decision:** everything goes in the game's directory. The `$HOME` copy is
removed from the engine; README gives the Mac path
(`~/Library/Application Support/Steam/steamapps/common/Total War WARHAMMER III/TotalWarhammer3Data/`)
and says Windows uses the install folder. Writing to `~` can be revisited if
it ever matters. Stale `~/upgrade_all_*.txt` files from earlier builds can
be deleted by hand.

### B5. Windows — `done`

Most development ran on Windows (RPFM wasn't on the Mac until today), the
last time a couple of weeks ago; nothing since the rebuild has run there.

**Decision:** README now says built against v9.0.5 for macOS, developed
largely on Windows, current build played only on the Mac. If a Windows
session happens later, one turn's trace from it would confirm the current
build (popups, settings button); not required.

### B6. The trainer changes the priorities — `noted`

With ~4.9M gold, `gold_floor`, spend-to-zero, income-first ordering and the
multi-pass refund logic are inert. Game refusals (A1) are the only limiter.
No action by itself; it informs A1, B2, B3.

Scale: the current (Dark Elf) campaign started 4 days ago, when Dark Elf
support was added. The gold-rationing paths have been exercised in play
before that, just not since the rebuild. Not an immediate concern.

**Follow-up, after this plan is worked through:** Ryan starts a new
campaign and plays a few hours; I read the trace and summary files and
make recommendations from what actually ran.

---

## C. Design

### C0. Packaging — `done`
`build.py --pack` makes `dist/upgrade_all.pack` with rpfm_cli as a movie
pack (the macOS launcher doesn't manage local packs; movie packs load
unconditionally). `--install` copies it into the game's data folder. CI
builds the pack and uploads it with the script as the `upgrade_all`
artifact. **Revisit the movie type if the mod is ever published.**

### C1. CONFIG is compiled in — `deferred`
Every change is edit → `build.py --install` → restart the game. The settings panel already
persists per-campaign state in the save; `gold_floor`, `allow_demolish`,
`popup` could live there with a few more rows.
**Decision:** deferred. C0 made a rebuild one command; the knobs change
rarely; the panel is the riskiest code and saves per campaign (wrong for
global settings). Revisit when the mod is published or a contributor can't
rebuild. When it comes back, prefer an optional `upgrade_all_config.txt`
override file in the game's working folder (`key = value`, read at load
with plain string ops; the mod already reads files there) over more UI
rows; keep the panel for per-campaign choices. First knob to expose:
`gold_floor` (B3).

### C2. Layouts are code, not data — `open`
The capital/minor sequences in `CULTURE_RULES` are the first thing another
player would want to change, and today that's a source edit.
**Decision:**

### C3. Other cultures — `open`
Architecture is culture-generic; adding one is a layout, a tag in `OUR_TAGS`,
and a real test campaign (the crash-on-foreign-building behaviour can't be
checked outside the game). "When you feel like playing them."
**Decision:**

---

## D. Engineering

### D1. `run_turn` is ~280 lines with five nested closures — `open`
`try`, `resolved_layout`, `belongs_here`, `clear_unwanted` and the
slot-filling loop as top-level functions taking a `stats` argument. Low risk
given mutation coverage; worth doing before anyone else contributes.
**Decision:**

### D2. Data block is 7,500 committed lines that change wholesale per patch — `open`
Fine for now. If diffs get painful, CI could regenerate instead of requiring
it committed. The current "must match" check is right until then.
**Decision:**

### D3. `mutate.py` is slow and edits `src/engine.lua` in place — `open`
Write the mutant to a temp file and point `build.py` at it: safe to Ctrl-C,
parallelisable. ~3 minutes today.
**Decision:**

### D4. Things the harness can't check — `open`
That `get_building_level_upgrades`, `template_key` and the UI layout names
behave as modelled, and that nothing crashes. A short after-patch smoke
checklist in the README: load a save, End Turn, check the trace for
`Refusing key`, `FAILED`, `popup failed`.
**Decision:**

---

## E. README

### E1. Honesty pass on the lessons — `done` with B1
### E2. Fix the log location — `done` with B4
### E3. Windows status — `done` with B5
### E4. "Known limitations" section — `open`
Minors cap at level 3 (so one-settlement minor provinces are "grown" at 3);
multi-path buildings left alone; single-player only; one province protected;
Aislinn's colonies upgrades-only.
**Decision:**

---

## Suggested order

A1 → B2 → B1/E1 → A2 → B4/E2 → B5/E3 → C1 → D1 → the rest.
