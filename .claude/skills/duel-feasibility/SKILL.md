---
name: duel-feasibility
description: Run the mandatory feasibility phase of the Team Duel addon (spec §2, info "First deliverable"). Use when asked to write or update the technical feasibility report, design or build the feasibility prototype, write in-game test procedures, interpret in-game test results the user pastes back, or decide whether a feature may move from "unverified" into implementation.
---

# Feasibility phase: Team Duel addon

**Gate:** do not implement the full addon until `docs/03-feasibility-report.md` exists and the
prototype has resolved the high-risk items below (spec §2, §11.5 steps 1–4). If the user asks to skip ahead,
point out the gate once, then follow their decision.

## Deliverable 1: `docs/03-feasibility-report.md`
Use the spec §2.2 table rows exactly. Each row has a **status**, the **evidence** (dump entry, wiki URL, or
verification-log date), the **limits**, the **fallback**, and the **in-game test** if it is not yet verified.
Status ∈ Verified / Partially supported / Unverified / Unsupported.
Never call something Verified because it exists in Retail or Classic, or because it is in the dump.
Existence is not behavior.

Required sections (info doc): duel lifecycle & winner detection · duel request/acceptance restrictions ·
messaging between ungrouped opponents · SavedVariables · position & distance for both fighters ·
dynamic countdown · stalling detection & forfeits · UI & timers · designated-location validation ·
**plus** a section on the Midnight/Forever restriction model (secrets, lockdown), because it affects every row.

Starting knowledge is in `.claude/skills/wow-forever-api/references/duel-addon-api.md`. Re-run the lookup script
when in doubt. End the report with: the unresolved questions, the spec changes I propose (clearly marked as proposals), and the prototype plan.

## Known high-risk items (prototype must resolve)
1. **Winner detection.** `DUEL_FINISHED` has no payload. Does `CHAT_MSG_SYSTEM` + `DUEL_WINNER_*` work, is it non-secret, and do both clients see it?
2. **Duel start signal.** There is no start event in the dump. Find one that fires reliably.
3. **Automation.** Can `StartDuel` and `AcceptDuel` run without a hardware event? Expect "no" and design a manual click fallback.
4. **Comms around duels.** Does `SendAddonMessage` return `AddOnMessageLockdown` during or right after a duel? Does WHISPER work ungrouped?
5. **Positions.** Does `UnitPosition("player")` return readable (non-secret) yards at the candidate location?
   Is `UnitPosition("partyN")` available for the opponent when grouped? Does an exchanged position agree with a local one?
6. **Approach detection.** Is the distance trend stable at about a 0.2–0.5s sampling rate? What is the noise in yards?
7. **Location.** Run the probe at **each of the four candidate spots** in docs/decisions.md (Orgrimmar gate,
   Thunder Bluff Hunter Rise, Ironforge gate, Stormwind gate). Record the uiMapID, zone and subzone on both sides of the
   gate, the reference `UnitPosition`, whether `IsInInstance` is false, and whether duels are allowed at all (especially
   inside Thunder Bluff). Also note guard/NPC interference and whether positions are readable there.
8. **Identity.** Is `UnitGUID("player")` stable across sessions? Is `Name-Realm` unambiguous?

## Deliverable 2: the prototype `prototypes/DuelProbe/`
One small addon, not the real one. It is pure instrumentation.
- Logs **every** relevant event with `GetTime()`: `DUEL_REQUESTED`, `DUEL_FINISHED`, `DUEL_INBOUNDS/OUTOFBOUNDS`,
  `CHAT_MSG_SYSTEM` (raw text plus `issecretvalue`), `PLAYER_REGEN_*`, `UNIT_FLAGS`, `ADDON_ACTION_BLOCKED/FORBIDDEN`,
  `ADDON_RESTRICTION_STATE_CHANGED`, `CHAT_MSG_ADDON`, `ZONE_CHANGED*`.
- Slash commands, each isolating one question:
  `/dp duel <name>` (StartDuel from a click) · `/dp duellater <name>` (StartDuel from `C_Timer.After(2)`) ·
  `/dp autoaccept on|off` (AcceptDuel inside DUEL_REQUESTED) · `/dp ping <name>` (WHISPER/PARTY/RAID result codes and RTT) ·
  `/dp pos start|stop` (sample own and party positions at 5 Hz, broadcast them, print the distance and its trend) ·
  `/dp where` (map id, zone/subzone, instance info, position) · `/dp restr` (dump the restriction states) · `/dp dump` (print the log).
- Persists its log to SavedVariables so the user can send me the file
  (`WTF/Account/<acct>/SavedVariables/DuelProbe.lua`).

## In-game test procedures
Write each procedure as numbered steps the user can follow with two (or more) accounts or characters: setup,
commands, actions, expected observation, and **what to paste back**. Cover: a normal knockout, a flee/out-of-bounds,
a cancel before the countdown, a decline, out of range, one player in combat, a disconnect mid-duel, and an ungrouped vs grouped
run. Record outcomes in `docs/verification-log.md` (date, build, accounts, result, raw log excerpt), then update the
status column in the API reference table and the report.

## If a critical feature is unsupported
State it plainly. Say what the addon can still do without it (spec §2.3), and propose the reduced design, for example:
- No opponent positions → a fixed countdown with no stalling forfeit, plus a "report no-show" button that needs the other team to confirm.
- No automated duel → a big "Challenge next" and "Accept" button, with the addon only validating and tracking.
- Winner undetectable → both duelists confirm the result with buttons. If they disagree, the duel is disputed and no rating changes.
