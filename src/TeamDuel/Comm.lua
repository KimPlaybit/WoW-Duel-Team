-- Addon-message transport: WHISPER to each participant (works without a group), paced send queue,
-- ACK + retry for critical messages, de-duplication. Payload rules live in Protocol.lua.
-- UNVERIFIED on Forever: whisper delivery between ungrouped players, throttle limits, lockdown
-- during duels. Every send result is logged so in-game tests can tell.
local _, ns = ...
local Comm = {}
ns.Comm = Comm

local RELIABLE = { TINV = true, TJOIN = true, TLEAVE = true, CHAL = true, ACC = true, DEC = true, RES = true, ABORT = true }

local queue = {}      -- { target, text }
local pending = {}    -- [seq] = { target, text, type, tries, sentAt }
local seen = {}       -- [sender] = { [seq] = true }
local tokens, lastRefill = 0, 0
local epoch, counter = 0, 0
local pumpScheduled = false

local function SendSucceeded(result)
	if result == true then return true end -- older clients returned a boolean
	local enum = Enum and Enum.SendAddonMessageResult
	return result == ((enum and enum.Success) or 0)
end

local function Pump()
	local cfg = ns.Config
	local now = GetTime()
	tokens = math.min(cfg.COMM_BURST, tokens + (now - lastRefill) * cfg.COMM_RATE)
	lastRefill = now
	while #queue > 0 and tokens >= 1 do
		local item = table.remove(queue, 1)
		tokens = tokens - 1
		local ok, result = pcall(C_ChatInfo.SendAddonMessage, cfg.PREFIX, item.text, "WHISPER", item.target)
		if not ok or not SendSucceeded(result) then
			ns.Log("warn", "send failed to", item.target, "result", result)
		else
			ns.Log("debug", "sent", item.target, item.text)
		end
	end
	if #queue > 0 and not pumpScheduled then
		pumpScheduled = true
		C_Timer.After(0.25, function()
			pumpScheduled = false
			Pump()
		end)
	end
end

local function Enqueue(target, text)
	queue[#queue + 1] = { target = target, text = text }
	Pump()
end

local function RetryPending()
	local now = GetTime()
	for seq, p in pairs(pending) do
		if now - p.sentAt >= ns.Config.ACK_TIMEOUT then
			if p.tries > ns.Config.MAX_RETRIES then
				pending[seq] = nil
				ns.Log("warn", "no ACK from", p.target, "for", p.type)
				ns.Session.OnPeerUnreachable(p.target, p.type)
			else
				p.tries = p.tries + 1
				p.sentAt = now
				Enqueue(p.target, p.text)
			end
		end
	end
end

function Comm.Init()
	epoch = GetServerTime()
	tokens, lastRefill = ns.Config.COMM_BURST, GetTime()
	local result = C_ChatInfo.RegisterAddonMessagePrefix(ns.Config.PREFIX)
	ns.Log("info", "registered prefix", ns.Config.PREFIX, "result", result)
	ns.On("CHAT_MSG_ADDON", Comm.OnAddonMessage)
	C_Timer.NewTicker(1, RetryPending)
end

-- Returns true if queued. Messages to ourselves are dropped; callers apply their own events locally.
function Comm.Send(target, msgType, mid, fields)
	if target == ns.Me() then return true end
	counter = counter + 1
	local seq = epoch .. ":" .. counter
	local text, err = ns.Protocol.Encode({ type = msgType, mid = mid or "-", seq = seq, fields = fields or {} }, ns.MyRealm())
	if not text then
		ns.Log("error", "cannot encode", msgType, "for", target, err)
		return false
	end
	if RELIABLE[msgType] then
		pending[seq] = { target = target, text = text, type = msgType, tries = 1, sentAt = GetTime() }
	end
	Enqueue(target, text)
	return true
end

function Comm.SendToAll(names, msgType, mid, fields)
	local ok = true
	for _, name in ipairs(names) do
		ok = Comm.Send(name, msgType, mid, fields) and ok
	end
	return ok
end

function Comm.OnAddonMessage(prefix, text, _, sender)
	if prefix ~= ns.Config.PREFIX then return end
	if not (ns.Util.IsReadable(text) and ns.Util.IsReadable(sender)) then
		ns.Log("warn", "addon message payload is secret; ignored")
		return
	end
	local from = ns.Util.FullName(sender, ns.MyRealm())
	if not from or from == ns.Me() then return end
	local senderRealm = string.match(from, "%-(.+)$")

	local msg, err = ns.Protocol.Decode(text, senderRealm)
	if not msg then
		ns.Log("warn", "dropped message from", from, err)
		return
	end

	if msg.type == "ACK" then
		local p = pending[msg.fields.ack]
		if p and p.target == from then pending[msg.fields.ack] = nil end
		return
	end

	-- ACK every reliable message, including duplicates: our earlier ACK may have been lost.
	if RELIABLE[msg.type] then
		Comm.Send(from, "ACK", "-", { ack = msg.seq })
	end
	seen[from] = seen[from] or {}
	if seen[from][msg.seq] then return end
	seen[from][msg.seq] = true

	ns.Log("debug", "recv", from, text)
	ns.Session.OnMessage(from, msg)
end
