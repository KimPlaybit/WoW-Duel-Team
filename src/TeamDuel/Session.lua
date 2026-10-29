-- Session controller: teams, challenges, the active match, duel events, results, ratings.
-- Pure rules live in Match/Rating/Protocol; this file wires them to the game and to Comm.
--
-- Duel requests are sent from a click and accepted with Blizzard's own popup. Results are read from the
-- game's duel message by every client in the match, and count when both teams agree. There are no manual
-- results or aborts (decided by the user): an unreadable result re-runs the duel, and a team that stalls
-- or disconnects forfeits (spec §7-8; timings in Config are PROVISIONAL).
local _, ns = ...
local Session = {}
ns.Session = Session

local Util, Match, Rating, DB, DuelResult, Position = ns.Util, ns.Match, ns.Rating, ns.DB, ns.DuelResult, ns.Position

local S = {
	-- The team is our party. ratings: what party members reported ({[name] = {r1, r2, r3}});
	-- order: fighter order set by the leader; reportedTo: leader we last sent our ratings to.
	team = { ratings = {}, order = nil, reportedTo = nil },
	challengeOut = nil,  -- { mid, opp, fmt, pg, a, ra, expires }
	challengeIn = nil,   -- { mid, from, fmt, pg, a, ra, expires }
	teamChallenge = nil, -- our leader challenged someone: { opp?, fmt }
	match = nil,
	duelFrom = nil,      -- who the pending Blizzard duel request is from, as the game gave the name
	lastSummary = nil,   -- record of the last finished/aborted match
	reported = {},       -- ["duel:attempt"] = true, results this client already sent
	sentState = {},      -- ["duel:attempt:s"] = true, duel states this client already sent (DST)
	lastSeen = {},       -- [name] = GetTime() we last heard from a player in the match
	clockKey = nil,      -- "mid:duel:attempt" the stall clock runs for
	countdown = nil,     -- Position countdown while we're a fighter in a duel that hasn't started
	oppPos = nil,        -- { x, y, map, at }: our opponent's last reported position
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
-- Teams: a team is the player's party (not a raid). The party leader leads; the members are the party.
-- Members' addons report their ratings to the leader (TRAT) whenever the group changes.
---------------------------------------------------------------------------

-- Full name of a unit, or nil if it doesn't exist or is unreadable.
local function UnitFullNameOf(unit)
	if not UnitExists(unit) then return nil end
	local name, realm = UnitName(unit)
	if not Util.IsReadable(name) then return nil end
	return Util.FullName(name, (Util.IsReadable(realm) and realm ~= "" and realm) or ns.MyRealm())
end
Session.UnitFullNameOf = UnitFullNameOf

-- true/false, or nil when the client can't tell (API missing, errored or secret).
-- CheckInteractDistance's duel index is UNVERIFIED on Forever (see docs/verification-log.md).
local function InDuelRange(unit)
	local ok, inRange = pcall(CheckInteractDistance, unit, ns.Config.DUEL_RANGE_INDEX)
	if not ok then ns.Log("warn", "CheckInteractDistance failed:", inRange) end
	if not ok or not Util.IsReadable(inRange) or type(inRange) ~= "boolean" then return nil end
	return inRange
end

-- Is a party member within Config.TEAM_RANGE_YARDS of us? true/false, or nil when the client can't tell.
-- UnitDistanceSquared is in the Forever dump; its behavior there is UNVERIFIED.
local function InTeamRange(unit)
	local ok, distSq, checked = pcall(UnitDistanceSquared, unit)
	if not ok then ns.Log("warn", "UnitDistanceSquared failed:", distSq) end
	if not ok or not Util.IsReadable(distSq) or not Util.IsReadable(checked) then return nil end
	if not checked or type(distSq) ~= "number" then return nil end
	local yards = ns.Config.TEAM_RANGE_YARDS
	return distSq <= yards * yards
end

local PARTY_UNITS = { "party1", "party2", "party3", "party4" }

local function Readable(v)
	return Util.IsReadable(v) and v
end

function Session.InParty()
	return Readable(IsInGroup()) and not Readable(IsInRaid())
end

-- Unit tokens and full names of the party's other members, in party order.
local function PartyMembers()
	local units, names = {}, {}
	if not Session.InParty() then return units, names end
	for _, unit in ipairs(PARTY_UNITS) do
		local name = UnitFullNameOf(unit)
		if name then units[#units + 1], names[#names + 1] = unit, name end
	end
	return units, names
end

-- Full name of the party leader, or nil when not in a party (or it can't be read).
function Session.PartyLeader()
	if not Session.InParty() then return nil end
	if Readable(UnitIsGroupLeader("player")) then return ns.Me() end
	for _, unit in ipairs(PARTY_UNITS) do
		if Readable(UnitIsGroupLeader(unit)) then return UnitFullNameOf(unit) end
	end
	return nil
end

function Session.IsLeader()
	return not Session.InParty() or Session.PartyLeader() == ns.Me()
end

-- Our team (leader first, then the fighter order set with /td order, else party order) when we lead it
-- or are solo; nil when someone else leads our party.
function Session.TeamMembers()
	if not Session.IsLeader() then return nil end
	local _, others = PartyMembers()
	local members = { ns.Me() }
	local order = S.team.order
	if order and #order == #others + 1 then
		for i = 2, #order do
			if not Util.IndexOf(others, order[i]) then order = nil; break end
		end
	else
		order = nil
	end
	if order then return Util.Copy(order) end
	for _, name in ipairs(others) do members[#members + 1] = name end
	return members
end

local function RatingsFor(members, fmt)
	local out = {}
	for i, name in ipairs(members) do
		if name == ns.Me() then
			out[i] = DB.GetRating(ns.db, name, fmt)
		else
			local r = S.team.ratings[name]
			out[i] = r and r[fmt]
		end
	end
	return out
end

function Session.TeamRatings(fmt)
	local members = Session.TeamMembers()
	if not members then return nil end
	local ratings = RatingsFor(members, fmt or #members)
	for i = 1, #members do ratings[i] = ratings[i] or ns.Config.RATING_START end
	return ratings
end

-- Members tell the leader their ratings; the leader needs them to put the team's ratings in a challenge.
local function ReportRatings()
	local leader = Session.PartyLeader()
	if not leader or leader == ns.Me() then
		S.team.reportedTo = nil
		return
	end
	if S.team.reportedTo == leader then return end
	local fields = {
		r1 = DB.GetRating(ns.db, ns.Me(), 1),
		r2 = DB.GetRating(ns.db, ns.Me(), 2),
		r3 = DB.GetRating(ns.db, ns.Me(), 3),
	}
	if ns.Comm.Send(leader, "TRAT", "-", fields) then S.team.reportedTo = leader end
end

local function OnGroupChanged()
	if not Session.InParty() then S.team.reportedTo, S.team.order = nil, nil end
	ReportRatings()
	Refresh()
end

-- Fighter order (spec §3.3). The leader always fights first: the challenge's duel is the match's first duel.
function Session.SetOrder(inputs)
	if S.match then return ns.Print("The fighter order is locked during a match.") end
	local members = Session.TeamMembers()
	if not members then return ns.Print("Only your party leader sets the fighter order.") end
	local order = {}
	for i, input in ipairs(inputs) do order[i] = ns.Canonical(input) end
	if #order ~= #members then return ns.Print("List every party member exactly once.") end
	if order[1] ~= ns.Me() then return ns.Print("You are the leader, so you always fight first. List the others after you.") end
	for i, name in ipairs(order) do
		if not Util.IndexOf(members, name) then return ns.Print(tostring(name) .. " is not in your party.") end
		if Util.IndexOf(order, name) ~= i then return ns.Print("List every party member exactly once.") end
	end
	S.team.order = order
	ns.Print("Fighter order: " .. table.concat(order, ", "))
	Refresh()
end

---------------------------------------------------------------------------
-- Challenges
---------------------------------------------------------------------------

-- Our side of a fmt-sized match. 1v1 is always just us, whatever group we're in. 2v2/3v3 need us to lead
-- a party of exactly that size whose members all have the addon and stand within TEAM_RANGE_YARDS of us.
-- Returns members, ratings, or nil, a reason code (also sent in DEC) and, for our own chat, the names involved.
local function OwnRoster(fmt)
	if fmt == 1 then return { ns.Me() }, { DB.GetRating(ns.db, ns.Me(), 1) } end
	if Readable(IsInRaid()) then return nil, "raid" end
	local members = Session.TeamMembers()
	if not members then return nil, "notleader" end
	if #members ~= fmt then return nil, "size" .. #members end
	local ratings = RatingsFor(members, fmt)
	local missing = {}
	for i, name in ipairs(members) do
		if not ratings[i] then missing[#missing + 1] = Short(name) end
	end
	if #missing > 0 then return nil, "noaddon", table.concat(missing, ", ") end
	local far = {}
	local units = PartyMembers()
	for _, unit in ipairs(units) do
		local inRange = InTeamRange(unit)
		if inRange == false or (inRange == nil and ns.Config.DUEL_RANGE_UNKNOWN ~= "allow") then
			far[#far + 1] = Short(UnitFullNameOf(unit))
		end
	end
	if #far > 0 then return nil, "far", table.concat(far, ", ") end
	return members, ratings
end

-- For greying out the menu: can we challenge in this format at all? (Range and addons are checked on click.)
function Session.FormatAvailable(fmt)
	if fmt == 1 then return true end
	if Readable(IsInRaid()) then return false end
	local members = Session.TeamMembers()
	return members ~= nil and #members == fmt
end

local function Format(fmt)
	return ("%dv%d"):format(fmt, fmt)
end

-- Why our own roster can't take a fmt challenge, for our own chat.
local function OwnRosterProblem(reason, fmt, names)
	if reason == "notleader" then return "Only your party leader can take on a " .. Format(fmt) .. "." end
	if reason == "raid" then return "Leave the raid: a " .. Format(fmt) .. " team is a party." end
	if reason == "noaddon" then return (names or "A party member") .. " doesn't have TeamDuel running (or hasn't answered yet)." end
	if reason == "far" then return (names or "A party member") .. (" must be within %d yards of you first."):format(ns.Config.TEAM_RANGE_YARDS) end
	local n = tonumber(string.match(reason, "^size(%d)$"))
	if n then
		return ("Your party has %d player(s); a %s needs exactly %d."):format(n, Format(fmt), fmt)
	end
	return reason
end

-- Challenges need the challenger within normal duel range of the opponent (the opposing leader for 2v2/3v3).
-- input: a name (slash command, chat-name menu) or nil; unit: the unit token from the right-click menu, if any;
-- fmt: 1-3, default our team size. Without a usable unit token the range can only be checked on the target.
function Session.Challenge(input, unit, fmt)
	local opp = input and ns.Canonical(input) or UnitFullNameOf(unit or "target")
	if not opp or opp == ns.Me() then return ns.Print("Right-click your opponent (the other party's leader for 2v2/3v3) and choose Challenge.") end
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
	local members, ratings, names = OwnRoster(fmt)
	if not members then return ns.Print(OwnRosterProblem(ratings, fmt, names)) end
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
	-- The first duel (leader vs leader) may already be accepted along with the challenge.
	if f.da == 1 then Match.MarkAccepted(m, 1, 0, m.duels[1].b) end
	S.match = m
	S.challengeOut, S.challengeIn, S.teamChallenge, S.lastSummary = nil, nil, nil, nil
	S.reported, S.sentState, S.lastSeen, S.clockKey = {}, {}, {}, nil
	for _, name in ipairs(Match.Participants(m)) do S.lastSeen[name] = GetTime() end
	-- Kept in SavedVariables until the match ends: a client that reloads or reconnects mid-match finds it at
	-- login and records its team's forfeit (names and ratings only, all validated and readable).
	ns.db.activeMatch = {
		mid = mid, fmt = m.fmt, progression = m.progression, teamA = m.teamA, teamB = m.teamB,
		ratingsA = m.ratingsA, ratingsB = m.ratingsB, leaderA = m.leaderA, leaderB = m.leaderB,
	}
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
	local members, ratings, names = OwnRoster(c.fmt)
	if not members then
		ns.Print(OwnRosterProblem(ratings, c.fmt, names))
		if viaDuel then
			-- The duel popup was already accepted: this duel goes ahead outside the match. Tell the challenger.
			S.challengeIn, S.duelFrom = nil, nil
			ns.Comm.Send(c.from, "DEC", c.mid, { why = ratings })
			ns.Print("The duel was accepted, but the challenge wasn't, so this duel doesn't count.")
			Refresh()
		end
		return
	end
	for _, name in ipairs(members) do
		if Util.IndexOf(c.a, name) then return ns.Print(Short(name) .. " is on both teams.") end
	end
	local fields = {
		fmt = c.fmt, pg = c.pg, a = c.a, ra = c.ra,
		b = members, rb = ratings,
		li = Util.IndexOf(c.a, c.from),
	}
	local acceptDuel = not viaDuel and DuelIsFrom(c.from)
	fields.da = (viaDuel or acceptDuel) and 1 or 0
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
	if opp and duel.accepted[duel.attempt] then
		ns.Print("You are up! The duel with " .. Short(opp) .. " was accepted with the challenge.")
	elseif opp then
		ns.Print(("You are up! Walk to %s: %ds on the clock, and it slows while you close in. Moving away from them forfeits. When you're close, click 'Start duel' or accept their request."):format(
			Short(opp), ns.Config.COUNTDOWN))
		Ding()
	end
	Session.ArmDuelClock()
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
	local avgA, avgB, k = Rating.TeamAverage(m.ratingsA), Rating.TeamAverage(m.ratingsB), ns.Config.RATING_K
	local deltaA, deltaB
	if m.result == "none" then
		-- Both teams forfeited: both take a loss.
		deltaA = Rating.MatchDeltas(avgA, avgB, 0, k)
		deltaB = Rating.MatchDeltas(avgB, avgA, 0, k)
	else
		local scoreA = (m.result == "A" and 1) or (m.result == "B" and 0) or 0.5
		deltaA, deltaB = Rating.MatchDeltas(avgA, avgB, scoreA, k)
	end
	for i, name in ipairs(m.teamA) do DB.SetRating(ns.db, name, m.fmt, m.ratingsA[i] + deltaA) end
	for i, name in ipairs(m.teamB) do DB.SetRating(ns.db, name, m.fmt, m.ratingsB[i] + deltaB) end
	for name, ratings in pairs(S.team.ratings) do
		if Match.TeamOf(m, name) then ratings[m.fmt] = DB.GetRating(ns.db, name, m.fmt) end
	end

	local duels = {}
	for _, d in ipairs(m.duels) do
		if d.winner then duels[#duels + 1] = { a = d.a, b = d.b, winner = d.winner, disputes = d.disputes } end
	end
	local record = {
		mid = m.mid, status = m.forfeit and "forfeit" or "completed", ts = GetServerTime(), fmt = m.fmt,
		progression = m.progression, teamA = m.teamA, teamB = m.teamB, ratingsA = m.ratingsA, ratingsB = m.ratingsB,
		result = m.result, wins = { A = m.wins.A, B = m.wins.B }, duels = duels,
		deltaA = deltaA, deltaB = deltaB, forfeit = m.forfeit, reason = m.forfeitReason,
	}
	DB.RecordMatch(ns.db, record)
	S.lastSummary, S.match, S.clockKey = record, nil, nil
	ns.db.activeMatch = nil

	local myTeam = Match.TeamOf(m, ns.Me())
	local outcome = (m.result == "draw" and "Draw") or (m.result == myTeam and "Victory") or "Defeat"
	local myDelta = (myTeam == "A") and deltaA or deltaB
	if m.forfeit then
		ns.Print(("Match over: %s. %s (%s)."):format(outcome, Session.ForfeitText(m.forfeit, m.leaderA, m.leaderB),
			Session.ForfeitReasonText(m.forfeitReason)))
	else
		ns.Print(("Match over: %s (%d-%d)."):format(outcome, m.wins.A, m.wins.B))
	end
	ns.Print(("Rating %s%d."):format(myDelta >= 0 and "+" or "", myDelta))
	if ns.db.readOnly then ns.Print("Saved data is read-only (see /td log); this result was not stored.") end
	Open()
	Refresh()
end

function Session.ForfeitText(side, leaderA, leaderB)
	if side == "both" then return "Both teams forfeited" end
	return Short(side == "A" and leaderA or leaderB) .. "'s team forfeited"
end

local REASONS = {
	stall = "the next duel didn't start in time",
	avoid = "a fighter moved away from their opponent",
	offline = "a player went offline",
	gone = "a player stopped responding",
	left = "a player reloaded or logged out mid-match",
}
function Session.ForfeitReasonText(why)
	return REASONS[why] or tostring(why)
end

-- Only repeated result disputes (clients reading different winners from the same game message) end a
-- match without a result.
local function FinalizeAborted(reason)
	local m = S.match
	if not m then return end
	Match.Abort(m, reason)
	local record = {
		mid = m.mid, status = "aborted", reason = reason, ts = GetServerTime(), fmt = m.fmt,
		teamA = m.teamA, teamB = m.teamB, wins = { A = m.wins.A, B = m.wins.B },
	}
	DB.RecordMatch(ns.db, record)
	S.lastSummary, S.match, S.clockKey = record, nil, nil
	ns.db.activeMatch = nil
	ns.Print("Match ended without a result (" .. reason .. "). No rating changes.")
	Refresh()
end

local function Forfeit(side, reason)
	local m = S.match
	if not (m and side and Match.Forfeit(m, side, reason)) then return end
	ns.Log("info", "forfeit", side, reason)
	Finalize()
end

-- After a result, re-run or dispute: the next duel or attempt, or the end of the match.
local function AfterOutcome(outcome)
	if outcome == "aborted" then return FinalizeAborted("repeated result disputes") end
	if S.match and S.match.state == "FINISHED" then return Finalize() end
	if outcome == "confirmed" or outcome == "disputed" or outcome == "rerun" then Session.AnnounceDuel() end
	Refresh()
end

local function ApplyResult(reporter, idx, winner, attempt)
	local outcome, why = Match.ReportResult(S.match, reporter, idx, winner, attempt)
	if outcome == "ignored" then
		ns.Log("warn", "result ignored from", reporter, why)
		return
	end
	if outcome == "disputed" then
		ns.Print(("Duel %d is disputed: the teams read different winners. Fight it again."):format(idx))
	elseif outcome == "confirmed" then
		ns.Print(Short(winner) .. " wins duel " .. idx .. ".")
	end
	AfterOutcome(outcome)
end

-- Any player in the match who reads the duel message reports it; teammates and the next fighters are
-- witnesses for when a fighter's client misses it.
local function SendResult(winner)
	local m = S.match
	local duel, idx = Match.CurrentDuel(m)
	local key = idx .. ":" .. duel.attempt
	if S.reported[key] then return end
	S.reported[key] = true
	local fields = { d = idx, w = winner, t = duel.attempt, src = "auto" }
	ns.Comm.SendToAll(Participants(), "RES", m.mid, fields)
	ApplyResult(ns.Me(), idx, winner, duel.attempt)
end

-- The two fighters' clients tell everyone what they saw of the duel request (DST):
-- rcv = the scheduled request arrived, acc = it was accepted, rerun = it ended without a readable result.
local function ApplyDuelState(by, idx, attempt, state)
	local m = S.match
	if state == "rcv" then
		-- The request is out: the receiver gets at least REQUEST_GRACE seconds to accept it (decided by the user).
		local cd = S.countdown
		if Match.MarkRequested(m, idx, attempt, by) and cd and cd.remaining < ns.Config.REQUEST_GRACE then
			cd.remaining = ns.Config.REQUEST_GRACE
		end
	elseif state == "acc" then
		if Match.MarkAccepted(m, idx, attempt, by) then
			-- It may never really have started (a failed AcceptDuel): re-run it if it goes on far too long.
			local key = S.clockKey
			C_Timer.After(ns.Config.DUEL_MAX_LENGTH, function()
				if S.match == m and S.clockKey == key then
					ns.Print(("Duel %d took over %d minutes; fight it again."):format(idx, ns.Config.DUEL_MAX_LENGTH / 60))
					AfterOutcome(Match.Rerun(m, idx, attempt))
				end
			end)
		end
	elseif state == "rerun" then
		local duel = Match.CurrentDuel(m)
		if by ~= duel.a and by ~= duel.b then return ns.Log("warn", "rerun from non-fighter", by) end
		local outcome = Match.Rerun(m, idx, attempt)
		if outcome == "ignored" then return end
		ns.Print(("Duel %d: the result couldn't be read by both teams. Fight it again."):format(idx))
		AfterOutcome(outcome)
	end
	Refresh()
end

local function SendDuelState(state)
	local duel, idx = Session.MyDuel()
	if not duel then return end
	local key = idx .. ":" .. duel.attempt .. ":" .. state
	if S.sentState[key] then return end
	S.sentState[key] = true
	ns.Comm.SendToAll(Participants(), "DST", S.match.mid, { d = idx, t = duel.attempt, s = state })
	ApplyDuelState(ns.Me(), idx, duel.attempt, state)
end

-- The stall clock (spec §7.4, decided by the user): every client starts it when a duel or attempt becomes
-- current. If the duel hasn't been accepted when it runs out, the team at fault forfeits: the fighter who got
-- the request and didn't accept, or both teams if no request ever arrived.
function Session.ArmDuelClock()
	local m = S.match
	if not m or m.state ~= "ACTIVE" then return end
	local duel, idx = Match.CurrentDuel(m)
	local key = m.mid .. ":" .. idx .. ":" .. duel.attempt
	if S.clockKey == key then return end
	-- Fighters of an earlier duel may have been unable to message during it: their silence starts now.
	local now = GetTime()
	for _, d in ipairs(m.duels) do S.lastSeen[d.a], S.lastSeen[d.b] = now, now end
	S.clockKey = key
	local _, _, opp = Session.MyDuel()
	S.countdown = (opp and not duel.accepted[duel.attempt]) and Position.NewCountdown(ns.Config) or nil
	S.oppPos = nil
	-- Backstop on every client, in case the fighters' clients never settle the countdown.
	C_Timer.After(ns.Config.STALL_BACKSTOP, function()
		if S.match ~= m or S.clockKey ~= key then return end
		Forfeit(Match.StallingSide(m), "stall")
	end)
end

-- Our own position in yards, or nil when it can't be read (API missing, secret, errored).
local function OwnPosition()
	local ok, x, y, _, map = pcall(UnitPosition, "player")
	if not ok or not (Util.IsReadable(x) and Util.IsReadable(y) and Util.IsReadable(map)) then return nil end
	if type(x) ~= "number" or type(y) ~= "number" or type(map) ~= "number" then return nil end
	local function Tenth(v) return math.floor(v * 10 + 0.5) / 10 end
	return { x = Tenth(x), y = Tenth(y), map = map }
end

-- The countdown runs on the two fighters' clients, the only ones with both positions; the one that sees it end
-- tells everyone. Every POS_INTERVAL: send our position to our opponent, then step the clock.
local function CountdownTick()
	local cd, m, cfg = S.countdown, S.match, ns.Config
	local duel, _, opp = Session.MyDuel()
	if not (cd and duel) then return end
	if duel.accepted[duel.attempt] then
		S.countdown = nil
		return Refresh()
	end
	-- Not a word from our opponent for a while: they may be offline. Hold the clock and let the heartbeat's
	-- OFFLINE_AFTER decide, so their disconnect doesn't make both teams forfeit.
	if GetTime() - (S.lastSeen[opp] or 0) > cfg.HEARTBEAT + cfg.POS_INTERVAL then return end
	local mine = OwnPosition()
	if mine then ns.Comm.Send(opp, "POS", m.mid, { x = mine.x, y = mine.y, mp = mine.map }) end
	local theirs = S.oppPos
	if theirs and GetTime() - theirs.at > 2 * cfg.POS_INTERVAL + 1 then theirs = nil end
	local posA, posB = mine, theirs
	if Match.TeamOf(m, ns.Me()) == "B" then posA, posB = theirs, mine end
	local outcome, side = Position.Step(cd, posA, posB, cfg.POS_INTERVAL, cfg)
	Refresh()
	if not outcome then return end
	S.countdown = nil
	local why = outcome == "avoid" and "avoid" or "stall"
	side = side or Match.StallingSide(m)
	if not side then return end
	ns.Comm.SendToAll(Participants(), "FORF", m.mid, { tm = side, why = why })
	Forfeit(side, why)
end

-- Our client knows a party member in the match went offline (or we came back to a match we left).
-- Only a team's own members announce its forfeit, so FORF is trusted only about the sender's own team.
local function OwnTeamForfeits(reason)
	local m = S.match
	local side = m and Match.TeamOf(m, ns.Me())
	if not side then return end
	ns.Comm.SendToAll(Participants(), "FORF", m.mid, { tm = side, why = reason })
	Forfeit(side, reason)
end

local function CheckParty()
	local m = S.match
	if not m then return end
	for _, unit in ipairs(PARTY_UNITS) do
		local name = UnitFullNameOf(unit)
		local side = name and Match.TeamOf(m, name)
		local connected = side and UnitIsConnected(unit)
		if side and Util.IsReadable(connected) and connected == false then
			ns.Print(Short(name) .. " went offline.")
			if side == Match.TeamOf(m, ns.Me()) then return OwnTeamForfeits("offline") end
			return Forfeit(side, "offline")
		end
	end
end

-- Every HEARTBEAT seconds during a match: ping everyone, and forfeit a team whose player has been silent too
-- long. The current fighters aren't judged while their duel runs (addon messages may be blocked in a duel).
local function Heartbeat()
	local m = S.match
	if not m then return end
	ns.Comm.SendToAll(Participants(), "PING", m.mid, {})
	CheckParty()
	if S.match ~= m then return end
	local duel = Match.CurrentDuel(m)
	local running = duel.accepted[duel.attempt]
	local now = GetTime()
	for _, name in ipairs(Match.Participants(m)) do
		local fighting = running and (name == duel.a or name == duel.b)
		if name ~= ns.Me() and not fighting and now - (S.lastSeen[name] or now) > ns.Config.OFFLINE_AFTER then
			ns.Print(Short(name) .. " stopped responding.")
			return Forfeit(Match.TeamOf(m, name), "gone")
		end
	end
end

-- A match we were in when we reloaded, logged out or disconnected: our team forfeited it.
function Session.ResumeLeftMatch()
	local am = ns.db.activeMatch
	if not am then return end
	ns.db.activeMatch = nil
	local ok, m = pcall(Match.New, {
		mid = am.mid, fmt = am.fmt, progression = am.progression, teamA = am.teamA, teamB = am.teamB,
		ratingsA = am.ratingsA, ratingsB = am.ratingsB, leaderA = am.leaderA, leaderB = am.leaderB,
	})
	if not ok or not Match.TeamOf(m, ns.Me()) then return ns.Log("warn", "unusable saved match", m) end
	S.match = m
	ns.Print("You left a match in progress (reload, logout or disconnect), so your team forfeits it.")
	OwnTeamForfeits("left")
end

function Session.OnPeerUnreachable(target, msgType)
	if S.match and Match.TeamOf(S.match, target) then
		ns.Print(("%s is not responding (%s). If they stay silent, their team forfeits."):format(Short(target), msgType))
	elseif msgType == "CHAL" or msgType == "TRAT" then
		ns.Print(Short(target) .. " did not respond. Do they have TeamDuel installed and are they online?")
	end
end

---------------------------------------------------------------------------
-- Incoming messages (already decoded and validated by Protocol, de-duplicated by Comm)
---------------------------------------------------------------------------

local Handlers = {}

-- A party member's ratings, for when we lead the party.
function Handlers.TRAT(from, msg)
	local f = msg.fields
	S.team.ratings[from] = { f.r1, f.r2, f.r3 }
	ns.Tooltip.OnRatings(from, f, false)
	Refresh()
end

-- Tooltip ratings: someone hovered us (RREQ) or answered our hover (RINF).
function Handlers.RREQ(from, msg) ns.Tooltip.OnRatings(from, msg.fields, true) end
function Handlers.RINF(from, msg) ns.Tooltip.OnRatings(from, msg.fields, false) end

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
	-- 2v2/3v3 must reach a party leader with a full, gathered party; say why otherwise so the challenger isn't left waiting.
	local members, reason, names = OwnRoster(f.fmt)
	if not members then
		ns.Comm.Send(from, "DEC", msg.mid, { why = reason })
		ns.Print(("%s challenged you to a %s, but it can't go ahead: %s"):format(Short(from), Format(f.fmt), OwnRosterProblem(reason, f.fmt, names)))
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
			ns.Print(("Challenge failed: %s is not their party's leader, so they can't take a %s. Challenge their leader."):format(opp, fmt))
		elseif n then
			ns.Print(("Challenge failed: %s's party has %d player(s); a %s needs %d."):format(opp, n, fmt, out.fmt))
		elseif why == "far" then
			ns.Print(("Challenge failed: %s's party isn't gathered; everyone must be within %d yards of them."):format(
				opp, ns.Config.TEAM_RANGE_YARDS))
		elseif why == "noaddon" then
			ns.Print(("Challenge failed: someone in %s's party doesn't have TeamDuel running."):format(opp))
		elseif why == "raid" then
			ns.Print(("Challenge failed: %s is in a raid; teams are parties."):format(opp))
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

function Handlers.DST(from, msg)
	local m = S.match
	if not (m and m.mid == msg.mid) then return end
	local f = msg.fields
	ApplyDuelState(from, f.d, f.t, f.s)
end

function Handlers.FORF(from, msg)
	local m = S.match
	if not (m and m.mid == msg.mid) then return end
	-- A team's own member may forfeit it; a current fighter may also end the countdown (avoid, stall). The
	-- latter trusts the opponent's client, like every client-reported result (local ratings, spec §11.3).
	local duel = Match.CurrentDuel(m)
	local why = msg.fields.why
	local countdown = (why == "avoid" or why == "stall") and (from == duel.a or from == duel.b)
	if Match.TeamOf(m, from) ~= msg.fields.tm and not countdown then
		return ns.Log("warn", "FORF about another team from", from)
	end
	if msg.fields.why == "offline" then ns.Print(Short(from) .. " reports a teammate went offline.") end
	Forfeit(msg.fields.tm, msg.fields.why)
end

function Handlers.PING() end

function Handlers.POS(from, msg)
	local _, _, opp = Session.MyDuel()
	if not (S.match and S.match.mid == msg.mid and opp == from) then return end
	local f = msg.fields
	S.oppPos = { x = f.x, y = f.y, map = f.mp, at = GetTime() }
end

function Session.OnMessage(from, msg)
	if S.match and Match.TeamOf(S.match, from) then S.lastSeen[from] = GetTime() end
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
		SendDuelState("rcv")
		-- The scheduled opponent's request is accepted for the player (decided by the user). Accepting from an
		-- event rather than a click is UNVERIFIED on Forever; if it's blocked, the player clicks Accept.
		local ok, err = pcall(AcceptDuel)
		if not ok then
			ns.Log("warn", "auto-accept failed:", err)
			ns.Print("Accept the duel request from " .. Short(opp) .. ", your scheduled opponent. If it isn't accepted in time, your team forfeits.")
		end
	else
		ns.Print("Duel request from " .. playerName .. ", who is NOT your scheduled opponent (" .. Short(opp) .. ").")
	end
end

-- Every client in the match reads the duel message (it's shown to players nearby), not only the fighters'.
local function OnSystemMessage(text)
	if not S.match or not Util.IsReadable(text) then return end
	local winner, loser, how = DuelResult.FromSystemMessage(duelPatterns, text)
	if not winner then return end
	ns.Log("info", "duel message:", how, winner, loser)
	local duel = Match.CurrentDuel(S.match)
	local w = DuelResult.ResolveFighter(winner, duel.a, duel.b)
	local l = DuelResult.ResolveFighter(loser, duel.a, duel.b)
	if w and l and w ~= l then
		SendResult(w)
	else
		ns.Log("warn", "duel message does not match the current fighters")
	end
end

-- A fighter's duel ended: if both teams haven't read the same winner shortly after, it's fought again.
local function OnDuelFinished()
	local duel, idx = Session.MyDuel()
	if not duel then return end
	local attempt = duel.attempt
	C_Timer.After(ns.Config.RESULT_WAIT, function()
		local current, currentIdx = Session.MyDuel()
		if current == duel and currentIdx == idx and duel.attempt == attempt and not duel.winner then
			SendDuelState("rerun")
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
	ns.On("GROUP_ROSTER_UPDATE", OnGroupChanged)
	ns.On("PARTY_LEADER_CHANGED", OnGroupChanged)
	ns.On("UNIT_CONNECTION", CheckParty)
	C_Timer.NewTicker(ns.Config.HEARTBEAT, Heartbeat)
	C_Timer.NewTicker(ns.Config.POS_INTERVAL, CountdownTick)
	OnGroupChanged()
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
	Hook("AcceptDuel", function()
		if ChallengeDuelPending() then return Session.Accept(true) end
		local _, _, opp = Session.MyDuel()
		if opp and DuelIsFrom(opp) then SendDuelState("acc") end
	end)
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
