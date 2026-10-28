# Team Duel

A World of Warcraft addon for **WoW: Forever** that turns ordinary duels into organized 1v1, 2v2 and 3v3 team matches, with ratings.

> **Status: early development, untested in game.** WoW: Forever isn't released yet, so the addon has only run in a simulator.
> Several game behaviors it relies on are still unverified (see [Status](#status)).

## How it works

### Teams
Everyone is a team of one until they invite others. The inviting player becomes the **leader**, and a team holds up to 3 players.

```
/td invite <name>     invite a player (they answer with /td join)
/td order <names...>  set the fighter order; the leader always fights first
/td leave             leave the team, or disband it as leader
```

### Challenging
Right-click a player and choose **Challenge**, which sits just below **Duel**. Then pick **1v1**, **2v2** or **3v3**.

- You must be within normal duel range of the player.
- **1v1** works between any two players, whatever team they're on.
- **2v2 / 3v3** go from leader to leader, and both teams must have exactly that many players.
  If the other player isn't a leader, or their team is the wrong size, the challenge fails and you're told why.
- The challenge also sends the normal duel request. The challenged player sees Blizzard's usual duel popup with the
  challenge details added underneath:

```
Anna has challenged you to a duel.

Anna's team challenges you to a 2v2 (each fighter once).
Team average 1500, spread 0
1. Anna  1500
2. Arne  1500
Your team average 1500, spread 0
Rating at stake: win +16, loss -16, draw +0
Repeated-matchup restrictions: not tracked yet.
Location: one of the candidate duel spots (/td locations).
Accepting the duel accepts the challenge. Leaders fight first.
```

**Accepting the duel accepts the challenge** and starts the match. Declining it declines the challenge.
Ordinary duels that aren't challenges are left untouched.

You can also send a challenge with `/td challenge [1v1|2v2|3v3] [name]` on your target.

### The match
- Only one duel happens at a time. The leaders fight first, then fighter #2 against fighter #2, and so on.
  Each fighter fights once and the majority wins. A 2v2 that ends 1–1 is a draw.
- The addon reads each duel's winner from the game's "X has defeated Y in a duel" message. If it can't,
  both fighters report it with the **I won / I lost** buttons (or `/td won` / `/td lost`).
- A duel only counts when **both fighters' clients agree** on the winner. A disputed duel is re-run, and repeated
  disputes abort the match without rating changes.
- For the next duel, the fighters click **Start duel** in the `/td` window.

### Ratings
- Everyone starts at **1500** in each format (1v1, 2v2 and 3v3 are separate ratings).
- Points use Elo on the team averages (K = 32), and every player on a team gets the same change.
  The duel popup and the match start show what's at stake.
- `/td rating` shows your ratings and `/td history` your recent matches.
- Ratings are **stored on your own computer** (SavedVariables), not on a server.

## Commands

| Command | What it does |
|---|---|
| `/td` | Open or close the window |
| `/td invite <name>` / `join` / `leave` | Manage your team |
| `/td order <name> ...` | Set the fighter order (leader first) |
| `/td challenge [1v1\|2v2\|3v3] [name]` | Challenge your target |
| `/td accept` / `decline` | Answer a challenge |
| `/td duel` | Send the duel request to your current opponent |
| `/td won` / `lost` | Report your duel result manually |
| `/td abort` | End the match without a result (team leaders) |
| `/td abandon` | Drop a stuck match on this computer only |
| `/td rating` / `history` | Your ratings and recent matches |
| `/td where` / `locations` | Your position data / the candidate duel spots |
| `/td debug` / `log` | Toggle debug output / show the last log lines |

## Installing

Copy `src/TeamDuel` into your game's AddOns folder, for example
`World of Warcraft\_forever_\Interface\AddOns\TeamDuel`. Then enable it on the character select screen
(tick "Load out of date AddOns" if it's greyed out).

Everyone taking part needs the addon. Trial accounts can't send addon messages, so they can't take part.

## Status

Milestone 1 (teams, challenges, matches, local ratings) is implemented and passes the simulated tests.
Nothing has run in the real game yet. These still need testing once WoW: Forever is out:

- addon messages between players, before, during and after a duel;
- the right-click menu entry and the details added to the duel popup;
- whether sending, accepting and cancelling duels from the addon is allowed;
- the range check and the duel result message.

The full checklist is in [todo.md](todo.md) and results go in [docs/verification-log.md](docs/verification-log.md).

Not built yet: repeated-matchup (win-trading) tracking, the dynamic preparation countdown, stalling forfeits,
the designated duel location, and a settings UI.

## Development

| | |
|---|---|
| Spec | [docs/01-spec.md](docs/01-spec.md) |
| Addon technical rules | [docs/02-wow-addon-info.md](docs/02-wow-addon-info.md) |
| Design decisions | [docs/decisions.md](docs/decisions.md) |

```powershell
.\scripts\check.ps1    # luacheck + unit/simulation tests (needs .tools\luacheck.exe and LuaJIT)
.\scripts\deploy.ps1   # junction-link src\* into the game install(s) in wow-dev.config.json
```

- Tests run under LuaJIT (Lua 5.1, like the game): `luajit tests/run.lua`. The simulator in `tests/sim.lua`
  runs several fake clients over the real addon files.
- Look up APIs in the WoW: Forever API dump: clone `https://github.com/Atraeau/WoW-Addons` into `.ref/WoW-Addons`,
  then run `py -I .claude/skills/wow-forever-api/scripts/api_lookup.py '<regex>'`.
- Set your own game path in `wow-dev.config.local.json` (gitignored), using the same `targets` shape as `wow-dev.config.json`.
