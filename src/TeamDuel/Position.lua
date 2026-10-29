-- The preparation countdown between duels (spec §7, decided by the user). Pure: fed one position sample per
-- fighter per step, it runs the clock and says when a team forfeits.
--
-- - The clock starts at Config.COUNTDOWN (10 s) when a duel becomes current.
-- - While the fighters close the distance it runs at COUNTDOWN_SLOW_RATE; otherwise at full speed. Once they
--   are within duel range it runs at full speed too: they only need to send and accept the request.
-- - One fighter closing in while the other moves away, AVOID_SAMPLES steps in a row, is avoiding: forfeit.
-- - When the clock runs out out of range, the fighter who closed in less forfeits (both if neither did).
--   In range, the caller decides from the duel request instead (Match.StallingSide).
-- - Without positions (unreadable, secret, other map) the clock runs at COUNTDOWN / COUNTDOWN_NO_POSITION,
--   so the duel then has COUNTDOWN_NO_POSITION seconds, and the caller decides from the duel request.
local _, ns = ...
local Position = {}
ns.Position = Position

local function Distance(p, q)
	local dx, dy = p.x - q.x, p.y - q.y
	return math.sqrt(dx * dx + dy * dy)
end
Position.Distance = Distance

function Position.NewCountdown(cfg)
	return {
		remaining = cfg.COUNTDOWN,
		closedIn = { A = 0, B = 0 },  -- yards each fighter has closed in, net (moving away subtracts)
		avoiding = { A = 0, B = 0 },  -- consecutive steps spent moving away while the other closed in
		prev = nil,                   -- { A = pos, B = pos } from the last step with both positions
	}
end

local function SameMap(p, q)
	return p and q and p.map == q.map
end

-- One step of dt seconds. posA/posB: { x, y, map } in yards, or nil when unknown.
-- Returns nil while the countdown goes on, or an outcome:
--   "avoid", side          side moved away while the other closed in: it forfeits
--   "expired", side|nil    the clock ran out; side ("A" | "B" | "both") is at fault, nil = decide from the request
function Position.Step(cd, posA, posB, dt, cfg)
	if not SameMap(posA, posB) then
		cd.prev = nil
		cd.remaining = cd.remaining - dt * cfg.COUNTDOWN / cfg.COUNTDOWN_NO_POSITION
		if cd.remaining <= 1e-6 then return "expired", nil end
		return nil
	end

	local rate = 1
	local dist = Distance(posA, posB)
	local prev = cd.prev
	if prev and SameMap(prev.A, posA) and SameMap(prev.B, posB) then
		-- How far each fighter's own movement closed the gap, measured against the other's current spot.
		local byA = Distance(prev.A, posB) - dist
		local byB = Distance(prev.B, posA) - dist
		cd.closedIn.A, cd.closedIn.B = cd.closedIn.A + byA, cd.closedIn.B + byB
		local move = cfg.MOVE_YARDS
		local function Avoids(mine, theirs) return mine <= -move and theirs >= move end
		cd.avoiding.A = Avoids(byA, byB) and cd.avoiding.A + 1 or 0
		cd.avoiding.B = Avoids(byB, byA) and cd.avoiding.B + 1 or 0
		if cd.avoiding.A >= cfg.AVOID_SAMPLES then return "avoid", "A" end
		if cd.avoiding.B >= cfg.AVOID_SAMPLES then return "avoid", "B" end
		if Distance(prev.A, prev.B) - dist >= move and dist > cfg.DUEL_RANGE_YARDS then
			rate = cfg.COUNTDOWN_SLOW_RATE
		end
	end
	cd.prev = { A = posA, B = posB }

	cd.remaining = cd.remaining - dt * rate
	if cd.remaining > 1e-6 then return nil end
	if dist <= cfg.DUEL_RANGE_YARDS then return "expired", nil end
	local a, b, move = cd.closedIn.A, cd.closedIn.B, cfg.MOVE_YARDS
	if a - b >= move then return "expired", "B" end
	if b - a >= move then return "expired", "A" end
	return "expired", "both"
end
