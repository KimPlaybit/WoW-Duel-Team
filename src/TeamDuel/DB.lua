-- SavedVariables schema, migrations, and accessors. Pure: operates on the table it is given.
-- Local data is a personal record, not an authoritative rating database (spec §5.6, §11.3).
local _, ns = ...
local DB = {}
ns.DB = DB

DB.CURRENT_SCHEMA = 1

-- MIGRATIONS[v] upgrades a db from schema v-1 to v. Append only; never edit a shipped migration.
DB.MIGRATIONS = {
	[1] = function(db)
		db.players = db.players or {}     -- ["Name-Realm"] = { ratings = { [format] = rating } }
		db.matches = db.matches or {}     -- array of match records, oldest first
		db.settings = db.settings or { debug = false }
		db.debugLog = db.debugLog or {}
	end,
}

-- Returns the migrated db (a new table on upgrade) and an error string if it had to go read-only.
-- A failed migration leaves the original data untouched and blocks writes, so nothing is lost.
function DB.Migrate(db)
	if type(db) ~= "table" then db = {} end
	local from = db.schema or 0
	if from > DB.CURRENT_SCHEMA then
		db.readOnly = true
		return db, "saved data is from a newer addon version (schema " .. from .. ")"
	end
	if from == DB.CURRENT_SCHEMA then
		db.readOnly = nil
		return db
	end
	local work = ns.Util.DeepCopy(db)
	for v = from + 1, DB.CURRENT_SCHEMA do
		local ok, err = pcall(DB.MIGRATIONS[v], work)
		if not ok then
			db.readOnly = true
			return db, "migration to schema " .. v .. " failed: " .. tostring(err)
		end
		work.schema = v
	end
	work.readOnly = nil
	return work
end

function DB.GetRating(db, name, fmt)
	local player = db.players and db.players[name]
	local rating = player and player.ratings and player.ratings[fmt]
	return rating or ns.Config.RATING_START
end

function DB.SetRating(db, name, fmt, rating)
	if db.readOnly then return false end
	local player = db.players[name]
	if not player then
		player = { ratings = {} }
		db.players[name] = player
	end
	player.ratings[fmt] = math.max(0, ns.Util.Round(rating))
	return true
end

function DB.RecordMatch(db, record)
	if db.readOnly then return false end
	db.matches[#db.matches + 1] = record
	while #db.matches > ns.Config.HISTORY_LIMIT do
		table.remove(db.matches, 1)
	end
	return true
end
