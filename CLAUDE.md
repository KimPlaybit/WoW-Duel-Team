# Addon-Duel: WoW: Forever Team Duel addon

Lua addon for **WoW: Forever** (Camelot, Interface 16001, Midnight-era restrictions).
Spec: [docs/01-spec.md](docs/01-spec.md) · Technical rules: [docs/02-wow-addon-info.md](docs/02-wow-addon-info.md)

## Project skills (`.claude/skills/`)
- `wow-forever-api`: look up and verify every API, event and restriction. Includes `scripts/api_lookup.py` over the client dump in `.ref/WoW-Addons`.
- `wow-addon-lua`: code structure, SavedVariables and migrations, events, timers, and the dev loop.
- `duel-addon-comms`: the addon-message protocol, validation, and result agreement.
- `duel-feasibility`: the mandatory first phase: the report, the DuelProbe prototype, and in-game test procedures.
- `duel-match-rules`: digest of the spec's domain rules and the list of OPEN decisions.

## Non-negotiables
- Feasibility report + prototype before the full addon (spec §2).
- Never invent APIs or assume Retail/Classic behavior. Mark every finding Verified / Partially supported / Unverified / Unsupported.
- Values may be secret (`issecretvalue`). Guard every comparison and never persist secrets.
- Every automated action has a manual fallback. Client-reported results are untrusted.
- Don't silently decide open design questions. Ask, or use a labelled provisional config value.
- I can't run the game: write in-game test steps for the user and log the outcomes in `docs/verification-log.md`.
