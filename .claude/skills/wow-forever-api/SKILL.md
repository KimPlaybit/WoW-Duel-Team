---
name: wow-forever-api
description: Ground truth for the WoW: Forever (Camelot, Interface 16001) client API. Use BEFORE writing or reviewing any Lua that calls a WoW API, event, or enum; when classifying a feasibility finding (Verified / Partially supported / Unverified / Unsupported); or when asked "does X work in Forever". Covers how to look up the client's own API dump, the Midnight-era restriction model (secret values, AddOnRestrictionType, addon-comm lockdown), and the verified facts relevant to the Team Duel addon.
---

# WoW: Forever API — verify before you use

The target is **WoW: Forever** (internal codename **Camelot**, product `wow_classic_beta`,
version **1.60.1**, build 70170, **Interface 16001**). It is NOT Classic Era and NOT plain Retail:
it shares Mainline (12.x) UI architecture and **inherits Midnight's addon "disarmament"
restrictions (secret values, comm lockdown)**. Never assume a Retail/Classic tutorial is correct.

## Sources, in order of authority

1. **The running client** — `/dump <expr>`, `/run`, a probe addon. Only this makes something *Verified* for behavior.
2. **Client API dump** — `.ref/WoW-Addons/docs/api.json` (generated from the client's own `APIDocumentation`).
   Proves a function/event *exists* with a documented signature. It does not prove runtime behavior.
   - Markdown per namespace: `.ref/WoW-Addons/docs/api/<Category>/<Namespace>.md`
   - LuaLS definitions: `.ref/WoW-Addons/types/WowForeverAPI.lua`
   - Online: https://atraeau.github.io/WoW-Addons/ · repo https://github.com/Atraeau/WoW-Addons
3. **Forever patch notes** — https://warcraft.wiki.gg/wiki/Patch_1.60.1/API_changes/notes
4. **Midnight (12.0) API notes**, which Forever inherits — https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes/notes
5. **warcraft.wiki.gg API pages** — useful for semantics, but written for Retail/Classic; treat as *Unverified* for Forever.

## Look things up — don't recall them

```bash
python -I .claude/skills/wow-forever-api/scripts/api_lookup.py '<regex>'            # fns, events, types, globals
python -I .claude/skills/wow-forever-api/scripts/api_lookup.py 'DUEL_' --kind events
python -I .claude/skills/wow-forever-api/scripts/api_lookup.py '^SendAddonMessage$' --full
```

If `.ref/WoW-Addons` is missing:
`git clone --depth 1 https://github.com/Atraeau/WoW-Addons.git .ref/WoW-Addons` (`.ref/` is gitignored).

Output tags:
- `[fn]` / `[event]` — documented, signature trustworthy.
- `[global] X (undocumented)` — exists in `_G` only; **signature and protection status are NOT verified**.

Enum *values* (e.g. `Enum.AddOnRestrictionType.Combat`) and **global strings** (e.g.
`DUEL_WINNER_KNOCKOUT`) are **not** in the dump. Verify them in-game with `/dump Enum.AddOnRestrictionType`
and `/dump DUEL_WINNER_KNOCKOUT` before relying on them.

## Rules

- Never call an API you haven't looked up in this session. When unsure, run the lookup script.
- Every claim about behavior gets a status: **Verified** (in-game test or client dump + documented behavior),
  **Partially supported**, **Unverified** (needs in-game test, write the test procedure), **Unsupported**.
- Guard calls that might not exist: `if C_Foo and C_Foo.Bar then ... end`. Then log which branch ran.
- Values may be **secret**. Before comparing, doing arithmetic on, or saving any value derived from units,
  chat, or combat, check it with `issecretvalue(v)`. A comparison or arithmetic on a secret throws a Lua error.
  Secrets **cannot be stored in SavedVariables**; they serialize as nil.
- Keep a log of in-game verification results in `docs/verification-log.md`, with the date, build and what was observed.

## The restriction model you must design around

See [references/restrictions.md](references/restrictions.md) for details and sources. In short:
- `C_RestrictedActions.IsAddOnRestrictionActive(type)` / `GetAddOnRestrictionState(type)` and the event
  `ADDON_RESTRICTION_STATE_CHANGED(type, state)`. The types reported in the 12.0 notes are
  Combat, Encounter, ChallengeMode, PvPMatch and Map. **Verify the enum values in-game.**
- Addon messaging and chat reading are locked down during M+ runs, PvP matches and instance encounters.
  **Whether a duel or ordinary combat triggers any lockdown on Forever is UNVERIFIED and must be tested first.**
- `SendAddonMessage` returns `Enum.SendAddonMessageResult`; `AddOnMessageLockdown` and `AddonMessageThrottle`
  are failure modes you must handle. Trial/Veteran accounts cannot send addon messages at all.
- Protected actions fire `ADDON_ACTION_BLOCKED` / `ADDON_ACTION_FORBIDDEN`. Register both in prototypes.

## Facts for the Team Duel addon

[references/duel-addon-api.md](references/duel-addon-api.md) is the curated table of every API this addon is
expected to need, with its verification status. **Update its status column whenever an in-game test resolves something.**
