-- Rating math (spec §4.2, §4.3). Pure.
-- PROVISIONAL algorithm (§12 #3): Elo on team averages; every member of a team gets the same delta.
local _, ns = ...
local Rating = {}
ns.Rating = Rating

function Rating.TeamAverage(ratings)
	if #ratings == 0 then return nil end
	local sum = 0
	for _, r in ipairs(ratings) do sum = sum + r end
	return sum / #ratings
end

-- Rating spread = highest - lowest individual rating (§4.3).
function Rating.Spread(ratings)
	if #ratings == 0 then return nil end
	local lo, hi = ratings[1], ratings[1]
	for _, r in ipairs(ratings) do
		if r < lo then lo = r end
		if r > hi then hi = r end
	end
	return hi - lo
end

function Rating.Expected(ratingA, ratingB)
	return 1 / (1 + 10 ^ ((ratingB - ratingA) / 400))
end

-- scoreA: 1 = team A won, 0 = lost, 0.5 = draw. Returns integer deltas for A and B (always opposite).
function Rating.MatchDeltas(avgA, avgB, scoreA, k)
	local delta = ns.Util.Round(k * (scoreA - Rating.Expected(avgA, avgB)))
	if delta == 0 then return 0, 0 end -- avoid -0
	return delta, -delta
end
