# TODO

Status as of 2026-10-28. Milestone 1 is implemented and passes the simulated tests, but nothing has run in game yet.
In-game testing is blocked until WoW: Forever is released; until then the simulator (`tests/sim.lua`) is the only check.

## Decisions needed (see docs/decisions.md)
- [ ] 2v2/3v3 progression: "each fighter once" (current default) or "winner stays"?
- [ ] 2v2 that ends 1–1: draw (current default) or something else?
- [ ] Rating algorithm and constants (currently Elo, K=32, start 1500)
- [ ] Repeated-matchup thresholds and restriction expiry (spec §5.5)
- [ ] Countdown slowdown and stalling thresholds (spec §7)
- [ ] Final duel location (candidates: Orgrimmar gate, Thunder Bluff Hunter Rise, Ironforge gate, Stormwind gate)
- [ ] Cross-faction matches: needed? Currently impossible (whispers and duels are same-faction)

## Blocked on having the game
- [x] Install WoW: Forever and set up deploy (`scripts/deploy.ps1` → `D:\WoWForeverLive`)
- [ ] Get two or more non-trial test accounts (trial accounts can't send addon messages)
- [ ] Confirm the interface number: `/dump select(4, GetBuildInfo())` (TOC says 16001)

## In-game verification (log results in docs/verification-log.md)
- [ ] Addon loads, `/td` window and buttons render (UIPanelButtonTemplate / GameFont fallbacks)
- [ ] Addon whispers arrive between ungrouped players; log the send result codes
- [ ] Addon messages work right before, during and after a duel (no lockdown)
- [ ] Right-click a player (portrait, target frame, chat name): "Challenge" shows right below "Duel" with a 1v1/2v2/3v3 submenu, and sends the challenge. A 2v2 to a non-leader, or 3v3 to a 2-player team, fails with a reason in the challenger's chat. If missing, `/dump Menu, MenuUtil` and `/td log`
- [ ] Challenge: Blizzard's duel popup shows the challenge details under its normal text (format, average, every rating, your rating, rating at stake). Popup resized to fit? A plain duel shows nothing extra
- [ ] Accepting that duel starts the match; declining it tells the challenger. `/td log` for "hook" / "action blocked" lines (hooks on StaticPopup_Show/AcceptDuel/CancelDuel are unverified)
- [ ] `/td challenge` range gate: `/dump CheckInteractDistance("target", 3)` true next to the target, false at about 15 yards, and matching the range where a normal duel request works
- [ ] `StartDuel` from the "Start duel" button works (hardware-event requirement?)
- [ ] `/dump DUEL_WINNER_KNOCKOUT, DUEL_WINNER_RETREAT`: present, readable (not secret), and seen by both duelists
- [ ] `DUEL_FINISHED` timing relative to the system message; is there any usable duel-start signal?
- [ ] Duel request name format in `DUEL_REQUESTED` (with or without realm)
- [ ] `/td where` at each candidate spot: map ID, zone/subzone, position, not an instance
- [ ] Are duels allowed inside Thunder Bluff?
- [ ] `UnitPosition` readable at the spots, for self and for party members
- [ ] Is `UnitGUID("player")` stable across sessions (identity option)?
- [ ] Full 1v1, then 2v2 and 3v3, with two or more accounts

## Later milestones (spec §11.5)
- [ ] Feasibility report `docs/03-feasibility-report.md` (skipped to build first; fill it in from the in-game results)
- [ ] Repeated-matchup tracking: consecutive streak, rolling window, player overlap, rating tiers, challenge warning
- [ ] Dynamic preparation countdown with approach tracking (only if positions are verified)
- [ ] Stalling detection and automatic forfeit
- [ ] Forfeit popup shown to both teams
- [ ] Location validation against recorded map data
- [ ] Disconnect handling beyond pause/abort (`UNIT_CONNECTION`, group events)
- [ ] Settings UI for the provisional config values

## Tech debt / nice to have
- [ ] Cross-realm 3v3 rosters with long realm names can exceed 255 bytes; split messages if that turns out to matter
- [ ] UI polish: proper frame template, positions saved per character
