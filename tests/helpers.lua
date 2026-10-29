-- Loads the pure addon modules into a fresh namespace, in TOC order.
local PURE = { "Util", "Config", "Protocol", "Rating", "Match", "DuelResult", "Position", "DB" }

function LoadPure()
	local ns = {}
	for _, name in ipairs(PURE) do
		LoadAddonFile("src/TeamDuel/" .. name .. ".lua", ns)
	end
	return ns
end
