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
	M.ReportResult(m, duel.a, idx, winner, duel.disputes)
	return M.ReportResult(m, duel.b, idx, winner, duel.disputes)
end

describe("Match", function()
	it("rejects invalid rosters", function()
		expect(pcall(M.New, { fmt = 2, teamA = { "A-R" }, teamB = { "B-R", "C-R" }, ratingsA = { 1 }, ratingsB = { 1, 1 }, progression = "pairs" })).toBeFalsy()
		expect(pcall(M.New, { fmt = 1, teamA = { "A-R" }, teamB = { "A-R" }, ratingsA = { 1 }, ratingsB = { 1 }, progression = "pairs" })).toBeFalsy()
		expect(pcall(M.New, { fmt = 1, teamA = { "A-R" }, teamB = { "B-R" }, ratingsA = { 1 }, ratingsB = { 1 }, progression = "random" })).toBeFalsy()
	end)

	it("needs both fighters to agree", function()
		local m = new(1)
		expect((M.ReportResult(m, "A1-R", 1, "A1-R", 0))).toBe("pending")
		expect((M.ReportResult(m, "B1-R", 1, "A1-R", 0))).toBe("confirmed")
		expect(m.state).toBe("FINISHED")
		expect(m.result).toBe("A")
	end)

	it("ignores reports from non-fighters, wrong duels and unknown winners", function()
		local m = new(2)
		expect((M.ReportResult(m, "A2-R", 1, "A1-R", 0))).toBe("ignored") -- teammate, not fighting
		expect((M.ReportResult(m, "A1-R", 2, "A1-R", 0))).toBe("ignored") -- future duel
		expect((M.ReportResult(m, "A1-R", 1, "X-R", 0))).toBe("ignored")  -- not a fighter
	end)

	it("ignores a second report from the same fighter in the same attempt", function()
		local m = new(1)
		M.ReportResult(m, "A1-R", 1, "A1-R", 0)
		expect((M.ReportResult(m, "A1-R", 1, "B1-R", 0))).toBe("ignored")
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
		expect(M.Abort(m, "leader")).toBeTruthy()
		expect(M.Abort(m, "again")).toBeFalsy()
		expect((M.ReportResult(m, "A1-R", 1, "A1-R", 0))).toBe("ignored")
	end)
end)
