--[[
	PLAY3 SDK - In-Game Leaderboard

	Reads the brand's creator leaderboard from reels.play3.ai and exposes it
	to your game code in the simplest possible shape: rank + Roblox user id +
	points. Look up the rest (username, headshot) via native Roblox APIs.

	REQUIRES:
		Config.ATTRIBUTION_API_KEY  (same key as the Attribution module)

	IF YOUR BRAND HAS NO LEADERBOARD CONFIGURED:
		This module silently returns empty boards. It logs one info line, then
		keeps the auto-refresh loop running quietly in the background. No
		spam, no errors, no UI surprises.

	PUBLIC API:
		Leaderboard:GetTop({ limit = 10 })
			Returns { computedAt, totalParticipants, entries, stale } table.
			`entries` is always an array (possibly empty). `stale` is true
			when the last network refresh failed and we're serving cached data.
			Fetches synchronously on first call (yields). Subsequent calls
			within Config.LEADERBOARD_CACHE_TTL return the cached value.

		Leaderboard:GetPlayerEntry(robloxUserId)
			Local lookup against the cached entries by robloxUserId.
			Returns the entry table or nil. Does NOT trigger a network fetch.

		Leaderboard:OnUpdate(function(board) ... end)
			Subscribe to refresh callbacks. The callback fires once each time
			the leaderboard data changes (compared by computedAt). Returns a
			connection table with :Disconnect().

		Leaderboard:StartAutoRefresh()
			Kicks off a background loop that refreshes every TTL seconds.
			Idempotent — calling twice is a no-op. Stops automatically if the
			API key is rejected (401).

		Leaderboard:Refresh()
			Force a refresh now, ignoring cache TTL. Useful for admin
			commands or testing. Yields.

	GAME-SIDE USAGE EXAMPLE (typical ScreenGui pattern):

		local Leaderboard = require(SSS.PLAY3_SDK.Modules.Leaderboard)
		local Players = game:GetService("Players")

		local function render(board)
			-- Clear and re-render your ScreenGui rows here.
			for _, row in ipairs(board.entries) do
				-- Native Roblox lookups — these yield, do them in a coroutine
				-- if rendering many rows synchronously feels slow.
				local _, name = pcall(Players.GetNameFromUserIdAsync, Players, row.robloxUserId)
				local headshotContentId = string.format(
					"rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150",
					row.robloxUserId
				)
				-- ... build UI rows with row.rank, row.points, name, headshotContentId
			end
		end

		local first = Leaderboard:GetTop({ limit = 10 })
		if first then render(first) end

		Leaderboard:StartAutoRefresh()
		Leaderboard:OnUpdate(render)
]]

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

-- Edit-mode safe: return a no-op module so `require` from another script
-- doesn't error in Studio when the game isn't running.
if not RunService:IsRunning() then
	return {}
end

local Config = require(script.Parent.Parent.Config)

local Leaderboard = {}

local DEFAULT_LIMIT = 10
local MAX_LIMIT = 25
local PATH = "/api/game/leaderboard"

-- Failure-mode warning: when refreshes keep failing, we don't want to log
-- every interval. Throttle network-error warnings to at most once every
-- FAILURE_LOG_INTERVAL seconds.
local FAILURE_LOG_INTERVAL = 300 -- 5 minutes

local function isPlaceholder(key)
	return type(key) ~= "string" or key == "" or key:match("^YOUR_") ~= nil
end

local function log(...)
	if Config.debug then
		print("[PLAY3 Leaderboard]", ...)
	end
end

local function warn1(message)
	-- Always-on warn, used for one-shot informational notices the brand
	-- should see even with debug off.
	warn("[PLAY3 Leaderboard] " .. message)
end

-- ── INTERNAL STATE ──────────────────────────────────────────────────────

-- Cache shape: { computedAt, totalParticipants, entries, stale }
local cache = nil
local cacheLimit = nil       -- the `limit` used when populating `cache`
local cacheFetchedAt = 0     -- os.time() of last successful fetch
local lastNoLeaderboardLog = false  -- already-told-the-user-it's-empty?
local lastFailureLogAt = 0
local authDisabled = false   -- set on 401; halts auto-refresh until manual Refresh()

local fetchInFlight = nil    -- coroutine handle when a fetch is running

local autoRefreshRunning = false

-- OnUpdate listeners: array of { callback = fn, disconnected = bool }
local listeners = {}

-- ── HELPERS ─────────────────────────────────────────────────────────────

local function fireUpdate(board)
	-- Copy listener list so a disconnect during dispatch doesn't shift indices
	local snap = {}
	for i, l in ipairs(listeners) do snap[i] = l end
	for _, l in ipairs(snap) do
		if not l.disconnected then
			task.spawn(function()
				local ok, err = pcall(l.callback, board)
				if not ok then
					warn("[PLAY3 Leaderboard] OnUpdate callback errored: " .. tostring(err))
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

-- Returns true if two boards represent the same snapshot (so we can skip
-- re-firing OnUpdate when the cron hasn't written a new one yet).
local function boardsEqual(a, b)
	if not a or not b then return false end
	if a.computedAt ~= b.computedAt then return false end
	if #(a.entries or {}) ~= #(b.entries or {}) then return false end
	return true
end

-- ── NETWORK ─────────────────────────────────────────────────────────────

-- Synchronous fetch via RequestAsync. Returns (board, err). Yields.
local function doFetch(limit)
	if isPlaceholder(Config.ATTRIBUTION_API_KEY) then
		return nil, "no_api_key"
	end

	local url = string.format("%s%s?limit=%d", Config.ATTRIBUTION_API_URL, PATH, limit)

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

	if not response.Success then
		return nil, "http:" .. tostring(response.StatusCode)
	end

	local decodeOk, decoded = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if not decodeOk or type(decoded) ~= "table" then
		return nil, "decode"
	end

	-- Backend returns { success, computedAt, entries, ... } even when the
	-- board is empty. Treat missing fields defensively.
	return {
		computedAt = decoded.computedAt,           -- nil when no snapshot yet
		totalParticipants = decoded.totalParticipants or 0,
		entries = type(decoded.entries) == "table" and decoded.entries or {},
		stale = false,
	}, nil
end

-- Public/private refresh worker. Coalesces concurrent callers so only one
-- network request flies in parallel. Returns the resulting board (or
-- the existing cache with stale=true on error).
local function refresh(limit)
	if fetchInFlight then
		-- Wait for the in-flight fetch to finish, then return whatever it
		-- produced. task.wait on a thread isn't quite right; use a simple
		-- spin with a yield. Fetches are fast (< 1s typically) so this is
		-- fine.
		while fetchInFlight do task.wait(0.05) end
		return cache
	end

	fetchInFlight = true
	local board, err = doFetch(limit)
	fetchInFlight = nil

	if board then
		-- Success.
		lastFailureLogAt = 0
		authDisabled = false
		local previous = cache
		cache = board
		cacheLimit = limit
		cacheFetchedAt = os.time()

		-- Friendly one-shot log when the brand simply has no data yet.
		if #board.entries == 0 then
			if not lastNoLeaderboardLog then
				log("Leaderboard returned empty (no snapshot yet / no campaign / no Roblox-linked creators). Auto-refresh will keep checking quietly.")
				lastNoLeaderboardLog = true
			end
		else
			lastNoLeaderboardLog = false
		end

		if not boardsEqual(previous, board) then
			fireUpdate(board)
		end
		return board
	end

	-- Error path.
	if err == "no_api_key" then
		if not lastNoLeaderboardLog then
			warn1("ATTRIBUTION_API_KEY is not set in Config.lua; leaderboard disabled. Get a key at https://reels.play3.ai/brand")
			lastNoLeaderboardLog = true
		end
		return cache  -- nil if we never had data
	end

	if err == "auth" then
		if not authDisabled then
			warn1("API key rejected by reels.play3.ai (401). Auto-refresh stopped — fix the key and call Leaderboard:Refresh() to retry.")
			authDisabled = true
		end
		return cache
	end

	-- Network / 5xx / decode — rate-limited warning, mark cache stale,
	-- but keep auto-refresh running for the next interval.
	local now = os.time()
	if now - lastFailureLogAt >= FAILURE_LOG_INTERVAL then
		warn("[PLAY3 Leaderboard] Refresh failed (" .. tostring(err) .. "); serving stale cache if available.")
		lastFailureLogAt = now
	end
	if cache then cache.stale = true end
	return cache
end

-- ── PUBLIC API ──────────────────────────────────────────────────────────

function Leaderboard:GetTop(options)
	options = options or {}
	local limit = clampLimit(options.limit)

	-- Cache hit when within TTL AND requested limit fits the cached one.
	-- (If a caller asks for limit=5 we can slice down a cached limit=10.)
	if cache and cacheLimit and limit <= cacheLimit then
		local age = os.time() - cacheFetchedAt
		if age < (Config.LEADERBOARD_CACHE_TTL or 1800) then
			-- Return a sliced view (without mutating the cached array).
			if #cache.entries <= limit then
				return cache
			end
			local sliced = {}
			for i = 1, limit do sliced[i] = cache.entries[i] end
			return {
				computedAt = cache.computedAt,
				totalParticipants = cache.totalParticipants,
				entries = sliced,
				stale = cache.stale,
			}
		end
	end

	-- Cache miss — fetch. Use max(limit, cached limit) so we don't shrink
	-- the cache on a smaller request.
	local fetchLimit = math.max(limit, cacheLimit or 0, DEFAULT_LIMIT)
	if fetchLimit > MAX_LIMIT then fetchLimit = MAX_LIMIT end
	return refresh(fetchLimit) or {
		computedAt = nil,
		totalParticipants = 0,
		entries = {},
		stale = true,
	}
end

function Leaderboard:GetPlayerEntry(robloxUserId)
	if type(robloxUserId) ~= "number" then
		return nil
	end
	if not cache or not cache.entries then return nil end
	for _, entry in ipairs(cache.entries) do
		if entry.robloxUserId == robloxUserId then
			return entry
		end
	end
	return nil
end

function Leaderboard:OnUpdate(callback)
	if type(callback) ~= "function" then
		error("Leaderboard:OnUpdate expects a function")
	end
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

function Leaderboard:Refresh()
	-- Manual refresh — clear the auth-disabled flag so the user can retry
	-- after fixing a bad key without restarting the server.
	authDisabled = false
	local limit = cacheLimit or DEFAULT_LIMIT
	return refresh(limit)
end

function Leaderboard:StartAutoRefresh()
	if autoRefreshRunning then return end
	autoRefreshRunning = true

	task.spawn(function()
		-- Initial fetch so the cache is warm and OnUpdate listeners get
		-- their first board ASAP.
		refresh(cacheLimit or DEFAULT_LIMIT)

		while autoRefreshRunning do
			local interval = Config.LEADERBOARD_CACHE_TTL or 1800
			task.wait(interval)
			-- If auth was rejected, skip the refresh until Leaderboard:Refresh
			-- is called explicitly. Saves the backend from being hammered
			-- with bad creds.
			if not authDisabled then
				refresh(cacheLimit or DEFAULT_LIMIT)
			end
		end
	end)

	log("Auto-refresh started (interval: " .. tostring(Config.LEADERBOARD_CACHE_TTL or 1800) .. "s)")
end

function Leaderboard:StopAutoRefresh()
	autoRefreshRunning = false
end

-- ── CLIENT REPLICATION (one-call dev integration) ──────────────────────
--
-- Most games want the leaderboard rendered inside a ScreenGui, which means
-- the server has to push board updates to clients. The cross-script
-- plumbing (RemoteEvent + broadcast-on-update + warm-paint-on-join) is the
-- same in every game, so the SDK owns it.
--
-- After calling this once on the server, a client LocalScript can render
-- the leaderboard with three lines:
--
--   local remote = game:GetService("ReplicatedStorage")
--     :WaitForChild("Play3LeaderboardUpdate")
--   remote.OnClientEvent:Connect(function(board)
--     -- board.entries = { { rank, robloxUserId, points, videos, totalViews }, ... }
--   end)
--
-- Idempotent — calling this twice is a no-op. Also auto-starts the
-- refresh loop so the dev never has to call StartAutoRefresh separately.

local REMOTE_NAME = "Play3LeaderboardUpdate"
local replicationEnabled = false

function Leaderboard:EnableClientReplication()
	if replicationEnabled then return end

	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Players = game:GetService("Players")

	-- Create or reuse the RemoteEvent. Reusing is important because some
	-- games may have wired up listeners before we ran, and re-creating
	-- would orphan their connections.
	local remote = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = REMOTE_NAME
		remote.Parent = ReplicatedStorage
	end

	-- Broadcast every successful refresh to all connected players.
	self:OnUpdate(function(board)
		remote:FireAllClients(board)
	end)

	-- Warm-paint: players who join between refresh cycles get the current
	-- cached board immediately, so their UI doesn't sit empty waiting for
	-- the next 30-min tick.
	Players.PlayerAdded:Connect(function(player)
		if cache and #cache.entries > 0 then
			remote:FireClient(player, cache)
		end
	end)

	-- Auto-start the refresh loop so the dev doesn't have to remember.
	self:StartAutoRefresh()

	replicationEnabled = true
	log("Client replication enabled — clients can subscribe via ReplicatedStorage." .. REMOTE_NAME)
end

log("Leaderboard module ready")

return Leaderboard
