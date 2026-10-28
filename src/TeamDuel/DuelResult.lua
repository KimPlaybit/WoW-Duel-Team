-- Reads the duel winner from system chat text. Pure.
-- Blizzard's global strings are format strings such as (Classic wording, UNVERIFIED on Forever):
--   DUEL_WINNER_KNOCKOUT = "%1$s has defeated %2$s in a duel"
--   DUEL_WINNER_RETREAT  = "%2$s has fled from %1$s in a duel"
-- In both, argument 1 is the winner and argument 2 the loser. The strings are read at runtime,
-- so localized clients work without hardcoded English.
local _, ns = ...
local DuelResult = {}
ns.DuelResult = DuelResult

local MAGIC = "^[%^%$%(%)%%%.%[%]%*%+%-%?]$"

-- Turns a format string into { pattern = <Lua pattern>, slots = { argIndex per capture } }.
function DuelResult.Compile(formatString)
	if type(formatString) ~= "string" or formatString == "" then return nil end
	local pattern, slots, nextAuto = "^", {}, 0
	local i = 1
	while i <= #formatString do
		local argIndex, after = string.match(formatString, "^%%(%d)%$s()", i)
		if argIndex then
			slots[#slots + 1] = tonumber(argIndex)
			pattern = pattern .. "(.+)"
			i = after
		elseif string.sub(formatString, i, i + 1) == "%s" then
			nextAuto = nextAuto + 1
			slots[#slots + 1] = nextAuto
			pattern = pattern .. "(.+)"
			i = i + 2
		else
			local c = string.sub(formatString, i, i)
			pattern = pattern .. (string.match(c, MAGIC) and ("%" .. c) or c)
			i = i + 1
		end
	end
	if #slots == 0 then return nil end
	return { pattern = pattern .. "$", slots = slots }
end

-- Returns args indexed by format-argument number, or nil.
function DuelResult.Parse(compiled, text)
	if not compiled or type(text) ~= "string" then return nil end
	local captures = { string.match(text, compiled.pattern) }
	if #captures ~= #compiled.slots then return nil end
	local args = {}
	for i, slot in ipairs(compiled.slots) do args[slot] = captures[i] end
	return args
end

-- compiledList: { { compiled = ..., how = "knockout" | "retreat" } }. Returns winner, loser, how.
function DuelResult.FromSystemMessage(compiledList, text)
	for _, entry in ipairs(compiledList) do
		local args = DuelResult.Parse(entry.compiled, text)
		if args and args[1] and args[2] then
			return args[1], args[2], entry.how
		end
	end
	return nil
end

-- Maps a name from the system message (short or Name-Realm) to one of the two fighters.
-- Returns nil when it matches neither or is ambiguous.
function DuelResult.ResolveFighter(name, fighterA, fighterB)
	if name == fighterA or name == fighterB then return name end
	local Util = ns.Util
	local short = Util.ShortName(name)
	local matchA = short == Util.ShortName(fighterA)
	local matchB = short == Util.ShortName(fighterB)
	if matchA and not matchB then return fighterA end
	if matchB and not matchA then return fighterB end
	return nil
end
