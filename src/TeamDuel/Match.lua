-- Match state machine (spec §3, §6.1). Pure and deterministic: every client applies the same
-- validated events and must reach the same state regardless of message arrival order.
--
-- States: ACTIVE -> FINISHED | ABORTED
-- Every client in the match reads the game's duel message, so results come from both fighters and their
-- teammates. A duel's result counts when the first report from each TEAM names the same winner. Reports are
-- kept per attempt; disagreement is a dispute and the duel is re-run as the next attempt. A duel with no
-- readable result is re-run too. Only repeated disputes abort the match (no rating change).
-- A team that stalls or leaves forfeits (decided by the user): the match finishes with a result.
local _, ns = ...
local Match = {}
ns.Match = Match

local Util = ns.Util

local function AddDuel(m)
	m.duels[#m.duels + 1] = {
		a = m.teamA[m.idxA],
		b = m.teamB[m.idxB],
		attempt = 0,    -- re-runs (disputes, no readable result) start a new attempt
		disputes = 0,
		reports = {},   -- [attempt] = { A = winner, B = winner }: the first report from each team's clients
		requested = {}, -- [attempt] = fighter whose client saw the scheduled duel request arrive
		accepted = {},  -- [attempt] = true once the duel request was accepted
	}
end

-- opts: mid, fmt, teamA, teamB (names in fighter order), ratingsA, ratingsB, leaderA, leaderB,
--       progression ("pairs" | "winnerStays"), maxDisputes
function Match.New(opts)
	local fmt = opts.fmt
	if not (fmt and fmt >= 1 and fmt <= 3) then error("invalid format") end
	if #opts.teamA ~= fmt or #opts.teamB ~= fmt then error("roster size must equal format") end
	if #opts.ratingsA ~= fmt or #opts.ratingsB ~= fmt then error("one rating per player required") end
	local seen = {}
	for _, list in ipairs({ opts.teamA, opts.teamB }) do
		for _, name in ipairs(list) do
			if seen[name] then error("player listed twice: " .. name) end
			seen[name] = true
		end
	end
	if opts.progression ~= "pairs" and opts.progression ~= "winnerStays" then error("invalid progression") end

	local m = {
		mid = opts.mid,
		fmt = fmt,
		progression = opts.progression,
		teamA = Util.Copy(opts.teamA),
		teamB = Util.Copy(opts.teamB),
		ratingsA = Util.Copy(opts.ratingsA),
		ratingsB = Util.Copy(opts.ratingsB),
		leaderA = opts.leaderA,
		leaderB = opts.leaderB,
		maxDisputes = opts.maxDisputes or 2,
		state = "ACTIVE",
		wins = { A = 0, B = 0 },
		idxA = 1,
		idxB = 1,
		duels = {},
	}
	AddDuel(m)
	return m
end

function Match.CurrentDuel(m)
	return m.duels[#m.duels], #m.duels
end

function Match.MaxDuels(m)
	if m.progression == "pairs" then return m.fmt end
	return 2 * m.fmt - 1
end

function Match.TeamOf(m, name)
	if Util.IndexOf(m.teamA, name) then return "A" end
	if Util.IndexOf(m.teamB, name) then return "B" end
	return nil
end

function Match.Participants(m)
	local out = Util.Copy(m.teamA)
	for _, name in ipairs(m.teamB) do out[#out + 1] = name end
	return out
end

-- Who fights next for each team (for winnerStays: who comes in if the current fighter loses).
function Match.NextUp(m)
	if m.state ~= "ACTIVE" then return nil, nil end
	if m.progression == "pairs" then
		local n = #m.duels + 1
		return m.teamA[n], m.teamB[n]
	end
	return m.teamA[m.idxA + 1], m.teamB[m.idxB + 1]
end

local function Finish(m)
	m.state = "FINISHED"
	if m.wins.A > m.wins.B then
		m.result = "A"
	elseif m.wins.B > m.wins.A then
		m.result = "B"
	else
		m.result = "draw"
	end
end

local function Advance(m, winningSide)
	m.wins[winningSide] = m.wins[winningSide] + 1
	if m.progression == "pairs" then
		local played = #m.duels
		if m.wins.A > m.fmt / 2 or m.wins.B > m.fmt / 2 or played >= m.fmt then
			Finish(m)
		else
			m.idxA, m.idxB = played + 1, played + 1
			AddDuel(m)
		end
	else
		if winningSide == "A" then m.idxB = m.idxB + 1 else m.idxA = m.idxA + 1 end
		if m.idxA > m.fmt or m.idxB > m.fmt then
			Finish(m)
		else
			AddDuel(m)
		end
	end
end

local function Evaluate(m)
	local duel = m.duels[#m.duels]
	local disputed = false
	while true do
		local reports = duel.reports[duel.attempt]
		local byA = reports and reports.A
		local byB = reports and reports.B
		if not (byA and byB) then
			return disputed and "disputed" or "pending"
		end
		if byA == byB then
			duel.winner = byA
			Advance(m, byA == duel.a and "A" or "B")
			return "confirmed"
		end
		disputed = true
		duel.disputes = duel.disputes + 1
		duel.attempt = duel.attempt + 1
		if duel.disputes >= m.maxDisputes then
			Match.Abort(m, "disputed")
			return "aborted"
		end
	end
end

local MAX_ATTEMPT = 99

-- Checks that an event is about the current duel and a current or later attempt.
local function CurrentAttempt(m, duelIndex, attempt)
	if m.state ~= "ACTIVE" then return nil, "match not active" end
	if duelIndex ~= #m.duels then return nil, "not the current duel" end
	local duel = m.duels[duelIndex]
	if attempt < duel.attempt then return nil, "stale attempt" end
	if attempt > MAX_ATTEMPT then return nil, "attempt out of range" end
	return duel
end

-- reporter: any player in the match. Returns "pending" | "confirmed" | "disputed" | "aborted" | "ignored", reason
function Match.ReportResult(m, reporter, duelIndex, winner, attempt)
	attempt = attempt or 0
	local duel, why = CurrentAttempt(m, duelIndex, attempt)
	if not duel then return "ignored", why end
	local side = Match.TeamOf(m, reporter)
	if not side then return "ignored", "reporter is not in the match" end
	if winner ~= duel.a and winner ~= duel.b then return "ignored", "winner is not a fighter" end
	duel.reports[attempt] = duel.reports[attempt] or {}
	if duel.reports[attempt][side] then return "ignored", "team already reported" end
	duel.reports[attempt][side] = winner
	return Evaluate(m)
end

-- A fighter's client saw the scheduled duel request arrive (receiver) or saw it accepted.
-- Returns true when this changed anything.
function Match.MarkRequested(m, duelIndex, attempt, receiver)
	local duel = CurrentAttempt(m, duelIndex, attempt)
	if not duel or (receiver ~= duel.a and receiver ~= duel.b) or duel.requested[attempt] then return false end
	duel.requested[attempt] = receiver
	return true
end

function Match.MarkAccepted(m, duelIndex, attempt, by)
	local duel = CurrentAttempt(m, duelIndex, attempt)
	if not duel or (by ~= duel.a and by ~= duel.b) or duel.accepted[attempt] then return false end
	duel.accepted[attempt] = true
	return true
end

-- The duel ended (or never did) without a readable result: fight it again as the next attempt.
-- Returns "rerun" (or what the next attempt's early reports already settle) | "ignored", reason
function Match.Rerun(m, duelIndex, attempt)
	local duel, why = CurrentAttempt(m, duelIndex, attempt)
	if not duel then return "ignored", why end
	if attempt ~= duel.attempt then return "ignored", "not the current attempt" end
	duel.attempt = duel.attempt + 1
	local outcome = Evaluate(m)
	return outcome == "pending" and "rerun" or outcome
end

-- Who is to blame when the current duel wasn't accepted in time: the fighter whose client received the
-- request and didn't accept it, or both teams when no request arrived at all. nil if it was accepted.
-- Returns "A" | "B" | "both" | nil
function Match.StallingSide(m)
	if m.state ~= "ACTIVE" then return nil end
	local duel = m.duels[#m.duels]
	if duel.accepted[duel.attempt] then return nil end
	local receiver = duel.requested[duel.attempt]
	if receiver then return Match.TeamOf(m, receiver) end
	return "both"
end

-- side: "A" | "B" | "both". The other team wins; "both" means both teams lose.
function Match.Forfeit(m, side, reason)
	if m.state ~= "ACTIVE" then return false end
	m.state = "FINISHED"
	m.forfeit, m.forfeitReason = side, reason
	m.result = (side == "A" and "B") or (side == "B" and "A") or "none"
	return true
end

function Match.Abort(m, reason)
	if m.state ~= "ACTIVE" then return false end
	m.state = "ABORTED"
	m.abortReason = reason
	return true
end
