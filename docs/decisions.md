# Design decisions

Tracks the open decisions from spec §12. Newest first. "Provisional" means it can still change.

## 2026-10-29: No manual results or aborts; stalling and disconnecting forfeit (decided by the user)

Removed: `/td won|lost`, `/td abort`, `/td abandon`, the I won / I lost / Abort buttons, and the ABORT message.
This deliberately drops the manual fallback for results (a CLAUDE.md non-negotiable) at the user's request:
self-reported results can't be trusted. The duel request itself stays manual (Start duel / Blizzard's popup).

- **Results (user: "the duel message is always visible"):** both duelists always see the duel message, one on each
  team, and their addons send it to everyone in the match (RES). A duel counts when the first report from each team
  names the same winner. Teammates and waiting fighters who also see it report too, as backup readers; whether
  bystanders see it on Forever is UNVERIFIED but not required.
- **No readable result:** `RESULT_WAIT` (10 s) after DUEL_FINISHED, a fighter's client sends DST rerun and the duel
  is fought again as a new attempt. An accepted duel with no outcome after `DUEL_MAX_LENGTH` (10 min) is re-run too.
- **Disputes:** the teams read different winners, so the duel is re-run. After `MAX_DISPUTES_PER_DUEL` the match
  still ends without rating changes. That's the one remaining no-result outcome; it needs clients reading
  different text from the same message (tampering or a bug). **Open:** the user said a no-rating end is a problem,
  so this may need a different rule.
- **Disconnect = forfeit, with rating changes (spec §12 #9):**
  - A party member sees `UnitIsConnected(partyN) == false` or gets UNIT_CONNECTION, and announces their own team's
    forfeit (FORF, which is trusted only about the sender's own team).
  - Everyone pings every `HEARTBEAT` (10 s). A player silent for `OFFLINE_AFTER` (45 s) forfeits for their team.
    The current fighters aren't judged while their accepted duel runs, in case messages are blocked in duels.
  - The running match is kept in SavedVariables (`activeMatch`). A client that comes back after a reload, logout
    or disconnect records its team's forfeit at login and announces it. A client crash doesn't save it.
- **Countdown and stalling (spec §7, §12 #5; user, 2026-10-29):** the next duel must start within `COUNTDOWN`
  (10 s, decided by the user). Position.lua runs the clock on the two fighters' clients, which swap positions
  (`UnitPosition("player")`, POS message) every `POS_INTERVAL` (2 s).
  - The clock runs at `COUNTDOWN_SLOW_RATE` (0.25) while the gap closes; otherwise at full speed (user: "if they
    walk towards each other... the 10 seconds don't count down as fast").
  - Avoiding forfeits (user): moving away by `MOVE_YARDS` (1.5) or more while the other closes in, for
    `AVOID_SAMPLES` (2) samples in a row.
  - The clock runs out apart: the fighter who closed in less forfeits, or both teams if neither did (provisional).
  - It runs out within duel range: the request decides (provisional). The receiver who didn't accept forfeits;
    if no request arrived, **both teams forfeit and both take a loss**.
  - Positions unreadable, secret or on another map: the clock lasts `COUNTDOWN_NO_POSITION` (30 s) and the
    request decides (provisional; the spec said no automatic forfeit without positions, the user wants one).
  - A silent opponent holds the clock, so a disconnect is judged by `OFFLINE_AFTER` instead of forfeiting both.
  - The fighter whose client ends the countdown announces it (FORF avoid/stall). Other clients accept that from
    either current fighter, so the opponent's client is trusted here, like any client-reported result.
  - `STALL_BACKSTOP` (120 s) on every client covers fighters' clients that never decide.
  - This replaces spec §8.1's "a failed duel request alone never causes a forfeit", per the user.
  - Auto-accept (user): the scheduled opponent's request is accepted for the player from DUEL_REQUESTED
    (`AcceptDuel`, unverified without a click). Backup: the player clicks Accept. When the request arrives (DST rcv),
    the clock goes up to `REQUEST_GRACE` (3 s, user) if it's lower; then it continues as before. All backups are
    in [fallbacks.md](fallbacks.md).
- New messages: DST (d, t, s = rcv/acc/rerun), FORF (tm = A/B/both, why), PING, POS (x, y, mp). ACC has a new `da` field: whether the first
  duel was accepted along with the challenge.

## 2026-10-29: Ratings in player tooltips (decided by the user)

- Hovering a player adds `TeamDuel: 1v1 X  2v2 Y  3v3 Z` under their name in the unit tooltip.
- A player whose addon doesn't answer within `Config.TOOLTIP_NO_REPLY` (3 s) is shown with 0 (decided by the user).
  This also covers players who are offline or on the other faction, since we can't whisper them.
- How: hovering whispers `RREQ` (our ratings) and they answer with `RINF` (theirs). Both are unreliable (no ACK).
  Answers are cached for `TOOLTIP_REFRESH` (60 s), and requests and replies are at least `TOOLTIP_ASK_GAP` (1 s)
  apart, so hovering a crowd can't flood the shared comm queue. No requests in combat lockdown.
- These ratings are self-reported and stored on the other player's computer. They are only displayed and never
  feed a match (a challenge carries its own ratings).
- Hook: `GameTooltip:HookScript("OnTooltipSetUnit")` (listed in the reference UI schema, unverified), falling back
  to `TooltipDataProcessor`, which isn't in the Forever dump.

## 2026-10-28: Teams are parties (decided by the user)

- A team is the player's WoW party (not a raid); the party leader is the team leader. `/td invite|join|leave` and the
  TINV/TJOIN/TLEAVE messages are gone; members whisper their ratings to the leader (`TRAT`) when the group changes.
- 2v2 needs a party of exactly 2 and 3v3 exactly 3; solo players play 1v1. In the right-click menu, 1v1 is never greyed
  out, 2v2/3v3 are greyed out unless we lead a party of exactly that size (`SetEnabled`, unverified; the click re-checks).
- Every party member must be within 20 yards of their leader (decided by the user; `Config.TEAM_RANGE_YARDS`),
  measured with `UnitDistanceSquared(partyN)` (in the Forever dump, unverified in game; unreadable falls under
  `Config.DUEL_RANGE_UNKNOWN`). Checked on the challenger's side when challenging and on the other side when the
  challenge arrives and when it's accepted. A member whose addon hasn't reported ratings blocks the challenge.
- Fighter order: the leader first, then the party order unless the leader sets one with `/td order`.

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
| #9 Disconnects | Superseded 2026-10-29: disconnecting or leaving forfeits (see the entry at the top). | Decided by the user. |
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
