local ns = LoadPure()
local M = ns.Match

local function new(fmt, progression)
	local a, b, ra, rb = {}, {}, {}, {}
	for i = 1, fmt do
		a[i], b[i] = "A" .. i .. "-R", "B" .. i .. "-R"
		ra[i], rb[i] = 1500, 1500
	end
	return M.New({
		mid = "m", fmt = fmt, teamA = a, teamB = b, ratingsA = ra, ratingsB = rb,
		leaderA = a[1], leaderB = b[1], progression = progression or "pairs", maxDisputes = 2,
	})
end

-- Both fighters of the current duel agree that `winner` won.
local function settle(m, winner)
	local duel, idx = M.CurrentDuel(m)
	M.ReportResult(m, duel.a, idx, winner, duel.attempt)
	return M.ReportResult(m, duel.b, idx, winner, duel.attempt)
end

describe("Match", function()
	it("rejects invalid rosters", function()
		expect(pcall(M.New, { fmt = 2, teamA = { "A-R" }, teamB = { "B-R", "C-R" }, ratingsA = { 1 }, ratingsB = { 1, 1 }, progression = "pairs" })).toBeFalsy()
		expect(pcall(M.New, { fmt = 1, teamA = { "A-R" }, teamB = { "A-R" }, ratingsA = { 1 }, ratingsB = { 1 }, progression = "pairs" })).toBeFalsy()
		expect(pcall(M.New, { fmt = 1, teamA = { "A-R" }, teamB = { "B-R" }, ratingsA = { 1 }, ratingsB = { 1 }, progression = "random" })).toBeFalsy()
	end)

	it("needs both teams to agree", function()
		local m = new(1)
		expect((M.ReportResult(m, "A1-R", 1, "A1-R", 0))).toBe("pending")
		expect((M.ReportResult(m, "B1-R", 1, "A1-R", 0))).toBe("confirmed")
		expect(m.state).toBe("FINISHED")
		expect(m.result).toBe("A")
	end)

	it("counts teammates as witnesses, and ignores outsiders, wrong duels and unknown winners", function()
		local m = new(2)
		expect((M.ReportResult(m, "X-R", 1, "A1-R", 0))).toBe("ignored")  -- not in the match
		expect((M.ReportResult(m, "A1-R", 2, "A1-R", 0))).toBe("ignored") -- future duel
		expect((M.ReportResult(m, "A1-R", 1, "X-R", 0))).toBe("ignored")  -- winner not a fighter
		expect((M.ReportResult(m, "A2-R", 1, "B1-R", 0))).toBe("pending")  -- teammate witness
		expect((M.ReportResult(m, "B2-R", 1, "B1-R", 0))).toBe("confirmed")
		expect(m.duels[1].winner).toBe("B1-R")
	end)

	it("takes the first report from each team in an attempt", function()
		local m = new(2)
		M.ReportResult(m, "A1-R", 1, "A1-R", 0)
		expect((M.ReportResult(m, "A2-R", 1, "B1-R", 0))).toBe("ignored")
	end)

	it("re-runs a disputed duel and aborts after too many disputes", function()
		local m = new(1)
		M.ReportResult(m, "A1-R", 1, "A1-R", 0)
		expect((M.ReportResult(m, "B1-R", 1, "B1-R", 0))).toBe("disputed")
		expect(m.duels[1].disputes).toBe(1)
		expect((M.ReportResult(m, "A1-R", 1, "A1-R", 0))).toBe("ignored") -- stale attempt
		M.ReportResult(m, "A1-R", 1, "A1-R", 1)
		expect((M.ReportResult(m, "B1-R", 1, "B1-R", 1))).toBe("aborted")
		expect(m.state).toBe("ABORTED")
		expect(m.result).toBe(nil)
	end)

	it("reaches the same state when reports arrive in a different order", function()
		-- Client 1 sees A0, B0 (dispute), A1, B1. Client 2 sees A0, A1, B0, B1.
		local c1, c2 = new(1), new(1)
		M.ReportResult(c1, "A1-R", 1, "A1-R", 0); M.ReportResult(c1, "B1-R", 1, "B1-R", 0)
		M.ReportResult(c1, "A1-R", 1, "B1-R", 1); M.ReportResult(c1, "B1-R", 1, "B1-R", 1)
		M.ReportResult(c2, "A1-R", 1, "A1-R", 0); M.ReportResult(c2, "A1-R", 1, "B1-R", 1)
		M.ReportResult(c2, "B1-R", 1, "B1-R", 0); M.ReportResult(c2, "B1-R", 1, "B1-R", 1)
		expect(c1.result).toBe("B")
		expect(c2.result).toBe("B")
	end)

	it("pairs: 3v3 ends early once a team has a majority", function()
		local m = new(3)
		expect(M.MaxDuels(m)).toBe(3)
		local a, b = M.NextUp(m)
		expect(a).toBe("A2-R"); expect(b).toBe("B2-R")
		settle(m, "A1-R")
		local duel = M.CurrentDuel(m)
		expect(duel.a).toBe("A2-R"); expect(duel.b).toBe("B2-R")
		settle(m, "A2-R")
		expect(m.state).toBe("FINISHED")
		expect(m.result).toBe("A")
		expect(#m.duels).toBe(2)
	end)

	it("pairs: 2v2 split is a draw (provisional rule)", function()
		local m = new(2)
		settle(m, "A1-R")
		settle(m, "B2-R")
		expect(m.result).toBe("draw")
	end)

	it("winnerStays: the winner keeps fighting until a team is eliminated", function()
		local m = new(3, "winnerStays")
		expect(M.MaxDuels(m)).toBe(5)
		settle(m, "A1-R")                       -- B1 out
		local duel = M.CurrentDuel(m)
		expect(duel.a).toBe("A1-R"); expect(duel.b).toBe("B2-R")
		local nextA, nextB = M.NextUp(m)
		expect(nextA).toBe("A2-R"); expect(nextB).toBe("B3-R")
		settle(m, "B2-R")                       -- A1 out
		settle(m, "B2-R")                       -- A2 out
		settle(m, "B2-R")                       -- A3 out
		expect(m.state).toBe("FINISHED")
		expect(m.result).toBe("B")
		expect(m.wins.B).toBe(3)
	end)

	it("abort only applies to an active match", function()
		local m = new(1)
		expect(M.Abort(m, "disputed")).toBeTruthy()
		expect(M.Abort(m, "again")).toBeFalsy()
		expect((M.ReportResult(m, "A1-R", 1, "A1-R", 0))).toBe("ignored")
	end)

	it("re-runs a duel with no readable result as the next attempt", function()
		local m = new(1)
		M.ReportResult(m, "A1-R", 1, "A1-R", 0)               -- only one team read it
		expect((M.Rerun(m, 1, 0))).toBe("rerun")
		expect(m.duels[1].attempt).toBe(1)
		expect(m.duels[1].disputes).toBe(0)
		expect((M.Rerun(m, 1, 0))).toBe("ignored")            -- that attempt is over
		expect((M.ReportResult(m, "B1-R", 1, "A1-R", 0))).toBe("ignored")
		expect(settle(m, "B1-R")).toBe("confirmed")
		expect(m.result).toBe("B")
	end)

	it("a re-run picks up reports that arrived early for the next attempt", function()
		local m = new(1)
		M.ReportResult(m, "A1-R", 1, "B1-R", 1)
		M.ReportResult(m, "B1-R", 1, "B1-R", 1)
		expect((M.Rerun(m, 1, 0))).toBe("confirmed")
	end)

	it("blames the fighter who got the request and didn't accept, or both teams", function()
		local m = new(2)
		expect(M.StallingSide(m)).toBe("both")
		expect(M.MarkRequested(m, 1, 0, "X-R")).toBeFalsy()   -- not a fighter
		expect(M.MarkRequested(m, 1, 0, "B1-R")).toBeTruthy()
		expect(M.StallingSide(m)).toBe("B")
		M.MarkAccepted(m, 1, 0, "B1-R")
		expect(M.StallingSide(m)).toBe(nil)
		M.Rerun(m, 1, 0)                                      -- a new attempt needs a new request
		expect(M.StallingSide(m)).toBe("both")
	end)

	it("a forfeit finishes the match for the other team, or for nobody", function()
		local m = new(3)
		settle(m, "A1-R")
		expect(M.Forfeit(m, "A", "offline")).toBeTruthy()
		expect(m.state).toBe("FINISHED")
		expect(m.result).toBe("B")
		expect(M.Forfeit(m, "B", "stall")).toBeFalsy()
		local both = new(1)
		M.Forfeit(both, "both", "stall")
		expect(both.result).toBe("none")
	end)
end)
