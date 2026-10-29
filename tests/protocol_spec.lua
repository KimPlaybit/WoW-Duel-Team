local ns = LoadPure()
local P = ns.Protocol

local function chal()
	return {
		type = "CHAL", mid = "Alice-Realm:1700000000:1234", seq = "1700000000:1",
		fields = { fmt = 2, pg = "pairs", a = { "Alice-Realm", "Bob-Realm" }, ra = { 1500, 1620 }, exp = 1700000120 },
	}
end

describe("Protocol", function()
	it("round-trips a challenge", function()
		local text = assert(P.Encode(chal()))
		local msg = assert(P.Decode(text))
		expect(msg.type).toBe("CHAL")
		expect(msg.fields.fmt).toBe(2)
		expect(msg.fields.a[2]).toBe("Bob-Realm")
		expect(msg.fields.ra[2]).toBe(1620)
	end)

	it("round-trips a party member's ratings", function()
		local text = assert(P.Encode({ type = "TRAT", mid = "-", seq = "1:1", fields = { r1 = 1500, r2 = 1620, r3 = 1480 } }))
		local msg = P.Decode(text)
		expect(msg.type).toBe("TRAT")
		expect(msg.fields.r2).toBe(1620)
	end)

	it("rejects a roster that does not match the format", function()
		local m = chal()
		m.fields.fmt = 3
		local text, err = P.Encode(m)
		expect(text).toBe(nil)
		expect(err).toBe("inconsistent CHAL")
	end)

	it("rejects an accept whose challenging leader index is outside team A", function()
		local text, err = P.Encode({
			type = "ACC", mid = "1:1", seq = "1:2",
			fields = { fmt = 1, pg = "pairs", a = { "Alice-Realm" }, ra = { 1500 }, b = { "Carol-Realm" }, rb = { 1500 }, li = 2, da = 0 },
		})
		expect(text).toBe(nil)
		expect(err).toBe("inconsistent ACC")
	end)

	it("sends own-realm names without the realm and expands them on receipt", function()
		local text = assert(P.Encode(chal(), "Realm"))
		expect(string.find(text, "a=Alice,Bob;", 1, true) ~= nil).toBeTruthy()
		local msg = assert(P.Decode(text, "Realm"))
		expect(msg.fields.a[1]).toBe("Alice-Realm")
	end)

	it("keeps other-realm names qualified", function()
		local m = chal()
		m.fields.a = { "Alice-Realm", "Bob-Other" }
		local msg = assert(P.Decode(assert(P.Encode(m, "Realm")), "Realm"))
		expect(msg.fields.a[2]).toBe("Bob-Other")
	end)

	it("rejects realm-less names when the sender realm is unknown", function()
		local _, err = P.Decode("1|RES|m|1:1|d=1;w=Alice;t=0;src=auto")
		expect(err).toBe("unqualified name in w")
	end)

	it("rejects malformed input", function()
		expect(P.Decode(nil)).toBe(nil)
		expect(P.Decode("")).toBe(nil)
		expect(P.Decode(string.rep("x", 256))).toBe(nil)
		expect(P.Decode("1|CHAL|m|1:1")).toBe(nil)                    -- too few parts
		expect(P.Decode("2|TRAT|-|1:1|r1=1;r2=1;r3=1")).toBe(nil)      -- wrong version
		expect(P.Decode("1|HACK|-|1:1|")).toBe(nil)                   -- unknown type
		expect(P.Decode("1|TRAT|-|abc|r1=1;r2=1;r3=1")).toBe(nil)      -- bad seq
		expect(P.Decode("1|RES|-|1:1|d=1;w=A-R;t=0;src=auto")).toBe(nil) -- result without match id
	end)

	it("rejects bad field values", function()
		expect(P.Decode("1|RES|m|1:1|d=1;w=Bad Name-R;t=0;src=auto")).toBe(nil)
		expect(P.Decode("1|RES|m|1:1|d=0;w=A-R;t=0;src=auto")).toBe(nil)
		expect(P.Decode("1|RES|m|1:1|d=1;w=A-R;t=0;src=guess")).toBe(nil)
		expect(P.Decode("1|RES|m|1:1|d=1.5;w=A-R;t=0;src=auto")).toBe(nil)
		expect(P.Decode("1|TRAT|-|1:1|r1=1500;r2=1500")).toBe(nil)    -- missing r3
		expect(P.Decode("1|TRAT|-|1:1|r1=1;r1=2;r2=1;r3=1")).toBe(nil)  -- duplicate key
	end)

	it("ignores unknown extra fields", function()
		local msg = P.Decode("1|RES|m|1:1|d=1;w=A-R;t=0;src=auto;future=1")
		expect(msg ~= nil).toBeTruthy()
		expect(msg.fields.future).toBe(nil)
	end)

	it("refuses to encode values containing separators", function()
		local m = chal()
		m.fields.a = { "Al|ice-Realm", "Bob-Realm" }
		expect(P.Encode(m)).toBe(nil)
	end)

	local function acc3(realmOf)
		local a, b = {}, {}
		for i = 1, 3 do
			a[i] = "Abcdefghijk" .. i .. "-" .. realmOf(i)
			b[i] = "Bbcdefghijk" .. i .. "-" .. realmOf(i + 3)
		end
		return {
			type = "ACC", mid = "1700000000:999999", seq = "1700000000:42",
			fields = { fmt = 3, pg = "winnerStays", a = a, ra = { 2500, 2500, 2500 }, b = b, rb = { 2500, 2500, 2500 }, li = 1, da = 1 },
		}
	end

	it("fits a same-realm 3v3 accept with 12-character names in 255 bytes", function()
		local text = assert(P.Encode(acc3(function() return "Argentdawnrealmx" end), "Argentdawnrealmx"))
		expect(#text <= 255).toBeTruthy()
	end)

	it("fails loudly, not truncated, when a cross-realm roster is too long", function()
		local text, err = P.Encode(acc3(function(i) return "Verylongrealmname" .. i end), "Elsewhere")
		expect(text).toBe(nil)
		expect(err).toBe("bad length")
	end)
end)
