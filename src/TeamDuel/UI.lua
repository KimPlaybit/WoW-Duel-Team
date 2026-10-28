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

local function TeamLines(lines, S)
	local me = ns.Me()
	if S.team and S.team.leader ~= me then
		lines[#lines + 1] = "Team: member of " .. Short(S.team.leader) .. "'s team."
		return
	end
	local members = ns.Session.TeamMembers()
	if not members or #members == 1 then
		lines[#lines + 1] = "Solo (1v1). Invite teammates with /td invite <name>."
		return
	end
	local ratings = ns.Session.TeamRatings(#members)
	local parts = {}
	for i, name in ipairs(members) do parts[i] = ("%d. %s (%d)"):format(i, Short(name), ratings[i]) end
	lines[#lines + 1] = ("Your team, %dv%d, fighter order: %s"):format(#members, #members, table.concat(parts, ", "))
end

local function ChallengeLines(lines, c)
	local avg = Rating.TeamAverage(c.ra)
	lines[#lines + 1] = Gold(("Challenge from %s's team: %dv%d"):format(Short(c.from), c.fmt, c.fmt))
		.. (c.pg == "pairs" and " (each fighter once)" or " (winner stays)")
	lines[#lines + 1] = ("Team average %d, spread %d"):format(Util.Round(avg), Rating.Spread(c.ra))
	for i, name in ipairs(c.a) do
		lines[#lines + 1] = ("   %d. %s  %d"):format(i, name, c.ra[i])
	end
	lines[#lines + 1] = "Repeated-matchup restrictions: not tracked yet."
	lines[#lines + 1] = "Location: one of the candidate duel spots (/td locations)."
	local members = ns.Session.TeamMembers()
	if not members then
		lines[#lines + 1] = Red("Only your team leader can accept.")
	elseif #members ~= c.fmt then
		lines[#lines + 1] = Red(("Your team has %d player(s); this challenge needs %d."):format(#members, c.fmt))
	end
	lines[#lines + 1] = ("Expires in %ds."):format(math.max(0, c.expires - GetServerTime()))
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
	if duel.disputes > 0 then
		lines[#lines + 1] = Red(("Attempt %d: earlier reports disagreed. Re-run the duel."):format(duel.disputes + 1))
	end
	local reports = duel.reports[duel.disputes] or {}
	for _, fighter in ipairs({ duel.a, duel.b }) do
		if reports[fighter] then
			lines[#lines + 1] = ("%s reported: %s won."):format(Short(fighter), Short(reports[fighter]))
		end
	end
	local myDuel = ns.Session.MyDuel()
	if myDuel then
		if ns.Session.state.awaitingManual then
			lines[#lines + 1] = Gold("Who won? Click 'I won' or 'I lost'.")
		else
			lines[#lines + 1] = Gold("You are up: start the duel or accept their request.")
		end
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
	TeamLines(lines, S)
	lines[#lines + 1] = " "

	if S.inviteIn then
		lines[#lines + 1] = Gold(Short(S.inviteIn.from) .. " invited you to their team.")
		actions[#actions + 1] = { "Join team", Session.JoinTeam }
		actions[#actions + 1] = { "Ignore", Session.IgnoreInvite }
	end

	if S.match then
		MatchLines(lines, S.match)
		if Session.MyDuel() then
			actions[#actions + 1] = { "Start duel", Session.StartDuel }
			actions[#actions + 1] = { "I won", function() Session.Report(true) end }
			actions[#actions + 1] = { "I lost", function() Session.Report(false) end }
		end
		local me = ns.Me()
		if me == S.match.leaderA or me == S.match.leaderB then
			actions[#actions + 1] = { "Abort", Session.Abort }
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
			lines[#lines + 1] = "No match. Challenge a team leader with /td challenge <name>."
		end
	end

	actions[#actions + 1] = { "Close", UI.Hide }
	return lines, actions
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

function UI.Refresh()
	if not frame or not frame:IsShown() then return end
	local lines, actions = Build()
	body:SetText(table.concat(lines, "\n"))
	for i, b in ipairs(buttons) do
		local action = actions[i]
		if action then
			b:SetText(action[1])
			b:SetScript("OnClick", action[2])
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
end
