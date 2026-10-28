---@meta
-- Hand-written LuaLS stubs for globals that EXIST in the WoW: Forever client (build 70170,
-- Interface 16001) but have NO documented signature in the API dump.
-- Signatures come from warcraft.wiki.gg (Retail/Classic) and are UNVERIFIED on Forever.
-- Protection status (hardware event required?) is unknown: see docs/verification-log.md.
-- Documented APIs come from .ref/WoW-Addons/types/WowForeverAPI.lua; don't duplicate them here.

---UNVERIFIED on Forever. Challenge a unit (or a name) to a duel. May require a hardware event.
---@param unitOrName string
---@param exactMatch? boolean
function StartDuel(unitOrName, exactMatch) end

---UNVERIFIED on Forever. Accept a pending duel request. May require a hardware event.
function AcceptDuel() end

---UNVERIFIED on Forever. Decline a pending duel request or cancel your outgoing one.
function CancelDuel() end

---UNVERIFIED on Forever. Forfeit the duel currently in progress.
function ForfeitDuel() end

---UNVERIFIED on Forever: global string, not in the dump. /dump it in game.
---Classic format: "%1$s has defeated %2$s in a duel"
---@type string
DUEL_WINNER_KNOCKOUT = nil

---UNVERIFIED on Forever: global string, not in the dump. /dump it in game.
---Classic format: "%2$s has fled from %1$s in a duel"
---@type string
DUEL_WINNER_RETREAT = nil
