# Team Duel

A World of Warcraft addon for **WoW: Forever** that turns ordinary duels into organized 1v1, 2v2 and 3v3 team matches, with ratings.

> **Status: early development, untested in game.** WoW: Forever isn't released yet, so the addon has only run in a simulator.
> Several game behaviors it relies on are still unverified (see [Status](#status)).

## How it works

### Teams are parties
Your team is your normal WoW **party**. Invite people with the usual `/invite`, and the **party leader** is the team leader.

- A party of 2 can play **2v2**, and a party of 3 can play **3v3**. Solo players play **1v1**.
- Everyone in the party needs the addon. Their addons send their ratings to the leader automatically.
- When challenging, and again when accepting, every party member must be within 20 yards of their leader.
- `/td order <names...>` sets the fighter order. The leader always fights first.

### Challenging
Right-click a player and choose **Challenge**, which sits just below **Duel**. Then pick **1v1**, **2v2** or **3v3**.
**1v1** is always available. **2v2** and **3v3** are greyed out unless you lead a party of exactly that size.

- You must be within normal duel range of the player.
- **1v1** works between any two players, whatever party they're in.
- **2v2 / 3v3** go from party leader to party leader. Both parties must have exactly that many players, all with the
  addon and all within 20 yards of their leader. If not, the challenge fails and you're told why: not a leader, wrong size, not gathered,
  or a member without the addon.
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
- For the next duel, the fighters click **Start duel** in the `/td` window, or accept the other's request.
- Results are read from the game's "X has defeated Y in a duel" message. Both duelists' addons read it and tell
  everyone in the match. Teammates nearby who see it report it too, as a backup. There's no way to report a result
  by hand.
- A duel counts when **both teams' clients read the same winner**. If one side couldn't read it, the duel is fought
  again. If the teams read different winners, it's fought again too, and repeated disagreement ends the match
  without rating changes.

### Forfeits
A match always ends with a result. There's no abort: a team that holds things up or leaves **forfeits** and loses
the rating, as if it had lost the match.

- **Getting to the next duel:** when a duel ends, the next one has to start within **10 seconds**. The two
  fighters' addons swap positions every 2 seconds and measure the distance between them.
  - While they walk toward each other, the clock runs at a quarter of its speed, so walking over is never a problem.
  - Standing still, or moving apart, runs the clock at full speed.
  - **Moving away** while the other fighter walks toward you is avoiding the duel: your team forfeits right away
    (two samples in a row, about 4 seconds).
  - If the clock runs out while they're still apart, the fighter who didn't close in forfeits, or both teams if
    neither did.
  - If it runs out once they're within duel range, the duel request decides: if a fighter got it and didn't
    accept, their team forfeits; if nobody sent one, **both teams** forfeit and both lose rating.
  - If positions can't be read, the clock lasts 30 seconds instead, and the duel request decides.
  - Your scheduled opponent's duel request is **accepted for you** automatically. If the game doesn't allow that,
    you click Accept on the normal popup, and the clock goes back up to 3 seconds when the request arrives.
- **Going offline:** if a player disconnects, their team forfeits. Their own party notices it right away, and other
  players notice when they've been silent for 45 seconds.
- **Leaving:** reloading the UI or logging out mid-match forfeits it too. The addon records it when you log back in.

All timings are provisional and live in `Config.lua`.

### Ratings
- Everyone starts at **1500** in each format (1v1, 2v2 and 3v3 are separate ratings).
- Points use Elo on the team averages (K = 32), and every player on a team gets the same change.
  The duel popup and the match start show what's at stake.
- Hover over a player to see their ratings under their name in the tooltip
  (`TeamDuel: 1v1 1530  2v2 1500  3v3 1500`). A player without the addon shows 0.
  The ratings come from that player's own addon, so they're for show and never used in a match.
- `/td rating` shows your ratings and `/td history` your recent matches.
- Ratings are **stored on your own computer** (SavedVariables), not on a server.

## Commands

| Command | What it does |
|---|---|
| `/td` | Open or close the window |
| `/td order <name> ...` | Set your party's fighter order (leader first) |
| `/td challenge [1v1\|2v2\|3v3] [name]` | Challenge your target |
| `/td accept` / `decline` | Answer a challenge |
| `/td duel` | Send the duel request to your current opponent |
| `/td rating` / `history` | Your ratings and recent matches |
| `/td where` / `locations` | Your position data / the candidate duel spots |
| `/td debug` / `log` | Toggle debug output / show the last log lines |

## Installing

Copy `src/TeamDuel` into your game's AddOns folder, for example
`World of Warcraft\_forever_\Interface\AddOns\TeamDuel`. Then enable it on the character select screen
(tick "Load out of date AddOns" if it's greyed out).

Everyone taking part needs the addon. Trial accounts can't send addon messages, so they can't take part.

## Status

Milestone 1 (party teams, challenges, matches, local ratings) is implemented and passes the simulated tests.
Nothing has run in the real game yet. These still need testing once WoW: Forever is out:

- addon messages between players, before, during and after a duel;
- the right-click menu entry (and greying out formats) and the details added to the duel popup;
- the rating line in player tooltips;
- party leader and member detection, and range checks on party members;
- whether sending, accepting and cancelling duels from the addon is allowed;
- the range check and the duel result message.

The full checklist is in [todo.md](todo.md) and results go in [docs/verification-log.md](docs/verification-log.md).

Not built yet: repeated-matchup (win-trading) tracking, the dynamic preparation countdown, position-based stall detection,
the designated duel location, and a settings UI.

## Development

| | |
|---|---|
| Spec | [docs/01-spec.md](docs/01-spec.md) |
| Addon technical rules | [docs/02-wow-addon-info.md](docs/02-wow-addon-info.md) |
| Design decisions | [docs/decisions.md](docs/decisions.md) |
| Backup plans (what happens when an automatic step fails) | [docs/fallbacks.md](docs/fallbacks.md) |

```powershell
.\scripts\check.ps1    # luacheck + unit/simulation tests (needs .tools\luacheck.exe and LuaJIT)
.\scripts\deploy.ps1   # junction-link src\* into the game install(s) in wow-dev.config.json
```

- Tests run under LuaJIT (Lua 5.1, like the game): `luajit tests/run.lua`. The simulator in `tests/sim.lua`
  runs several fake clients over the real addon files.
- Look up APIs in the WoW: Forever API dump: clone `https://github.com/Atraeau/WoW-Addons` into `.ref/WoW-Addons`,
  then run `py -I .claude/skills/wow-forever-api/scripts/api_lookup.py '<regex>'`.
- Set your own game path in `wow-dev.config.local.json` (gitignored), using the same `targets` shape as `wow-dev.config.json`.
