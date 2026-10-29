-- End-to-end flows across simulated clients (see tests/sim.lua for what is and isn't modelled).
local World = dofile("tests/sim.lua")

local function Rating(world, client, of, fmt)
	return world:As(client, function() return client.ns.DB.GetRating(client.ns.db, of.name, fmt) end)
end

local function MatchOf(client)
	return client.ns.Session.state.match
end

-- A team is a party; members report their ratings to the leader over the next step.
local function FormTeam(world, leader, members)
	world:Group(leader, members)
	world:Run(1)
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

	it("a duel nobody could read is fought again, never reported by hand", function()
		local w = World.New()
		local alice, bob = w:AddClient("Alice"), w:AddClient("Bob")
		w:Target(alice, bob); w:Slash(alice, "challenge bob"); w:Run(1)
		w:Slash(bob, "accept"); w:Run(1)

		w:DuelWithoutMessage(alice, bob)
		w:Run(11)
		expect(w:Printed(alice, "couldn't be read by both teams. Fight it again.")).toBeTruthy()
		expect(MatchOf(alice).duels[1].attempt).toBe(1)
		expect(MatchOf(bob).duels[1].attempt).toBe(1)

		w:Duel(bob, alice)
		w:Run(1)
		expect(MatchOf(alice)).toBe(nil)
		expect(bob.ns.Session.state.lastSummary.result).toBe("B")
	end)

	it("a dispute re-runs the duel instead of guessing", function()
		local w = World.New()
		local alice, bob = w:AddClient("Alice"), w:AddClient("Bob")
		w:Target(alice, bob); w:Slash(alice, "challenge bob"); w:Run(1)
		w:Slash(bob, "accept"); w:Run(1)

		-- each client reads a different winner (a tampered client, say)
		w:Duel(alice, bob, { alice }); w:Duel(bob, alice, { bob })
		w:Run(1)
		expect(MatchOf(alice).duels[1].disputes).toBe(1)
		expect(MatchOf(bob).duels[1].disputes).toBe(1)
		expect(Rating(w, alice, alice, 1)).toBe(1500)

		w:Duel(alice, bob)
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
				if kind ~= "ACK" and kind ~= "PING" and not dropped[kind .. msg.to] then
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

	it("ignores results reported by someone outside the match", function()
		local w = World.New()
		local alice, bob, eve = w:AddClient("Alice"), w:AddClient("Bob"), w:AddClient("Eve")
		w:Target(alice, bob); w:Slash(alice, "challenge bob"); w:Run(1)
		w:Slash(bob, "accept"); w:Run(1)
		-- Eve forges a result message for Alice's match.
		local mid = MatchOf(alice).mid
		w:As(eve, function()
			eve.ns.Comm.Send(alice.name, "RES", mid, { d = 1, w = eve.name, t = 0, src = "auto" })
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

	it("an opponent who goes silent forfeits, with rating changes", function()
		local w = World.New()
		local alice, bob = w:AddClient("Alice"), w:AddClient("Bob")
		w:Target(alice, bob); w:Slash(alice, "challenge bob"); w:Run(1)
		w:Slash(bob, "accept"); w:Run(1)
		w:Disconnect(bob)
		w:Fire(alice, "DUEL_FINISHED") -- the duel ends when Bob drops; no winner message
		w:Run(70)
		local summary = alice.ns.Session.state.lastSummary
		expect(summary.status).toBe("forfeit")
		expect(summary.forfeit).toBe("B")
		expect(summary.reason).toBe("gone")
		expect(Rating(w, alice, alice, 1)).toBe(1516)
		expect(Rating(w, alice, bob, 1)).toBe(1484)
	end)

	it("reloading mid-match forfeits it, on every client", function()
		local w = World.New()
		local alice, bob = w:AddClient("Alice"), w:AddClient("Bob")
		w:Target(alice, bob); w:Slash(alice, "challenge bob"); w:Run(1)
		w:Slash(bob, "accept"); w:Run(1)
		w:Reload(alice)
		w:Run(1)
		expect(w:Printed(alice, "You left a match in progress")).toBeTruthy()
		expect(alice.ns.Session.state.lastSummary.forfeit).toBe("A")
		expect(bob.ns.Session.state.lastSummary.forfeit).toBe("A")
		expect(bob.ns.Session.state.lastSummary.reason).toBe("left")
		expect(Rating(w, alice, alice, 1)).toBe(1484)
		expect(Rating(w, bob, bob, 1)).toBe(1516)
		expect(alice.ns.db.activeMatch).toBe(nil)
	end)
end)

describe("forfeits in team matches", function()
	-- 2v2 in progress: Anna beat Bert in duel 1, so Arne vs Bo is up and nobody has requested it yet.
	local function SecondDuel()
		local w = World.New()
		local a1, a2, b1, b2 = w:AddClient("Anna"), w:AddClient("Arne"), w:AddClient("Bert"), w:AddClient("Bo")
		FormTeam(w, a1, { a2 })
		FormTeam(w, b1, { b2 })
		w:Target(a1, b1); w:Slash(a1, "challenge 2v2"); w:Run(1)
		w:PopupClick(b1, "accept"); w:Run(1)
		w:Duel(a1, b1); w:Run(1)
		expect(#MatchOf(a1).duels).toBe(2)
		return w, a1, a2, b1, b2
	end

	it("teammates read the result when the fighters' clients miss it", function()
		local w = World.New()
		local a1, a2, b1, b2 = w:AddClient("Anna"), w:AddClient("Arne"), w:AddClient("Bert"), w:AddClient("Bo")
		FormTeam(w, a1, { a2 })
		FormTeam(w, b1, { b2 })
		w:Target(a1, b1); w:Slash(a1, "challenge 2v2"); w:Run(1)
		w:PopupClick(b1, "accept"); w:Run(1)
		w:Duel(b1, a1, { a2, b2 }); w:Run(1)
		expect(MatchOf(a1).duels[1].winner).toBe("Bert-Testrealm")
		expect(#MatchOf(b1).duels).toBe(2)
	end)

	it("if auto-accept is blocked, the fighter who doesn't accept in time forfeits the match", function()
		local w, a1, a2, b1, b2 = SecondDuel()
		w.blockAutoAccept = true
		w:Target(a2, b2); w:Click(a2, "Start duel"); w:Run(1)
		expect(w:PopupText(b2)).toBe("Arne has challenged you to a duel.")
		w:Run(15)
		for _, c in ipairs({ a1, a2, b1, b2 }) do
			local summary = c.ns.Session.state.lastSummary
			expect(summary.forfeit).toBe("B")
			expect(summary.reason).toBe("stall")
			expect(summary.result).toBe("A")
		end
		expect(Rating(w, b2, b2, 2)).toBe(1484)
		expect(w:Printed(b1, "Match over: Defeat. Bert's team forfeited (the next duel didn't start in time).")).toBeTruthy()
	end)

	it("the scheduled opponent's request is accepted automatically, which stops the clock", function()
		local w, a1, a2, _, b2 = SecondDuel()
		w:Target(a2, b2); w:Click(a2, "Start duel"); w:Run(1)
		expect(b2.duelAccepts).toBe(1)
		expect(w:PopupText(b2)).toBe(nil)
		w:Run(130)
		expect(MatchOf(a1) ~= nil).toBeTruthy()
		w:Duel(a2, b2); w:Run(1)
		expect(a1.ns.Session.state.lastSummary.result).toBe("A")
		expect(a1.ns.Session.state.lastSummary.status).toBe("completed")
	end)

	it("when nobody sends the request, both teams forfeit and lose rating", function()
		local w, a1, _, b1 = SecondDuel()
		w:Run(15)
		local summary = a1.ns.Session.state.lastSummary
		expect(summary.forfeit).toBe("both")
		expect(summary.result).toBe("none")
		expect(Rating(w, a1, a1, 2)).toBe(1484)
		expect(Rating(w, a1, b1, 2)).toBe(1484)
		expect(Rating(w, b1, b1, 2)).toBe(1484)
	end)

	it("a player who goes offline forfeits for their team", function()
		local w, a1, a2, b1, b2 = SecondDuel()
		w:Disconnect(b2)
		w:Run(5) -- the forfeit goes out through the paced send queue
		for _, c in ipairs({ a1, a2, b1 }) do
			expect(c.ns.Session.state.lastSummary.forfeit).toBe("B")
			expect(c.ns.Session.state.lastSummary.reason).toBe("offline")
		end
		expect(Rating(w, a1, a1, 2)).toBe(1516)
	end)

	it("a request that arrives with under 3 s left puts the clock back to 3 s", function()
		local w, a1, a2, _, b2 = SecondDuel()
		w.blockAutoAccept = true
		local cd = b2.ns.Session.state.countdown
		while cd.remaining >= 3 do w:Run(0.1) end -- just ticked: the next tick is ~2 s away
		w:Target(a2, b2); w:Click(a2, "Start duel"); w:Run(0.3)
		expect(b2.ns.Session.state.countdown.remaining).toBe(3)
		expect(a2.ns.Session.state.countdown.remaining).toBe(3)
		expect(MatchOf(a1) ~= nil).toBeTruthy()
		w:PopupClick(b2, "accept"); w:Run(1)
		w:Run(10)
		expect(MatchOf(a1) ~= nil).toBeTruthy() -- accepted in the grace: no forfeit
	end)

	it("a fighter who moves away while the other walks up forfeits", function()
		local w, a1, a2, b1, b2 = SecondDuel()
		w.pos.Arne, w.pos.Bo = { 0, 0 }, { 40, 0 }
		for i = 1, 8 do
			w.pos.Arne, w.pos.Bo = { 3 * i, 0 }, { 40 + 3 * i, 0 }
			w:Run(1)
		end
		w:Run(3)
		for _, c in ipairs({ a1, a2, b1, b2 }) do
			expect(c.ns.Session.state.lastSummary.forfeit).toBe("B")
			expect(c.ns.Session.state.lastSummary.reason).toBe("avoid")
		end
		expect(w:Printed(b1, "a fighter moved away from their opponent")).toBeTruthy()
	end)

	it("walking up to each other takes longer than 10 s without a forfeit", function()
		local w, a1, a2, _, b2 = SecondDuel()
		w.pos.Arne, w.pos.Bo = { 0, 0 }, { 60, 0 }
		for i = 1, 18 do -- both walk in at ~1.5 yd/s
			w.pos.Arne, w.pos.Bo = { 1.5 * i, 0 }, { 60 - 1.5 * i, 0 }
			w:Run(1)
		end
		expect(MatchOf(a1) ~= nil).toBeTruthy()
		w:Target(a2, b2); w:Click(a2, "Start duel"); w:Run(1)
		w:Duel(a2, b2); w:Run(1)
		expect(a1.ns.Session.state.lastSummary.status).toBe("completed")
	end)

	it("a forged forfeit for the other team is ignored", function()
		local w, a1, _, b1 = SecondDuel()
		local mid = MatchOf(a1).mid
		w:As(a1, function() a1.ns.Comm.Send(b1.name, "FORF", mid, { tm = "B", why = "offline" }) end)
		w:Run(1)
		expect(MatchOf(b1) ~= nil).toBeTruthy()
	end)
end)

describe("right-click Challenge", function()
	it("sits right below Duel with 1v1/2v2/3v3, and 1v1 sends the challenge", function()
		local w = World.New()
		local alice, bob = w:AddClient("Alice"), w:AddClient("Bob")
		w:Target(alice, bob)
		local top, sub = w:RightClickTarget(alice, { "Challenge", "1v1" })
		expect(top).toBe("Whisper,Invite,Trade,Duel,Challenge,Follow")
		expect(sub).toBe("1v1,2v2 (off),3v3 (off)") -- solo: only 1v1
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
		expect(w:Printed(a1, "Bo is not their party's leader")).toBeTruthy()
	end)

	it("3v3 to a leader without three players fails and tells the challenger", function()
		local w = World.New()
		local a1, a2, a3 = w:AddClient("Anna"), w:AddClient("Arne"), w:AddClient("Ada")
		local b1, b2 = w:AddClient("Bert"), w:AddClient("Bo")
		FormTeam(w, a1, { a2, a3 })
		FormTeam(w, b1, { b2 })
		w:Target(a1, b1); w:RightClickTarget(a1, { "Challenge", "3v3" }); w:Run(1)
		expect(b1.ns.Session.state.challengeIn).toBe(nil)
		expect(w:Printed(a1, "Bert's party has 2 player(s); a 3v3 needs 3.")).toBeTruthy()
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

	it("greys out formats that don't match our party", function()
		local w = World.New()
		local a1, a2, a3, b1 = w:AddClient("Anna"), w:AddClient("Arne"), w:AddClient("Ada"), w:AddClient("Bert")
		w:Target(a1, b1)
		FormTeam(w, a1, { a2 })
		expect(select(2, w:RightClickTarget(a1, { "Challenge" }))).toBe("1v1,2v2,3v3 (off)")
		FormTeam(w, a1, { a2, a3 })
		expect(select(2, w:RightClickTarget(a1, { "Challenge" }))).toBe("1v1,2v2 (off),3v3")
		w:Target(a2, b1)
		expect(select(2, w:RightClickTarget(a2, { "Challenge" }))).toBe("1v1,2v2 (off),3v3 (off)") -- not the leader
	end)

	it("refuses (and explains) the wrong size from the slash command", function()
		local w = World.New()
		local alice, bob = w:AddClient("Alice"), w:AddClient("Bob")
		w:Target(alice, bob); w:Slash(alice, "challenge 2v2"); w:Run(1)
		expect(bob.ns.Session.state.challengeIn).toBe(nil)
		expect(w:Printed(alice, "Your party has 1 player(s); a 2v2 needs exactly 2.")).toBeTruthy()
	end)

	it("2v2/3v3 need every party member within 20 yards of their leader", function()
		local w = World.New()
		local a1, a2, b1, b2 = w:AddClient("Anna"), w:AddClient("Arne"), w:AddClient("Bert"), w:AddClient("Bo")
		FormTeam(w, a1, { a2 })
		FormTeam(w, b1, { b2 })
		w.dist.Arne = 21
		w:Target(a1, b1); w:RightClickTarget(a1, { "Challenge", "2v2" }); w:Run(1)
		expect(b1.ns.Session.state.challengeIn).toBe(nil)
		expect(w:Printed(a1, "Arne must be within 20 yards of you first.")).toBeTruthy()
		w.dist.Arne, w.dist.Bo = 20, 25
		w:RightClickTarget(a1, { "Challenge", "2v2" }); w:Run(1)
		expect(b1.ns.Session.state.challengeIn).toBe(nil)
		expect(w:Printed(a1, "Bert's party isn't gathered")).toBeTruthy()
	end)

	it("a party member without the addon blocks 2v2", function()
		local w = World.New()
		local a1, a2, b1 = w:AddClient("Anna"), w:AddClient("Arne"), w:AddClient("Bert")
		w.opts.dropIf = function(msg) return msg.from == a2.name end -- Arne's addon never answers
		FormTeam(w, a1, { a2 })
		w:Target(a1, b1); w:Slash(a1, "challenge 2v2"); w:Run(1)
		expect(w:Printed(a1, "Arne doesn't have TeamDuel running")).toBeTruthy()
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
		expect(w:Printed(b1, "was accepted with the challenge")).toBeTruthy()
		expect(w:Printed(a1, "was accepted with the challenge")).toBeTruthy()
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
		expect(w:Printed(a1, "Bert's party has 1 player(s); a 3v3 needs 3.")).toBeTruthy()
		expect(w:Printed(b1, "Your party has 1 player(s); a 3v3 needs exactly 3.")).toBeTruthy()
	end)

	it("a team that shrinks after the challenge can't accept", function()
		local w = World.New()
		local a1, a2, b1, b2 = w:AddClient("Anna"), w:AddClient("Arne"), w:AddClient("Bert"), w:AddClient("Bo")
		FormTeam(w, a1, { a2 })
		FormTeam(w, b1, { b2 })
		w:Target(a1, b1); w:Slash(a1, "challenge 2v2"); w:Run(1)
		w:Ungroup(b2); w:Run(1)
		w:Slash(b1, "accept"); w:Run(1)
		expect(MatchOf(b1)).toBe(nil)
		expect(w:Printed(b1, "Your party has 1 player(s); a 2v2 needs exactly 2.")).toBeTruthy()
	end)
end)

describe("player tooltip ratings", function()
	it("shows a hovered player's ratings once their addon answers, and caches them", function()
		local w = World.New()
		local alice, bob = w:AddClient("Alice"), w:AddClient("Bob")
		w:As(bob, function() bob.ns.DB.SetRating(bob.ns.db, bob.name, 1, 1530) end)
		w:Hover(alice, bob)
		expect(w:TooltipText(alice)).toBe("Bob")
		w:Run(1)
		expect(w:TooltipText(alice)).toBe("Bob / TeamDuel: 1v1 1530  2v2 1500  3v3 1500")
		-- Bob learned Alice's ratings from the request, so his tooltip needs no round trip.
		w:Hover(bob, alice)
		expect(w:TooltipText(bob)).toBe("Alice / TeamDuel: 1v1 1500  2v2 1500  3v3 1500")
		w:Hover(alice, nil); w:Hover(alice, bob)
		expect(w:TooltipText(alice)).toBe("Bob / TeamDuel: 1v1 1530  2v2 1500  3v3 1500")
	end)

	it("shows 0 for a player without the addon", function()
		local w = World.New()
		local alice = w:AddClient("Alice")
		w:Hover(alice, { short = "Nobody" })
		w:Run(2)
		expect(w:TooltipText(alice)).toBe("Nobody")
		w:Run(1.5)
		expect(w:TooltipText(alice)).toBe("Nobody / TeamDuel: 1v1 0  2v2 0  3v3 0")
	end)

	it("shows our own ratings without asking anyone", function()
		local w = World.New()
		local alice = w:AddClient("Alice")
		w:Hover(alice, alice)
		expect(w:TooltipText(alice)).toBe("Alice / TeamDuel: 1v1 1500  2v2 1500  3v3 1500")
		expect(#w.bus).toBe(0)
	end)

	it("only adds the line for the player still shown, asking a quickly-hovered one after the gap", function()
		local w = World.New()
		local alice, bob, carl = w:AddClient("Alice"), w:AddClient("Bob"), w:AddClient("Carl")
		w:Hover(alice, bob)
		w:Hover(alice, carl) -- within the 1 s request gap: Carl is asked once it's over
		w:Run(0.5)
		expect(w:TooltipText(alice)).toBe("Carl")
		w:Run(1)
		expect(w:TooltipText(alice)).toBe("Carl / TeamDuel: 1v1 1500  2v2 1500  3v3 1500")
	end)
end)
