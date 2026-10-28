-- Startup and slash commands. Loaded last.
local addonName, ns = ...
local Util = ns.Util

ns.On("ADDON_LOADED", function(name)
	if name ~= addonName then return end
	local db, err = ns.DB.Migrate(TeamDuelDB)
	TeamDuelDB = db
	ns.db = db
	ns.FlushEarlyLog()
	if err then
		ns.Log("error", err)
		ns.Print("|cffff4040Saved data problem: " .. err .. ". Ratings are read-only this session.|r")
	end
end)

ns.On("PLAYER_LOGIN", function()
	if not ns.db or not ns.Me() then
		ns.Print("|cffff4040Could not initialize (saved data or character name unavailable). Addon disabled.|r")
		return
	end
	ns.Comm.Init()
	ns.Session.Init()
	ns.UI.Init()
	ns.ready = true
	ns.Log("info", "loaded", "version", C_AddOns.GetAddOnMetadata(addonName, "Version"), "build", select(2, GetBuildInfo()))
	ns.Print("loaded. /td opens the window, /td help lists commands.")
end)

local function Show(v)
	if Util.IsReadable(v) then return tostring(v) end
	return v == nil and "nil" or "<secret>"
end

-- Prints where we stand; logged too, so readings end up in SavedVariables for docs/verification-log.md.
local function Where()
	local mapID = C_Map.GetBestMapForUnit("player")
	local y, x, _, instanceID = UnitPosition("player")
	local inInstance, instanceType = IsInInstance()
	local line = ("map %s | zone %s | subzone %s | pos y=%s x=%s instance=%s | inInstance %s (%s)"):format(
		Show(mapID), Show(GetRealZoneText()), Show(GetSubZoneText()),
		Show(y), Show(x), Show(instanceID), Show(inInstance), Show(instanceType))
	ns.Print(line)
	ns.Log("info", "where", line)
end

local function Ratings()
	local me = ns.Me()
	ns.Print(("Your ratings: 1v1 %d, 2v2 %d, 3v3 %d (stored locally on this computer)."):format(
		ns.DB.GetRating(ns.db, me, 1), ns.DB.GetRating(ns.db, me, 2), ns.DB.GetRating(ns.db, me, 3)))
end

local function History()
	local matches = ns.db.matches
	if #matches == 0 then return ns.Print("No matches recorded yet.") end
	for i = #matches, math.max(1, #matches - 4), -1 do
		local r = matches[i]
		local when = date("%Y-%m-%d %H:%M", r.ts)
		if r.status == "aborted" then
			ns.Print(("%s %dv%d aborted (%s)"):format(when, r.fmt, r.fmt, tostring(r.reason)))
		else
			ns.Print(("%s %dv%d %s's team %d-%d %s's team"):format(when, r.fmt, r.fmt,
				Util.ShortName(r.teamA[1]), r.wins.A, r.wins.B, Util.ShortName(r.teamB[1])))
		end
	end
end

local HELP = {
	"/td - open or close the window",
	"/td invite <name> - invite a player to your team (you lead; max 3)",
	"/td join - accept a team invite",
	"/td leave - leave your team (or disband it as leader)",
	"/td order <name> <name> ... - set your team's fighter order",
	"/td challenge <leader> - challenge another team (format = your team size)",
	"/td accept | decline - answer a challenge",
	"/td duel - send the duel request to your current opponent",
	"/td won | lost - report your duel result manually",
	"/td abort - end the match without a result (team leaders)",
	"/td abandon - drop a stuck match on this computer only",
	"/td rating | history - your local ratings and recent matches",
	"/td where | locations - your position data / candidate duel spots",
	"/td debug | log - toggle debug output / show the last log lines",
}

local Commands = {
	help = function() for _, line in ipairs(HELP) do ns.Print(line) end end,
	invite = function(args) ns.Session.Invite(args[1]) end,
	join = function() ns.Session.JoinTeam() end,
	leave = function() ns.Session.LeaveTeam() end,
	order = function(args) ns.Session.SetOrder(args) end,
	challenge = function(args) ns.Session.Challenge(args[1]) end,
	accept = function() ns.Session.Accept() end,
	decline = function() ns.Session.Decline() end,
	duel = function() ns.Session.StartDuel() end,
	won = function() ns.Session.Report(true) end,
	lost = function() ns.Session.Report(false) end,
	abort = function() ns.Session.Abort() end,
	abandon = function() ns.Session.Abandon() end,
	rating = Ratings,
	history = History,
	where = Where,
	locations = function()
		for i, loc in ipairs(ns.Config.LOCATIONS) do
			ns.Print(("%d. %s (%s)"):format(i, loc.name, loc.faction))
		end
	end,
	debug = function()
		ns.db.settings.debug = not ns.db.settings.debug
		ns.Print("Debug output " .. (ns.db.settings.debug and "on." or "off."))
	end,
	log = function()
		local log = ns.db.debugLog
		for i = math.max(1, #log - 29), #log do print(log[i]) end
	end,
}

SLASH_TEAMDUEL1 = "/td"
SLASH_TEAMDUEL2 = "/teamduel"
SlashCmdList.TEAMDUEL = function(input)
	if not ns.ready then return ns.Print("Not initialized; see the message at login.") end
	local args = {}
	for word in string.gmatch(input or "", "%S+") do args[#args + 1] = word end
	local cmd = string.lower(table.remove(args, 1) or "")
	if cmd == "" then return ns.UI.Toggle() end
	local handler = Commands[cmd]
	if not handler then return ns.Print("Unknown command. /td help lists commands.") end
	handler(args)
end
