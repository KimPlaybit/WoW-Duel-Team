---@meta
-- Hand-written LuaLS stubs for globals that EXIST in the WoW: Forever client (build 70170,
-- Interface 16001) but have NO documented signature in the API dump.
-- Signatures come from warcraft.wiki.gg (Retail/Classic) and are UNVERIFIED on Forever.
-- Protection status (hardware event required?) is unknown: see docs/verification-log.md.
-- Documented APIs come from .ref/WoW-Addons/types/WowForeverAPI.lua; don't duplicate them here.

-- Base types the generated definitions reference but never define.
---@alias UnitToken string
---@alias UnitTokenVariant string
---@alias cstring string
---@alias WOWGUID string
---@alias uiUnit number
---@alias luaIndex number

-- WoW exposes these os functions as globals.
date = os.date
time = os.time

---Exists as a global (undocumented). Plays a sound kit by ID.
---@param soundKitID number
---@param channel? string
---@param forceNoDuplicates? boolean
---@return boolean willPlay
---@return number soundHandle
function PlaySound(soundKitID, channel, forceNoDuplicates) end

---Exists as a global (undocumented). The generated types have no widget classes, so frames are `any`.
---@param frameType string
---@param name? string
---@param parent? any
---@param template? string
---@return any frame
function CreateFrame(frameType, name, parent, template) end

---FrameXML root frame.
---@type any
UIParent = nil

---FrameXML list of frame names closed by Escape. UNVERIFIED on Forever; guard before use.
---@type string[]
UISpecialFrames = {}

---FrameXML constant table of sound kit IDs. UNVERIFIED on Forever.
---@type table<string, number>
SOUNDKIT = {}

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
