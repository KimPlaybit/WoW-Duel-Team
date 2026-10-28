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

function Session.Challenge(input)
	local opp = ns.Canonical(input)
	if not opp or opp == ns.Me() then return ns.Print("Usage: /td challenge <opposing team leader>") end
	if S.match then return ns.Print("A match is already running.") end
	local team = LeaderTeam()
	if not team then return ns.Print("Only your team leader can send challenges.") end
	if Util.IndexOf(team.members, opp) then return ns.Print("You can't challenge your own teammate.") end
	if IsInInstance() then
		ns.Print("Warning: you are in an instance. Duels need an open-world spot (/td locations).")
	end
	local fmt = #team.members
	local mid = GetServerTime() .. ":" .. math.random(100000, 999999)
	local c = {
		mid = mid, opp = opp, fmt = fmt, pg = ns.Config.PROGRESSION,
		a = Util.Copy(team.members), ra = RatingsFor(team, fmt),
		expires = GetServerTime() + ns.Config.CHALLENGE_TTL,
	}
	local fields = { fmt = c.fmt, pg = c.pg, a = c.a, ra = c.ra, exp = c.expires }
	if not ns.Comm.Send(opp, "CHAL", mid, fields) then
		return ns.Print("Could not send the challenge (see /td log).")
	end
	ns.Comm.SendToAll(team.members, "CHAL", mid, fields)
	S.challengeOut = c
	ns.Print(("Challenged %s to a %dv%d."):format(Short(opp), fmt, fmt))
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
	S.match = m
	S.challengeOut, S.challengeIn, S.teamChallenge, S.lastSummary = nil, nil, nil, nil
	S.reported, S.awaitingManual = {}, false
	ns.Print(("Match started: %dv%d, %s."):format(m.fmt, m.fmt, m.progression == "pairs" and "each fighter once" or "winner stays"))
	Open()
	Session.AnnounceDuel()
end

function Session.Accept()
	local c = S.challengeIn
	if not c then return ns.Print("No pending challenge.") end
	if c.expires < GetServerTime() then
		S.challengeIn = nil
		Refresh()
		return ns.Print("That challenge has expired.")
	end
	local team = LeaderTeam()
	if not team then return ns.Print("Only your team leader can accept challenges.") end
	if #team.members ~= c.fmt then
		return ns.Print(("This is a %dv%d challenge but your team has %d player(s)."):format(c.fmt, c.fmt, #team.members))
	end
	for _, name in ipairs(team.members) do
		if Util.IndexOf(c.a, name) then return ns.Print(Short(name) .. " is on both teams.") end
	end
	local fields = {
		fmt = c.fmt, pg = c.pg, a = c.a, ra = c.ra,
		b = Util.Copy(team.members), rb = RatingsFor(team, c.fmt),
		li = Util.IndexOf(c.a, c.from),
	}
	ns.Comm.SendToAll(c.a, "ACC", c.mid, fields)
	ns.Comm.SendToAll(fields.b, "ACC", c.mid, fields)
	StartMatch(c.mid, fields, ns.Me())
end

function Session.Decline()
	local c = S.challengeIn
	if not c then return ns.Print("No pending challenge.") end
	ns.Comm.Send(c.from, "DEC", c.mid, { why = "declined" })
	S.challengeIn = nil
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
	if opp then
		ns.Print("You are up! Get in range of " .. Short(opp) .. " and click 'Start duel', or accept their request.")
		Ding()
	end
	Refresh()
end

-- Must run from a click (hardware event). Whether StartDuel needs one on Forever is UNVERIFIED.
function Session.StartDuel()
	local _, _, opp = Session.MyDuel()
	if not opp then return ns.Print("You are not in the current duel.") end
	local unit = Short(opp)
	if UnitExists("target") then
		local name, realm = UnitName("target")
		if Util.IsReadable(name) then
			local targetName = Util.FullName(name, (Util.IsReadable(realm) and realm ~= "" and realm) or ns.MyRealm())
			if targetName == opp then unit = "target" end
		end
	end
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
	if not Util.IndexOf(f.a, from) then return ns.Log("warn", "CHAL sender not on challenging team", from) end
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
	S.challengeIn = { mid = msg.mid, from = from, fmt = f.fmt, pg = f.pg, a = f.a, ra = f.ra, expires = f.exp }
	ns.Print(("%s's team challenges you to a %dv%d. Open /td to accept or decline."):format(Short(from), f.fmt, f.fmt))
	Ding()
	Open()
end

function Handlers.ACC(from, msg)
	local f = msg.fields
	local me = ns.Me()
	if not Util.IndexOf(f.b, from) then return ns.Log("warn", "ACC sender not on accepting team", from) end
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
		ns.Print(Short(from) .. " declined (" .. msg.fields.why .. ").")
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

local function OnDuelRequested(playerName)
	local _, _, opp = Session.MyDuel()
	if not opp or not Util.IsReadable(playerName) then return end
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
