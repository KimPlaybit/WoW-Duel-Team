-- Simulated WoW world for integration tests: several clients, each loading the real addon files
-- into its own namespace, with whispers routed between them on a simulated clock.
-- It models only what the addon uses, with the semantics we EXPECT on Forever; passing here
-- says the addon's logic is coherent, not that the game behaves this way (that needs in-game tests).

local TOC = { "Core", "Util", "Config", "Protocol", "Rating", "Match", "DuelResult", "DB", "Comm", "Session", "UI", "Init" }
local REALM = "Testrealm"

local World = {}
World.__index = World

local CURRENT -- client whose code is running

local function FakeWidget(client)
	local w = { scripts = {}, events = {}, shown = false }
	local methods = {
		RegisterEvent = function(self, e) self.events[e] = true end,
		SetScript = function(self, name, fn) self.scripts[name] = fn end,
		Show = function(self) self.shown = true end,
		Hide = function(self) self.shown = false end,
		IsShown = function(self) return self.shown end,
		CreateFontString = function() return FakeWidget(client) end,
		CreateTexture = function() return FakeWidget(client) end,
		GetFont = function() return "font" end,
		SetText = function(self, text) self.text = text end,
		GetText = function(self) return self.text end,
	}
	return setmetatable(w, {
		__index = function(_, key)
			return methods[key] or function() end
		end,
	})
end

local function InstallGlobals(world)
	_G.CreateFrame = function()
		local f = FakeWidget(CURRENT)
		table.insert(CURRENT.frames, f)
		return f
	end
	_G.UIParent = FakeWidget()
	_G.SlashCmdList = {}
	_G.Enum = { SendAddonMessageResult = { Success = 0 } }
	_G.date = os.date
	_G.GetTime = function() return world.now end
	_G.GetServerTime = function() return 1700000000 + math.floor(world.now) end
	_G.GetBuildInfo = function() return "1.60.1", "70170", "Oct 1 2026", 16001 end
	_G.GetNormalizedRealmName = function() return REALM end
	_G.UnitName = function(unit)
		if unit == "player" then return CURRENT.short end
		return nil
	end
	_G.UnitExists = function() return false end
	_G.UnitPosition = function() return 10, 20, 0, 1 end
	_G.IsInInstance = function() return false, "none" end
	_G.GetRealZoneText = function() return "Durotar" end
	_G.GetSubZoneText = function() return "" end
	_G.C_Map = { GetBestMapForUnit = function() return 1411 end }
	_G.C_AddOns = { GetAddOnMetadata = function() return "0.1.0" end }
	_G.PlaySound = function() end
	_G.StartDuel = function(unit) table.insert(CURRENT.duelRequests, unit) end
	local realPrint = World.realPrint or print
	World.realPrint = realPrint
	_G.print = function(...)
		if not CURRENT then return realPrint(...) end
		local parts = {}
		for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
		table.insert(CURRENT.printed, table.concat(parts, " "))
	end
	_G.C_Timer = {
		After = function(seconds, fn) world:AddTimer(seconds, fn, nil) end,
		NewTimer = function(seconds, fn) return world:AddTimer(seconds, fn, nil) end,
		NewTicker = function(seconds, fn) return world:AddTimer(seconds, fn, seconds) end,
	}
	_G.C_ChatInfo = {
		RegisterAddonMessagePrefix = function() return 0 end,
		SendAddonMessage = function(prefix, text, chatType, target)
			assert(chatType == "WHISPER", "addon only whispers")
			assert(#text <= 255, "message over 255 bytes")
			table.insert(world.bus, { prefix = prefix, text = text, from = CURRENT.name, to = target })
			return 0
		end,
	}
end

function World.New(opts)
	local world = setmetatable({ now = 0, clients = {}, timers = {}, bus = {}, sent = {}, opts = opts or {} }, World)
	InstallGlobals(world)
	_G.DUEL_WINNER_KNOCKOUT = (opts and opts.noDuelStrings) and nil or "%1$s has defeated %2$s in a duel"
	_G.DUEL_WINNER_RETREAT = (opts and opts.noDuelStrings) and nil or "%2$s has fled from %1$s in a duel"
	return world
end

function World:AddTimer(seconds, fn, interval)
	local t = { client = CURRENT, at = self.now + seconds, fn = fn, interval = interval }
	t.Cancel = function() t.cancelled = true end
	table.insert(self.timers, t)
	return t
end

function World:As(client, fn, ...)
	local previous = CURRENT
	CURRENT = client
	local results = { fn(...) }
	CURRENT = previous
	return unpack(results)
end

function World:Fire(client, event, ...)
	local args = { ... }
	self:As(client, function()
		for _, f in ipairs(client.frames) do
			if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, unpack(args)) end
		end
	end)
end

function World:AddClient(short)
	local client = {
		short = short, name = short .. "-" .. REALM,
		frames = {}, printed = {}, duelRequests = {}, ns = {},
	}
	self.clients[client.name] = client
	self:As(client, function()
		for _, file in ipairs(TOC) do LoadAddonFile("src/TeamDuel/" .. file .. ".lua", client.ns) end
		client.slash = _G.SlashCmdList.TEAMDUEL
	end)
	_G.TeamDuelDB = nil
	self:Fire(client, "ADDON_LOADED", "TeamDuel")
	self:Fire(client, "PLAYER_LOGIN")
	return client
end

function World:Slash(client, input)
	self:As(client, client.slash, input)
end

-- Click a UI action by label, the way a player would.
function World:Click(client, label)
	local found
	self:As(client, function()
		client.ns.UI.Show()
		for _, f in ipairs(client.frames) do
			if f.shown and f.text == label and f.scripts.OnClick then found = f end
		end
		assert(found, client.short .. " has no visible '" .. label .. "' button")
		found.scripts.OnClick(found)
	end)
end

function World:Step(dt)
	self.now = self.now + dt
	-- deliver whispers
	local bus = self.bus
	self.bus = {}
	for _, msg in ipairs(bus) do
		table.insert(self.sent, msg)
		local to = self.clients[msg.to]
		local drop = self.opts.dropIf and self.opts.dropIf(msg)
		if to and not drop then
			self:Fire(to, "CHAT_MSG_ADDON", msg.prefix, msg.text, "WHISPER", msg.from)
		end
	end
	-- run due timers
	local due = {}
	for _, t in ipairs(self.timers) do
		if not t.cancelled and t.at <= self.now then due[#due + 1] = t end
	end
	for _, t in ipairs(due) do
		if t.interval then t.at = t.at + t.interval else t.cancelled = true end
		self:As(t.client, t.fn)
	end
end

function World:Run(seconds)
	for _ = 1, math.floor(seconds / 0.1 + 0.5) do self:Step(0.1) end
end

-- The server's duel outcome as both duelists' clients would see it.
function World:Duel(winner, loser)
	for _, c in ipairs({ winner, loser }) do
		self:Fire(c, "CHAT_MSG_SYSTEM", winner.short .. " has defeated " .. loser.short .. " in a duel")
		self:Fire(c, "DUEL_FINISHED")
	end
end

function World:DuelWithoutMessage(a, b)
	self:Fire(a, "DUEL_FINISHED")
	self:Fire(b, "DUEL_FINISHED")
end

function World:Printed(client, needle)
	for _, line in ipairs(client.printed) do
		if string.find(line, needle, 1, true) then return true end
	end
	return false
end

return World
