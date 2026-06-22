--[[
	PLAY3 SDK - Custom Metrics

	Lets game devs record arbitrary per-player metrics that flow to the brand's
	BigQuery dataset and surface in the Brand Dashboard. Three shapes:

		Metrics:Increment(player, key, value, attrs)
			Counter — adds `value` to the running total (e.g. coins_earned).
			Aggregates as SUM in the dashboard.

		Metrics:Set(player, key, value, attrs)
			Gauge — overwrites the current value (e.g. level, hp, inventory_size).
			Aggregates as LATEST per player.

		Metrics:Record(player, key, attrs)
			Event — fire-and-forget log row, no numeric value (e.g. boss_defeated).
			Aggregates as COUNT.

	REQUIRES:
		Config.ATTRIBUTION_API_KEY  (same gk_ key as the Attribution module)

	KEYS:
		`key` must match [a-z0-9_]{1,64} (snake_case). Invalid keys are dropped
		client-side with a warn() so you notice during dev. Define metric display
		names + units in the Brand Dashboard once the data starts flowing.

	ATTRIBUTION:
		Unlike Attribution:TrackMilestone, these calls work for ALL players —
		attributed or organic. The visitorId is the only player identifier sent.

	SYSTEM METRICS (auto-tracked):
		The SDK reserves the `_` prefix for built-in metrics and emits them
		automatically so brands can leaderboard against them without writing
		any game code. v1.1.0 ships:

			_playtime_seconds  counter, emitted every 30s with the delta playtime
			                   per active player. Picks up where SessionTracker
			                   leaves off — this one targets custom_metrics so it
			                   shows up in the Brand Dashboard metric dropdown.

		User-defined keys starting with `_` are rejected so app code can't
		collide with future system metrics.

	BATCHING:
		Rows are buffered in-memory and flushed every FLUSH_INTERVAL seconds, or
		when the buffer hits BATCH_MAX. BindToClose flushes once at shutdown.

	USAGE:
		local Metrics = require(SSS.PLAY3_SDK.Modules.Metrics)
		Metrics:Increment(player, "coins_earned", 50, { source = "boss_drop" })
		Metrics:Set(player, "level", 12)
		Metrics:Record(player, "boss_defeated", { bossId = "wraith", ttkSec = 184 })
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

if not RunService:IsRunning() then
	return {}
end

local Config = require(script.Parent.Parent.Config)
local PlayerState = require(script.Parent.Parent.Core.PlayerState)
local HttpQueue = require(script.Parent.Parent.Core.HttpQueue)

local Metrics = {}

local SDK_VERSION = "1.1.0"
local FLUSH_INTERVAL = 30      -- seconds
local BATCH_MAX = 200          -- force-flush at this many buffered rows
local MAX_ATTRS_KEYS = 16      -- per-row attrs cap to keep payloads sane
local KEY_PATTERN = "^[a-z0-9_]+$"
local KEY_MAX_LEN = 64

-- Playtime auto-emit. Every active player gets a `_playtime_seconds` counter
-- row each PLAYTIME_INTERVAL with the delta since the last tick. Chosen so
-- the row count is bounded (50 players × 30s = 100 rows/min/server) and
-- snapshot freshness lags by < 1 tick.
local PLAYTIME_INTERVAL = 30
local PLAYTIME_KEY = "_playtime_seconds"

local buffer = {}
local setupDone = false

local function log(...)
	if Config.debug then
		print("[PLAY3 Metrics]", ...)
	end
end

local function getIsoTimestampUTC()
	return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function isValidKey(key)
	return type(key) == "string"
		and #key > 0
		and #key <= KEY_MAX_LEN
		and key:match(KEY_PATTERN) ~= nil
end

-- Public callers can't use `_`-prefixed keys — that namespace is reserved
-- for SDK-built-in metrics (_playtime_seconds today, more later). The
-- internal enqueue path bypasses this check.
local function isValidPublicKey(key)
	return isValidKey(key) and key:sub(1, 1) ~= "_"
end

-- Strip non-scalar values and cap keycount. attrs ride along as JSON; we don't
-- want devs accidentally shipping Instances/tables that fail to encode or
-- bloat each row.
local function sanitizeAttrs(attrs)
	if type(attrs) ~= "table" then
		return nil
	end
	local out = {}
	local count = 0
	for k, v in pairs(attrs) do
		if count >= MAX_ATTRS_KEYS then break end
		local t = type(v)
		if type(k) == "string" and (t == "string" or t == "number" or t == "boolean") then
			out[k] = v
			count = count + 1
		end
	end
	if count == 0 then return nil end
	return out
end

local function flush()
	if #buffer == 0 then
		return
	end

	local rows = buffer
	buffer = {}

	HttpQueue.sendToAttribution("/api/metrics/ingest", {
		gameId = tostring(game.GameId),
		placeId = tostring(game.PlaceId),
		instanceId = game.JobId,
		sdkVersion = SDK_VERSION,
		timestamp = getIsoTimestampUTC(),
		events = rows,
	}, {
		onSuccess = function()
			log("Flushed", #rows, "metric rows")
		end,
		onError = function(err)
			warn("[PLAY3 Metrics] Flush failed:", err)
		end,
	})
end

local function enqueue(player, key, metricType, numericValue, attrs, isInternal)
	if not player or not player.UserId then
		return false
	end
	-- Internal callers (system metrics like _playtime_seconds) can use the
	-- `_` namespace; public callers can't.
	local validator = isInternal and isValidKey or isValidPublicKey
	if not validator(key) then
		warn("[PLAY3 Metrics] Invalid key (must match [a-z0-9_]{1,64}, public keys must not start with _):", tostring(key))
		return false
	end

	table.insert(buffer, {
		playerId = PlayerState.getVisitorIdByUserId(player.UserId),
		-- Raw UserId rides alongside the hashed playerId so the custom-leaderboard
		-- snapshot job can resolve username + avatar. Sent as string because Roblox
		-- UserIds are 64-bit and JSON loses precision past 53 bits.
		robloxUserId = tostring(player.UserId),
		sessionId = PlayerState.getSessionIdByUserId(player.UserId),
		metricKey = key,
		metricType = metricType,
		numericValue = numericValue,
		attrs = sanitizeAttrs(attrs),
		timestamp = getIsoTimestampUTC(),
	})

	if #buffer >= BATCH_MAX then
		task.spawn(flush)
	end
	return true
end

-- ── PLAYTIME AUTO-EMIT ─────────────────────────────────────────────────
--
-- Tracks per-player "seconds since we last emitted" and fires a
-- _playtime_seconds counter on every PLAYTIME_INTERVAL tick. Lets every
-- brand build a Playtime leaderboard with zero game-code changes — the
-- metric just shows up in their custom-metrics table.
--
-- Server-side state only. Clears on PlayerRemoving.

local playtimeLastEmittedAt = {}   -- userId → os.time() of last emit

local function playtimeOnJoin(player)
	playtimeLastEmittedAt[player.UserId] = os.time()
end

local function playtimeOnLeave(player)
	-- Emit a final partial-window row so the player's total playtime is
	-- captured even if they leave mid-tick. PlayerRemoving fires while the
	-- player is still in Players, so player.UserId is valid here.
	local last = playtimeLastEmittedAt[player.UserId]
	if last then
		local delta = os.time() - last
		if delta > 0 then
			enqueue(player, PLAYTIME_KEY, "counter", delta, nil, true)
		end
		playtimeLastEmittedAt[player.UserId] = nil
	end
end

local function playtimeTick()
	local now = os.time()
	for _, player in ipairs(Players:GetPlayers()) do
		local last = playtimeLastEmittedAt[player.UserId] or now
		local delta = now - last
		if delta > 0 then
			enqueue(player, PLAYTIME_KEY, "counter", delta, nil, true)
			playtimeLastEmittedAt[player.UserId] = now
		end
	end
end

local function isPlaceholder(key)
	return type(key) ~= "string" or key == "" or key:match("^YOUR_") ~= nil
end

local function setupOnce()
	if setupDone then return end
	setupDone = true

	-- No API key = no flush destination. Skip setup entirely so the playtime
	-- ticker doesn't fill a buffer that can't go anywhere. Public callers of
	-- Increment/Set/Record still log warnings via HttpQueue on flush attempt.
	if isPlaceholder(Config.ATTRIBUTION_API_KEY) then
		log("ATTRIBUTION_API_KEY not set; metrics + playtime auto-emit disabled.")
		return
	end

	-- Flush loop.
	task.spawn(function()
		while true do
			task.wait(FLUSH_INTERVAL)
			flush()
		end
	end)

	-- Playtime auto-emit. Track existing players first (in case the module
	-- requires late), then wire PlayerAdded/Removing, then start the ticker.
	for _, player in ipairs(Players:GetPlayers()) do
		playtimeOnJoin(player)
	end
	Players.PlayerAdded:Connect(playtimeOnJoin)
	Players.PlayerRemoving:Connect(playtimeOnLeave)

	task.spawn(function()
		while true do
			task.wait(PLAYTIME_INTERVAL)
			playtimeTick()
		end
	end)

	game:BindToClose(function()
		-- Snap a final delta for everyone still in the server before flushing,
		-- so the totals don't lose the final partial window.
		for _, player in ipairs(Players:GetPlayers()) do
			playtimeOnLeave(player)
		end
		flush()
		task.wait(1) -- let HttpQueue drain
	end)

	log("Metrics initialized (flush:", FLUSH_INTERVAL, "s, batch max:", BATCH_MAX, ", playtime tick:", PLAYTIME_INTERVAL, "s)")
end

-- ============ PUBLIC API ============

function Metrics:Increment(player, key, value, attrs)
	local n = tonumber(value)
	if not n then
		warn("[PLAY3 Metrics] Increment value must be a number:", tostring(value))
		return false
	end
	return enqueue(player, key, "counter", n, attrs)
end

function Metrics:Set(player, key, value, attrs)
	local n = tonumber(value)
	if not n then
		warn("[PLAY3 Metrics] Set value must be a number:", tostring(value))
		return false
	end
	return enqueue(player, key, "gauge", n, attrs)
end

function Metrics:Record(player, key, attrs)
	return enqueue(player, key, "event", nil, attrs)
end

-- Force a flush now. Useful for tests / admin commands.
function Metrics:Flush()
	task.spawn(flush)
end

-- Debug helper.
function Metrics:GetBufferSize()
	return #buffer
end

-- Initialize at module load so `_playtime_seconds` auto-emits for every
-- player from the moment the SDK boots — no game-code changes required.
setupOnce()

return Metrics
