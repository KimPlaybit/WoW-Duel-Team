-- Minimal test runner for pure addon modules (no WoW API). Runs under LuaJIT (Lua 5.1).
--   luajit tests/run.lua            -- runs every tests/*_spec.lua listed below
-- A spec loads addon files with LoadAddonFile(path, ns), which mimics the WoW loader
-- passing (addonName, ns) as varargs.

local print = print -- tests/sim.lua replaces the global print to capture chat output
local passed, failed, current = 0, 0, ""

function describe(name, fn) current = name; fn() end

function it(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		print(("FAIL  %s > %s\n      %s"):format(current, name, tostring(err)))
	end
end

function expect(actual)
	return {
		toBe = function(expected)
			if actual ~= expected then
				error(("expected %s, got %s"):format(tostring(expected), tostring(actual)), 2)
			end
		end,
		toBeNear = function(expected, eps)
			if math.abs(actual - expected) > (eps or 1e-9) then
				error(("expected ~%s, got %s"):format(tostring(expected), tostring(actual)), 2)
			end
		end,
		toBeTruthy = function()
			if not actual then error("expected truthy, got " .. tostring(actual), 2) end
		end,
		toBeFalsy = function()
			if actual then error("expected falsy, got " .. tostring(actual), 2) end
		end,
	}
end

function LoadAddonFile(path, ns)
	local chunk = assert(loadfile(path))
	chunk("TeamDuel", ns)
	return ns
end

-- Specs are listed explicitly: plain Lua 5.1 can't list a directory without LuaFileSystem.
local SPECS = {
	"tests/runner_spec.lua",
	"tests/protocol_spec.lua",
	"tests/rating_spec.lua",
	"tests/match_spec.lua",
	"tests/duelresult_spec.lua",
	"tests/db_spec.lua",
	"tests/flow_spec.lua", -- last: installs fake WoW globals
}

dofile("tests/helpers.lua")

for _, spec in ipairs(SPECS) do dofile(spec) end
print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
