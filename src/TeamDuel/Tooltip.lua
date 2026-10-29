-- Unit tooltips: a "TeamDuel" line under a player's name with their 1v1/2v2/3v3 ratings.
-- Other players' ratings are what their own addon reports when we hover them (RREQ -> RINF): stored on their
-- computer and self-reported, so they are for display only and never feed a match. A player whose addon
-- doesn't answer within Config.TOOLTIP_NO_REPLY seconds is shown with 0 (decided by the user).
-- UNVERIFIED on Forever: the OnTooltipSetUnit script, GameTooltip:GetUnit, and adding a line to a shown tooltip.
local _, ns = ...
local Tooltip = {}
ns.Tooltip = Tooltip

local Util = ns.Util

local NO_ADDON = { 0, 0, 0 }

local known = {}       -- [name] = { ratings = { r1, r2, r3 }, at = GetTime() }
local asked = {}       -- [name] = GetTime() of our last RREQ to them
local answered = {}    -- [name] = GetTime() of our last RINF to them
local lastAsk = -math.huge
local waiting = nil    -- { tooltip, name }: a shown tooltip still missing our line

local function OwnRatings()
	local me = ns.Me()
	return { ns.DB.GetRating(ns.db, me, 1), ns.DB.GetRating(ns.db, me, 2), ns.DB.GetRating(ns.db, me, 3) }
end

local function OwnFields()
	local r = OwnRatings()
	return { r1 = r[1], r2 = r[2], r3 = r[3] }
end

function Tooltip.Line(ratings)
	return ("TeamDuel: 1v1 %d  2v2 %d  3v3 %d"):format(ratings[1], ratings[2], ratings[3])
end

function Tooltip.RatingsOf(name)
	if name == ns.Me() then return OwnRatings() end
	return known[name] and known[name].ratings
end

local function AddLine(tooltip, ratings)
	tooltip:AddLine(Tooltip.Line(ratings), 1, 0.82, 0)
	tooltip:Show() -- resize to fit the new line
end

-- Full name of the player a tooltip shows, or nil (not a player, nothing readable).
local function TooltipPlayer(tooltip)
	local ok, _, unit = pcall(tooltip.GetUnit, tooltip)
	if not ok then return nil end
	if unit == nil then unit = "mouseover" end
	if not Util.IsReadable(unit) or type(unit) ~= "string" then return nil end
	local isPlayer = UnitIsPlayer(unit)
	if not Util.IsReadable(isPlayer) or not isPlayer then return nil end
	return ns.Session.UnitFullNameOf(unit)
end

-- Adds the line to a tooltip that was shown before the ratings arrived, if it still shows that player.
local function Update(name)
	if not waiting or waiting.name ~= name then return end
	local tooltip = waiting.tooltip
	if not tooltip:IsShown() or TooltipPlayer(tooltip) ~= name then
		waiting = nil
		return
	end
	waiting = nil
	AddLine(tooltip, Tooltip.RatingsOf(name))
end

-- Whispers our ratings to a hovered player and asks for theirs. Paced so hovering a crowd can't flood the
-- comm queue that challenges and results share.
local function Ask(name)
	local cfg, now = ns.Config, GetTime()
	if known[name] and now - known[name].at < cfg.TOOLTIP_REFRESH then return end
	if asked[name] and now - asked[name] < cfg.TOOLTIP_REFRESH then return end
	if now - lastAsk < cfg.TOOLTIP_ASK_GAP then
		-- Too soon after the last request: try again when the gap is over, if we're still showing them.
		C_Timer.After(cfg.TOOLTIP_ASK_GAP - (now - lastAsk), function()
			if waiting and waiting.name == name then Ask(name) end
		end)
		return
	end
	if InCombatLockdown() then return end
	if not ns.Comm.Send(name, "RREQ", "-", OwnFields()) then return end
	asked[name], lastAsk = now, now
	C_Timer.After(cfg.TOOLTIP_NO_REPLY, function()
		if known[name] and known[name].at >= now then return end
		-- No answer: no addon (or offline, or another faction). Keep an older real answer if we have one.
		if not known[name] then known[name] = { ratings = NO_ADDON, at = GetTime() } end
		Update(name)
	end)
end

local function OnTooltipSetUnit(tooltip)
	if waiting and waiting.tooltip == tooltip then waiting = nil end
	local name = TooltipPlayer(tooltip)
	if not name then return end
	local ratings = Tooltip.RatingsOf(name)
	if ratings then
		AddLine(tooltip, ratings)
	else
		waiting = { tooltip = tooltip, name = name }
	end
	if name ~= ns.Me() then Ask(name) end
end

-- A player's ratings arrived: RREQ (they hovered us; answer them), RINF (their answer) or TRAT (party member).
function Tooltip.OnRatings(from, fields, wantsReply)
	known[from] = { ratings = { fields.r1, fields.r2, fields.r3 }, at = GetTime() }
	if wantsReply then
		local now = GetTime()
		if not answered[from] or now - answered[from] >= ns.Config.TOOLTIP_ASK_GAP then
			answered[from] = now
			ns.Comm.Send(from, "RINF", "-", OwnFields())
		end
	end
	Update(from)
end

function Tooltip.Init()
	local function Safe(tooltip)
		local ok, err = pcall(OnTooltipSetUnit, tooltip)
		if not ok then ns.Log("error", "tooltip", err) end
	end
	local ok, err = false, "no tooltip hook available"
	if GameTooltip and GameTooltip.HookScript then
		ok, err = pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit", Safe)
	end
	if not ok and TooltipDataProcessor and Enum and Enum.TooltipDataType then
		ok, err = pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Unit, Safe)
	end
	if not ok then ns.Log("warn", "player tooltips show no rating:", err) end
end
