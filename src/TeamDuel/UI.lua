-- One window with the challenge, match-status and result views (spec §10).
-- FrameXML templates (UIPanelButtonTemplate, GameFont*) are UNVERIFIED on Forever, so every
-- template use falls back to plain frames.
local _, ns = ...
local UI = {}
ns.UI = UI

local Util, Match, Rating = ns.Util, ns.Match, ns.Rating

local WIDTH, BUTTON_WIDTH = 440, 82
local frame, body
local buttons = {}

local function Short(name)
	return Util.ShortName(name) or "?"
end

local function Font(parent, template, size)
	local ok, fs = pcall(parent.CreateFontString, parent, nil, "OVERLAY", template)
	if not ok or not fs then fs = parent:CreateFontString(nil, "OVERLAY") end
	if not fs:GetFont() then fs:SetFont("Fonts\\FRIZQT__.TTF", size or 12, "") end
	return fs
end

local function NewButton(parent)
	local ok, b = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
	if not ok or not b then
		b = CreateFrame("Button", nil, parent)
		local bg = b:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0.35, 0.08, 0.08, 0.9)
		local label = Font(b, "GameFontNormal", 12)
		label:SetPoint("CENTER")
		b:SetFontString(label)
	end
	b:SetSize(BUTTON_WIDTH, 22)
	return b
end

local function Signed(n)
	return (n >= 0 and "+" or "") .. n
end

local function Gold(text)
	return "|cffffd100" .. text .. "|r"
end

local function Red(text)
	return "|cffff4040" .. text .. "|r"
end

---------------------------------------------------------------------------
-- Content
---------------------------------------------------------------------------

local function TeamLines(lines)
	local Session = ns.Session
	local members = Session.TeamMembers()
	if not members then
		lines[#lines + 1] = ("Team: %s's party (they lead and send challenges)."):format(Short(Session.PartyLeader()))
		return
	end
	if #members == 1 then
		lines[#lines + 1] = "Solo: 1v1 only. Form a party of 2 or 3 for 2v2/3v3."
		return
	end
	local ratings = Session.TeamRatings(#members)
	local parts = {}
	for i, name in ipairs(members) do parts[i] = ("%d. %s (%d)"):format(i, Short(name), ratings[i]) end
	lines[#lines + 1] = ("Your party, %dv%d, fighter order: %s"):format(#members, #members, table.concat(parts, ", "))
end

-- Spec §4.1 / §10.1: who, format, team average, every player's rating, restrictions, location.
-- Shared by the window and the challenge popup (which has its own timer, so no expiry line).
local function ChallengeLines(lines, c, forPopup)
	local fmt = ("%dv%d"):format(c.fmt, c.fmt)
	if c.fmt == 1 then
		lines[#lines + 1] = Gold(("%s challenges you to a %s duel."):format(Short(c.from), fmt))
		lines[#lines + 1] = ("Rating: %d"):format(c.ra[1])
	else
		lines[#lines + 1] = Gold(("%s's team challenges you to a %s"):format(Short(c.from), fmt))
			.. (c.pg == "pairs" and " (each fighter once)." or " (winner stays).")
		lines[#lines + 1] = ("Team average %d, spread %d"):format(Util.Round(Rating.TeamAverage(c.ra)), Rating.Spread(c.ra))
		for i, name in ipairs(c.a) do
			lines[#lines + 1] = ("%d. %s  %d"):format(i, Short(name), c.ra[i])
		end
	end
	local members, mine = ns.Session.TeamMembers(), nil
	if c.fmt == 1 then
		mine = { ns.DB.GetRating(ns.db, ns.Me(), 1) }
		lines[#lines + 1] = ("Your rating: %d"):format(mine[1])
	elseif not members then
		lines[#lines + 1] = Red("Only your party leader can accept.")
	elseif #members ~= c.fmt then
		lines[#lines + 1] = Red(("Your team has %d player(s); this challenge needs %d."):format(#members, c.fmt))
	else
		mine = ns.Session.TeamRatings(c.fmt)
		lines[#lines + 1] = ("Your team average %d, spread %d"):format(Util.Round(Rating.TeamAverage(mine)), Rating.Spread(mine))
	end
	if mine then
		lines[#lines + 1] = "Rating at stake: " .. ns.Session.FormatStakes(ns.Session.RatingStakes(mine, c.ra, c.fmt, c.pg))
	end
	lines[#lines + 1] = "Repeated-matchup restrictions: not tracked yet."
	lines[#lines + 1] = "Location: one of the candidate duel spots (/td locations)."
	if forPopup then
		lines[#lines + 1] = "Accepting the duel accepts the challenge. Leaders fight first."
	else
		lines[#lines + 1] = ("Expires in %ds."):format(math.max(0, c.expires - GetServerTime()))
	end
end

local function MatchLines(lines, m)
	local duel, idx = Match.CurrentDuel(m)
	local teamA, teamB = Short(m.leaderA) .. "'s team", Short(m.leaderB) .. "'s team"
	lines[#lines + 1] = Gold(("Match %dv%d"):format(m.fmt, m.fmt))
		.. ("  duel %d of up to %d"):format(idx, Match.MaxDuels(m))
	lines[#lines + 1] = ("Score: %s %d - %d %s"):format(teamA, m.wins.A, m.wins.B, teamB)
	lines[#lines + 1] = ("Now fighting: %s vs %s"):format(Short(duel.a), Short(duel.b))
	local nextA, nextB = Match.NextUp(m)
	if nextA or nextB then
		local label = m.progression == "pairs" and "Next up" or "Next in if they lose"
		lines[#lines + 1] = ("%s: %s / %s"):format(label, nextA and Short(nextA) or "-", nextB and Short(nextB) or "-")
	end
	if duel.attempt > 0 then
		lines[#lines + 1] = Red(("Attempt %d: the duel is being fought again."):format(duel.attempt + 1))
	end
	local reports = duel.reports[duel.attempt] or {}
	for _, side in ipairs({ "A", "B" }) do
		if reports[side] then
			lines[#lines + 1] = ("%s read: %s won."):format(side == "A" and teamA or teamB, Short(reports[side]))
		end
	end
	local myDuel = ns.Session.MyDuel()
	if myDuel and duel.accepted[duel.attempt] then
		lines[#lines + 1] = Gold("You are fighting.")
	elseif myDuel and ns.Session.state.countdown then
		lines[#lines + 1] = Gold(("You are up: %ds left to start the duel. Walk toward them (the clock slows); moving away forfeits."):format(
			math.max(0, math.ceil(ns.Session.state.countdown.remaining))))
	elseif myDuel then
		lines[#lines + 1] = Gold("You are up: start the duel or accept their request.")
	else
		lines[#lines + 1] = "You are not in this duel."
	end
end

local function SummaryLines(lines, r)
	if r.status == "aborted" then
		lines[#lines + 1] = Gold("Last match ended without a result") .. " (" .. tostring(r.reason) .. ")."
		return
	end
	local myTeam = Util.IndexOf(r.teamA, ns.Me()) and "A" or "B"
	local outcome = (r.result == "draw" and "Draw") or (r.result == myTeam and "Victory") or "Defeat"
	lines[#lines + 1] = Gold(("Last match: %s (%d-%d)"):format(outcome, r.wins.A, r.wins.B))
	if r.forfeit then
		lines[#lines + 1] = Red(("%s: %s."):format(ns.Session.ForfeitText(r.forfeit, r.teamA[1], r.teamB[1]),
			ns.Session.ForfeitReasonText(r.reason)))
	end
	for i, d in ipairs(r.duels) do
		local loser = d.winner == d.a and d.b or d.a
		lines[#lines + 1] = ("   Duel %d: %s beat %s"):format(i, Short(d.winner), Short(loser))
	end
	local myDelta = myTeam == "A" and r.deltaA or r.deltaB
	lines[#lines + 1] = ("Your %dv%d rating: %s"):format(r.fmt, r.fmt, Signed(myDelta))
end

local function Build()
	local S, Session = ns.Session.state, ns.Session
	local lines, actions = {}, {}
	TeamLines(lines)
	lines[#lines + 1] = " "

	if S.match then
		MatchLines(lines, S.match)
		if Session.MyDuel() then
			actions[#actions + 1] = { "Start duel", Session.StartDuel }
		end
	else
		if S.challengeIn then
			ChallengeLines(lines, S.challengeIn)
			actions[#actions + 1] = { "Accept", Session.Accept }
			actions[#actions + 1] = { "Decline", Session.Decline }
		end
		if S.challengeOut then
			local left = S.challengeOut.expires - GetServerTime()
			lines[#lines + 1] = ("Challenge sent to %s (%dv%d), %s."):format(
				Short(S.challengeOut.opp), S.challengeOut.fmt, S.challengeOut.fmt,
				left > 0 and ("expires in " .. left .. "s") or "expired")
		end
		if S.teamChallenge then
			lines[#lines + 1] = ("Your leader sent a %dv%d challenge. Waiting for an answer."):format(S.teamChallenge.fmt, S.teamChallenge.fmt)
		end
		if S.lastSummary then
			lines[#lines + 1] = " "
			SummaryLines(lines, S.lastSummary)
		end
		if not (S.challengeIn or S.challengeOut or S.teamChallenge or S.lastSummary) then
			lines[#lines + 1] = "No match. Right-click a player in duel range and choose Challenge (or target them and /td challenge). For 2v2/3v3, challenge the other party's leader."
		end
	end

	actions[#actions + 1] = { "Close", UI.Hide }
	return lines, actions
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Challenge details under Blizzard's own duel request popup ("DUEL_REQUESTED"). Ordinary duels are left
-- alone. Its Accept/Decline call AcceptDuel/CancelDuel, which Session hooks to accept/decline the challenge.
-- StaticPopup internals are FrameXML and UNVERIFIED on Forever; the /td window is the fallback.
---------------------------------------------------------------------------

local DUEL_POPUP = "DUEL_REQUESTED"

local function DuelPopupFontString()
	if not StaticPopup_FindVisible then return nil end
	local dialog = StaticPopup_FindVisible(DUEL_POPUP)
	if not dialog then return nil end
	if dialog.GetTextFontString then return dialog:GetTextFontString(), dialog end
	return dialog.Text or dialog.text, dialog
end

-- Adds the challenge details to the visible duel popup. Returns true if they are showing.
function UI.DecorateDuelPopup(c)
	local ok, fs = pcall(DuelPopupFontString)
	if not (ok and fs and fs.GetText and fs.SetText) then return false end
	local base = fs:GetText()
	if not Util.IsReadable(base) or type(base) ~= "string" then return false end
	local lines = {}
	ChallengeLines(lines, c, true)
	local info = table.concat(lines, "\n")
	if string.find(base, info, 1, true) then return true end
	fs:SetText(base .. "\n\n" .. info)
	if StaticPopup_ResizeShownDialogs then pcall(StaticPopup_ResizeShownDialogs) end
	return true
end

function UI.Refresh()
	if not frame or not frame:IsShown() then return end
	local lines, actions = Build()
	body:SetText(table.concat(lines, "\n"))
	for i, b in ipairs(buttons) do
		local action = actions[i]
		if action then
			b:SetText(action[1])
			local fn = action[2]
			b:SetScript("OnClick", function() fn() end) -- never pass the button frame on as an argument
			b:ClearAllPoints()
			b:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12 + (i - 1) * (BUTTON_WIDTH + 2), 10)
			b:Show()
		else
			b:Hide()
		end
	end
end

function UI.Show()
	if not frame then return end
	frame:Show()
	UI.Refresh()
end

function UI.Hide()
	if frame then frame:Hide() end
end

function UI.Toggle()
	if not frame then return end
	if frame:IsShown() then UI.Hide() else UI.Show() end
end

function UI.Init()
	frame = CreateFrame("Frame", "TeamDuelFrame", UIParent)
	frame:SetSize(WIDTH, 340)
	frame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
	frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

	local bg = frame:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.05, 0.05, 0.08, 0.92)

	local title = Font(frame, "GameFontNormalLarge", 14)
	title:SetPoint("TOP", frame, "TOP", 0, -10)
	title:SetText("Team Duel")

	body = Font(frame, "GameFontHighlight", 12)
	body:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -36)
	body:SetWidth(WIDTH - 28)
	body:SetJustifyH("LEFT")
	body:SetJustifyV("TOP")

	for i = 1, 5 do buttons[i] = NewButton(frame) end

	-- Refresh once a second while open, for countdowns.
	local elapsed = 0
	frame:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if elapsed >= 1 then
			elapsed = 0
			UI.Refresh()
		end
	end)

	if UISpecialFrames then table.insert(UISpecialFrames, "TeamDuelFrame") end -- close with Escape
	frame:Hide()
	UI.InstallUnitMenu()
end

---------------------------------------------------------------------------
-- "Challenge" on the right-click menu of players, right below Blizzard's "Duel", with a 1v1/2v2/3v3 submenu.
-- Menu.ModifyMenu / MenuUtil are Retail 11.x FrameXML and UNVERIFIED on Forever: the dump has
-- UnitPopup_OpenMenu (the same menu system) but doesn't list FrameXML tables. /td challenge is the fallback.
---------------------------------------------------------------------------

local CHALLENGE_LABEL = "Challenge"
local UNIT_MENUS = {
	"MENU_UNIT_PLAYER", "MENU_UNIT_TARGET", "MENU_UNIT_FOCUS",
	"MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_FRIEND",
}

-- Index of the "Duel" entry, or nil.
local function DuelIndex(root)
	for index, desc in root:EnumerateElementDescriptions() do
		if MenuUtil.GetElementText(desc) == DUEL then return index end
	end
end

local function AddChallenge(_, root, contextData)
	if type(contextData) ~= "table" or not Util.IsReadable(contextData.name) then return end
	local unit = contextData.unit
	if unit then
		local isPlayer, isMe = UnitIsPlayer(unit), UnitIsUnit(unit, "player")
		if not (Util.IsReadable(isPlayer) and isPlayer) then return end
		if not Util.IsReadable(isMe) or isMe then return end
	end
	local server = Util.IsReadable(contextData.server) and contextData.server ~= "" and contextData.server or nil
	local name = server and (contextData.name .. "-" .. server) or contextData.name
	if ns.Canonical(name) == ns.Me() then return end
	-- 1v1 is always available; 2v2/3v3 are greyed out unless we lead a party of exactly that size.
	-- SetEnabled is UNVERIFIED on Forever; Challenge re-checks and explains either way.
	local function AddFormats(challenge)
		for fmt = 1, ns.Config.MAX_TEAM_SIZE do
			local button = challenge:CreateButton(("%dv%d"):format(fmt, fmt), function() ns.Session.Challenge(name, unit, fmt) end)
			if button and button.SetEnabled then pcall(button.SetEnabled, button, ns.Session.FormatAvailable(fmt)) end
		end
	end

	local ok, index = pcall(DuelIndex, root)
	if ok and index then
		local challenge = MenuUtil.CreateButton(CHALLENGE_LABEL)
		AddFormats(challenge)
		if pcall(root.Insert, root, challenge, index + 1) then return end
	end
	-- No "Duel" entry (or the API differs): append at the end instead.
	root:CreateDivider()
	AddFormats(root:CreateButton(CHALLENGE_LABEL))
end

function UI.InstallUnitMenu()
	if not (Menu and Menu.ModifyMenu) then
		ns.Log("warn", "Menu.ModifyMenu unavailable; no right-click Challenge, use /td challenge")
		return
	end
	for _, tag in ipairs(UNIT_MENUS) do
		local ok, err = pcall(Menu.ModifyMenu, tag, function(owner, root, contextData)
			local okAdd, errAdd = pcall(AddChallenge, owner, root, contextData)
			if not okAdd then ns.Log("error", "unit menu", tag, errAdd) end
		end)
		if not ok then ns.Log("warn", "Menu.ModifyMenu", tag, err) end
	end
	ns.Log("info", "unit menu Challenge installed")
end
