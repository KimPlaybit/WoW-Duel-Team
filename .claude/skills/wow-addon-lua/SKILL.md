---
name: wow-addon-lua
description: How to write, structure, lint, deploy and iterate on Lua addon code for WoW: Forever in this repo. Use when creating or editing any .lua or .toc file, scaffolding the addon or a prototype, adding SavedVariables or migrations, wiring events, timers, slash commands or UI frames, or setting up the dev loop (deploy, /reload, luacheck).
---

# Writing WoW: Forever addon Lua

Pair this with the **wow-forever-api** skill: look up every API before using it.

## Runtime facts
- Lua **5.1** semantics. No `goto`, no integer division `//`, no `utf8` library. `#` on tables with holes is unreliable.
- Forever 1.60.1 renamed Lua `require` to `import`. Don't use either; load files through the TOC.
- Each file receives `local addonName, ns = ...`. Put all shared state on `ns`. **No accidental globals.**
  The only globals allowed are the SavedVariables table and `SLASH_*` names.
- Everything runs on the single UI thread. Never busy-wait. Use `C_Timer`.

## Layout (addon name `TeamDuel` is provisional; confirm with the user before publishing)
```
src/TeamDuel/
  TeamDuel.toc             ## Interface: 16001 (base TOC)
  TeamDuel_Forever.toc     flavor TOC; "_Forever" and "_Camelot" are both accepted suffixes
  Core.lua                 ns bootstrap, event dispatcher, logging, slash commands
  Util.lua                 name normalization, secret-safe helpers, small pure functions
  DB.lua                   SavedVariables load, defaults, schema version, migrations
  Comm.lua                 prefix registration, envelope encode/decode, send queue, validation
  Match.lua                match state machine (pure logic, no frames)
  Rating.lua               rating math + matchup restriction logic (pure)
  Position.lua             position sampling, distance, approach trend
  Duel.lua                 duel lifecycle: events → normalized duel results
  UI/*.lua                 challenge window, status panel, result panel, forfeit popup
prototypes/<Name>/         throwaway in-game probes (feasibility phase)
tests/                     plain-Lua unit tests for pure modules (run with lua5.1 / busted if available)
```
- TOC file order is the load order: Util → DB → Comm → Rating → Match → Position → Duel → UI → Core last.
- Keep **pure logic** (Match, Rating, the distance math) free of WoW API calls so it can be unit tested outside the game.
  Inject the clock and the transport as dependencies.

## Module pattern
```lua
local addonName, ns = ...
local Rating = {}
ns.Rating = Rating

function Rating.TeamAverage(ratings) -- pure, testable
	local sum, n = 0, 0
	for _, r in ipairs(ratings) do sum, n = sum + r, n + 1 end
	return n > 0 and sum / n or nil
end
```

## Events: one dispatcher frame
```lua
local f = CreateFrame("Frame")
ns.handlers = {}
function ns.On(event, fn)
	if not ns.handlers[event] then ns.handlers[event] = {}; f:RegisterEvent(event) end
	table.insert(ns.handlers[event], fn)
end
f:SetScript("OnEvent", function(_, event, ...)
	for _, fn in ipairs(ns.handlers[event]) do
		local ok, err = pcall(fn, ...)
		if not ok then ns.Log("error", event, err) end
	end
end)
```

## SavedVariables with versioning (required by spec §11.3 / info rule 5)
- TOC: `## SavedVariables: TeamDuelDB` (account-wide ratings and history). Use `SavedVariablesPerCharacter` only for UI layout.
- The data is available on `ADDON_LOADED` when `arg1 == addonName`. It is written only on logout or `/reload`, so a crash loses the session.
- Layout: `TeamDuelDB = { schema = N, players = {}, matches = {}, settings = {} }`.
- Migrations: an ordered list `MIGRATIONS[i] = function(db) ... end`. Run each one from `db.schema + 1` up to `CURRENT`
  inside `pcall`. If one fails, keep the old data and disable writes. Never wipe the DB.
- Never store secret values. Run `issecretvalue` on anything that comes from unit, chat or combat APIs before you write it.
- Cap history growth (for example, prune matches older than the restriction window + margin, or keep the last N).

## Secret-safe coding
```lua
local function Readable(v) return v ~= nil and not (issecretvalue and issecretvalue(v)) end
local y, x, _, inst = UnitPosition("player")
if not (Readable(x) and Readable(y)) then ns.Log("warn", "position unavailable/secret"); return end
```
Never compare or do arithmetic on a value before this check. A compare on a secret is a hard Lua error.

## Timers
- Countdown and sampling: `C_Timer.NewTicker(0.2, fn)`. Keep the handle and `:Cancel()` it on every state exit.
- Measure elapsed time with `GetTime()`. Don't count ticks, because ticks drift.
- Use `GetServerTime()` for persisted timestamps.

## Protected actions
Register `ADDON_ACTION_BLOCKED` and `ADDON_ACTION_FORBIDDEN` and log them. Anything that might need a hardware event
(`StartDuel`, `AcceptDuel`, `C_PartyInfo.InviteUnit`) must be callable from a **button click**, and the
automated path is only an optimization that falls back to that button (info rule 10).

## Dev loop
- The reference environment is in `.ref/WoW-Addons`: `scripts/deploy.ps1` junction-links `src/*` into the game,
  `scripts/new-addon.ps1` scaffolds, and `.luacheckrc` is the lint config.
  The game path is in `wow-dev.config.json` (`gamePath`, `flavorDir` `_classic_beta_`). Ask the user for their
  path, or copy the scripts and config into this repo and adapt them, instead of guessing.
- After a Lua edit: `/reload` in game. Redeploy only after adding or removing files or TOCs.
- **Run `.\scripts\check.ps1` after every Lua change.** It runs luacheck over `src`, `prototypes` and `tests`,
  then the unit tests. It must exit 0 before I report the work as done.
  - Lint: `.tools/luacheck.exe` (v1.2.0 standalone, gitignored), configured by the root `.luacheckrc` (std lua51).
    When code uses a new WoW global, add it to `read_globals` there, after looking it up.
  - Tests: LuaJIT (Lua 5.1 semantics, the same as the game) is installed per-user and on the user PATH
    (`%LOCALAPPDATA%\Programs\LuaJIT\bin\luajit.exe`). `luajit tests/run.lua` is a zero-dependency runner
    (`describe`/`it`/`expect`, `LoadAddonFile(path, ns)`). **Register each new `*_spec.lua` in its `SPECS` list.**
  - LuaJIT ≈ 5.1 but not identical to the WoW client: it is missing WoW's Lua extensions (`strsplit`, `wipe`, `bit`, …).
    Pure modules must not use them, or the spec has to stub them.
- Confirm the interface number in game: `/dump select(4, GetBuildInfo())`. Update the TOCs if the client patched.
- Enable "Load out of date AddOns" if needed.
- I cannot run the game. For anything that needs in-game verification, give the user exact steps
  (slash command, what to do, what to paste back), then record the result in `docs/verification-log.md`.

## Logging
`ns.Log(level, ...)` writes to a ring buffer in `TeamDuelDB.debugLog` (capped at about 500 lines) and prints when debug is on.
`/td debug` toggles it, `/td log` dumps it. The user pastes the log back to me so I can diagnose.
