-- Simulated WoW world for integration tests: several clients, each loading the real addon files
-- into its own namespace, with whispers routed between them on a simulated clock.
-- It models only what the addon uses, with the semantics we EXPECT on Forever; passing here
-- says the addon's logic is coherent, not that the game behaves this way (that needs in-game tests).

local TOC = { "Core", "Util", "Config", "Protocol", "Rating", "Match", "DuelResult", "Position", "DB", "Comm", "Session", "UI", "Tooltip", "Init" }
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

-- Right-click menus: element descriptions that can hold a submenu.
local MenuDesc = {}
MenuDesc.__index = MenuDesc
local function NewMenuDesc(text, onClick)
	return setmetatable({ text = text, onClick = onClick, elements = {} }, MenuDesc)
end
function MenuDesc:EnumerateElementDescriptions() return ipairs(self.elements) end
function MenuDesc:Insert(desc, index) table.insert(self.elements, index, desc) end
function MenuDesc:CreateButton(text, onClick)
	local desc = NewMenuDesc(text, onClick)
	table.insert(self.elements, desc)
	return desc
end
function MenuDesc:SetEnabled(enabled) self.disabled = not enabled end
function MenuDesc:CreateDivider() table.insert(self.elements, NewMenuDesc("---")) end

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
	-- Units: player, target and partyN (the other members of CURRENT's party, in join order).
	local function UnitShort(unit)
		if unit == "player" then return CURRENT.short end
		if unit == "target" then return CURRENT.target end
		if unit == "mouseover" then return CURRENT.mouseover end
		local n = tonumber(string.match(unit or "", "^party(%d)$"))
		local group = CURRENT.group
		if n and group then
			local i = 0
			for _, short in ipairs(group.members) do
				if short ~= CURRENT.short then
					i = i + 1
					if i == n then return short end
				end
			end
		end
		return nil
	end
	_G.UnitName = function(unit) return UnitShort(unit) end
	_G.UnitExists = function(unit) return UnitShort(unit) ~= nil end
	_G.UnitIsPlayer = function(unit) return UnitShort(unit) ~= nil end
	_G.UnitIsUnit = function(a, b) return UnitShort(a) ~= nil and UnitShort(a) == UnitShort(b) end
	_G.IsInGroup = function() return CURRENT.group ~= nil end
	_G.IsInRaid = function() return false end
	_G.UnitIsConnected = function(unit)
		local short = UnitShort(unit)
		return short ~= nil and not world.offline[short]
	end
	_G.UnitIsGroupLeader = function(unit)
		return CURRENT.group ~= nil and UnitShort(unit) == CURRENT.group.leader
	end
	-- world.duelRange: true / false, or "error" for a client that can't check it (applies to the target);
	-- world.far[short] = true puts that player out of duel range of everyone.
	_G.CheckInteractDistance = function(unit, index)
		assert(index == 3, "unexpected range index")
		local short = UnitShort(unit)
		if short == nil then return false end
		if world.far[short] then return false end
		if unit ~= "target" then return true end
		if world.duelRange == "error" then error("range check unavailable") end
		return world.duelRange
	end
	-- world.dist[short] = yards from everyone (default 5); world.far[short] counts as 30.
	_G.UnitDistanceSquared = function(unit)
		local short = UnitShort(unit)
		if short == nil or not string.match(unit, "^party") then return 0, false end
		local yards = world.dist[short] or (world.far[short] and 30) or 5
		return yards * yards, true
	end
	-- hooksecurefunc: post-hooks are kept per client, so one client's hooks never run for another.
	local function RunHooks(name, ...)
		for _, fn in ipairs(CURRENT.hooks[name] or {}) do fn(...) end
	end
	_G.hooksecurefunc = function(name, fn)
		CURRENT.hooks[name] = CURRENT.hooks[name] or {}
		table.insert(CURRENT.hooks[name], fn)
	end
	-- GameTooltip: one per client (CURRENT.tooltip = { name, lines } while shown); scripts are hooked per client.
	_G.GameTooltip = {
		HookScript = function(_, script, fn)
			local key = "GameTooltip:" .. script
			CURRENT.hooks[key] = CURRENT.hooks[key] or {}
			table.insert(CURRENT.hooks[key], fn)
		end,
		GetUnit = function()
			if CURRENT.tooltip then return CURRENT.tooltip.name, "mouseover" end
		end,
		IsShown = function() return CURRENT.tooltip ~= nil end,
		AddLine = function(_, text) table.insert(CURRENT.tooltip.lines, text) end,
		Show = function() end,
	}
	_G.InCombatLockdown = function() return CURRENT.inCombat == true end
	-- StaticPopup with Blizzard's duel request dialog: one visible popup per client.
	_G.StaticPopupDialogs = {
		DUEL_REQUESTED = {
			text = "%s has challenged you to a duel.",
			OnAccept = function() _G.AcceptDuel() end,
			OnCancel = function() _G.CancelDuel() end,
		},
	}
	_G.StaticPopup_Show = function(which, arg1)
		local info = _G.StaticPopupDialogs[which]
		local fs = { text = string.format(info.text, arg1) }
		function fs:GetText() return self.text end
		function fs:SetText(text) self.text = text end
		local dialog = { which = which, info = info, fs = fs }
		function dialog:GetTextFontString() return self.fs end
		CURRENT.popup = dialog
		RunHooks("StaticPopup_Show", which, arg1)
		return dialog
	end
	_G.StaticPopup_FindVisible = function(which)
		return CURRENT.popup and CURRENT.popup.which == which and CURRENT.popup or nil
	end
	_G.StaticPopup_Hide = function(which)
		if CURRENT.popup and CURRENT.popup.which == which then CURRENT.popup = nil end
	end
	-- Right-click menus: the Retail 11.x Menu API surface the addon uses.
	_G.DUEL = "Duel"
	_G.Menu = {
		ModifyMenu = function(tag, fn)
			CURRENT.menus[tag] = CURRENT.menus[tag] or {}
			table.insert(CURRENT.menus[tag], fn)
		end,
	}
	_G.MenuUtil = {
		CreateButton = function(text, onClick) return NewMenuDesc(text, onClick) end,
		GetElementText = function(desc) return desc.text end,
	}
	-- world.pos[short] = { x, y } in yards (default: everyone on the same spot); world.noPosition hides them.
	_G.UnitPosition = function(unit)
		if world.noPosition or unit ~= "player" then return nil end
		local p = world.pos[CURRENT.short] or { 0, 0 }
		return p[1], p[2], 0, 1411
	end
	_G.IsInInstance = function() return false, "none" end
	_G.GetRealZoneText = function() return "Durotar" end
	_G.GetSubZoneText = function() return "" end
	_G.C_Map = { GetBestMapForUnit = function() return 1411 end }
	_G.C_AddOns = { GetAddOnMetadata = function() return "0.1.0" end }
	_G.PlaySound = function() end
	-- Duel requests reach the other client as DUEL_REQUESTED on the next step.
	_G.StartDuel = function(unit)
		table.insert(CURRENT.duelRequests, unit)
		local to = unit == "target" and CURRENT.target or unit
		table.insert(world.duelBus, { from = CURRENT.short, to = to })
	end
	-- Accepting or cancelling closes the duel request popup, as the game does.
	-- world.blockAutoAccept: AcceptDuel errors unless it comes from a popup click (a protected call).
	_G.AcceptDuel = function()
		if world.blockAutoAccept and not CURRENT.clicking then error("AcceptDuel blocked") end
		CURRENT.duelAccepts = CURRENT.duelAccepts + 1
		_G.StaticPopup_Hide("DUEL_REQUESTED")
		RunHooks("AcceptDuel")
	end
	_G.CancelDuel = function()
		CURRENT.duelCancels = CURRENT.duelCancels + 1
		_G.StaticPopup_Hide("DUEL_REQUESTED")
		RunHooks("CancelDuel")
	end
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
	local world = setmetatable({ now = 0, clients = {}, timers = {}, bus = {}, sent = {}, opts = opts or {}, duelRange = true, far = {}, dist = {}, offline = {}, pos = {}, duelBus = {} }, World)
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

-- Loads the addon into the client, with `db` as its SavedVariables (nil for a fresh install).
local function Login(world, client, db)
	client.frames, client.menus, client.hooks, client.ns = {}, {}, {}, {}
	world:As(client, function()
		for _, file in ipairs(TOC) do LoadAddonFile("src/TeamDuel/" .. file .. ".lua", client.ns) end
		client.slash = _G.SlashCmdList.TEAMDUEL
	end)
	_G.TeamDuelDB = db
	world:Fire(client, "ADDON_LOADED", "TeamDuel")
	world:Fire(client, "PLAYER_LOGIN")
end

function World:AddClient(short)
	local client = {
		short = short, name = short .. "-" .. REALM, printed = {}, duelRequests = {}, duelAccepts = 0, duelCancels = 0,
	}
	self.clients[client.name] = client
	Login(self, client, nil)
	return client
end

-- /reload: the client's timers stop and the addon starts again from its saved data.
function World:Reload(client)
	local db = client.ns.db
	for _, t in ipairs(self.timers) do
		if t.client == client then t.cancelled = true end
	end
	Login(self, client, db)
end

-- The client loses its connection: nothing reaches it or comes from it, its timers stop, and its party
-- members' clients get UNIT_CONNECTION.
function World:Disconnect(client)
	self.offline[client.short] = true
	for _, t in ipairs(self.timers) do
		if t.client == client then t.cancelled = true end
	end
	local group = client.group
	if not group then return end
	for _, short in ipairs(group.members) do
		local c = self.clients[short .. "-" .. REALM]
		if c ~= client then
			local unit = self:As(c, function()
				for i = 1, 4 do
					if _G.UnitName("party" .. i) == client.short then return "party" .. i end
				end
			end)
			self:Fire(c, "UNIT_CONNECTION", unit, false)
		end
	end
end

-- Click a button on the client's StaticPopup: "accept", "decline", or "timeout" to let it run out.
function World:PopupClick(client, button)
	local popup = assert(client.popup, client.short .. " has no popup")
	self:As(client, function()
		client.clicking = true
		if button == "accept" then popup.info.OnAccept(popup)
		else popup.info.OnCancel(popup, nil, button == "timeout" and "timeout" or "clicked") end
		client.clicking = nil
	end)
	client.popup = nil
end

function World:PopupText(client)
	return client.popup and client.popup.fs.text
end

-- Put clients in one party (leader first). Leaves any party they were in.
function World:Group(leader, members)
	local group = { leader = leader.short, members = { leader.short } }
	for _, m in ipairs(members) do group.members[#group.members + 1] = m.short end
	for _, short in ipairs(group.members) do
		for _, c in pairs(self.clients) do
			if c.short == short then
				if c.group and c.group ~= group then self:Ungroup(c) end
				c.group = group
			end
		end
	end
	for _, c in pairs(self.clients) do
		if c.group == group then self:Fire(c, "GROUP_ROSTER_UPDATE") end
	end
end

function World:Ungroup(client)
	local group = client.group
	if not group then return end
	client.group = nil
	for i, short in ipairs(group.members) do
		if short == client.short then table.remove(group.members, i) break end
	end
	self:Fire(client, "GROUP_ROSTER_UPDATE")
	local remaining = {}
	for _, c in pairs(self.clients) do
		if c.group == group then remaining[#remaining + 1] = c end
	end
	for _, c in ipairs(remaining) do
		if #group.members < 2 then c.group = nil end
		self:Fire(c, "GROUP_ROSTER_UPDATE")
	end
end

-- Target another client (nil clears the target).
function World:Target(client, other)
	client.target = other and other.short or nil
end

-- Mouse over another client (nil moves the mouse away): shows the unit tooltip and runs its OnTooltipSetUnit hooks.
function World:Hover(client, other)
	client.mouseover = other and other.short or nil
	client.tooltip = other and { name = other.short, lines = { other.short } } or nil
	if not other then return end
	self:As(client, function()
		for _, fn in ipairs(client.hooks["GameTooltip:OnTooltipSetUnit"] or {}) do fn(_G.GameTooltip) end
	end)
end

-- The lines of the client's shown tooltip, joined by " / " ("" when none is shown).
function World:TooltipText(client)
	return client.tooltip and table.concat(client.tooltip.lines, " / ") or ""
end

-- Right-click the target's unit frame and click through `path` (e.g. { "Challenge", "2v2" }).
-- Returns the texts of the top-level entries and of the last submenu opened.
function World:RightClickTarget(client, path)
	local root = NewMenuDesc()
	for _, text in ipairs({ "Whisper", "Invite", "Trade", "Duel", "Follow" }) do root:CreateButton(text) end
	local function Texts(desc)
		local out = {}
		for _, e in ipairs(desc.elements) do out[#out + 1] = e.text .. (e.disabled and " (off)" or "") end
		return table.concat(out, ",")
	end
	local sub
	self:As(client, function()
		for _, fn in ipairs(client.menus.MENU_UNIT_TARGET or {}) do
			fn(nil, root, { unit = "target", name = client.target })
		end
		local desc = root
		for _, text in ipairs(path or {}) do
			local found
			for _, e in ipairs(desc.elements) do
				if e.text == text then found = e end
			end
			assert(found, "no menu entry " .. text)
			if found.onClick and not found.disabled then found.onClick() end
			desc = found
			if #desc.elements > 0 then sub = Texts(desc) end
		end
	end)
	return Texts(root), sub
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

function World:DeliverWhispers()
	local bus = self.bus
	self.bus = {}
	for _, msg in ipairs(bus) do
		table.insert(self.sent, msg)
		local to = self.clients[msg.to]
		local fromClient = self.clients[msg.from]
		local drop = (self.opts.dropIf and self.opts.dropIf(msg))
			or (to and self.offline[to.short]) or (fromClient and self.offline[fromClient.short])
		if to and not drop then
			self:Fire(to, "CHAT_MSG_ADDON", msg.prefix, msg.text, "WHISPER", msg.from)
		end
	end
end

-- Blizzard's UI handles DUEL_REQUESTED before addons (it loads first): popup, then the addon event.
function World:DeliverDuelRequests()
	local duels = self.duelBus
	self.duelBus = {}
	for _, d in ipairs(duels) do
		for _, c in pairs(self.clients) do
			if c.short == d.to then
				self:As(c, _G.StaticPopup_Show, "DUEL_REQUESTED", d.from)
				self:Fire(c, "DUEL_REQUESTED", d.from)
			end
		end
	end
end

function World:Step(dt)
	self.now = self.now + dt
	-- opts.duelFirst: the duel request arrives before the challenge's addon message
	if self.opts.duelFirst then
		self:DeliverDuelRequests()
		self:DeliverWhispers()
	else
		self:DeliverWhispers()
		self:DeliverDuelRequests()
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

-- The server's duel outcome. The duel message reaches the clients in `seenBy` (default: every client, as
-- everyone stands nearby); DUEL_FINISHED only reaches the two duelists.
function World:Duel(winner, loser, seenBy)
	local text = winner.short .. " has defeated " .. loser.short .. " in a duel"
	if not seenBy then
		seenBy = {}
		for _, c in pairs(self.clients) do seenBy[#seenBy + 1] = c end
	end
	for _, c in ipairs(seenBy) do self:Fire(c, "CHAT_MSG_SYSTEM", text) end
	self:Fire(winner, "DUEL_FINISHED")
	self:Fire(loser, "DUEL_FINISHED")
end

function World:DuelWithoutMessage(a, b)
	self:Duel(a, b, {})
end

function World:Printed(client, needle)
	for _, line in ipairs(client.printed) do
		if string.find(line, needle, 1, true) then return true end
	end
	return false
end

return World
