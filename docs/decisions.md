# Design decisions

Tracks the open decisions from spec §12. Newest first. "Provisional" means it can still change.

## 2026-10-28: The challenge is the duel request; leaders fight first (decided by the user)

- Every player starts at 1500 in each format; rating points are Elo on team averages (K=32, see below).
  The duel popup and the match start show the points at stake (win / loss, and draw for 2v2 pairs).
- Sending a challenge also sends the duel request (`StartDuel`) from the same click.
- There is no separate challenge popup: the challenge details (spec §4.1) are added under Blizzard's own duel request
  popup. Accepting that duel accepts the challenge; declining it declines the challenge (post-hooks on
  `StaticPopup_Show`, `AcceptDuel`, `CancelDuel`). Ordinary duels are untouched. Accepting/declining from `/td` also
  accepts/declines the duel.
  If the challenge is declined or can't go ahead, the challenger withdraws its request (`CancelDuel`).
- In 2v2/3v3 the team leaders always fight first, so the challenge's duel is the match's first duel. `/td order` keeps the leader first.
- Supersedes #8 below ("accept is always the player clicking Blizzard's popup"). Protection of all three calls is UNVERIFIED;
  Blizzard's own duel popup and the "Start duel" button remain the fallbacks.

## 2026-10-28: Challenges require normal duel range (decided by the user)

The challenger must target the opposing team leader and be within normal duel range of them.
Checked with `CheckInteractDistance("target", 3)` (`Config.DUEL_RANGE_INDEX`; index 3 = duel range is unverified on Forever).
Only the challenger's client checks this, so it is a convenience rule, not an enforced one.
Provisional: if the range can't be read, the challenge is sent with a warning (`Config.DUEL_RANGE_UNKNOWN = "allow"`).
Challenges are sent from a "Challenge" entry right below "Duel" on a player's right-click menu (user's choice);
`/td challenge [1v1|2v2|3v3] [name]` on the target stays available as the manual fallback.

Format rules (user's choice): "Challenge" opens 1v1 / 2v2 / 3v3.
- 1v1 is always individual: anyone can challenge anyone, whatever team either is on (teammates included).
- 2v2/3v3: the challenger must lead a team of exactly that size (refused locally otherwise), and the opponent must
  be a team leader with exactly that many players. If not, the opponent's addon auto-declines with a reason
  (`notleader`, `size<n>`) and the challenger is told why. Accept re-checks in case the team changed meanwhile.

## 2026-10-28: Provisional defaults used by the milestone-1 implementation

These are placeholders so the code can run. All of them live in `src/TeamDuel/Config.lua` and can change.

| Open decision (spec §12) | Provisional choice | Why |
|---|---|---|
| #1 Progression | `pairs`: fighter i vs fighter i, each fights once, majority wins, early finish once decided. `winnerStays` (elimination) is implemented too, chosen per challenge. | Matches §3.1's "max duels = team size". |
| — Tie in 2v2 `pairs` (1–1) | Draw (0.5 score for rating) | Simplest rule that is fair to both teams. |
| #2 HP/resources carry over | Not controlled. The addon can't heal or reset; WoW ends a duel at low HP. | Not technically controllable. |
| #3 Rating algorithm | Elo on team averages, K=32, start 1500, per format; same delta for every team member | Common default. |
| #6 Identity | `Name-Realm` | Stable and readable. GUID stability is unverified on Forever. |
| #8 Duel automation | ~~Request from a button click; accept is always the player clicking Blizzard's popup~~ Superseded: see "The challenge is the duel request" above. | `StartDuel`/`AcceptDuel` protection is unverified. |
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
