-- Tunables. Values marked PROVISIONAL are open design decisions (spec §12, docs/decisions.md);
-- change them here, not in the logic.
local _, ns = ...

ns.Config = {
	PROTOCOL_VERSION = 1,
	PREFIX = "TDuel1",              -- addon message prefix, max 16 chars

	MAX_TEAM_SIZE = 3,

	-- PROVISIONAL (§12 #1): "pairs" = fighter i vs fighter i, each fights once, majority wins (matches §3.1's
	-- "max duels = team size"); "winnerStays" = elimination, the winner stays in for the next opponent.
	PROGRESSION = "pairs",

	-- PROVISIONAL (§12 #3): Elo on team averages, per format.
	RATING_START = 1500,
	RATING_K = 32,

	-- A duel whose fighters report different winners is re-run; after this many disputes the match is aborted
	-- without rating changes (spec §11.4: never silently produce a wrong winner).
	MAX_DISPUTES_PER_DUEL = 2,

	CHALLENGE_TTL = 120,            -- seconds a challenge stays open
	HISTORY_LIMIT = 500,            -- stored matches
	LOG_LIMIT = 500,                -- debug log lines

	-- Comm pacing. Mirrors the documented Retail addon-message throttle (10 burst, 1/s);
	-- UNVERIFIED on Forever, so stay conservative.
	COMM_BURST = 8,
	COMM_RATE = 1,
	ACK_TIMEOUT = 3,
	MAX_RETRIES = 3,

	-- Seconds after DUEL_FINISHED to wait for the system message before asking for a manual result.
	AUTO_RESULT_GRACE = 2,

	-- PROVISIONAL (§12 #7): candidate duel spots, see docs/decisions.md. Map IDs and coordinates are
	-- deliberately absent until recorded in game with /td where.
	LOCATIONS = {
		{ name = "Outside the Orgrimmar gate", faction = "Horde" },
		{ name = "Thunder Bluff, Hunter Rise", faction = "Horde" },
		{ name = "Outside the Ironforge gate", faction = "Alliance" },
		{ name = "Outside the Stormwind gate", faction = "Alliance" },
	},
}
