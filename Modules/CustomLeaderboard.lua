--[[
	PLAY3 SDK - Custom Leaderboards

	Parallel to Modules/Leaderboard.lua but parameterized by a configId. The
	brand defines a leaderboard config in their PLAY3 dashboard (metric +
	aggregation + time window + scope), the dashboard returns a configId,
	and the game pulls data for that configId here.

	Multiple leaderboards per game is the normal case — each call site uses
	its own configId. Caches, listeners, and auto-refresh state are kept
	per-configId so the boards don't interfere.

	REQUIRES:
		Config.ATTRIBUTION_API_KEY  (same gk_ key as the rest of the SDK)
		Brand must have customLeaderboards feature flag enabled
		(otherwise the endpoint returns 404 silently — the SDK treats it
		identical to "no snapshot yet" and stays quiet).

	PUBLIC API:
		CustomLeaderboard:Get(configId, { limit = 10 })
			Returns { computedAt, totalParticipants, entries, stale } table.
			`entries` is always an array; row shape is { rank, robloxUserId, value }.
			Fetches synchronously on first call (yields). Subsequent calls
			within Config.CUSTOM_LEADERBOARD_CACHE_TTL hit the cache.

		CustomLeaderboard:GetPlayerEntry(configId, robloxUserId)
			Local lookup against the cached entries. No network call.

		CustomLeaderboard:OnUpdate(configId, function(board) ... end)
			Subscribe to refresh callbacks for this configId. Returns a
			connection with :Disconnect().

		CustomLeaderboard:StartAutoRefresh(configId)
			Kicks off a background loop for this configId. Idempotent.

		CustomLeaderboard:Refresh(configId)
			Force-refresh now, ignoring cache TTL. Clears auth-disabled flag.

		CustomLeaderboard:EnableClientReplication(configId)
			One-call dev integration: creates a RemoteEvent and broadcasts
			updates to clients, with warm-paint on join. Auto-starts refresh.

	CLIENT-SIDE (single RemoteEvent for all configs):
		local remote = game:GetService("ReplicatedStorage")
		  :WaitForChild("Play3CustomLeaderboardUpdate")
		remote.OnClientEvent:Connect(function(configId, board)
		  -- board.entries = { { rank, robloxUserId, value }, ... }
		end)
]]

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

if not RunService:IsRunning() then
	return {}
end

local Config = require(script.Parent.Parent.Config)

local CustomLeaderboard = {}

local DEFAULT_LIMIT = 10
local MAX_LIMIT = 100
local PATH = "/api/game/custom-leaderboard"
local DEFAULT_TTL = 900            -- 15 min; faster than creator leaderboard
local FAILURE_LOG_INTERVAL = 300   -- 5 min between repeated warnings

local function isPlaceholder(key)
	return type(key) ~= "string" or key == "" or key:match("^YOUR_") ~= nil
end

local function log(...)
	if Config.debug then
		print("[PLAY3 CustomLeaderboard]", ...)
	end
end

local function warn1(message)
	warn("[PLAY3 CustomLeaderboard] " .. message)
end

local function isValidConfigId(configId)
	return type(configId) == "string" and #configId > 0 and #configId <= 80
end

-- ── PER-CONFIG STATE ────────────────────────────────────────────────────
--
-- Every key is keyed by configId. A brand with 3 leaderboards has 3
-- independent caches, listener lists, fetch-in-flight flags, etc. Calls
-- for one configId never block another.

local caches = {}              -- configId → { computedAt, totalParticipants, entries, stale }
local cacheLimits = {}         -- configId → the `limit` used when populating cache
local cacheFetchedAts = {}     -- configId → os.time() of last successful fetch
local lastEmptyLogged = {}     -- configId → already-told-the-user-it's-empty
local lastFailureLogAt = {}    -- configId → os.time() of last failure warn
local authDisabled = {}        -- configId → 401 flag
local fetchInFlight = {}       -- configId → bool while a fetch is running
local autoRefreshRunning = {}  -- configId → bool
local listenersByConfig = {}   -- configId → array of { callback, disconnected }

local function getListeners(configId)
	if not listenersByConfig[configId] then
		listenersByConfig[configId] = {}
	end
	return listenersByConfig[configId]
end

-- ── HELPERS ─────────────────────────────────────────────────────────────

local function fireUpdate(configId, board)
	local listeners = getListeners(configId)
	-- Copy so a disconnect mid-dispatch doesn't shift indices.
	local snap = {}
	for i, l in ipairs(listeners) do snap[i] = l end
	for _, l in ipairs(snap) do
		if not l.disconnected then
			task.spawn(function()
				local ok, err = pcall(l.callback, board)
				if not ok then
					warn("[PLAY3 CustomLeaderboard] OnUpdate callback errored for " .. configId .. ": " .. tostring(err))
				end
			end)
		end
	end
end

local function clampLimit(limit)
	local n = tonumber(limit) or DEFAULT_LIMIT
	if n < 1 then n = 1 end
	if n > MAX_LIMIT then n = MAX_LIMIT end
	return math.floor(n)
end

local function boardsEqual(a, b)
	if not a or not b then return false end
	if a.computedAt ~= b.computedAt then return false end
	if #(a.entries or {}) ~= #(b.entries or {}) then return false end
	return true
end

-- ── NETWORK ─────────────────────────────────────────────────────────────

local function doFetch(configId, limit)
	if isPlaceholder(Config.ATTRIBUTION_API_KEY) then
		return nil, "no_api_key"
	end

	local url = string.format("%s%s/%s?limit=%d",
		Config.ATTRIBUTION_API_URL, PATH, configId, limit)

	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = "GET",
			Headers = {
				["X-API-Key"] = Config.ATTRIBUTION_API_KEY,
				["Accept"] = "application/json",
			},
		})
	end)

	if not ok then
		return nil, "network:" .. tostring(response)
	end

	if response.StatusCode == 401 then
		return nil, "auth"
	end

	-- 404 happens when:
	--   1. configId doesn't exist or belongs to another brand
	--   2. Brand doesn't have the customLeaderboards feature flag on
	-- The SDK shouldn't differentiate — both look like "this leaderboard
	-- isn't available." Treat as a soft empty board, log once.
	if response.StatusCode == 404 then
		return nil, "not_found"
	end

	if not response.Success then
		return nil, "http:" .. tostring(response.StatusCode)
	end

	local decodeOk, decoded = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if not decodeOk or type(decoded) ~= "table" then
		return nil, "decode"
	end

	return {
		computedAt = decoded.computedAt,
		totalParticipants = decoded.totalParticipants or 0,
		entries = type(decoded.entries) == "table" and decoded.entries or {},
		name = decoded.name,
		metricKey = decoded.metricKey,
		valueLabel = decoded.valueLabel,
		aggregation = decoded.aggregation,
		timeWindow = decoded.timeWindow,
		stale = false,
	}, nil
end

-- Coalesce concurrent callers for the SAME configId. Calls for different
-- configIds run in parallel — they don't share state.
local function refresh(configId, limit)
	if fetchInFlight[configId] then
		while fetchInFlight[configId] do task.wait(0.05) end
		return caches[configId]
	end

	fetchInFlight[configId] = true
	local board, err = doFetch(configId, limit)
	fetchInFlight[configId] = nil

	if board then
		lastFailureLogAt[configId] = 0
		authDisabled[configId] = false
		local previous = caches[configId]
		caches[configId] = board
		cacheLimits[configId] = limit
		cacheFetchedAts[configId] = os.time()

		if #board.entries == 0 then
			if not lastEmptyLogged[configId] then
				log("Empty board for " .. configId .. " (no snapshot yet / no matching players). Auto-refresh will keep checking.")
				lastEmptyLogged[configId] = true
			end
		else
			lastEmptyLogged[configId] = false
		end

		if not boardsEqual(previous, board) then
			fireUpdate(configId, board)
		end
		return board
	end

	if err == "no_api_key" then
		if not lastEmptyLogged[configId] then
			warn1("ATTRIBUTION_API_KEY is not set in Config.lua; custom leaderboard disabled.")
			lastEmptyLogged[configId] = true
		end
		return caches[configId]
	end

	if err == "auth" then
		if not authDisabled[configId] then
			warn1("API key rejected by reels.play3.ai (401) for configId " .. configId .. ". Auto-refresh stopped — fix the key and call CustomLeaderboard:Refresh(\"" .. configId .. "\").")
			authDisabled[configId] = true
		end
		return caches[configId]
	end

	if err == "not_found" then
		-- Common during dev: brand created the config but the feature flag
		-- isn't enabled yet, or the configId in code is misspelled. Log
		-- once per configId and serve empty.
		if not lastEmptyLogged[configId] then
			log("Custom leaderboard " .. configId .. " is unavailable (404). Verify the configId in your PLAY3 dashboard and that the brand has the feature enabled.")
			lastEmptyLogged[configId] = true
		end
		caches[configId] = {
			computedAt = nil,
			totalParticipants = 0,
			entries = {},
			stale = true,
		}
		return caches[configId]
	end

	-- Network / 5xx / decode — throttled warn, mark stale, keep auto-refresh.
	local now = os.time()
	if now - (lastFailureLogAt[configId] or 0) >= FAILURE_LOG_INTERVAL then
		warn("[PLAY3 CustomLeaderboard] Refresh failed for " .. configId .. " (" .. tostring(err) .. "); serving stale cache if available.")
		lastFailureLogAt[configId] = now
	end
	if caches[configId] then caches[configId].stale = true end
	return caches[configId]
end

-- ── PUBLIC API ──────────────────────────────────────────────────────────

function CustomLeaderboard:Get(configId, options)
	if not isValidConfigId(configId) then
		warn1("Get requires a valid configId string")
		return { computedAt = nil, totalParticipants = 0, entries = {}, stale = true }
	end
	options = options or {}
	local limit = clampLimit(options.limit)

	local cache = caches[configId]
	local cLimit = cacheLimits[configId]
	if cache and cLimit and limit <= cLimit then
		local age = os.time() - (cacheFetchedAts[configId] or 0)
		local ttl = Config.CUSTOM_LEADERBOARD_CACHE_TTL or DEFAULT_TTL
		if age < ttl then
			if #cache.entries <= limit then
				return cache
			end
			local sliced = {}
			for i = 1, limit do sliced[i] = cache.entries[i] end
			return {
				computedAt = cache.computedAt,
				totalParticipants = cache.totalParticipants,
				entries = sliced,
				name = cache.name,
				metricKey = cache.metricKey,
				valueLabel = cache.valueLabel,
				aggregation = cache.aggregation,
				timeWindow = cache.timeWindow,
				stale = cache.stale,
			}
		end
	end

	local fetchLimit = math.max(limit, cLimit or 0, DEFAULT_LIMIT)
	if fetchLimit > MAX_LIMIT then fetchLimit = MAX_LIMIT end
	return refresh(configId, fetchLimit) or {
		computedAt = nil, totalParticipants = 0, entries = {}, stale = true,
	}
end

function CustomLeaderboard:GetPlayerEntry(configId, robloxUserId)
	if not isValidConfigId(configId) then return nil end
	local cache = caches[configId]
	if not cache or not cache.entries then return nil end
	-- robloxUserId comes back from the backend as a string (BQ STRING column),
	-- but devs naturally pass player.UserId which is a number. Compare both.
	local target = tostring(robloxUserId)
	for _, entry in ipairs(cache.entries) do
		if tostring(entry.robloxUserId) == target then
			return entry
		end
	end
	return nil
end

function CustomLeaderboard:OnUpdate(configId, callback)
	if not isValidConfigId(configId) then
		error("CustomLeaderboard:OnUpdate requires a valid configId")
	end
	if type(callback) ~= "function" then
		error("CustomLeaderboard:OnUpdate expects a function")
	end
	local listeners = getListeners(configId)
	local listener = { callback = callback, disconnected = false }
	table.insert(listeners, listener)

	local connection = {}
	function connection:Disconnect()
		listener.disconnected = true
		for i, l in ipairs(listeners) do
			if l == listener then
				table.remove(listeners, i)
				break
			end
		end
	end
	return connection
end

function CustomLeaderboard:Refresh(configId)
	if not isValidConfigId(configId) then return nil end
	authDisabled[configId] = false
	local limit = cacheLimits[configId] or DEFAULT_LIMIT
	return refresh(configId, limit)
end

function CustomLeaderboard:StartAutoRefresh(configId)
	if not isValidConfigId(configId) then return end
	if autoRefreshRunning[configId] then return end
	autoRefreshRunning[configId] = true

	task.spawn(function()
		refresh(configId, cacheLimits[configId] or DEFAULT_LIMIT)
		while autoRefreshRunning[configId] do
			local interval = Config.CUSTOM_LEADERBOARD_CACHE_TTL or DEFAULT_TTL
			task.wait(interval)
			if not authDisabled[configId] then
				refresh(configId, cacheLimits[configId] or DEFAULT_LIMIT)
			end
		end
	end)

	log("Auto-refresh started for " .. configId .. " (interval: " .. tostring(Config.CUSTOM_LEADERBOARD_CACHE_TTL or DEFAULT_TTL) .. "s)")
end

function CustomLeaderboard:StopAutoRefresh(configId)
	if not isValidConfigId(configId) then return end
	autoRefreshRunning[configId] = false
end

-- ── CLIENT REPLICATION ─────────────────────────────────────────────────
--
-- Single RemoteEvent for all custom leaderboards (rather than one per
-- configId). The payload carries configId so clients can route to the
-- right UI. Keeps ReplicatedStorage tidy when a brand wires up 5+ boards.
--
-- Per-configId tracking on the server side: each call to
-- EnableClientReplication(configId) is idempotent and adds another broadcast
-- subscription to the same RemoteEvent.

local REMOTE_NAME = "Play3CustomLeaderboardUpdate"
local replicationEnabledFor = {}      -- configId → bool
local replicationRemote = nil          -- shared RemoteEvent instance
local replicationPlayerAddedWired = false

local function ensureReplicationRemote()
	if replicationRemote then return replicationRemote end
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local existing = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
	if existing then
		replicationRemote = existing
	else
		replicationRemote = Instance.new("RemoteEvent")
		replicationRemote.Name = REMOTE_NAME
		replicationRemote.Parent = ReplicatedStorage
	end
	return replicationRemote
end

function CustomLeaderboard:EnableClientReplication(configId)
	if not isValidConfigId(configId) then
		warn1("EnableClientReplication requires a valid configId")
		return
	end
	if replicationEnabledFor[configId] then return end

	local remote = ensureReplicationRemote()

	-- Broadcast updates for this configId.
	self:OnUpdate(configId, function(board)
		remote:FireAllClients(configId, board)
	end)

	-- Warm-paint on join — once per process, fires the current cache for
	-- EVERY enabled configId. Single PlayerAdded connection so each new
	-- replication call doesn't pile on duplicates.
	if not replicationPlayerAddedWired then
		replicationPlayerAddedWired = true
		game:GetService("Players").PlayerAdded:Connect(function(player)
			for cid, enabled in pairs(replicationEnabledFor) do
				if enabled then
					local cache = caches[cid]
					if cache and #cache.entries > 0 then
						remote:FireClient(player, cid, cache)
					end
				end
			end
		end)
	end

	self:StartAutoRefresh(configId)
	replicationEnabledFor[configId] = true
	log("Client replication enabled for " .. configId .. " — clients subscribe via ReplicatedStorage." .. REMOTE_NAME)
end

log("CustomLeaderboard module ready")

return CustomLeaderboard
