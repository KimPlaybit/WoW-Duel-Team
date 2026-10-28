local ns = LoadPure()
local DB = ns.DB

describe("DB", function()
	it("initializes an empty or missing db", function()
		local db = DB.Migrate(nil)
		expect(db.schema).toBe(DB.CURRENT_SCHEMA)
		expect(type(db.players)).toBe("table")
		expect(type(db.matches)).toBe("table")
	end)

	it("keeps existing data when migrating", function()
		local db = DB.Migrate({ players = { ["A-R"] = { ratings = { [1] = 1600 } } } })
		expect(DB.GetRating(db, "A-R", 1)).toBe(1600)
	end)

	it("goes read-only on data from a newer version and refuses writes", function()
		local db, err = DB.Migrate({ schema = DB.CURRENT_SCHEMA + 1, players = {}, matches = {} })
		expect(db.readOnly).toBeTruthy()
		expect(err ~= nil).toBeTruthy()
		expect(DB.SetRating(db, "A-R", 1, 1600)).toBeFalsy()
	end)

	it("leaves the original untouched when a migration fails", function()
		local original = { schema = 0, players = { keep = true } }
		local saved = DB.MIGRATIONS[1]
		DB.MIGRATIONS[1] = function(db) db.players = nil; error("boom") end
		local db, err = DB.Migrate(original)
		DB.MIGRATIONS[1] = saved
		expect(db).toBe(original)
		expect(db.players.keep).toBeTruthy()
		expect(db.readOnly).toBeTruthy()
		expect(err ~= nil).toBeTruthy()
	end)

	it("stores ratings per format with a default", function()
		local db = DB.Migrate(nil)
		expect(DB.GetRating(db, "A-R", 2)).toBe(ns.Config.RATING_START)
		DB.SetRating(db, "A-R", 2, 1516.4)
		expect(DB.GetRating(db, "A-R", 2)).toBe(1516)
		expect(DB.GetRating(db, "A-R", 3)).toBe(ns.Config.RATING_START)
	end)

	it("caps match history", function()
		local db = DB.Migrate(nil)
		for i = 1, ns.Config.HISTORY_LIMIT + 5 do DB.RecordMatch(db, { n = i }) end
		expect(#db.matches).toBe(ns.Config.HISTORY_LIMIT)
		expect(db.matches[1].n).toBe(6)
	end)
end)
