# WoW: Forever Team Duel Addon
## Product & Technical Specification — Version 0.2

**Status:** Design specification; technical feasibility not yet verified  
**Target platform:** WoW: Forever  
**Implementation assistant:** Claude  
**Development approach:** Feasibility report first, incremental implementation afterward

---

## 1. Project overview

The WoW: Forever Team Duel Addon introduces an organized team-elimination mode using World of Warcraft's existing duel system.

Supported formats:

- 1v1
- 2v2
- 3v3

Only one duel takes place at a time. When a duel ends, the addon determines the result, identifies the next scheduled fighters, and coordinates the next duel.

The addon also provides individual and team ratings, detects repeated matchups that could indicate win-trading, dynamically manages preparation countdowns, and penalizes teams that deliberately stall.

The goal is to make team duels feel like a continuous competitive match with minimal manual coordination.

### Core principles

1. One active duel per match.
2. Automatic progression between duels wherever the WoW API permits.
3. Predetermined fighter order for each team.
4. Transparent individual and team ratings.
5. Reduced opportunities for rating farming and win-trading.
6. Strict forfeits for detected stalling.
7. A designated duel location to minimize outside interference.
8. Implementation based on verified WoW: Forever API capabilities, not assumptions.

---

## 2. Mandatory first phase: technical feasibility report

**Claude must investigate feasibility before implementing the addon.**

The initial task is to produce a technical feasibility report for the actual WoW: Forever client. Do not begin implementing the complete addon until this report identifies the available APIs, restrictions, and unresolved technical risks.

### 2.1 Required investigation

Claude must investigate the following capabilities:

**A. Duel lifecycle**
- How to detect when a duel starts.
- How to detect duel completion.
- How to determine the winner and distinguish wins, losses, draws, cancellations, and other termination conditions.
- Whether a duel request can be initiated programmatically.
- Whether accepting a duel request requires player interaction.
- Whether the addon can reliably coordinate consecutive duels.

**B. Player positioning and distance**
- Whether `UnitPosition()` is available in WoW: Forever and under what restrictions.
- Whether `C_Map.GetPlayerMapPosition()` is available and useful for this use case.
- Whether the addon can obtain positions for arbitrary opposing players who are not grouped with the local player.
- Whether positions can be exchanged between clients using addon messages.
- Whether the reported positions use compatible coordinate systems.
- Whether position tracking works at the proposed duel location.
- Whether distance and movement can be tracked reliably enough to determine whether a player is approaching or deliberately stalling.

This is a critical investigation. The dynamic countdown and automatic stalling-forfeit system depend on reliable information about both fighters' positions.

**C. Addon communication**
- Which addon messaging APIs are available.
- How clients can communicate match state, fighter order, readiness, and results.
- Whether messages can be received reliably from players outside the local group.
- How to validate incoming messages and handle conflicting reports.

**D. Protected actions and restrictions**
- Which actions can be initiated automatically.
- Which actions require a hardware event or player interaction.
- Whether the client imposes additional restrictions on duel automation.
- Whether any proposed behavior violates the platform's addon rules.

**E. Persistence**
- How to store ratings and match history locally.
- Whether the client permits the required SavedVariables functionality.
- What persistence is possible without an external service.
- Which anti-cheating guarantees are impossible with local addon data alone.

**F. Designated location**
- Whether the intended duel area exists in the target version.
- Whether ordinary players can access it.
- Whether addons can reliably identify that players are in the designated area.
- Whether the location supports the required position tracking and duel initiation.

### 2.2 Feasibility report format

Claude should produce a report with:

| Feature | Required finding |
|---|---|
| Duel initiation | Verified API and restrictions |
| Duel result detection | Available events and reliability |
| Opponent coordinates | Availability and limitations |
| Distance calculation | Feasibility at the designated location |
| Countdown automation | Feasible behavior and fallback |
| Stalling detection | Reliable signals and false-positive risks |
| Addon messaging | Supported communication model |
| Rating persistence | Local storage capabilities and limitations |
| Automatic forfeits | Available evidence and implementation constraints |
| Location validation | Supported methods and restrictions |

Every finding should be classified as:

- **Verified:** Confirmed from applicable documentation or a working test.
- **Partially supported:** Possible with restrictions or missing guarantees.
- **Unverified:** Requires a prototype or further investigation.
- **Unsupported:** Cannot be implemented using the available addon capabilities.

Claude must not invent API functions or claim that a feature works merely because it is available in another WoW version.

### 2.3 Feasibility prototype

After documenting the findings, Claude should recommend a small prototype that tests the highest-risk capabilities first.

The initial prototype should focus on:

1. Detecting duel start and completion.
2. Exchanging addon messages between participating players.
3. Determining which duel result is reported by each client.
4. Testing access to both fighters' positions at the designated location.
5. Calculating distance and detecting whether it decreases.
6. Testing whether duel requests and acceptance can be coordinated automatically.

The complete addon should not depend on unverified position tracking or automation behavior.

If a critical feature is unsupported, Claude must explain the limitation and identify what can still be implemented without it before proceeding.

---

## 3. Match formats and progression

### 3.1 Supported formats

| Format | Players per team | Maximum duels per full elimination match |
|---|---:|---:|
| 1v1 | 1 | 1 |
| 2v2 | 2 | 2 |
| 3v3 | 3 | 3 |

### 3.2 Match lifecycle

1. A team creates a challenge and selects the format.
2. The challenge displays the challenging team's average rating and every participating player's individual rating.
3. The opposing team accepts or declines.
4. Both teams prepare their fighter order.
5. The first designated fighters approach each other.
6. The addon coordinates the first duel when the required conditions are met.
7. When the duel ends, the addon determines the result and updates the match state.
8. The addon identifies the next prepared fighters.
9. The next duel begins after the preparation and range requirements are satisfied.
10. The process repeats until the match ends or a team forfeits.

The intended experience is a continuous sequence of duels, not several independent matches that require manual setup each time.

### 3.3 Fighter order

Both teams must prepare their fighter order before the match begins.

While a duel is underway, each team should know which player is scheduled to fight next.

The next matchup must follow the prepared order rather than being chosen randomly.

### 3.4 Outstanding rules

The following decisions remain unresolved:

- Whether the winner remains in the match to fight the next opponent, or each fighter participates only once.
- Whether health and resources carry over between duels or are reset.
- Whether a player who disconnects automatically forfeits the match.

These decisions must be finalized before the match progression system is considered complete.

---

## 4. Challenge interface and ratings

### 4.1 Challenge information

Each challenge should display:

- Challenging team identity.
- Match format.
- Average rating of the challenging team.
- Individual rating of every participating player.
- Rating restrictions affecting the matchup.
- Designated duel location.
- Accept and decline actions.

### 4.2 Team rating calculation

The team average is the arithmetic mean of the participating players' ratings for the selected format.

Example:

| Player | Rating |
|---|---:|
| Player A | 1,800 |
| Player B | 1,500 |
| Player C | 1,200 |
| **Team average** | **1,500** |

Formula:

Team average = sum of individual ratings / number of players.

Ratings must correspond to the relevant format. A player's 2v2 rating may differ from their 3v3 rating.

### 4.3 Boosting transparency

Displaying individual ratings makes large skill differences visible before a challenge is accepted.

The addon may also show the rating spread:

**Rating spread = highest individual rating − lowest individual rating.**

An uneven team is not automatically cheating. The objective is to provide transparent information rather than punish players simply for playing with friends of different skill levels.

---

## 5. Rating system and win-trading detection

### 5.1 Match history

The addon should record completed matches, including:

- Participating player identities.
- Team compositions.
- Match format.
- Opposing team composition.
- Match result.
- Timestamp.
- Rating changes, where applicable.

### 5.2 Consecutive rematch tracking

The addon must detect consecutive matches between the same teams without an intervening completed match against another team.

Example:

1. Team A vs. Team B.
2. Team A vs. Team B.
3. Team A vs. Team C.
4. Team A vs. Team B.

The third match resets the consecutive Team A versus Team B streak.

However, the previous encounters must remain in the recent matchup history.

Only completed matches against other opponents reset the streak. Merely sending or accepting another challenge does not count.

### 5.3 Recent matchup frequency

The addon must independently track how frequently teams fight within a rolling time window.

An intervening match does not erase recent matchup history.

This prevents players from bypassing the restriction simply by fighting one other team before resuming repeated matches.

### 5.4 Individual player overlap

The system should also track repeated encounters involving the same players when team compositions change.

For example, replacing one teammate should not completely reset the matchup history.

This helps discourage rating manipulation through team switching.

### 5.5 Rating restrictions

Proposed initial thresholds for testing:

- First two matches: normal rating calculations.
- Matches three and four: reduced rating impact.
- Match five onward: no rating change against that matchup until the restriction expires.

These thresholds are provisional and should be configurable.

Restrictions should apply symmetrically to both teams.

The challenge interface must warn players when a repeated-matchup restriction applies.

Repeated matches and alternating wins are indicators of potential win-trading, not definitive proof of cheating.

### 5.6 Rating integrity

Local addon storage can maintain personal ratings and match history, but cannot guarantee a globally authoritative, tamper-resistant rating database.

The initial implementation should establish the most reliable local system possible. Stronger community-wide rating integrity would require a trusted external service or another authoritative source.

---

## 6. Duel initiation and automatic transitions

### 6.1 Duel completion

When a duel ends, the addon should:

1. Detect the duel's termination.
2. Determine the winner where reliably possible.
3. Record the result.
4. Update the match state.
5. Identify the next scheduled fighters.
6. Notify both teams.
7. Start the preparation phase.
8. Initiate the next duel when the required conditions are met.

The addon must not assume that a duel request succeeded merely because it was issued.

### 6.2 Duel range

WoW requires duelists to be sufficiently close to initiate a duel.

The addon should coordinate positioning before attempting the request.

Failed requests must be handled gracefully. Depending on the verified API capabilities, the addon should retry or wait for the required player interaction.

### 6.3 Minimal downtime

The next fighter should be selected immediately after the previous duel ends.

Preparation and positioning should happen as efficiently as possible, without requiring the teams to coordinate manually through chat.

---

## 7. Dynamic countdown and distance tracking

### 7.1 Objective

The preparation countdown should reward players for actively approaching their next opponent while ensuring that a match cannot be delayed indefinitely.

The initial proposed preparation window is 10 seconds.

### 7.2 Countdown behavior

| Observed behavior | Intended behavior |
|---|---|
| Both fighters approach | Countdown slows significantly |
| Neither fighter approaches | Countdown runs at its normal rate |
| One approaches while the other moves away | Countdown continues and the apparent stalling player is monitored |
| Both stop approaching | Countdown resumes at its normal rate |
| Countdown expires and stalling criteria are met | Responsible team forfeits |

The countdown must always make progress. Players must not be able to keep it alive indefinitely by approaching extremely slowly.

The slowdown rate and minimum countdown progression rate must be determined through testing.

### 7.3 Distance calculation

If the WoW: Forever API allows compatible coordinates for both fighters, the addon can calculate their distance.

Given two positions:

- Player A: \((x_1,y_1)\)
- Player B: \((x_2,y_2)\)

The planar distance is:

\[
d=\sqrt{(x_2-x_1)^2+(y_2-y_1)^2}
\]

The addon should compare multiple samples over time to determine whether distance is decreasing.

Coordinate availability, map compatibility, and API restrictions must be verified before this mechanism is relied upon.

### 7.4 Stalling detection

Potential signals include:

- Persistent failure to reduce distance.
- Repeated movement away from the opponent.
- Insufficient progress before the countdown expires.
- Repeated stalling by the same player or team.

The addon should evaluate movement over time rather than relying on a single sample.

The intended competitive rule is strict: **when the configured stalling criteria are met, the responsible team forfeits the match.**

The addon does not need to distinguish between an obstacle and deliberate avoidance once the configured criteria have been met.

However, the implementation must use verified and sufficiently reliable signals. If the required position information is unavailable, Claude must report that limitation instead of fabricating a reliable detector.

---

## 8. Forfeit handling

### 8.1 Forfeit conditions

A team can forfeit through the stalling system when it fails to approach its designated opponent according to the configured criteria.

A failed duel request alone is not sufficient evidence of stalling.

### 8.2 Forfeit process

When the criteria are met:

1. Stop the preparation countdown.
2. End the match.
3. Display a forfeit popup to both teams.
4. Identify the forfeiting team.
5. Identify the winning team.
6. Explain the reason for the forfeit.
7. Record the result.
8. Apply the configured rating rules.

The match must not be left in an unresolved cancellation state.

### 8.3 Popup requirements

The popup should display:

- Match Forfeited.
- Forfeiting team.
- Winning team.
- Reason: failure to approach the designated opponent.
- Confirmation that the match has ended.

The result must be communicated consistently to both teams.

---

## 9. Designated duel location

### 9.1 Single-location approach

The addon should ideally operate at one designated location instead of supporting unrestricted matches throughout the world.

Benefits include:

- More consistent starting conditions.
- Reduced risk of outside interference.
- Fewer hostile NPC interruptions.
- Shorter distances between fighters.
- Easier position tracking and testing.
- Faster transitions between duels.

### 9.2 Location validation

Before a match begins, the addon should verify that players are at the designated location, to the extent supported by the available APIs.

If a player is elsewhere, the addon should explain where the match must take place.

The addon cannot assume that it can teleport players or grant access to an instance.

### 9.3 Potential dedicated arena

A dedicated duel area associated with WoW: Forever was discussed as a potential location.

Its actual availability, accessibility, and compatibility with the addon must be verified during the feasibility phase.

The addon must not depend on an unavailable or inaccessible arena.

### 9.4 Outside interference warning

If matches can occur outside the designated location, the addon should warn players against using contested or otherwise unsafe areas.

The warning should explain that outside players and hostile NPCs may interrupt the match.

---

## 10. Interface requirements

### 10.1 Challenge window

Displays the format, team average, individual player ratings, applicable repeated-matchup warnings, location requirements, and accept/decline actions.

### 10.2 Match status panel

Displays:

- Current duelists.
- Match progression.
- Next scheduled fighter for each team.
- Preparation countdown.
- Readiness and duel-start status.
- Applicable rating restrictions.

### 10.3 Match result panel

Displays:

- Winner of the completed duel.
- Overall match result.
- Rating changes, where applicable.
- Forfeit information, where applicable.

### 10.4 Forfeit popup

Displays the forfeiting team, winning team, reason, and confirmation that the match has ended.

The interface should be concise and prioritize rapid transitions.

---

## 11. Technical requirements

### 11.1 WoW: Forever compatibility

WoW: Forever is the explicit target platform.

All API calls, event names, addon messaging behavior, SavedVariables functionality, and protected-action restrictions must be verified against the actual Forever client.

Do not assume compatibility with Retail or Classic Era simply because an API has the same name.

### 11.2 Addon messaging

The addon must exchange match state, fighter order, readiness, and results between participating players.

Incoming messages must be validated.

A client-reported result must not automatically be treated as authoritative without an appropriate verification strategy.

### 11.3 Persistence

The addon should persist ratings, match history, and relevant player information using supported local storage mechanisms.

Local data must not be treated as tamper-proof.

### 11.4 Reliability

The addon must handle:

- Player disconnections.
- Players leaving the group.
- Failed duel requests.
- Ambiguous duel results.
- Communication failures.
- Unavailable players.
- Inconsistent match-state messages.

Failures must not silently produce incorrect winners or rating changes.

### 11.5 Development and implementation

Claude is responsible for helping implement the addon.

Development must follow this sequence:

1. Complete the technical feasibility report.
2. Identify API restrictions and unresolved questions.
3. Build the feasibility prototype.
4. Verify the highest-risk technical requirements.
5. Implement a minimal working 1v1 match.
6. Add sequential 2v2 and 3v3 progression.
7. Add ratings and match-history tracking.
8. Add repeated-matchup restrictions.
9. Add dynamic countdown and stalling detection if technically supported.
10. Add forfeit handling, location validation, and reliability improvements.
11. Test the complete addon in WoW: Forever.

Claude should keep the implementation aligned with this specification and clearly identify any proposed changes to its requirements.

---

## 12. Outstanding design decisions

These remain open until explicitly decided:

1. Whether winners remain in the match or each fighter participates once.
2. Whether health and resources carry over between duels.
3. The rating algorithm.
4. Final rematch thresholds and restriction expiry.
5. Countdown slowdown and stalling thresholds.
6. How player identities are tracked across team changes.
7. The exact designated duel location.
8. Whether duel initiation and acceptance can be automated.
9. How disconnects and withdrawals affect the match.
10. Whether ratings remain local or use an external rating service.

These questions should not prevent the initial API feasibility investigation.

---

## 13. Initial acceptance criteria

The first functional milestone should demonstrate that:

- A challenge can be created and accepted.
- The challenge displays the team average and every individual rating.
- Two players can complete a duel.
- The addon detects duel completion and records a result.
- Both clients remain synchronized about the match state.
- The addon can identify the next scheduled fighters.
- Failed duel requests do not silently corrupt the match.
- no Server yet, store rating locally on the client

Later milestones must demonstrate repeated-matchup tracking, rating restrictions, dynamic countdown behavior, reliable stalling detection, and the forfeit popup.

**Final development principle:** verify what WoW: Forever permits before implementing assumptions. Preserve the intended gameplay wherever possible, but never claim that an unsupported API capability works.
