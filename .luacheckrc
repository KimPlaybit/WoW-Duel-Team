-- Luacheck config for the Team Duel addon (WoW: Forever, Lua 5.1 semantics).
-- Run: scripts/check.ps1   (or: .tools/luacheck.exe src prototypes tests)
-- Based on .ref/WoW-Addons/.luacheckrc. Add an API here only after looking it up
-- with .claude/skills/wow-forever-api/scripts/api_lookup.py.

std = "lua51"
max_line_length = false
codes = true
self = false

exclude_files = {
	".ref/",
	".tools/",
	"types/",   -- LuaLS annotation stubs, not runtime code
}

-- Globals our addon intentionally writes (SavedVariables, slash commands).
globals = {
	"TeamDuelDB",
	"SLASH_TEAMDUEL1", "SLASH_TEAMDUEL2",
	"DuelProbeDB",
	"SLASH_DUELPROBE1",
	"SlashCmdList",
	"StaticPopupDialogs",
}

read_globals = {
	-- Lua / WoW Lua extensions
	"date", "time", "debugprofilestop", "format", "strsplit", "strjoin", "strtrim",
	"strmatch", "gsub", "tContains", "tinsert", "tremove", "wipe", "tostringall",
	"securecall", "securecallfunction", "hooksecurefunc", "bit",

	-- Secret values (Midnight/Forever)
	"issecretvalue", "canaccesssecrets", "hasanysecretvalues", "issecrettable", "scrubsecretvalues",

	-- Core
	"C_AddOns", "C_Timer", "C_ChatInfo", "C_EncodingUtil", "C_RestrictedActions", "C_Secrets",
	"C_Map", "C_PartyInfo", "Enum",
	"CreateFrame", "GetBuildInfo", "GetTime", "GetServerTime", "IsLoggedIn",

	-- Duel
	"StartDuel", "AcceptDuel", "CancelDuel", "ForfeitDuel",

	-- Units / group / identity
	"UnitName", "UnitFullName", "UnitGUID", "UnitIsUnit", "UnitExists", "UnitIsPlayer",
	"UnitIsConnected", "UnitIsDeadOrGhost", "UnitHealth", "UnitHealthMax", "UnitClass",
	"UnitAffectingCombat", "InCombatLockdown", "UnitPosition", "UnitInParty", "UnitInRaid",
	"UnitInRange", "CheckInteractDistance",
	"IsInGroup", "IsInRaid", "GetNumGroupMembers", "GetNormalizedRealmName", "GetRealmName", "Ambiguate",

	-- Location
	"GetRealZoneText", "GetSubZoneText", "GetZoneText", "GetMinimapZoneText",
	"GetInstanceInfo", "IsInInstance",

	-- UI
	"UIParent", "UISpecialFrames", "GameTooltip", "GameFontNormal", "GameFontHighlight", "GameFontNormalLarge",
	"StaticPopup_Show", "StaticPopup_Hide", "StaticPopup_FindVisible", "StaticPopup_ResizeShownDialogs",
	"PlaySound", "SOUNDKIT",
	"DEFAULT_CHAT_FRAME", "UIErrorsFrame", "RaidNotice_AddMessage", "Settings",
	"Menu", "MenuUtil", -- FrameXML right-click menus; UNVERIFIED on Forever
	"NORMAL_FONT_COLOR", "RED_FONT_COLOR", "GREEN_FONT_COLOR", "RAID_CLASS_COLORS", "WrapTextInColorCode",

	-- Global strings (UNVERIFIED on Forever: /dump them in game)
	"DUEL_WINNER_KNOCKOUT", "DUEL_WINNER_RETREAT", "DUEL",
}

-- Pure-Lua unit tests run under LuaJIT, outside the game.
files["tests/"] = { std = "lua51", globals = { "describe", "it", "expect", "LoadAddonFile", "LoadPure" } }
