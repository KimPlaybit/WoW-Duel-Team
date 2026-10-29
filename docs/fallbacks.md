# Backup plans

What the addon does automatically, and what happens when the game blocks it or the data isn't there.
None of the automatic steps has been tested in WoW: Forever yet (see [todo.md](../todo.md)), so each one has a
backup that still lets a match finish fairly. Timings are in `src/TeamDuel/Config.lua`.

## Starting a duel

| Automatic | If it doesn't work | Backup |
|---|---|---|
| **The scheduled opponent's duel request is accepted for you** during a match (`AcceptDuel` from the `DUEL_REQUESTED` event) | The game blocks accepting without a click | Blizzard's normal duel popup stays up and you click **Accept**. When the request arrives, the clock goes back up to **3 seconds** if it was lower, so there's time to click. If it still isn't accepted when the clock runs out, your team forfeits. |
| **Challenging sends the duel request** (`StartDuel` from the menu click or `/td challenge`) | `StartDuel` is blocked | The challenge still goes out. You're told to use **Start duel** in the `/td` window (or `/td duel`) once the match starts, or Blizzard's own right-click **Duel**. |
| **Accepting the duel popup accepts the challenge** (hook on `AcceptDuel`) | The hook doesn't fire | `/td accept`, or **Accept** in the `/td` window, which also accepts the pending duel. |
| **Declining the duel popup declines the challenge** (hook on `CancelDuel`) | The hook doesn't fire | `/td decline` or **Decline** in the window. The challenge also expires after 2 minutes. |
| **Challenge details under Blizzard's duel popup** | The popup can't be found or changed | The `/td` window opens with the same details. |
| **Challenge in the right-click menu** | The menu API is missing | `/td challenge [1v1/2v2/3v3]` on your target. |
| **2v2/3v3 greyed out in the menu** | Greying isn't supported | The option is clickable, but the click checks the party and explains why it can't be used. |

## Results

| Automatic | If it doesn't work | Backup |
|---|---|---|
| **Reading "X has defeated Y in a duel"** on both duelists' clients | One duelist's addon misses it | Teammates and waiting fighters standing nearby read it too and report it. |
| | Neither team reads it | **10 seconds** after the duel ends, it's fought again (a new attempt). There's no manual result: you can't type in who won. |
| | The teams read different winners | It's fought again. After 2 disagreements the match ends without rating changes; that's the only way a match ends without a result. |
| An accepted duel ends | Nothing ever ends it (it never really started) | After **10 minutes** it's fought again. |

## The countdown between duels

| Automatic | If it doesn't work | Backup |
|---|---|---|
| **Fighters swap positions** (`UnitPosition`) to time the 10 seconds and spot avoiding | Positions are unreadable, secret, or on different maps | The clock lasts **30 seconds** with no movement checks. When it runs out, the duel request decides: the fighter who got it and didn't accept forfeits, or both teams if nobody sent one. |
| | The opponent stops sending anything | The clock pauses, and the disconnect rule below decides, so a disconnect doesn't make both teams forfeit. |
| **The fighters' clients end the countdown** | Neither of them ever decides | Every client in the match has a **2-minute** backstop that applies the duel-request rule. |

## Disconnects and leaving

| Automatic | If it doesn't work | Backup |
|---|---|---|
| **A party member going offline** is seen at once (`UNIT_CONNECTION`, `UnitIsConnected`) and their team forfeits | The event or API doesn't work | Everyone pings everyone every 10 seconds. A player silent for **45 seconds** forfeits for their team. |
| **Reload or logout mid-match** is recorded as a forfeit at the next login (the match is kept in SavedVariables) | The client crashes, so SavedVariables aren't written | The other players' clients still record the forfeit through the 45-second silence rule; only the crashed player's own record misses it. |

## Range and other checks

| Automatic | If it doesn't work | Backup |
|---|---|---|
| **Duel range to the opponent** (`CheckInteractDistance`) | Unreadable | The challenge is sent with a warning (`DUEL_RANGE_UNKNOWN = "allow"`; can be set to `"block"`). |
| **Party within 20 yards of the leader** (`UnitDistanceSquared`) | Unreadable | Same setting: allowed with the default. |
| **Ratings in player tooltips** | The tooltip hook isn't available | No rating line in tooltips; `/td rating` still shows your own. |
