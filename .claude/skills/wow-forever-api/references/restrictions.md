# Forever / Midnight addon restrictions

Researched 2026-10-28. Re-check the patch-notes pages when the client updates.

## Why this matters
Blizzard (Midnight, "Combat Philosophy and Addon Disarmament"): addons "should not be able to make a player
more likely to succeed in combat against an encounter or another player". Forever 1.60.1 notes:
"The addon disarmament changes introduced in Midnight, including secrets, will also be active in Forever."

A duel is player-vs-player combat. Expect friction anywhere this addon reads combat or unit state during a duel.
Our core needs (who won, positions *before* the duel, messaging *between* duels) are mostly outside combat,
so design so that nothing critical has to happen *during* the duel.

## Secret values (12.0)
- A secret is an opaque box. Tainted (addon) code can pass it to some APIs, such as `SetText` and
  `string.format`, but cannot inspect it.
- Comparison and arithmetic on secrets raise a Lua error. Equality between different types returns false,
  and `if x then` works as a nil check.
- `tonumber(secretString)` is not permitted.
- Use `issecretvalue(v)`, `canaccesssecrets()` and `hasanysecretvalues(...)` (all in the dump) to test.
- Secrets are not allowed in SavedVariables. They serialize as nil, with a comment left behind.
- `/dump` prints a secret's contents, which helps debugging, but code still can't read it.
- Unit identity: creature names, GUIDs and IDs are secret while you are in an instance.
- Health/power percentage helpers return secrets. Many unit APIs are guarded by "combat restrictions".
- Test CVars (these do not persist): `secretCombatRestrictionsForced`, `secretMapRestrictionsForced`,
  `secretPvPMatchRestrictionsForced`, `addonChatRestrictionsForced`.

## Addon communication
- `C_ChatInfo.SendAddonMessage(prefix, message, chatType?, target?) -> Enum.SendAddonMessageResult`
  - prefix ≤ 16 chars, registered via `C_ChatInfo.RegisterAddonMessagePrefix`; message ≤ 255 bytes, no NUL.
  - chatType: PARTY (the default), RAID, INSTANCE_CHAT, GUILD, OFFICER, WHISPER (target = name, same or connected realm), CHANNEL.
  - Throttle (Retail defaults; the server may change them): 10 messages per prefix, regenerating 1 per second.
    The wiki says whispers outside instances are not throttled. **Verify on Forever.**
  - Result codes (wiki): 0 Success, 1 InvalidPrefix, 2 InvalidMessage, 3 AddonMessageThrottle, 4 InvalidChatType,
    5 NotInGroup, 6 TargetRequired, 7 InvalidChannel, 8 ChannelThrottle, 9 GeneralError, 10 NotInGuild,
    11 AddOnMessageLockdown, 12 TargetOffline. **Success means the message was queued, not delivered.**
- Received via `CHAT_MSG_ADDON(prefix, text, channel, sender, target, zoneChannelID, localID, name, instanceID)`.
- Lockdown: "addons are not allowed to send communications to other players" during a Mythic+ run, a PvP match
  or an instance encounter, and chat messages arrive as secrets. `CHAT_MSG_SYSTEM` may be affected. **Test during a duel.**
- Forever 1.60.1: "Trial accounts can no longer send addon messages."
- `SendChatMessage` with SAY, YELL or EMOTE needs a hardware event outside instances.

## Positions
- `UnitPosition(unit) -> x, y, z, instanceID`: yards, relative to the instance. The **first return is the Y axis**
  (the wiki labels it so). Z is always 0. It returns nil inside instances, battlegrounds and arenas, and only works
  for `player`, `partyN` and `raidN`, **not for ungrouped units**. A "Map" restriction type exists; check whether it
  ever makes `UnitPosition` secret.
- `C_Map.GetBestMapForUnit` / `C_Map.GetPlayerMapPosition`: documented as "Only works for the player and party
  members". The result is a normalized 0–1 position on a UI map, so it is not in yards.
- Fallback for ungrouped opponents: each client sends its own `UnitPosition("player")` over addon comms.
  Distance is only valid when both instanceIDs are equal. Sender honesty is not guaranteed.

## GUIDs
Forever 1.60.1 obfuscates the server/spawn parts of creature, vehicle, pet and game object GUIDs. Player GUIDs
are not mentioned; verify that `UnitGUID("player")` is stable across sessions before using it as a rating key.

## Not the addon API: the Battle.net Web API
https://community.developer.battle.net/documentation/world-of-warcraft/game-data-apis covers Blizzard's
**out-of-game** REST API: OAuth 2.0, with Game Data (`static-*` / `dynamic-*` namespaces) and Profile (`profile-*`).
- Addons cannot make HTTP requests, so **none of it is callable from Lua**. Never cite it as evidence of in-game behavior.
- Duels are not recorded by the game server, so this API has no duel data.
- Forever coverage is unverified (as of 2026-10-28 no Forever namespace was found).
- Possible future use: a companion rating service (spec open decision 10) could use the Profile API to check that a
  character exists and get its realm and class. Results would still be client-reported.

## Sources
- https://warcraft.wiki.gg/wiki/Patch_1.60.1/API_changes/notes
- https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes/notes
- https://news.blizzard.com/en-us/article/24246290/combat-philosophy-and-addon-disarmament-in-midnight
- https://warcraft.wiki.gg/wiki/API_C_ChatInfo.SendAddonMessage
- https://warcraft.wiki.gg/wiki/API_UnitPosition
- https://www.icy-veins.com/wow-forever/news/addons-in-wow-forever-blizzard-devs-just-addressed-the-big-question/
