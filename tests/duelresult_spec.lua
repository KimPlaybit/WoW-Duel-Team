local ns = LoadPure()
local D = ns.DuelResult

-- Classic-era wording; the addon reads the real strings from the client at runtime.
local KNOCKOUT = "%1$s has defeated %2$s in a duel"
local RETREAT = "%2$s has fled from %1$s in a duel"

describe("DuelResult", function()
	local list = {
		{ compiled = D.Compile(KNOCKOUT), how = "knockout" },
		{ compiled = D.Compile(RETREAT), how = "retreat" },
	}

	it("reads a knockout", function()
		local w, l, how = D.FromSystemMessage(list, "Alice has defeated Bob in a duel")
		expect(w).toBe("Alice"); expect(l).toBe("Bob"); expect(how).toBe("knockout")
	end)

	it("reads a retreat with swapped argument order", function()
		local w, l, how = D.FromSystemMessage(list, "Bob has fled from Alice in a duel")
		expect(w).toBe("Alice"); expect(l).toBe("Bob"); expect(how).toBe("retreat")
	end)

	it("handles realm-qualified names and pattern characters", function()
		local w, l = D.FromSystemMessage(list, "Al-Some.Realm has defeated Bo(b) in a duel")
		expect(w).toBe("Al-Some.Realm"); expect(l).toBe("Bo(b)")
	end)

	it("ignores unrelated system messages", function()
		expect(D.FromSystemMessage(list, "Alice has come online.")).toBe(nil)
	end)

	it("supports non-positional %s format strings", function()
		local c = D.Compile("%s beat %s")
		local args = D.Parse(c, "X beat Y")
		expect(args[1]).toBe("X"); expect(args[2]).toBe("Y")
	end)

	it("returns nil for missing or argument-less format strings", function()
		expect(D.Compile(nil)).toBe(nil)
		expect(D.Compile("no args")).toBe(nil)
	end)

	it("maps short names to the right fighter", function()
		expect(D.ResolveFighter("Alice", "Alice-R1", "Bob-R1")).toBe("Alice-R1")
		expect(D.ResolveFighter("Bob-R1", "Alice-R1", "Bob-R1")).toBe("Bob-R1")
		expect(D.ResolveFighter("Eve", "Alice-R1", "Bob-R1")).toBe(nil)
		expect(D.ResolveFighter("Sam", "Sam-R1", "Sam-R2")).toBe(nil) -- ambiguous
	end)
end)
