-- Session controller: teams, challenges, the active match, duel events, results, ratings.
-- Pure rules live in Match/Rating/Protocol; this file wires them to the game and to Comm.
--
-- Manual fallbacks (spec info rule 10): the duel request is sent from a button click, the opponent
-- accepts with Blizzard's own popup (never automated), and if the winner cannot be read from the
-- system message the fighters click "I won" / "I lost". A result counts only when both agree.
local _, ns = ...
local Session = {}
ns.Session = Session

local Util, Match, Rating, DB, DuelResult = ns.Util, ns.Match, ns.Rating, ns.DB, ns.DuelResult

local S = {
	team = nil,          -- leader: { leader, members = {names}, ratings = {[name] = {r1, r2, r3}} }; member: { leader }
	invitesOut = {},     -- [name] = true, team invites we sent
	inviteIn = nil,      -- { from }
	challengeOut = nil,  -- { mid, opp, fmt, pg, a, ra, expires }
	challengeIn = nil,   -- { mid, from, fmt, pg, a, ra, expires }
	teamChallenge = nil, -- our leader challenged someone: { opp?, fmt }
	match = nil,
	duelFrom = nil,      -- who the pending Blizzard duel request is from, as the game gave the name
	duelFlagFor = nil,   -- mid whose first duel was already requested/accepted with the challenge
	lastSummary = nil,   -- record of the last finished/aborted match
	reported = {},       -- ["duel:attempt"] = true, results this client already sent
	awaitingManual = false,
}
Session.state = S

local duelPatterns = {}

local function Refresh()
	if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
end

local function Open()
	if ns.UI and ns.UI.Show then ns.UI.Show() end
end

local function Short(name)
	return Util.ShortName(name) or "?"
end

-- Sound kit IDs are UNVERIFIED on Forever; a failed sound must never break the flow.
local function Ding()
	pcall(PlaySound, (SOUNDKIT and SOUNDKIT.READY_CHECK) or 8960)
end

---------------------------------------------------------------------------
-- Teams
---------------------------------------------------------------------------

function Session.IsLeader()
	return not S.team or S.team.leader == ns.Me()
end

-- Our team as leader, creating a solo team if needed. nil if we are someone else's member.
local function LeaderTeam()
	if not Session.IsLeader() then return nil end
	if not S.team then
		S.team = { leader = ns.Me(), members = { ns.Me() }, ratings = {} }
	end
	return S.team
end

function Session.TeamMembers()
	local team = LeaderTeam()
	return team and team.members or nil
end

local function RatingsFor(team, fmt)
	local out = {}
	for i, name in ipairs(team.members) do
		if name == ns.Me() then
			out[i] = DB.GetRating(ns.db, name, fmt)
		else
			local r = team.ratings[name]
			out[i] = (r and r[fmt]) or ns.Config.RATING_START
		end
	end
	return out
end

function Session.TeamRatings(fmt)
	local team = LeaderTeam()
	return team and RatingsFor(team, fmt or #team.members) or nil
end

function Session.Invite(input)
	local name = ns.Canonical(input)
	if not name or name == ns.Me() then return ns.Print("Usage: /td invite <name>") end
	if S.match then return ns.Print("Not while a match is running.") end
	local team = LeaderTeam()
	if not team then return ns.Print("Only your team leader can invite players.") end
	if #team.members >= ns.Config.MAX_TEAM_SIZE then return ns.Print("A team has at most 3 players.") end
	if Util.IndexOf(team.members, name) then return ns.Print(Short(name) .. " is already on your team.") end
	S.invitesOut[name] = true
	if ns.Comm.Send(name, "TINV", "-", {}) then
		ns.Print("Team invite sent to " .. Short(name) .. ".")
	end
end

function Session.JoinTeam()
	local inv = S.inviteIn
	if not inv then return ns.Print("No pending team invite.") end
	if S.match then return ns.Print("Not while a match is running.") end
	if S.team and S.team.members and #S.team.members > 1 then
		return ns.Print("You lead a team. Use /td leave to disband it first.")
	end
	local fields = {
		r1 = DB.GetRating(ns.db, ns.Me(), 1),
		r2 = DB.GetRating(ns.db, ns.Me(), 2),
		r3 = DB.GetRating(ns.db, ns.Me(), 3),
	}
	if ns.Comm.Send(inv.from, "TJOIN", "-", fields) then
		S.team = { leader = inv.from }
		S.inviteIn = nil
		ns.Print("You joined " .. Short(inv.from) .. "'s team.")
	end
	Refresh()
end

function Session.IgnoreInvite()
	S.inviteIn = nil
	Refresh()
end

function Session.LeaveTeam()
	if S.match then return ns.Print("Not while a match is running. A team leader can /td abort.") end
	if not S.team then return ns.Print("You are not on a team.") end
	if S.team.leader == ns.Me() then
		for _, name in ipairs(S.team.members) do ns.Comm.Send(name, "TLEAVE", "-", {}) end
		ns.Print("Team disbanded.")
	else
		ns.Comm.Send(S.team.leader, "TLEAVE", "-", {})
		ns.Print("You left " .. Short(S.team.leader) .. "'s team.")
	end
	S.team = nil
	Refresh()
end

-- Fighter order = member order (spec §3.3). Leader sets it before challenging.
function Session.SetOrder(inputs)
	if S.match then return ns.Print("The fighter order is locked during a match.") end
	local team = LeaderTeam()
	if not team then return ns.Print("Only your team leader sets the fighter order.") end
	local order = {}
	for i, input in ipairs(inputs) do order[i] = ns.Canonical(input) end
	if #order ~= #team.members then return ns.Print("List every team member exactly once.") end
	-- The leader always fights first: the challenge's duel flag is the match's first duel.
	if order[1] ~= ns.Me() then return ns.Print("You are the leader, so you always fight first. List the others after you.") end
	for _, name in ipairs(order) do
		if not Util.IndexOf(team.members, name) then return ns.Print(tostring(name) .. " is not on your team.") end
	end
	for i, name in ipairs(order) do
		if Util.IndexOf(order, name) ~= i then return ns.Print("List every team member exactly once.") end
	end
	team.members = order
	ns.Print("Fighter order: " .. table.concat(order, ", "))
	Refresh()
end

---------------------------------------------------------------------------
-- Challenges
---------------------------------------------------------------------------

-- Our side of a fmt-sized match. 1v1 is always just us, whatever team we're on; 2v2/3v3 need us to
-- lead a team of exactly that size. Returns members, ratings, or nil and a reason code
-- ("notleader", "size<n>") that also travels in DEC.
local function OwnRoster(fmt)
	if fmt == 1 then return { ns.Me() }, { DB.GetRating(ns.db, ns.Me(), 1) } end
	local team = LeaderTeam()
	if not team then return nil, "notleader" end
	if #team.members ~= fmt then return nil, "size" .. #team.members end
	return Util.Copy(team.members), RatingsFor(team, fmt)
end

local function Format(fmt)
	return ("%dv%d"):format(fmt, fmt)
end

-- Why our own roster can't take a fmt challenge, for our own chat.
local function OwnRosterProblem(reason, fmt)
	if reason == "notleader" then return "Only your team leader can take on a " .. Format(fmt) .. "." end
	local n = tonumber(string.match(reason, "^size(%d)$"))
	if n then
		return ("Your team has %d player(s); a %s needs %d. Invite teammates with /td invite <name>."):format(n, Format(fmt), fmt)
	end
	return reason
end

-- Full name of a unit, or nil if it doesn't exist or is unreadable.
local function UnitFullNameOf(unit)
	if not UnitExists(unit) then return nil end
	local name, realm = UnitName(unit)
	if not Util.IsReadable(name) then return nil end
	return Util.FullName(name, (Util.IsReadable(realm) and realm ~= "" and realm) or ns.MyRealm())
end

-- true/false, or nil when the client can't tell (API missing, errored or secret).
-- CheckInteractDistance's duel index is UNVERIFIED on Forever (see docs/verification-log.md).
local function InDuelRange(unit)
	local ok, inRange = pcall(CheckInteractDistance, unit, ns.Config.DUEL_RANGE_INDEX)
	if not ok then ns.Log("warn", "CheckInteractDistance failed:", inRange) end
	if not ok or not Util.IsReadable(inRange) or type(inRange) ~= "boolean" then return nil end
	return inRange
end

-- Challenges need the challenger within normal duel range of the opponent (the opposing leader for 2v2/3v3).
-- input: a name (slash command, chat-name menu) or nil; unit: the unit token from the right-click menu, if any;
-- fmt: 1-3, default our team size. Without a usable unit token the range can only be checked on the target.
function Session.Challenge(input, unit, fmt)
	local opp = input and ns.Canonical(input) or UnitFullNameOf(unit or "target")
	if not opp or opp == ns.Me() then return ns.Print("Right-click the opposing team leader and choose Challenge.") end
	if not unit or UnitFullNameOf(unit) ~= opp then
		unit = UnitFullNameOf("target") == opp and "target" or nil
	end
	if not unit then return ns.Print("Target " .. Short(opp) .. " to challenge them.") end
	local inRange = InDuelRange(unit)
	if inRange == false then return ns.Print("Too far away. Get within duel range of " .. Short(opp) .. ".") end
	if inRange == nil then
		ns.Log("warn", "duel range unknown, policy", ns.Config.DUEL_RANGE_UNKNOWN)
		if ns.Config.DUEL_RANGE_UNKNOWN ~= "allow" then
			return ns.Print("Could not check the distance to " .. Short(opp) .. ". Try again.")
		end
		ns.Print("Could not check the distance to " .. Short(opp) .. "; sending anyway.")
	end
	if S.match then return ns.Print("A match is already running.") end
	fmt = fmt or (Session.TeamMembers() and #Session.TeamMembers()) or 1
	local members, ratings = OwnRoster(fmt)
	if not members then return ns.Print(OwnRosterProblem(ratings, fmt)) end
	if Util.IndexOf(members, opp) then return ns.Print("You can't challenge your own teammate.") end
	if IsInInstance() then
		ns.Print("Warning: you are in an instance. Duels need an open-world spot (/td locations).")
	end
	local mid = GetServerTime() .. ":" .. math.random(100000, 999999)
	local c = {
		mid = mid, opp = opp, fmt = fmt, pg = ns.Config.PROGRESSION,
		a = members, ra = ratings,
		expires = GetServerTime() + ns.Config.CHALLENGE_TTL,
	}
	local fields = { fmt = c.fmt, pg = c.pg, a = c.a, ra = c.ra, exp = c.expires }
	if not ns.Comm.Send(opp, "CHAL", mid, fields) then
		return ns.Print("Could not send the challenge (see /td log).")
	end
	ns.Comm.SendToAll(members, "CHAL", mid, fields)
	S.challengeOut = c
	ns.Print(("Challenged %s to a %s."):format(Short(opp), Format(fmt)))
	-- The challenge is also the duel request for the first duel (leader vs leader). We are inside the
	-- click/slash handler here, so this has its hardware event; protection on Forever is UNVERIFIED.
	local ok, err = pcall(StartDuel, unit)
	c.flagged = ok
	if not ok then
		ns.Log("error", "StartDuel on challenge failed:", err)
		ns.Print("Could not send the duel request. Once the match starts, use 'Start duel'.")
	end
	Refresh()
end

local function StartMatch(mid, f, leaderB)
	local ok, m = pcall(Match.New, {
		mid = mid, fmt = f.fmt, progression = f.pg,
		teamA = f.a, teamB = f.b, ratingsA = f.ra, ratingsB = f.rb,
		leaderA = f.a[f.li], leaderB = leaderB,
		maxDisputes = ns.Config.MAX_DISPUTES_PER_DUEL,
	})
	if not ok then
		ns.Log("error", "match rejected:", m)
		return
	end
	local out = S.challengeOut
	if (out and out.mid == mid and out.flagged) or S.duelFlagFor == mid then S.duelFlagFor = mid end
	S.match = m
	S.challengeOut, S.challengeIn, S.teamChallenge, S.lastSummary = nil, nil, nil, nil
	S.reported, S.awaitingManual = {}, false
	ns.Print(("Match started: %dv%d, %s."):format(m.fmt, m.fmt, m.progression == "pairs" and "each fighter once" or "winner stays"))
	local side = Match.TeamOf(m, ns.Me())
	if side then
		local win, loss, draw = Session.RatingStakes(side == "A" and m.ratingsA or m.ratingsB,
			side == "A" and m.ratingsB or m.ratingsA, m.fmt, m.progression)
		ns.Print("Rating at stake: " .. Session.FormatStakes(win, loss, draw))
	end
	Open()
	Session.AnnounceDuel()
end

-- Rating points our team gets for a win, a loss, and (2v2 pairs only) a draw.
function Session.RatingStakes(mine, theirs, fmt, progression)
	local avgMine, avgTheirs, k = Rating.TeamAverage(mine), Rating.TeamAverage(theirs), ns.Config.RATING_K
	local win = Rating.MatchDeltas(avgMine, avgTheirs, 1, k)
	local loss = Rating.MatchDeltas(avgMine, avgTheirs, 0, k)
	local draw = (fmt == 2 and progression == "pairs") and Rating.MatchDeltas(avgMine, avgTheirs, 0.5, k) or nil
	return win, loss, draw
end

function Session.FormatStakes(win, loss, draw)
	local function Signed(n) return (n >= 0 and "+" or "") .. n end
	local text = ("win %s, loss %s"):format(Signed(win), Signed(loss))
	return draw and (text .. ", draw " .. Signed(draw)) or text
end

-- True if the pending Blizzard duel request comes from `name` (a full name).
local function DuelIsFrom(name)
	return S.duelFrom ~= nil and DuelResult.ResolveFighter(S.duelFrom, name, ns.Me()) == name
end

-- viaDuel: called from the AcceptDuel hook, i.e. the player already accepted Blizzard's duel popup.
function Session.Accept(viaDuel)
	local c = S.challengeIn
	if not c then return ns.Print("No pending challenge.") end
	if c.expires < GetServerTime() then
		S.challengeIn = nil
		Refresh()
		return ns.Print("That challenge has expired.")
	end
	local members, ratings = OwnRoster(c.fmt)
	if not members then return ns.Print(OwnRosterProblem(ratings, c.fmt)) end
	for _, name in ipairs(members) do
		if Util.IndexOf(c.a, name) then return ns.Print(Short(name) .. " is on both teams.") end
	end
	local fields = {
		fmt = c.fmt, pg = c.pg, a = c.a, ra = c.ra,
		b = members, rb = ratings,
		li = Util.IndexOf(c.a, c.from),
	}
	local acceptDuel = not viaDuel and DuelIsFrom(c.from)
	if viaDuel or acceptDuel then S.duelFlagFor = c.mid end
	S.duelFrom = nil
	ns.Comm.SendToAll(c.a, "ACC", c.mid, fields)
	ns.Comm.SendToAll(fields.b, "ACC", c.mid, fields)
	StartMatch(c.mid, fields, ns.Me()) -- clears challengeIn, so the AcceptDuel hook below does nothing
	-- Accepted from /td instead of the duel popup: accept the duel too (the first duel is leader vs leader).
	-- Runs from a click; AcceptDuel's protection on Forever is UNVERIFIED, Blizzard's popup is the fallback.
	if acceptDuel then
		local ok, err = pcall(AcceptDuel)
		if not ok then
			ns.Log("error", "AcceptDuel failed:", err)
			ns.Print("Could not accept the duel automatically. Click Accept on the duel request.")
		end
	elseif not viaDuel then
		ns.Print("No duel request from " .. Short(c.from) .. " yet. Accept it when it appears, or use 'Start duel'.")
	end
end

-- viaDuel: called from the CancelDuel hook, i.e. the player declined Blizzard's duel popup.
function Session.Decline(viaDuel)
	local c = S.challengeIn
	if not c then return ns.Print("No pending challenge.") end
	S.challengeIn = nil -- first, so the CancelDuel hook below does nothing
	ns.Comm.Send(c.from, "DEC", c.mid, { why = "declined" })
	if not viaDuel and DuelIsFrom(c.from) then
		local ok, err = pcall(CancelDuel)
		if not ok then ns.Log("warn", "CancelDuel failed:", err) end
	end
	S.duelFrom = nil
	ns.Print("Challenge declined.")
	Refresh()
end

---------------------------------------------------------------------------
-- Duels and results
---------------------------------------------------------------------------

-- Returns the current duel and our opponent in it, or nil if we're not fighting right now.
function Session.MyDuel()
	local m = S.match
	if not m or m.state ~= "ACTIVE" then return nil end
	local duel, idx = Match.CurrentDuel(m)
	local me = ns.Me()
	if me == duel.a then return duel, idx, duel.b end
	if me == duel.b then return duel, idx, duel.a end
	return nil
end

function Session.AnnounceDuel()
	local m = S.match
	if not m then return end
	local duel, idx = Match.CurrentDuel(m)
	ns.Print(("Duel %d: %s vs %s."):format(idx, Short(duel.a), Short(duel.b)))
	local _, _, opp = Session.MyDuel()
	if opp and idx == 1 and S.duelFlagFor == m.mid then
		ns.Print("You are up! The duel with " .. Short(opp) .. " was requested with the challenge. If it doesn't start, click 'Start duel'.")
	elseif opp then
		ns.Print("You are up! Get in range of " .. Short(opp) .. " and click 'Start duel', or accept their request.")
		Ding()
	end
	Refresh()
end

-- Must run from a click (hardware event). Whether StartDuel needs one on Forever is UNVERIFIED.
function Session.StartDuel()
	local _, _, opp = Session.MyDuel()
	if not opp then return ns.Print("You are not in the current duel.") end
	local unit = UnitFullNameOf("target") == opp and "target" or Short(opp)
	local ok, err = pcall(StartDuel, unit)
	if not ok then
		ns.Log("error", "StartDuel failed:", err)
		return ns.Print("Could not send the duel request. Target " .. Short(opp) .. " and try again.")
	end
	ns.Print("Duel request sent to " .. Short(opp) .. ". If nothing happens, target them and click again.")
end

local function Participants()
	return S.match and Match.Participants(S.match) or {}
end

local function Finalize()
	local m = S.match
	local avgA, avgB = Rating.TeamAverage(m.ratingsA), Rating.TeamAverage(m.ratingsB)
	local scoreA = (m.result == "A" and 1) or (m.result == "B" and 0) or 0.5
	local deltaA, deltaB = Rating.MatchDeltas(avgA, avgB, scoreA, ns.Config.RATING_K)
	for i, name in ipairs(m.teamA) do DB.SetRating(ns.db, name, m.fmt, m.ratingsA[i] + deltaA) end
	for i, name in ipairs(m.teamB) do DB.SetRating(ns.db, name, m.fmt, m.ratingsB[i] + deltaB) end
	if S.team and S.team.ratings then
		for name, ratings in pairs(S.team.ratings) do
			if Match.TeamOf(m, name) then ratings[m.fmt] = DB.GetRating(ns.db, name, m.fmt) end
		end
	end

	local duels = {}
	for i, d in ipairs(m.duels) do duels[i] = { a = d.a, b = d.b, winner = d.winner, disputes = d.disputes } end
	local record = {
		mid = m.mid, status = "completed", ts = GetServerTime(), fmt = m.fmt, progression = m.progression,
		teamA = m.teamA, teamB = m.teamB, ratingsA = m.ratingsA, ratingsB = m.ratingsB,
		result = m.result, wins = { A = m.wins.A, B = m.wins.B }, duels = duels,
		deltaA = deltaA, deltaB = deltaB,
	}
	DB.RecordMatch(ns.db, record)
	S.lastSummary, S.match = record, nil

	local myTeam = Match.TeamOf(m, ns.Me())
	local outcome = (m.result == "draw" and "Draw") or (m.result == myTeam and "Victory") or "Defeat"
	local myDelta = (myTeam == "A") and deltaA or deltaB
	ns.Print(("Match over: %s (%d-%d). Rating %s%d."):format(outcome, m.wins.A, m.wins.B, myDelta >= 0 and "+" or "", myDelta))
	if ns.db.readOnly then ns.Print("Saved data is read-only (see /td log); this result was not stored.") end
	Refresh()
end

local function FinalizeAborted(reason)
	local m = S.match
	if not m then return end
	Match.Abort(m, reason)
	local record = {
		mid = m.mid, status = "aborted", reason = reason, ts = GetServerTime(), fmt = m.fmt,
		teamA = m.teamA, teamB = m.teamB, wins = { A = m.wins.A, B = m.wins.B },
	}
	DB.RecordMatch(ns.db, record)
	S.lastSummary, S.match = record, nil
	ns.Print("Match ended without a result (" .. reason .. "). No rating changes.")
	Refresh()
end

local function ApplyResult(reporter, idx, winner, attempt)
	local m = S.match
	local outcome, why = Match.ReportResult(m, reporter, idx, winner, attempt)
	if outcome == "ignored" then
		ns.Log("warn", "result ignored from", reporter, why)
		return
	end
	S.awaitingManual = false
	if outcome == "pending" then
		if reporter ~= ns.Me() then
			ns.Print(Short(reporter) .. " reports " .. Short(winner) .. " won duel " .. idx .. "; waiting for confirmation.")
		end
	elseif outcome == "disputed" then
		ns.Print(("Duel %d is disputed: the fighters reported different winners. Re-run the duel."):format(idx))
	elseif outcome == "aborted" then
		FinalizeAborted("repeated result disputes")
		return
	elseif outcome == "confirmed" then
		ns.Print(Short(winner) .. " wins duel " .. idx .. ".")
		if m.state == "FINISHED" then
			Finalize()
			return
		end
		Session.AnnounceDuel()
	end
	Refresh()
end

local function SendResult(winner, source)
	local duel, idx = Session.MyDuel()
	if not duel then return end
	local key = idx .. ":" .. duel.disputes
	if S.reported[key] then return end
	S.reported[key] = true
	local fields = { d = idx, w = winner, t = duel.disputes, src = source }
	ns.Comm.SendToAll(Participants(), "RES", S.match.mid, fields)
	ApplyResult(ns.Me(), idx, winner, duel.disputes)
end

-- Manual result from the "I won" / "I lost" buttons or /td won|lost.
function Session.Report(iWon)
	local duel, _, opp = Session.MyDuel()
	if not duel then return ns.Print("Only the two current fighters report the result.") end
	SendResult(iWon and ns.Me() or opp, "manual")
end

function Session.Abort()
	local m = S.match
	if not m then return ns.Print("No match is running.") end
	local me = ns.Me()
	if me ~= m.leaderA and me ~= m.leaderB then return ns.Print("Only a team leader can abort the match.") end
	ns.Comm.SendToAll(Participants(), "ABORT", m.mid, { why = "leader" })
	FinalizeAborted("aborted by " .. Short(me))
end

-- Local escape hatch when the other side is gone for good: drops the match on THIS client only.
function Session.Abandon()
	if not S.match then return ns.Print("No match is running.") end
	FinalizeAborted("abandoned locally")
end

function Session.OnPeerUnreachable(target, msgType)
	if S.match and Match.TeamOf(S.match, target) then
		ns.Print(("%s is not responding (%s). The match is paused; a leader can /td abort."):format(Short(target), msgType))
	elseif msgType == "CHAL" or msgType == "TINV" then
		ns.Print(Short(target) .. " did not respond. Do they have TeamDuel installed and are they online?")
	end
end

---------------------------------------------------------------------------
-- Incoming messages (already decoded and validated by Protocol, de-duplicated by Comm)
---------------------------------------------------------------------------

local Handlers = {}

function Handlers.TINV(from)
	if S.match then return end
	S.inviteIn = { from = from }
	ns.Print(Short(from) .. " invited you to their team. /td join to accept.")
	Open()
end

function Handlers.TJOIN(from, msg)
	local team = LeaderTeam()
	if not (team and S.invitesOut[from]) then return ns.Log("warn", "unexpected TJOIN from", from) end
	S.invitesOut[from] = nil
	if #team.members >= ns.Config.MAX_TEAM_SIZE or Util.IndexOf(team.members, from) then return end
	team.members[#team.members + 1] = from
	local f = msg.fields
	team.ratings[from] = { f.r1, f.r2, f.r3 }
	ns.Print(Short(from) .. " joined your team.")
end

function Handlers.TLEAVE(from)
	if not S.team then return end
	if S.team.leader == ns.Me() then
		local i = Util.IndexOf(S.team.members, from)
		if i and not S.match then
			table.remove(S.team.members, i)
			S.team.ratings[from] = nil
			ns.Print(Short(from) .. " left your team.")
		end
	elseif S.team.leader == from then
		S.team = nil
		ns.Print(Short(from) .. " disbanded the team.")
	end
end

function Handlers.CHAL(from, msg)
	local f = msg.fields
	if f.a[1] ~= from then return ns.Log("warn", "CHAL sender is not the challenging team's first fighter", from) end
	if f.exp < GetServerTime() then return end
	if Util.IndexOf(f.a, ns.Me()) then
		S.teamChallenge = { fmt = f.fmt }
		ns.Print(("%s challenged another team to a %dv%d. You fight as #%d."):format(Short(from), f.fmt, f.fmt, Util.IndexOf(f.a, ns.Me())))
		return
	end
	if S.match then
		ns.Comm.Send(from, "DEC", msg.mid, { why = "busy" })
		return
	end
	-- 2v2/3v3 must reach a leader with a full team; say why otherwise so the challenger isn't left waiting.
	local members, reason = OwnRoster(f.fmt)
	if not members then
		ns.Comm.Send(from, "DEC", msg.mid, { why = reason })
		ns.Print(("%s challenged you to a %s, but it can't go ahead: %s"):format(Short(from), Format(f.fmt), OwnRosterProblem(reason, f.fmt)))
		return
	end
	S.challengeIn = { mid = msg.mid, from = from, fmt = f.fmt, pg = f.pg, a = f.a, ra = f.ra, expires = f.exp }
	ns.Print(("%s challenges you to a %s. Accepting their duel request starts the match (or use /td)."):format(Short(from), Format(f.fmt)))
	Ding()
	-- The duel request may already be up; otherwise the StaticPopup_Show hook adds the details when it opens.
	if DuelIsFrom(from) and not ns.UI.DecorateDuelPopup(S.challengeIn) then Open() end
	Refresh()
end

function Handlers.ACC(from, msg)
	local f = msg.fields
	local me = ns.Me()
	if f.b[1] ~= from then return ns.Log("warn", "ACC sender is not the accepting team's first fighter", from) end
	if not (Util.IndexOf(f.a, me) or Util.IndexOf(f.b, me)) then return end
	if S.match then return ns.Log("warn", "ACC while in a match", msg.mid) end
	local out = S.challengeOut
	if f.a[f.li] == me then
		-- We issued this challenge: the accepted terms must be exactly what we sent.
		if not (out and out.mid == msg.mid and out.pg == f.pg and Util.ListEquals(out.a, f.a) and Util.ListEquals(out.ra, f.ra)) then
			return ns.Log("warn", "ACC does not match our challenge", msg.mid)
		end
	end
	StartMatch(msg.mid, f, from)
end

function Handlers.DEC(from, msg)
	local out = S.challengeOut
	if out and out.mid == msg.mid and out.opp == from then
		S.challengeOut = nil
		if out.flagged then
			local ok, err = pcall(CancelDuel) -- withdraw our duel request; no hardware event here
			if not ok then ns.Log("warn", "CancelDuel failed:", err) end
		end
		local why, opp, fmt = msg.fields.why, Short(from), Format(out.fmt)
		local n = tonumber(string.match(why, "^size(%d)$"))
		if why == "notleader" then
			ns.Print(("Challenge failed: %s is not a team leader, so they can't take a %s. Challenge their leader."):format(opp, fmt))
		elseif n then
			ns.Print(("Challenge failed: %s's team has %d player(s); a %s needs %d."):format(opp, n, fmt, out.fmt))
		elseif why == "busy" then
			ns.Print(("Challenge failed: %s is already in a match."):format(opp))
		else
			ns.Print(opp .. " declined (" .. why .. ").")
		end
		Refresh()
	end
end

function Handlers.RES(from, msg)
	local m = S.match
	if not (m and m.mid == msg.mid) then return end
	local f = msg.fields
	ApplyResult(from, f.d, f.w, f.t)
end

function Handlers.ABORT(from, msg)
	local m = S.match
	if not (m and m.mid == msg.mid) then return end
	if from ~= m.leaderA and from ~= m.leaderB then return ns.Log("warn", "ABORT from non-leader", from) end
	FinalizeAborted("aborted by " .. Short(from))
end

function Session.OnMessage(from, msg)
	local handler = Handlers[msg.type]
	if handler then
		handler(from, msg)
		Refresh()
	end
end

---------------------------------------------------------------------------
-- Game events
---------------------------------------------------------------------------

-- A challenge's duel request gets the challenge details under Blizzard's popup.
local function ShowChallengeOnDuelPopup()
	local c = S.challengeIn
	if c and DuelIsFrom(c.from) and not ns.UI.DecorateDuelPopup(c) then Open() end
end

local function OnDuelRequested(playerName)
	if not Util.IsReadable(playerName) then return end
	S.duelFrom = playerName
	local c = S.challengeIn
	if c and DuelIsFrom(c.from) then return ShowChallengeOnDuelPopup() end
	local _, _, opp = Session.MyDuel()
	if not opp then return end
	if DuelResult.ResolveFighter(playerName, opp, ns.Me()) == opp then
		ns.Print("Accept the duel request from " .. Short(opp) .. ", your scheduled opponent.")
	else
		ns.Print("Duel request from " .. playerName .. ", who is NOT your scheduled opponent (" .. Short(opp) .. ").")
	end
end

local function OnSystemMessage(text)
	if not S.match or not Util.IsReadable(text) then return end
	local winner, loser, how = DuelResult.FromSystemMessage(duelPatterns, text)
	if not winner then return end
	ns.Log("info", "duel message:", how, winner, loser)
	local duel = Session.MyDuel()
	if not duel then return end
	local w = DuelResult.ResolveFighter(winner, duel.a, duel.b)
	local l = DuelResult.ResolveFighter(loser, duel.a, duel.b)
	if w and l and w ~= l then
		SendResult(w, "auto")
	else
		ns.Log("warn", "duel message does not match the current fighters")
	end
end

local function OnDuelFinished()
	local duel, idx = Session.MyDuel()
	if not duel then return end
	local key = idx .. ":" .. duel.disputes
	C_Timer.After(ns.Config.AUTO_RESULT_GRACE, function()
		local current, currentIdx = Session.MyDuel()
		if current and currentIdx == idx and not S.reported[key] then
			S.awaitingManual = true
			ns.Print("Duel finished, but the winner couldn't be read automatically. Click 'I won' or 'I lost'.")
			Refresh()
		end
	end)
end

local function CompileDuelPatterns()
	duelPatterns = {}
	for _, entry in ipairs({ { DUEL_WINNER_KNOCKOUT, "knockout" }, { DUEL_WINNER_RETREAT, "retreat" } }) do
		local compiled = Util.IsReadable(entry[1]) and DuelResult.Compile(entry[1])
		if compiled then
			duelPatterns[#duelPatterns + 1] = { compiled = compiled, how = entry[2] }
		else
			ns.Log("warn", "duel result string unavailable:", entry[2], "(manual results only)")
		end
	end
end

function Session.Init()
	CompileDuelPatterns()
	ns.On("DUEL_REQUESTED", OnDuelRequested)
	ns.On("CHAT_MSG_SYSTEM", OnSystemMessage)
	ns.On("DUEL_FINISHED", OnDuelFinished)
	ns.On("DUEL_FINISHED", function() S.duelFrom = nil end)
	-- Blizzard's duel popup: add the challenge details when it opens, and let its Accept/Decline (which call
	-- AcceptDuel/CancelDuel) accept or decline the challenge from the same player. Post-hooks only, so the
	-- popup's own secure calls are untouched. UNVERIFIED on Forever; /td accept|decline are the fallback.
	local function Hook(name, fn)
		if not hooksecurefunc then return end
		local ok, err = pcall(hooksecurefunc, name, function(...)
			local okFn, errFn = pcall(fn, ...)
			if not okFn then ns.Log("error", "hook", name, errFn) end
		end)
		if not ok then ns.Log("warn", "could not hook", name, err) end
	end
	local function ChallengeDuelPending()
		return S.challengeIn ~= nil and DuelIsFrom(S.challengeIn.from)
	end
	Hook("StaticPopup_Show", function(which, name)
		if which ~= "DUEL_REQUESTED" then return end
		if Util.IsReadable(name) and type(name) == "string" then S.duelFrom = name end
		ShowChallengeOnDuelPopup()
	end)
	Hook("AcceptDuel", function() if ChallengeDuelPending() then Session.Accept(true) end end)
	Hook("CancelDuel", function() if ChallengeDuelPending() then Session.Decline(true) end end)
	ns.On("ADDON_ACTION_BLOCKED", function(addon, func)
		if addon == ns.name then ns.Log("error", "action blocked:", func) end
	end)
	ns.On("ADDON_ACTION_FORBIDDEN", function(addon, func)
		if addon == ns.name then ns.Log("error", "action forbidden:", func) end
	end)
	ns.On("ADDON_RESTRICTION_STATE_CHANGED", function(restriction, state)
		ns.Log("info", "restriction state", restriction, state)
	end)
end
