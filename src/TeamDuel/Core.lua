-- Namespace bootstrap: logging, event dispatch, player identity.
local addonName, ns = ...
ns.name = addonName

local PREFIX = "|cff33ff99TeamDuel|r "
local earlyLog = {} -- lines logged before SavedVariables load

function ns.Print(msg)
	print(PREFIX .. msg)
end

-- Ring buffer in TeamDuelDB.debugLog; printed live when debug is on (/td debug), errors always.
function ns.Log(level, ...)
	local parts = {}
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if issecretvalue and issecretvalue(v) then
			parts[#parts + 1] = "<secret>"
		else
			parts[#parts + 1] = tostring(v)
		end
	end
	local line = date("%H:%M:%S") .. " [" .. level .. "] " .. table.concat(parts, " ")
	local buffer = ns.db and ns.db.debugLog or earlyLog
	buffer[#buffer + 1] = line
	local limit = ns.Config and ns.Config.LOG_LIMIT or 500
	while #buffer > limit do table.remove(buffer, 1) end
	if level == "error" or (ns.db and ns.db.settings.debug) then
		print(PREFIX .. line)
	end
end

function ns.FlushEarlyLog()
	if not ns.db then return end
	for _, line in ipairs(earlyLog) do ns.db.debugLog[#ns.db.debugLog + 1] = line end
	earlyLog = {}
end

-- One frame dispatches every event to registered handlers; a failing handler can't break the others.
local eventFrame = CreateFrame("Frame")
local handlers = {}

function ns.On(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		eventFrame:RegisterEvent(event)
	end
	table.insert(handlers[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
	for _, fn in ipairs(handlers[event]) do
		local ok, err = pcall(fn, ...)
		if not ok then ns.Log("error", event, err) end
	end
end)

-- Our canonical identity, "Name-Realm". Resolved once after login.
local me, myRealm

function ns.MyRealm()
	if not myRealm then
		local realm = GetNormalizedRealmName()
		if ns.Util.IsReadable(realm) and realm ~= "" then myRealm = realm end
	end
	return myRealm
end

function ns.Me()
	if not me then
		local name = UnitName("player")
		if ns.Util.IsReadable(name) then me = ns.Util.FullName(name, ns.MyRealm()) end
	end
	return me
end

-- Canonical key for a player name typed by the user or received from the game.
function ns.Canonical(name)
	if not ns.Util.IsReadable(name) or name == "" then return nil end
	return ns.Util.FullName(ns.Util.CapitalizeName(name), ns.MyRealm())
end
