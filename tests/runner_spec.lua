-- Sanity checks for the test runner itself and the Lua 5.1 environment.
describe("runner", function()
	it("runs on Lua 5.1 semantics", function()
		expect(_VERSION).toBe("Lua 5.1")
	end)

	it("compares floats approximately", function()
		expect(math.sqrt(2) ^ 2).toBeNear(2, 1e-12)
	end)
end)
