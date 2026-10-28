-- Match state machine (spec §3, §6.1). Pure and deterministic: every client applies the same
-- validated events and must reach the same state regardless of message arrival order.
--
-- States: ACTIVE -> FINISHED | ABORTED
-- A duel's result counts only when BOTH fighters report the same winner. Reports are kept per
-- attempt; disagreement is a dispute, the duel is re-run as the next attempt, and too many disputes
-- abort the match (no rating change).
local _, ns = ...
local Match = {}
ns.Match = Match

local Util = ns.Util

local function AddDuel(m)
	m.duels[#m.duels + 1] = {
		a = m.teamA[m.idxA],
		b = m.teamB[m.idxB],
		reports = {},   -- [attempt] = { [fighter] = winner }
		disputes = 0,   -- also the current attempt number
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
		local reports = duel.reports[duel.disputes]
		local byA = reports and reports[duel.a]
		local byB = reports and reports[duel.b]
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
		if duel.disputes >= m.maxDisputes then
			Match.Abort(m, "disputed")
			return "aborted"
		end
	end
end

-- Returns "pending" | "confirmed" | "disputed" | "aborted" | "ignored", reason
function Match.ReportResult(m, reporter, duelIndex, winner, attempt)
	attempt = attempt or 0
	if m.state ~= "ACTIVE" then return "ignored", "match not active" end
	if duelIndex ~= #m.duels then return "ignored", "not the current duel" end
	local duel = m.duels[duelIndex]
	if reporter ~= duel.a and reporter ~= duel.b then return "ignored", "reporter is not a fighter" end
	if winner ~= duel.a and winner ~= duel.b then return "ignored", "winner is not a fighter" end
	if attempt < duel.disputes then return "ignored", "stale attempt" end
	if attempt >= m.maxDisputes then return "ignored", "attempt out of range" end

	duel.reports[attempt] = duel.reports[attempt] or {}
	if duel.reports[attempt][reporter] then return "ignored", "already reported" end
	duel.reports[attempt][reporter] = winner
	return Evaluate(m)
end

function Match.Abort(m, reason)
	if m.state ~= "ACTIVE" then return false end
	m.state = "ABORTED"
	m.abortReason = reason
	return true
end
