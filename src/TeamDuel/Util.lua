-- Small pure helpers. No WoW API calls at load time; safe to load in unit tests.
local _, ns = ...
local Util = {}
ns.Util = Util

-- True when v can be inspected: not nil and not a secret value (Midnight/Forever restriction model).
function Util.IsReadable(v)
	if v == nil then return false end
	if issecretvalue and issecretvalue(v) then return false end
	return true
end

-- Plain-text split. Util.Split("", ",") returns an empty list.
function Util.Split(s, sep)
	local out = {}
	if s == nil or s == "" then return out end
	local start = 1
	while true do
		local i = string.find(s, sep, start, true)
		if not i then
			out[#out + 1] = string.sub(s, start)
			return out
		end
		out[#out + 1] = string.sub(s, start, i - 1)
		start = i + #sep
	end
end

-- Canonical player key "Name-Realm". Adds defaultRealm when name has none.
function Util.FullName(name, defaultRealm)
	if type(name) ~= "string" or name == "" then return nil end
	if string.find(name, "-", 1, true) then return name end
	if type(defaultRealm) ~= "string" or defaultRealm == "" then return nil end
	return name .. "-" .. defaultRealm
end

function Util.ShortName(fullName)
	if type(fullName) ~= "string" then return nil end
	return (string.match(fullName, "^([^%-]+)"))
end

-- "bob" -> "Bob"; leaves non-ASCII bytes untouched.
function Util.CapitalizeName(name)
	if type(name) ~= "string" or name == "" then return name end
	local short, realm = string.match(name, "^([^%-]+)%-(.+)$")
	short = short or name
	short = string.upper(string.sub(short, 1, 1)) .. string.lower(string.sub(short, 2))
	return realm and (short .. "-" .. realm) or short
end

function Util.IndexOf(list, value)
	for i, v in ipairs(list) do
		if v == value then return i end
	end
	return nil
end

function Util.Copy(list)
	local out = {}
	for i, v in ipairs(list) do out[i] = v end
	return out
end

function Util.DeepCopy(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for k, v in pairs(value) do out[Util.DeepCopy(k)] = Util.DeepCopy(v) end
	return out
end

function Util.ListEquals(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do
		if a[i] ~= b[i] then return false end
	end
	return true
end

function Util.Round(x)
	if x >= 0 then return math.floor(x + 0.5) end
	return -math.floor(-x + 0.5)
end
