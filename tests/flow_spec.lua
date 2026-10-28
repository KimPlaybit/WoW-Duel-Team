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

		w:Target(alice, bob); w:Slash(alice, "challenge bob")
		w:Run(1)
		expect(bob.ns.Session.state.challengeIn ~= nil).toBeTruthy()

		w:Click(bob, "Accept")
		w:Run(1)
		expect(MatchOf(alice) ~= nil).toBeTruthy()
		expect(MatchOf(bob) ~= nil).toBeTruthy()

		w:Click(alice, "Start duel")
		expect(alice.duelRequests[1]).toBe("target")

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
		w:Target(alice, bob); w:Slash(alice, "challenge bob"); w:Run(1)
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
		w:Target(alice, bob); w:Slash(alice, "challenge bob"); w:Run(1)
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
		w:Target(alice, bob); w:Slash(alice, "challenge bob"); w:Run(6)
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
		w:Target(alice, bob); w:Slash(alice, "challenge bob"); w:Run(1)
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
		w:Target(alice, bob); w:Slash(alice, "challenge bob"); w:Run(1)
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

describe("right-click Challenge", function()
	it("sits right below Duel with 1v1/2v2/3v3, and 1v1 sends the challenge", function()
		local w = World.New()
		local alice, bob = w:AddClient("Alice"), w:AddClient("Bob")
		w:Target(alice, bob)
		local top, sub = w:RightClickTarget(alice, { "Challenge", "1v1" })
		expect(top).toBe("Whisper,Invite,Trade,Duel,Challenge,Follow")
		expect(sub).toBe("1v1,2v2,3v3")
		w:Run(1)
		expect(bob.ns.Session.state.challengeIn.fmt).toBe(1)
	end)

	it("1v1 works between members of other teams", function()
		local w = World.New()
		local a1, a2, b1, b2 = w:AddClient("Anna"), w:AddClient("Arne"), w:AddClient("Bert"), w:AddClient("Bo")
		FormTeam(w, a1, { a2 })
		FormTeam(w, b1, { b2 })
		w:Target(a2, b2); w:RightClickTarget(a2, { "Challenge", "1v1" }); w:Run(1)
		expect(b2.ns.Session.state.challengeIn.fmt).toBe(1)
		w:Slash(b2, "accept"); w:Run(1)
		expect(table.concat(MatchOf(a2).teamA, ",")).toBe("Arne-Testrealm")
		expect(table.concat(MatchOf(a2).teamB, ",")).toBe("Bo-Testrealm")
	end)

	it("2v2 to someone who isn't a leader fails and tells the challenger", function()
		local w = World.New()
		local a1, a2, b1, b2 = w:AddClient("Anna"), w:AddClient("Arne"), w:AddClient("Bert"), w:AddClient("Bo")
		FormTeam(w, a1, { a2 })
		FormTeam(w, b1, { b2 })
		w:Target(a1, b2); w:RightClickTarget(a1, { "Challenge", "2v2" }); w:Run(1)
		expect(b2.ns.Session.state.challengeIn).toBe(nil)
		expect(a1.ns.Session.state.challengeOut).toBe(nil)
		expect(w:Printed(a1, "Bo is not a team leader")).toBeTruthy()
	end)

	it("3v3 to a leader without three players fails and tells the challenger", function()
		local w = World.New()
		local a1, a2, a3 = w:AddClient("Anna"), w:AddClient("Arne"), w:AddClient("Ada")
		local b1, b2 = w:AddClient("Bert"), w:AddClient("Bo")
		FormTeam(w, a1, { a2, a3 })
		FormTeam(w, b1, { b2 })
		w:Target(a1, b1); w:RightClickTarget(a1, { "Challenge", "3v3" }); w:Run(1)
		expect(b1.ns.Session.state.challengeIn).toBe(nil)
		expect(w:Printed(a1, "Bert's team has 2 player(s); a 3v3 needs 3.")).toBeTruthy()
	end)

	it("3v3 between two full teams reaches the leader", function()
		local w = World.New()
		local a1, a2, a3 = w:AddClient("Anna"), w:AddClient("Arne"), w:AddClient("Ada")
		local b1, b2, b3 = w:AddClient("Bert"), w:AddClient("Bo"), w:AddClient("Britt")
		FormTeam(w, a1, { a2, a3 })
		FormTeam(w, b1, { b2, b3 })
		w:Target(a1, b1); w:RightClickTarget(a1, { "Challenge", "3v3" }); w:Run(1)
		expect(b1.ns.Session.state.challengeIn.fmt).toBe(3)
	end)

	it("refuses locally when our own team is the wrong size", function()
		local w = World.New()
		local alice, bob = w:AddClient("Alice"), w:AddClient("Bob")
		w:Target(alice, bob); w:RightClickTarget(alice, { "Challenge", "2v2" }); w:Run(1)
		expect(bob.ns.Session.state.challengeIn).toBe(nil)
		expect(w:Printed(alice, "Your team has 1 player(s); a 2v2 needs 2.")).toBeTruthy()
	end)

	it("refuses when out of duel range", function()
		local w = World.New()
		local alice, bob = w:AddClient("Alice"), w:AddClient("Bob")
		w.duelRange = false
		w:Target(alice, bob)
		w:RightClickTarget(alice, { "Challenge", "1v1" }); w:Run(1)
		expect(bob.ns.Session.state.challengeIn).toBe(nil)
		expect(w:Printed(alice, "Too far away")).toBeTruthy()
	end)
end)

describe("challenge details on the duel popup", function()
	local function Challenge2v2(opts)
		local w = World.New(opts)
		local a1, a2, b1, b2 = w:AddClient("Anna"), w:AddClient("Arne"), w:AddClient("Bert"), w:AddClient("Bo")
		FormTeam(w, a1, { a2 })
		FormTeam(w, b1, { b2 })
		w:Target(a1, b1); w:RightClickTarget(a1, { "Challenge", "2v2" }); w:Run(1)
		return w, a1, b1
	end

	local function Has(text, needle)
		return text ~= nil and string.find(text, needle, 1, true) ~= nil
	end

	it("adds the spec's challenge details under Blizzard's text", function()
		local w, _, b1 = Challenge2v2()
		local text = w:PopupText(b1)
		expect(Has(text, "Anna has challenged you to a duel.")).toBeTruthy()
		for _, needle in ipairs({ "Anna's team challenges you to a 2v2", "Team average 1500, spread 0",
			"1. Anna  1500", "2. Arne  1500", "Your team average 1500",
			"Rating at stake: win +16, loss -16, draw +0", "Repeated-matchup", "Location:" }) do
			expect(Has(text, needle)).toBeTruthy()
		end
		expect(Has(text, "Expires in")).toBeFalsy()
	end)

	it("also works when the duel request arrives before the challenge message", function()
		local w, _, b1 = Challenge2v2({ duelFirst = true })
		expect(Has(w:PopupText(b1), "Rating at stake")).toBeTruthy()
	end)

	it("1v1 shows both ratings", function()
		local w = World.New()
		local alice, bob = w:AddClient("Alice"), w:AddClient("Bob")
		w:Target(alice, bob); w:RightClickTarget(alice, { "Challenge", "1v1" }); w:Run(1)
		expect(Has(w:PopupText(bob), "Alice challenges you to a 1v1 duel.")).toBeTruthy()
		expect(Has(w:PopupText(bob), "Your rating: 1500")).toBeTruthy()
	end)

	it("an ordinary duel request is left alone", function()
		local w = World.New()
		local alice, bob = w:AddClient("Alice"), w:AddClient("Bob")
		w:Target(alice, bob)
		w:As(alice, _G.StartDuel, "target"); w:Run(1)
		expect(w:PopupText(bob)).toBe("Alice has challenged you to a duel.")
		w:PopupClick(bob, "accept"); w:Run(1)
		expect(MatchOf(bob)).toBe(nil)
	end)

	it("accepting the duel accepts the challenge", function()
		local w, a1, b1 = Challenge2v2()
		w:PopupClick(b1, "accept"); w:Run(1)
		expect(b1.duelAccepts).toBe(1)
		expect(MatchOf(b1) ~= nil).toBeTruthy()
		expect(MatchOf(a1) ~= nil).toBeTruthy()
		expect(w:Printed(b1, "was requested with the challenge")).toBeTruthy()
		expect(w:Printed(a1, "was requested with the challenge")).toBeTruthy()
	end)

	it("declining the duel declines the challenge", function()
		local w, a1, b1 = Challenge2v2()
		w:PopupClick(b1, "decline"); w:Run(1)
		expect(b1.duelCancels).toBe(1)
		expect(b1.ns.Session.state.challengeIn).toBe(nil)
		expect(a1.ns.Session.state.challengeOut).toBe(nil)
		expect(w:Printed(a1, "Bert declined")).toBeTruthy()
		expect(a1.duelCancels).toBe(1) -- challenger withdraws its request on DEC
	end)

	it("accepting from the /td window accepts the duel once", function()
		local w, a1, b1 = Challenge2v2()
		w:Click(b1, "Accept"); w:Run(1)
		expect(b1.duelAccepts).toBe(1)
		expect(w:PopupText(b1)).toBe(nil)
		expect(MatchOf(a1) ~= nil).toBeTruthy()
	end)

	it("declining from /td declines the duel once", function()
		local w, _, b1 = Challenge2v2()
		w:Slash(b1, "decline"); w:Run(1)
		expect(b1.duelCancels).toBe(1)
		expect(w:Printed(b1, "No pending challenge")).toBeFalsy()
	end)

	it("a challenge that can't go ahead withdraws the duel request", function()
		local w = World.New()
		local a1, a2, b1 = w:AddClient("Anna"), w:AddClient("Arne"), w:AddClient("Bert")
		FormTeam(w, a1, { a2 })
		w:Target(a1, b1); w:RightClickTarget(a1, { "Challenge", "2v2" }); w:Run(1)
		expect(a1.duelCancels).toBe(1)
	end)
end)

describe("challenge range", function()
	it("needs the opponent targeted", function()
		local w = World.New()
		local alice, bob, carl = w:AddClient("Alice"), w:AddClient("Bob"), w:AddClient("Carl")
		w:Slash(alice, "challenge bob"); w:Run(1)
		expect(bob.ns.Session.state.challengeIn).toBe(nil)
		w:Target(alice, carl); w:Slash(alice, "challenge bob"); w:Run(1)
		expect(bob.ns.Session.state.challengeIn).toBe(nil)
		expect(w:Printed(alice, "Target Bob to challenge them.")).toBeTruthy()
	end)

	it("uses the target when no name is given", function()
		local w = World.New()
		local alice, bob = w:AddClient("Alice"), w:AddClient("Bob")
		w:Target(alice, bob); w:Slash(alice, "challenge"); w:Run(1)
		expect(bob.ns.Session.state.challengeIn ~= nil).toBeTruthy()
	end)

	it("refuses when out of duel range", function()
		local w = World.New()
		local alice, bob = w:AddClient("Alice"), w:AddClient("Bob")
		w.duelRange = false
		w:Target(alice, bob); w:Slash(alice, "challenge bob"); w:Run(1)
		expect(bob.ns.Session.state.challengeIn).toBe(nil)
		expect(w:Printed(alice, "Too far away")).toBeTruthy()
	end)

	it("sends with a warning when the range can't be checked", function()
		local w = World.New()
		local alice, bob = w:AddClient("Alice"), w:AddClient("Bob")
		w.duelRange = "error"
		w:Target(alice, bob); w:Slash(alice, "challenge bob"); w:Run(1)
		expect(bob.ns.Session.state.challengeIn ~= nil).toBeTruthy()
		expect(w:Printed(alice, "sending anyway")).toBeTruthy()
	end)
end)

describe("team flow", function()
	it("2v2 pairs: team formation, fighter order, two duels, draw", function()
		local w = World.New()
		local a1, a2, b1, b2 = w:AddClient("Anna"), w:AddClient("Arne"), w:AddClient("Bert"), w:AddClient("Bo")
		FormTeam(w, a1, { a2 })
		FormTeam(w, b1, { b2 })
		w:Slash(b1, "order bo bert")
		expect(w:Printed(b1, "you always fight first")).toBeTruthy()

		w:Target(a1, b1); w:Slash(a1, "challenge bert"); w:Run(1)
		local c = b1.ns.Session.state.challengeIn
		expect(c.fmt).toBe(2)
		w:Click(b1, "Accept"); w:Run(1)

		for _, client in ipairs({ a1, a2, b1, b2 }) do
			local m = MatchOf(client)
			expect(m ~= nil).toBeTruthy()
			expect(m.duels[1].a).toBe(a1.name) -- leaders fight first
			expect(m.duels[1].b).toBe(b1.name)
		end

		w:Duel(a1, b1); w:Run(3)
		expect(MatchOf(a2).duels[2].a).toBe(a2.name)
		expect(MatchOf(a2).duels[2].b).toBe(b2.name)

		w:Duel(b2, a2); w:Run(3)
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
		w:Target(a1, b1); w:Slash(a1, "challenge 3v3 bert"); w:Run(1)
		expect(b1.ns.Session.state.challengeIn).toBe(nil)
		expect(MatchOf(b1)).toBe(nil)
		expect(w:Printed(a1, "Bert's team has 1 player(s); a 3v3 needs 3.")).toBeTruthy()
		expect(w:Printed(b1, "Your team has 1 player(s); a 3v3 needs 3.")).toBeTruthy()
	end)

	it("a team that shrinks after the challenge can't accept", function()
		local w = World.New()
		local a1, a2, b1, b2 = w:AddClient("Anna"), w:AddClient("Arne"), w:AddClient("Bert"), w:AddClient("Bo")
		FormTeam(w, a1, { a2 })
		FormTeam(w, b1, { b2 })
		w:Target(a1, b1); w:Slash(a1, "challenge 2v2"); w:Run(1)
		w:Slash(b2, "leave"); w:Run(1)
		w:Slash(b1, "accept"); w:Run(1)
		expect(MatchOf(b1)).toBe(nil)
		expect(w:Printed(b1, "Your team has 1 player(s); a 2v2 needs 2.")).toBeTruthy()
	end)
end)
