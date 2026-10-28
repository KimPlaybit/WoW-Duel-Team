# Design decisions

Tracks the open decisions from spec §12. Newest first. "Provisional" means it can still change.

## 2026-10-28: Provisional defaults used by the milestone-1 implementation

These are placeholders so the code can run. All of them live in `src/TeamDuel/Config.lua` and can change.

| Open decision (spec §12) | Provisional choice | Why |
|---|---|---|
| #1 Progression | `pairs`: fighter i vs fighter i, each fights once, majority wins, early finish once decided. `winnerStays` (elimination) is implemented too, chosen per challenge. | Matches §3.1's "max duels = team size". |
| — Tie in 2v2 `pairs` (1–1) | Draw (0.5 score for rating) | Simplest rule that is fair to both teams. |
| #2 HP/resources carry over | Not controlled. The addon can't heal or reset; WoW ends a duel at low HP. | Not technically controllable. |
| #3 Rating algorithm | Elo on team averages, K=32, start 1500, per format; same delta for every team member | Common default. |
| #6 Identity | `Name-Realm` | Stable and readable. GUID stability is unverified on Forever. |
| #8 Duel automation | Request from a button click; accept is always the player clicking Blizzard's popup | `StartDuel`/`AcceptDuel` protection is unverified. |
| #9 Disconnects | No auto-forfeit. Unresponsive peers pause the match; a leader can `/td abort`, and anyone can `/td abandon` locally. | Spec §11.4: never silently decide. |
| #10 Rating storage | Local SavedVariables only (milestone 1, spec §13) | Already decided in the spec. |
| — Result trust | A duel counts only when both fighters report the same winner (auto from the system message, or manual buttons). Two disputes on one duel abort the match. | §11.2, §11.4 |

## 2026-10-28: Candidate duel locations (spec §12 #7; provisional, final spot not picked)

Feasibility testing and early development use these four spots. The final designated location is still open.

| # | Candidate | Faction | Setting | Notes |
|---|---|---|---|---|
| 1 | Outside the Orgrimmar gate | Horde | Open world, zone border (Orgrimmar / Durotar) | |
| 2 | Thunder Bluff, Hunter Rise | Horde | **Inside the capital city** | Verify that duels are allowed there on Forever |
| 3 | Outside the Ironforge gate | Alliance | Open world, zone border (Ironforge / Dun Morogh) | |
| 4 | Outside the Stormwind gate | Alliance | Open world, zone border (Stormwind / Elwynn Forest) | |

Consequences:
- Each spot belongs to one faction, so matches are implicitly same-faction. Cross-faction duels and whispers are
  normally impossible; this needs a decision if cross-faction matches are ever wanted.
- Location validation must accept a small *set* of areas (each spot: map ID + subzone + a radius around a
  reference point), not a single zone name. It must also tolerate players standing on either side of a zone border.
- Map IDs, subzone names and reference coordinates must be **recorded in game** with `/dp where` and logged in
  `docs/verification-log.md`, never filled in from memory.
- City spots have guards and heavy traffic (outside interference, spec §9.4). Note this during testing.
