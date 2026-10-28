local ns = LoadPure()
local R = ns.Rating

describe("Rating", function()
	it("averages team ratings (spec §4.2 example)", function()
		expect(R.TeamAverage({ 1800, 1500, 1200 })).toBe(1500)
		expect(R.TeamAverage({})).toBe(nil)
	end)

	it("computes the rating spread", function()
		expect(R.Spread({ 1800, 1500, 1200 })).toBe(600)
		expect(R.Spread({ 1500 })).toBe(0)
	end)

	it("gives even teams half the K factor", function()
		local dA, dB = R.MatchDeltas(1500, 1500, 1, 32)
		expect(dA).toBe(16)
		expect(dB).toBe(-16)
	end)

	it("rewards upsets more than expected wins", function()
		local upset = R.MatchDeltas(1400, 1600, 1, 32)
		local expected = R.MatchDeltas(1600, 1400, 1, 32)
		expect(upset > expected).toBeTruthy()
	end)

	it("returns zero, not -0, for an even draw", function()
		local dA, dB = R.MatchDeltas(1500, 1500, 0.5, 32)
		expect(tostring(dA)).toBe("0")
		expect(tostring(dB)).toBe("0")
	end)
end)
