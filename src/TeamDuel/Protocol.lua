-- Wire format and validation for addon messages. Pure; see .claude/skills/duel-addon-comms.
--
--   version|TYPE|matchId|seq|key=value;key=value
--
-- Lists are comma-separated. Every incoming message is fully parsed and type-checked here;
-- anything malformed, oversized, or inconsistent is rejected with a reason.
--
-- To fit 3v3 rosters in 255 bytes, player names on the SENDER's realm travel without "-Realm";
-- Decode needs the sender's realm to expand them back to canonical "Name-Realm".
local _, ns = ...
local Protocol = {}
ns.Protocol = Protocol

local Util = ns.Util
local MAX_LEN = 255
local NAME_PATTERN = "^[^%-,;|=:%s]+%-[^%-,;|=:%s]+$"
local SHORT_NAME_PATTERN = "^[^%-,;|=:%s]+$"
local NAME_FIELDS = { a = true, b = true, w = true }

local function Int(lo, hi)
	return function(s)
		local n = tonumber(s)
		if n and n == math.floor(n) and n >= lo and n <= hi then return n end
	end
end

local function Name(s)
	if string.match(s, NAME_PATTERN) or string.match(s, SHORT_NAME_PATTERN) then return s end
end

local function OneOf(set)
	return function(s)
		if set[s] then return s end
	end
end

local function Word(s)
	if #s <= 32 and string.match(s, "^[%w_]+$") then return s end
end

local function Seq(s)
	if string.match(s, "^%d+:%d+$") then return s end
end

local function List(item, maxCount)
	return function(s)
		local parts = Util.Split(s, ",")
		if #parts == 0 or #parts > maxCount then return nil end
		local out = {}
		for i, p in ipairs(parts) do
			local v = item(p)
			if v == nil then return nil end
			out[i] = v
		end
		return out
	end
end

local Rating = Int(0, 9999)

-- World coordinates in yards, at most one decimal.
local function Coord(s)
	if #s <= 10 and string.match(s, "^%-?%d+%.?%d?$") then return tonumber(s) end
end

local FIELDS = {
	fmt = Int(1, 3),
	pg = OneOf({ pairs = true, winnerStays = true }),
	a = List(Name, 3),
	b = List(Name, 3),
	ra = List(Rating, 3),
	rb = List(Rating, 3),
	li = Int(1, 3),
	exp = Int(0, 2147483647),
	d = Int(1, 9),
	w = Name,
	t = Int(0, 99),
	src = OneOf({ auto = true }),
	s = OneOf({ rcv = true, acc = true, rerun = true }),
	da = Int(0, 1),
	tm = OneOf({ A = true, B = true, both = true }),
	x = Coord,
	y = Coord,
	mp = Int(0, 99999999),
	why = Word,
	ack = Seq,
	r1 = Rating,
	r2 = Rating,
	r3 = Rating,
}

-- Required fields per message type, in wire order.
local SCHEMA = {
	TRAT = { "r1", "r2", "r3" },                     -- party member -> party leader: own 1v1/2v2/3v3 ratings
	RREQ = { "r1", "r2", "r3" },                     -- tooltip: here are mine, what are yours?
	RINF = { "r1", "r2", "r3" },                     -- tooltip: the answer to RREQ
	CHAL = { "fmt", "pg", "a", "ra", "exp" },        -- challenge: team a in fighter order + ratings
	ACC = { "fmt", "pg", "a", "ra", "b", "rb", "li", "da" }, -- accept: both rosters, li = index of challenging
	                                                 -- leader in a, da = 1 if the first duel was accepted with it
	DEC = { "why" },                                 -- decline
	RES = { "d", "w", "t", "src" },                  -- duel d result: winner w, attempt t (from any player in the match)
	DST = { "d", "t", "s" },                         -- fighter: duel d attempt t request received / accepted / rerun
	FORF = { "tm", "why" },                          -- team tm forfeits: from its own member (offline, left), or
	                                                 -- from a current fighter (avoid, stall: the countdown)
	POS = { "x", "y", "mp" },                        -- fighter -> opposing fighter: my position during the countdown
	PING = {},                                       -- still here (during a match)
	ACK = { "ack" },
}
Protocol.SCHEMA = SCHEMA

local NEEDS_MATCH_ID = { CHAL = true, ACC = true, DEC = true, RES = true, DST = true, FORF = true, PING = true, POS = true }

local CONSISTENCY = {
	CHAL = function(f)
		return #f.a == f.fmt and #f.ra == f.fmt
	end,
	ACC = function(f)
		return #f.a == f.fmt and #f.ra == f.fmt and #f.b == f.fmt and #f.rb == f.fmt and f.li <= f.fmt
	end,
}

local function ExpandName(name, realm)
	if string.find(name, "-", 1, true) then return name end
	if not realm then return nil end
	return name .. "-" .. realm
end

local function CompactName(name, realm)
	if realm then
		local short, nameRealm = string.match(name, "^([^%-]+)%-(.+)$")
		if nameRealm == realm then return short end
	end
	return name
end

local function ValidMatchId(mid)
	return mid == "-" or (#mid <= 64 and string.match(mid, "^[^|;=,]+$") ~= nil)
end

-- senderRealm: normalized realm of the sending player (expands realm-less names).
function Protocol.Decode(text, senderRealm)
	if type(text) ~= "string" or #text == 0 or #text > MAX_LEN then return nil, "bad length" end
	local parts = Util.Split(text, "|")
	if #parts ~= 5 then return nil, "bad envelope" end
	local version, msgType, mid, seq, payload = parts[1], parts[2], parts[3], parts[4], parts[5]

	if tonumber(version) ~= ns.Config.PROTOCOL_VERSION then return nil, "unsupported version " .. version end
	local schema = SCHEMA[msgType]
	if not schema then return nil, "unknown type" end
	if not ValidMatchId(mid) then return nil, "bad match id" end
	if NEEDS_MATCH_ID[msgType] and mid == "-" then return nil, "missing match id" end
	if not Seq(seq) then return nil, "bad seq" end

	local raw = {}
	for _, pair in ipairs(Util.Split(payload, ";")) do
		local key, value = string.match(pair, "^(%w+)=(.*)$")
		if not key then return nil, "bad field" end
		if raw[key] then return nil, "duplicate field " .. key end
		raw[key] = value
	end

	-- Unknown keys are ignored (forward compatible within a protocol version); required keys must parse.
	local fields = {}
	for _, key in ipairs(schema) do
		if raw[key] == nil then return nil, "missing " .. key end
		local value = FIELDS[key](raw[key])
		if value == nil then return nil, "invalid " .. key end
		if NAME_FIELDS[key] then
			if type(value) == "table" then
				for i, name in ipairs(value) do
					value[i] = ExpandName(name, senderRealm)
					if not value[i] then return nil, "unqualified name in " .. key end
				end
			else
				value = ExpandName(value, senderRealm)
				if not value then return nil, "unqualified name in " .. key end
			end
		end
		fields[key] = value
	end
	if CONSISTENCY[msgType] and not CONSISTENCY[msgType](fields) then
		return nil, "inconsistent " .. msgType
	end

	return { type = msgType, mid = mid, seq = seq, fields = fields }
end

-- Builds the wire text. Round-trips through Decode so we never send what we would reject.
-- senderRealm: our own normalized realm; names on it are sent without the realm suffix.
function Protocol.Encode(msg, senderRealm)
	local schema = SCHEMA[msg.type]
	if not schema then return nil, "unknown type" end
	local parts = {}
	for _, key in ipairs(schema) do
		local v = msg.fields and msg.fields[key]
		if v == nil then return nil, "missing field " .. key end
		if type(v) == "table" then
			local items = {}
			for i, item in ipairs(v) do
				items[i] = NAME_FIELDS[key] and CompactName(item, senderRealm) or tostring(item)
			end
			v = table.concat(items, ",")
		elseif NAME_FIELDS[key] then
			v = CompactName(v, senderRealm)
		else
			v = tostring(v)
		end
		parts[#parts + 1] = key .. "=" .. v
	end
	local text = table.concat({
		tostring(ns.Config.PROTOCOL_VERSION), msg.type, msg.mid or "-", msg.seq, table.concat(parts, ";"),
	}, "|")
	local ok, err = Protocol.Decode(text, senderRealm)
	if not ok then return nil, err end
	return text
end
