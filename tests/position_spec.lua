local ns = LoadPure()
local P, cfg = ns.Position, ns.Config

local function At(x, y) return { x = x, y = y, map = 1411 } end

-- Steps the countdown with A and B moving by (dxA, dxB) yards along x per step, from xA and xB.
local function Walk(cd, xA, xB, dxA, dxB, steps)
	local outcome, side
	for _ = 1, steps do
		xA, xB = xA + dxA, xB + dxB
		outcome, side = P.Step(cd, At(xA, 0), At(xB, 0), cfg.POS_INTERVAL, cfg)
		if outcome then break end
	end
	return outcome, side, xA, xB
end

describe("Position countdown", function()
	it("runs out after 10 s when the fighters stand still apart: both forfeit", function()
		local cd = P.NewCountdown(cfg)
		expect((Walk(cd, 0, 50, 0, 0, 4))).toBe(nil)        -- 8 s
		local outcome, side = Walk(cd, 0, 50, 0, 0, 1)      -- 10 s
		expect(outcome).toBe("expired")
		expect(side).toBe("both")
	end)

	it("slows down while they close in", function()
		local cd = P.NewCountdown(cfg)
		-- both walk in at 3 yd/s: 100 yards apart takes ~16 s, far longer than 10 s at full speed
		local outcome, _, xA, xB = Walk(cd, 0, 100, 6, -6, 7)
		expect(outcome).toBe(nil)
		expect(xB - xA <= 20).toBeTruthy()
		expect(cd.remaining > 0).toBeTruthy()
	end)

	it("forfeits the one who moves away while the other closes in", function()
		local cd = P.NewCountdown(cfg)
		P.Step(cd, At(0, 0), At(40, 0), cfg.POS_INTERVAL, cfg)
		local outcome, side = Walk(cd, 0, 40, 6, 4, 3)
		expect(outcome).toBe("avoid")
		expect(side).toBe("B")
	end)

	it("one step of drifting away isn't avoiding yet", function()
		local cd = P.NewCountdown(cfg)
		P.Step(cd, At(0, 0), At(40, 0), cfg.POS_INTERVAL, cfg)
		expect((P.Step(cd, At(6, 0), At(44, 0), cfg.POS_INTERVAL, cfg))).toBe(nil)
		expect((P.Step(cd, At(12, 0), At(44, 0), cfg.POS_INTERVAL, cfg))).toBe(nil) -- B stopped
		expect(cd.avoiding.B).toBe(0)
	end)

	it("at the end, the fighter who didn't close in forfeits", function()
		local cd = P.NewCountdown(cfg)
		P.Step(cd, At(0, 0), At(200, 0), cfg.POS_INTERVAL, cfg)
		local outcome, side = Walk(cd, 0, 200, 4, 0, 40)
		expect(outcome).toBe("expired")
		expect(side).toBe("B")
	end)

	it("in duel range the request decides, not the movement", function()
		local cd = P.NewCountdown(cfg)
		local outcome, side = Walk(cd, 0, 5, 0, 0, 5)
		expect(outcome).toBe("expired")
		expect(side).toBe(nil)
	end)

	it("without positions it lasts 30 s and the request decides", function()
		local cd = P.NewCountdown(cfg)
		for _ = 1, 14 do expect((P.Step(cd, nil, At(0, 0), cfg.POS_INTERVAL, cfg))).toBe(nil) end -- 28 s
		local outcome, side = P.Step(cd, nil, At(0, 0), cfg.POS_INTERVAL, cfg)
		expect(outcome).toBe("expired")
		expect(side).toBe(nil)
	end)

	it("different maps count as unknown positions", function()
		local cd = P.NewCountdown(cfg)
		P.Step(cd, At(0, 0), { x = 0, y = 0, map = 1 }, cfg.POS_INTERVAL, cfg)
		expect(cd.prev).toBe(nil)
	end)
end)
