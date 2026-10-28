-- End-to-end flows across simulated clients (see tests/sim.lua for what is and isn't modelled).
local World = dofile("tests/sim.lua")

local function Rating(world, client, of, fmt)
	return world:As(client, function() return client.ns.DB.GetRating(client.ns.db, of.name, fmt) end)
end

local function MatchOf(client)
	return client.ns.Session.state.match
end

local function FormTeam(world, leader, members)
	for _, m in ipairs(members) do
		world:Slash(leader, "invite " .. m.short)
		world:Run(1)
		world:Slash(m, "join")
		world:Run(1)
	end
end

describe("1v1 flow", function()
	it("challenge, accept, automatic result, ratings on both clients", function()
		local w = World.New()
		local alice, bob = w:AddClient("Alice"), w:AddClient("Bob")

		w:Slash(alice, "challenge bob")
		w:Run(1)
		expect(bob.ns.Session.state.challengeIn ~= nil).toBeTruthy()

		w:Click(bob, "Accept")
		w:Run(1)
		expect(MatchOf(alice) ~= nil).toBeTruthy()
		expect(MatchOf(bob) ~= nil).toBeTruthy()

		w:Click(alice, "Start duel")
		expect(alice.duelRequests[1]).toBe("Bob")

		w:Duel(alice, bob)
		w:Run(3)
		expect(MatchOf(alice)).toBe(nil)
		expect(MatchOf(bob)).toBe(nil)
		expect(alice.ns.Session.state.lastSummary.result).toBe("A")
		expect(Rating(w, alice, alice, 1)).toBe(1516)
		expect(Rating(w, alice, bob, 1)).toBe(1484)
		expect(Rating(w, bob, alice, 1)).toBe(1516)
		expect(Rating(w, bob, bob, 1)).toBe(1484)
		expect(#alice.ns.db.matches).toBe(1)
		expect(#bob.ns.db.matches).toBe(1)
	end)

	it("falls back to manual buttons when the duel text is unavailable", function()
		local w = World.New({ noDuelStrings = true })
		local alice, bob = w:AddClient("Alice"), w:AddClient("Bob")
		w:Slash(alice, "challenge bob"); w:Run(1)
		w:Slash(bob, "accept"); w:Run(1)

		w:DuelWithoutMessage(alice, bob)
		w:Run(3)
		expect(w:Printed(alice, "couldn't be read automatically")).toBeTruthy()
		expect(MatchOf(alice) ~= nil).toBeTruthy()

		w:Click(alice, "I lost")
		w:Run(1)
		expect(MatchOf(alice) ~= nil).toBeTruthy() -- one report is not enough
		w:Click(bob, "I won")
		w:Run(1)
		expect(MatchOf(alice)).toBe(nil)
		expect(bob.ns.Session.state.lastSummary.result).toBe("B")
	end)

	it("a dispute re-runs the duel instead of guessing", function()
		local w = World.New({ noDuelStrings = true })
		local alice, bob = w:AddClient("Alice"), w:AddClient("Bob")
		w:Slash(alice, "challenge bob"); w:Run(1)
		w:Slash(bob, "accept"); w:Run(1)

		w:Slash(alice, "won"); w:Slash(bob, "won")
		w:Run(1)
		expect(MatchOf(alice).duels[1].disputes).toBe(1)
		expect(MatchOf(bob).duels[1].disputes).toBe(1)
		expect(Rating(w, alice, alice, 1)).toBe(1500)

		w:Slash(alice, "won"); w:Slash(bob, "lost")
		w:Run(1)
		expect(alice.ns.Session.state.lastSummary.result).toBe("A")
		expect(bob.ns.Session.state.lastSummary.result).toBe("A")
	end)

	it("survives lost messages through ACK and retry", function()
		local dropped = {}
		local w = World.New({
			dropIf = function(msg)
				-- drop the first copy of every reliable message type once
				local kind = msg.text:match("^%d+|(%u+)|")
				if kind ~= "ACK" and not dropped[kind .. msg.to] then
					dropped[kind .. msg.to] = true
					return true
				end
			end,
		})
		local alice, bob = w:AddClient("Alice"), w:AddClient("Bob")
		w:Slash(alice, "challenge bob"); w:Run(6)
		w:Slash(bob, "accept"); w:Run(6)
		expect(MatchOf(alice) ~= nil).toBeTruthy()
		w:Duel(alice, bob)
		w:Run(10)
		expect(alice.ns.Session.state.lastSummary.result).toBe("A")
		expect(bob.ns.Session.state.lastSummary.result).toBe("A")
		for _, kind in ipairs({ "CHAL", "ACC", "RES" }) do
			expect(dropped[kind .. bob.name] or dropped[kind .. alice.name]).toBeTruthy()
		end
	end)

	it("a leader abort ends the match on both sides without rating changes", function()
		local w = World.New()
		local alice, bob = w:AddClient("Alice"), w:AddClient("Bob")
		w:Slash(alice, "challenge bob"); w:Run(1)
		w:Slash(bob, "accept"); w:Run(1)
		w:Click(bob, "Abort")
		w:Run(1)
		expect(MatchOf(alice)).toBe(nil)
		expect(alice.ns.Session.state.lastSummary.status).toBe("aborted")
		expect(Rating(w, alice, alice, 1)).toBe(1500)
	end)

	it("ignores results reported by a non-fighter", function()
		local w = World.New()
		local alice, bob, eve = w:AddClient("Alice"), w:AddClient("Bob"), w:AddClient("Eve")
		w:Slash(alice, "challenge bob"); w:Run(1)
		w:Slash(bob, "accept"); w:Run(1)
		-- Eve forges a result message for Alice's match.
		local mid = MatchOf(alice).mid
		w:As(eve, function()
			eve.ns.Comm.Send(alice.name, "RES", mid, { d = 1, w = eve.name, t = 0, src = "manual" })
		end)
		w:Run(1)
		expect(MatchOf(alice) ~= nil).toBeTruthy()
		expect(next(MatchOf(alice).duels[1].reports)).toBe(nil)
		-- and the delivery really happened (the guard, not the transport, stopped it)
		local delivered = false
		for _, msg in ipairs(w.sent) do
			if msg.from == eve.name and msg.text:find("|RES|", 1, true) then delivered = true end
		end
		expect(delivered).toBeTruthy()
	end)
end)

describe("team flow", function()
	it("2v2 pairs: team formation, fighter order, two duels, draw", function()
		local w = World.New()
		local a1, a2, b1, b2 = w:AddClient("Anna"), w:AddClient("Arne"), w:AddClient("Bert"), w:AddClient("Bo")
		FormTeam(w, a1, { a2 })
		FormTeam(w, b1, { b2 })
		w:Slash(b1, "order bo bert")

		w:Slash(a1, "challenge bert"); w:Run(1)
		local c = b1.ns.Session.state.challengeIn
		expect(c.fmt).toBe(2)
		w:Click(b1, "Accept"); w:Run(1)

		for _, client in ipairs({ a1, a2, b1, b2 }) do
			local m = MatchOf(client)
			expect(m ~= nil).toBeTruthy()
			expect(m.duels[1].a).toBe(a1.name)
			expect(m.duels[1].b).toBe(b2.name) -- Bo fights first per the order
		end

		w:Duel(a1, b2); w:Run(3)
		expect(MatchOf(a2).duels[2].a).toBe(a2.name)
		expect(MatchOf(a2).duels[2].b).toBe(b1.name)

		w:Duel(b1, a2); w:Run(3)
		for _, client in ipairs({ a1, a2, b1, b2 }) do
			expect(MatchOf(client)).toBe(nil)
			expect(client.ns.Session.state.lastSummary.result).toBe("draw")
		end
		expect(Rating(w, a1, a2, 2)).toBe(1500)
	end)

	it("3v3 rejected when the accepting team is too small", function()
		local w = World.New()
		local a1, a2, a3, b1 = w:AddClient("Anna"), w:AddClient("Arne"), w:AddClient("Ada"), w:AddClient("Bert")
		FormTeam(w, a1, { a2, a3 })
		w:Slash(a1, "challenge bert"); w:Run(1)
		expect(b1.ns.Session.state.challengeIn.fmt).toBe(3)
		w:Slash(b1, "accept"); w:Run(1)
		expect(MatchOf(b1)).toBe(nil)
		expect(w:Printed(b1, "This is a 3v3 challenge")).toBeTruthy()
	end)
end)
