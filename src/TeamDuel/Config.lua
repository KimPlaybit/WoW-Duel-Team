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

	-- A duel whose teams report different winners is re-run; after this many disputes the match is aborted
	-- without rating changes (spec §11.4: never silently produce a wrong winner).
	MAX_DISPUTES_PER_DUEL = 2,

	CHALLENGE_TTL = 120,            -- seconds a challenge stays open

	-- The challenger must be within normal duel range of the targeted opposing leader.
	-- CheckInteractDistance index 3 is duel range on Retail/Classic; UNVERIFIED on Forever.
	DUEL_RANGE_INDEX = 3,
	-- PROVISIONAL: when the range can't be read (API errors or returns a secret), "allow" sends the
	-- challenge with a warning; "block" refuses it.
	DUEL_RANGE_UNKNOWN = "allow",
	-- For 2v2/3v3 every party member must stand within this many yards of their leader (decided by the user).
	-- Measured with UnitDistanceSquared (in the Forever dump, behavior UNVERIFIED); unreadable falls under
	-- DUEL_RANGE_UNKNOWN.
	TEAM_RANGE_YARDS = 20,
	-- Player tooltips: seconds without an answer before a player counts as having no addon (shown as 0),
	-- seconds a player's ratings stay fresh, and the minimum gap between rating requests (and replies).
	TOOLTIP_NO_REPLY = 3,
	TOOLTIP_REFRESH = 60,
	TOOLTIP_ASK_GAP = 1,
	HISTORY_LIMIT = 500,            -- stored matches
	LOG_LIMIT = 500,                -- debug log lines

	-- Comm pacing. Mirrors the documented Retail addon-message throttle (10 burst, 1/s);
	-- UNVERIFIED on Forever, so stay conservative.
	COMM_BURST = 8,
	COMM_RATE = 1,
	ACK_TIMEOUT = 3,
	MAX_RETRIES = 3,

	-- Forfeits (decided by the user: stalling or disconnecting forfeits; there are no manual results or aborts).
	-- PROVISIONAL values (spec §12 #5, #9):
	-- Preparation countdown between duels (spec §7; Position.lua). The 10 s is decided by the user, the rest
	-- is PROVISIONAL.
	COUNTDOWN = 10,             -- seconds for the next duel to be accepted
	COUNTDOWN_SLOW_RATE = 0.25, -- clock speed while the fighters close in on each other
	COUNTDOWN_NO_POSITION = 30, -- seconds the countdown lasts when positions can't be read
	POS_INTERVAL = 2,           -- seconds between position samples (each one is an addon message)
	MOVE_YARDS = 1.5,           -- movement per sample that counts as closing in / moving away
	AVOID_SAMPLES = 2,          -- samples in a row of moving away while the other closes in = forfeit
	DUEL_RANGE_YARDS = 10,      -- close enough to send the duel request
	REQUEST_GRACE = 3,          -- the scheduled request arrived: at least this many seconds left to accept it
	STALL_BACKSTOP = 120,       -- every client: forfeit by the duel request if the fighters' clients never decide
	RESULT_WAIT = 10,       -- seconds after a duel ends for both teams' results, else the duel is re-run
	DUEL_MAX_LENGTH = 600,  -- seconds an accepted duel may take before it's re-run (it may never have started)
	HEARTBEAT = 10,         -- seconds between "still here" pings during a match
	OFFLINE_AFTER = 45,     -- seconds of silence before a player counts as gone and their team forfeits

	-- PROVISIONAL (§12 #7): candidate duel spots, see docs/decisions.md. Map IDs and coordinates are
	-- deliberately absent until recorded in game with /td where.
	LOCATIONS = {
		{ name = "Outside the Orgrimmar gate", faction = "Horde" },
		{ name = "Thunder Bluff, Hunter Rise", faction = "Horde" },
		{ name = "Outside the Ironforge gate", faction = "Alliance" },
		{ name = "Outside the Stormwind gate", faction = "Alliance" },
	},
}
