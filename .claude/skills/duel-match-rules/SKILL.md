---
name: duel-match-rules
description: The Team Duel addon's domain rules distilled from docs/01-spec.md: match formats, lifecycle state machine, fighter order, team/individual ratings, rematch and win-trading restrictions, dynamic countdown, stalling forfeits, location rules, UI panels, milestones, and the list of OPEN design decisions. Use when implementing or reviewing Match.lua, Rating.lua, Position.lua, the countdown, forfeits, or any UI, and whenever a rule seems ambiguous.
---

# Team Duel domain rules

`docs/01-spec.md` (v0.2) is the source of truth. This is a working digest. When it disagrees with the spec, the spec wins.
Cite spec sections (§) in code comments only where a rule is non-obvious.

## Open decisions — never decide silently (spec §3.4, §12)
1. Winner stays on vs each fighter fights once · 2. HP/resources carry over · 3. Rating algorithm ·
4. Rematch thresholds and expiry · 5. Countdown slowdown and stall thresholds · 6. Identity across team changes ·
7. Exact duel location · 8. Whether duel start/accept is automated · 9. Disconnects/withdrawals · 10. Local vs external ratings (an external service could use the Battle.net Web API
only for character identity, not for duel results; see wow-forever-api/references/restrictions.md).

When code needs one of these, **ask the user** (with a recommendation), or make it a named config value with a
clearly labelled provisional default. Record decisions in `docs/decisions.md` (date, decision, rationale).
Milestone-1 constraint already decided: **no server; ratings are stored locally** (§13).

## Formats
1v1, 2v2, 3v3. One active duel per match. Each team's fighter order is set **before** the match and is never random (§3.3).
The maximum number of duels in an elimination match equals the team size (§3.1). How that interacts with "winner stays" is open decision 1.

## Match state machine (suggested; keep it pure, in Match.lua)
`IDLE → CHALLENGED → ACCEPTED → ORDERING → PREPARING(duel i) → DUEL_PENDING → IN_DUEL → RESOLVING → (PREPARING(i+1) | FINISHED)`
plus the terminal states `FORFEITED`, `ABORTED`, `DISPUTED→(rerun|ABORTED)`.
- Every transition is caused by a validated local event or comm message. Illegal transitions are logged and ignored.
- `DUEL_PENDING` must not assume the request succeeded (§6.1). It needs an observed duel start, or a timeout followed by a retry or a manual prompt.
  **A failed duel request alone never causes a forfeit** (§8.1).
- No path may leave a match unresolved. Every state has a timeout to a defined outcome (§8.2).

## Ratings (§4, §5)
- Ratings are tracked per player **per format** (2v2 ≠ 3v3).
- Team average = arithmetic mean of the participants' format ratings. Spread = max − min. Show both, plus every individual
  rating, on the challenge.
- An uneven team is shown transparently, never penalized.
- The algorithm is open (decision 3). Recommend Elo-style as the default, with K configurable and the team average as the opponent rating.
- History record: participants, both compositions, format, result, timestamp, rating deltas, restriction tier applied.

## Repeated-matchup restrictions (§5.2–5.5)
Track three independent things:
- **Consecutive streak** for team A vs team B. It resets only when a *completed* match against a different opponent happens. Challenges don't count.
- **Rolling-window frequency** for A vs B. An intervening match does not erase it.
- **Player overlap.** A different team composition still accumulates history when players overlap (the metric is open decision 6.
  Propose overlap ratio = shared players / team size).

Provisional tiers (configurable): matches 1–2 normal · 3–4 reduced impact · 5+ no rating change until the restriction expires.
Apply them symmetrically to both teams. The challenge UI **warns** when a tier applies. These are indicators, never proof.

## Dynamic countdown (§7) — only if positions are verified
- Base window 10s (provisional).
- Both fighters approaching → the clock slows. Neither approaching, or approach stopped → normal rate.
  One approaching while the other retreats → normal rate, and the retreating player is flagged.
- The clock **always progresses**: there is a minimum rate floor, so a very slow approach can't stall it forever.
- Approach is judged from a trend over several samples (for example, a regression slope of distance over the last N samples),
  never from a single sample. Distance d = √((x₂−x₁)² + (y₂−y₁)²) in yards, and only if both instanceIDs match.
- **Stall forfeit:** when the countdown expires and the configured criteria are met (persistent non-approach, repeated
  retreat, insufficient progress), the responsible team forfeits. Obstacles are not excused (§7.4).
  If position data is unavailable or secret → **no automatic forfeit**. Fall back as described in the duel-feasibility skill.

## Forfeit (§8)
Stop the countdown → end the match → show a popup to **both** teams: "Match Forfeited", the forfeiting team, the winning team,
the reason ("failure to approach the designated opponent"), and that the match has ended → record → apply rating rules.
Both clients must show the same result (send it via FORFEIT plus an ACK).

## Location (§9)
- The final spot is still open (decision 7). **Provisional candidates (2026-10-28, see docs/decisions.md):**
  outside the Orgrimmar gate, Thunder Bluff Hunter Rise (inside the city), outside the Ironforge gate, outside the Stormwind gate.
  All are single-faction, so matches are same-faction for now.
- Model locations as data: a list of `{ id, name, faction, mapID, subzones, refY, refX, radius }`, filled in only from in-game `/dp where` readings.
  Validate with map ID / subzone / non-instance checks / distance to the reference point, to the extent the APIs allow.
  Allow for zone borders at the gates.
- If a player is elsewhere, say where to go. Never teleport or assume instance access. Never depend on an unverified arena.
- Outside the designated spot: warn about outside players and hostile NPCs.

## UI (§10)
Challenge window · Match status panel (current duelists, progression, next fighter per team, countdown, readiness,
restrictions) · Result panel (duel winner, overall result, rating deltas, forfeit info) · Forfeit popup. Keep it concise and fast.

## Implementation order (§11.5)
Feasibility report → API restrictions → prototype → verify high-risk items → minimal 1v1 → 2v2/3v3 progression → ratings
and history → rematch restrictions → countdown and stalling (if supported) → forfeits, location, reliability → full test on Forever.

**Milestone 1 acceptance (§13):** create and accept a challenge · the challenge shows the team average and each rating · two players
complete a duel · completion is detected and the result recorded · both clients stay in sync · the next fighters are identified ·
a failed duel request does not corrupt the match · ratings are stored locally.

## Proposing spec changes
If the API forces a deviation, label it **"Proposed spec change"** with the reason and the alternative. Don't implement it
until the user agrees (§11.5, last paragraph).
