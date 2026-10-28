# APIs the Team Duel addon needs, with their status

Status key: **D** = in the client dump with a documented signature. **G** = exists as an undocumented global only.
**W** = semantics from warcraft.wiki.gg (Retail/Classic). **IG** = verified in-game on Forever (fill in the date).
The feasibility status follows the spec: Verified / Partially / Unverified / Unsupported.

Dump checked: build 70170, Interface 16001, 2026-10-28.

## Duel lifecycle
| API | Source | Known facts | Feasibility | In-game test needed |
|---|---|---|---|---|
| `StartDuel(unit)` / `StartDuel(name, exact)` | G, W | Exists. Signature from the wiki only. Protection status unknown. | Unverified | Call it from a slash command (hardware event) and from `C_Timer.After` (no hardware event). Watch `ADDON_ACTION_BLOCKED/FORBIDDEN`. Test at range and out of range. |
| `AcceptDuel()` | G | Exists. Protection status unknown. Called from the challenge popup's Accept click. | Unverified | Call it from a `DUEL_REQUESTED` handler (no hardware event). If blocked, the player has to click Accept themselves. |
| `CancelDuel()` / `ForfeitDuel()` | G | Exist. | Unverified | Check the behavior before and after the countdown. |
| `DUEL_REQUESTED(playerName)` | D | Payload: the challenger's name. | Verified (exists) | Check the name format, for example whether a realm suffix is included. |
| `DUEL_TO_THE_DEATH_REQUESTED(playerName)` | D | Exists. Reject or ignore it. | Verified (exists) | — |
| `DUEL_FINISHED` | D | **No payload**, so it does not tell you who won. | Verified (exists) | Order relative to `CHAT_MSG_SYSTEM`, and whether it fires on cancel. |
| `DUEL_INBOUNDS` / `DUEL_OUTOFBOUNDS` | D | Fire when a duelist leaves or returns to the duel area. | Verified (exists) | Useful as a "fleeing" signal. |
| Winner via `CHAT_MSG_SYSTEM` + `DUEL_WINNER_KNOCKOUT` / `DUEL_WINNER_RETREAT` global strings | W | Classic approach: parse "%1$s has defeated %2$s in a duel" or "%2$s has fled from %1$s in a duel". | Unverified | `/dump DUEL_WINNER_KNOCKOUT, DUEL_WINNER_RETREAT`. Check whether the text is secret (`issecretvalue`), whether both clients see it, and how names are formatted. Bystanders nearby also see it. |
| Duel start | — | No `DUEL_STARTED` event in the dump. | Unverified | Candidates: a countdown in `CHAT_MSG_SYSTEM` text, `PLAYER_REGEN_DISABLED`, `UNIT_FLAGS`. Test which one fires. |

## Communication
| API | Source | Facts | Feasibility | Test |
|---|---|---|---|---|
| `C_ChatInfo.RegisterAddonMessagePrefix(prefix)` | D | Returns a `RegisterAddonMessagePrefixResult`. | Verified (exists) | — |
| `C_ChatInfo.SendAddonMessage(prefix,msg,chatType?,target?)` | D | Returns a `SendAddonMessageResult`. | Partially | WHISPER to an ungrouped player, before, during and after a duel. Log the result codes. |
| `CHAT_MSG_ADDON` | D | 9-arg payload (see restrictions.md). | Verified (exists) | Check the sender format: `Name-Realm`. Use `Ambiguate`. |
| `C_RestrictedActions.IsAddOnRestrictionActive(type)` | D | Always false during dispatch of `ADDON_RESTRICTION_STATE_CHANGED`. | Verified (exists) | `/dump Enum.AddOnRestrictionType`. Log state changes during a duel. |
| `C_EncodingUtil.SerializeCBOR` / `DeserializeCBOR` / `EncodeBase64` / `CompressString` | D | Available for encoding payloads. | Verified (exists) | Base64 output has to fit within 255 bytes. |

## Position and location
| API | Source | Facts | Feasibility | Test |
|---|---|---|---|---|
| `UnitPosition(unit)` | D, W | Returns `y, x, z, instanceID` in yards. Works for player, party and raid only. Returns nil in instances. | Partially | Check `UnitPosition("player")` at the duel spot, and whether it is secret. Exchange it via comms and compare with the partner's own reading. |
| `C_Map.GetBestMapForUnit(unit)` / `C_Map.GetPlayerMapPosition(mapID, unit)` | D | "Only works for the player and party members." Returns a normalized vector2. | Partially | Use it for location validation, not for distance. |
| `GetRealZoneText` / `GetSubZoneText` / `GetMinimapZoneText` / `GetZoneText` | D | Zone strings are localized, so compare them using the uiMapID where possible. | Verified (exists) | Read them at the designated spot. |
| `GetInstanceInfo()` / `IsInInstance()` | D | Use these to reject instanced locations. | Verified (exists) | — |
| `StaticPopup_Show` / `StaticPopup_FindVisible` / `hooksecurefunc` | G | Exist (undocumented). Used to add challenge details to Blizzard's `DUEL_REQUESTED` popup and post-hook `AcceptDuel`/`CancelDuel`. Dialog text region (`GetTextFontString` / `.Text`) unverified. | Unverified | Fallback: `/td accept`/`decline` window. |
| `Menu.ModifyMenu(tag, fn)` / `MenuUtil` | FrameXML | Adds "Challenge" to `MENU_UNIT_*` right-click menus. Not in the dump (it lists only `C_*` tables); `UnitPopup_OpenMenu` is, so the 11.x menu system is likely present. | Unverified | Fallback: `/td challenge`. |
| `CheckInteractDistance(unit, idx)` / `UnitInRange(unit)` | D | Coarse range booleans. `UnitInRange` is for group members only. | Partially | Gates challenges: `CheckInteractDistance("target", 3)` must be true (duel range). Index 3 and in-combat behavior UNVERIFIED. |
| `ZONE_CHANGED`, `ZONE_CHANGED_NEW_AREA`, `ZONE_CHANGED_INDOORS` | D | Exist. | Verified (exists) | — |

## Units, identity, group
| API | Source | Facts |
|---|---|---|
| `UnitName`, `UnitFullName`, `UnitGUID`, `UnitIsUnit`, `UnitIsConnected`, `UnitIsDeadOrGhost`, `UnitHealth`, `UnitAffectingCombat`, `InCombatLockdown` | D | All exist. Any of them may return secrets under restrictions, so check with `issecretvalue`. |
| `GetNormalizedRealmName`, `Ambiguate` | D | Use these to build a canonical `Name-Realm` key. |
| `IsInGroup`, `IsInRaid`, `GetNumGroupMembers`, `UnitInParty`, `UnitInRaid`, `GROUP_ROSTER_UPDATE` | D | A party holds at most 5 players, so a 3v3 match (6 players) needs a raid. |
| `C_PartyInfo.InviteUnit` | D | Legacy `InviteUnit` is **missing**. Probably needs a hardware event, so test it. |
| `UNIT_CONNECTION`, `PARTY_MEMBER_DISABLE`, `PLAYER_DEAD`, `UNIT_HEALTH` | D | Use these for disconnect detection. |

## Timers, time, UI, persistence
| API | Source | Facts |
|---|---|---|
| `C_Timer.After`, `C_Timer.NewTimer`, `C_Timer.NewTicker` | D | Use these for countdown and position sampling. |
| `GetTime()` | D | Local monotonic seconds, for durations. |
| `GetServerTime()`, `time()`, `date()` | D | Use these for match-history timestamps. |
| `CreateFrame`, `StaticPopup_Show`, `PlaySound` | D | For UI and the forfeit popup. |
| `ADDON_LOADED`, `PLAYER_LOGIN`, `PLAYER_LOGOUT`, `PLAYER_ENTERING_WORLD` | D | SavedVariables are available from `ADDON_LOADED` for our addon. |
| `C_AddOns.GetAddOnMetadata` | D | Reads the version from the TOC. |
| `ADDON_ACTION_BLOCKED`, `ADDON_ACTION_FORBIDDEN` | D | Register these in every prototype to detect protected calls. |
