--[[
	PLAY3 SDK - Chat Capture (standalone Server Script)
	Server-side intercept of every TextChatService message via
	TextChannel.ShouldDeliverCallback. Filtered text only; whispers excluded.

	ShouldDeliverCallback fires once per (message, recipient). We dedupe by
	message.MessageId so each message is captured exactly once.
]]

local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

if not RunService:IsRunning() then
	return
end

local Config = require(script.Parent.Parent.Config)
local PlayerState = require(script.Parent.Parent.Core.PlayerState)
local HttpQueue = require(script.Parent.Parent.Core.HttpQueue)

-- Locked defaults — devs only see ENABLE_CHAT_CAPTURE in Config.
local SDK_VERSION = "1.0.0"
local FLUSH_INTERVAL = 30      -- seconds
local BATCH_MAX = 100          -- force-flush at this many buffered messages
local MAX_TEXT_LENGTH = 500    -- truncate before send
local INCLUDE_WHISPERS = false -- per-minor-audience policy: off
local DEDUPE_TTL = 60          -- seconds to remember a MessageId

local function log(...)
	if Config.debug then
		print("[PLAY3 Chat]", ...)
	end
end

local function getIsoTimestampUTC()
	return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local buffer = {}
local seenMessageIds = {} -- [messageId] = expiryEpoch

local function flush()
	if #buffer == 0 then
		return
	end

	local messages = buffer
	buffer = {}

	HttpQueue.sendToAttribution("/api/deeplinks/chats", {
		gameId = tostring(game.GameId),
		timestamp = getIsoTimestampUTC(),
		instanceId = game.JobId,
		sdkVersion = SDK_VERSION,
		messages = messages,
	}, {
		onSuccess = function()
			log("Flushed", #messages, "messages")
		end,
		onError = function(err)
			warn("[PLAY3 Chat] Flush failed:", err)
		end,
	})
end

local function captureMessage(message)
	local source = message.TextSource
	if not source then
		return -- system / unauthored
	end

	local channel = message.TextChannel
	local channelName = channel and channel.Name or ""
	if not INCLUDE_WHISPERS and channelName:sub(1, 11) == "RBXWhisper:" then
		return
	end

	local text = message.Text or ""
	if #text > MAX_TEXT_LENGTH then
		text = text:sub(1, MAX_TEXT_LENGTH)
	end

	table.insert(buffer, {
		playerId = PlayerState.getVisitorIdByUserId(source.UserId),
		sessionId = PlayerState.getSessionIdByUserId(source.UserId),
		messageId = message.MessageId,
		text = text,
		textLength = #text,
		channel = channelName,
		timestamp = getIsoTimestampUTC(),
	})

	if #buffer >= BATCH_MAX then
		task.spawn(flush)
	end
end

local function setupChannel(channel)
	-- Roblox callback properties are write-only, so we can't chain. If the
	-- brand needs their own ShouldDeliverCallback, they should set it BEFORE
	-- the SDK loads, or wrap the SDK's capture logic in theirs.
	channel.ShouldDeliverCallback = function(message, recipientSource)
		local id = message.MessageId
		if id and not seenMessageIds[id] then
			seenMessageIds[id] = os.time() + DEDUPE_TTL
			captureMessage(message)
		end
		return true
	end
end

if Config.ENABLE_CHAT_CAPTURE then
	for _, descendant in ipairs(TextChatService:GetDescendants()) do
		if descendant:IsA("TextChannel") then
			setupChannel(descendant)
		end
	end

	TextChatService.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("TextChannel") then
			setupChannel(descendant)
		end
	end)

	-- Periodic flush
	task.spawn(function()
		while true do
			task.wait(FLUSH_INTERVAL)
			flush()
		end
	end)

	-- Periodic eviction of the dedupe set
	task.spawn(function()
		while true do
			task.wait(DEDUPE_TTL)
			local now = os.time()
			for id, expiry in pairs(seenMessageIds) do
				if expiry < now then
					seenMessageIds[id] = nil
				end
			end
		end
	end)

	game:BindToClose(function()
		flush()
		task.wait(1) -- let HttpQueue drain
	end)

	log("Chat capture started (flush:", FLUSH_INTERVAL, "s, batch max:", BATCH_MAX, ")")
end
