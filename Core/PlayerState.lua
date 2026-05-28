--[[
	PLAY3 SDK - Shared Player State
	Central state management for all SDK modules
	Uses hashed visitorId for COPPA compliance
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local HashLib = require(script.Parent.HashLib)
local Config = require(script.Parent.Parent.Config)

local PlayerState = {}

-- Player state storage: [userId] = { visitorId, joinTime, joinId, ... }
local playerStates = {}

-- Hash userId for COPPA compliance
function PlayerState.hashUserId(userId)
	return HashLib.sha256(tostring(userId))
end

-- Initialize player state on join
function PlayerState.initPlayer(player)
	local visitorId = PlayerState.hashUserId(player.UserId)

	playerStates[player.UserId] = {
		visitorId = visitorId,
		sessionId = HttpService:GenerateGUID(false), -- Per-join UUID; same across all events for this session
		joinTime = os.time(),
		joinId = nil,           -- Set by attribution module if attributed
		attributed = false,     -- Whether player came from p3_ token
		source = nil,           -- Attribution source (youtube, tiktok, etc)
		launchData = nil,       -- Raw launch data if p3_ token
	}

	return playerStates[player.UserId]
end

-- Get player state
function PlayerState.getState(player)
	return playerStates[player.UserId]
end

-- Get player state by userId
function PlayerState.getStateByUserId(userId)
	return playerStates[userId]
end

-- Update player state
function PlayerState.updateState(player, updates)
	local state = playerStates[player.UserId]
	if state then
		for key, value in pairs(updates) do
			state[key] = value
		end
	end
	return state
end

-- Set joinId from attribution response
function PlayerState.setJoinId(player, joinId, attributed, source)
	local state = playerStates[player.UserId]
	if state then
		state.joinId = joinId
		state.attributed = attributed
		state.source = source

		-- Also set as player attributes for other scripts to access
		player:SetAttribute("Play3JoinId", joinId)
		player:SetAttribute("Play3Attributed", attributed)
		player:SetAttribute("Play3Source", source or "unknown")
	end
end

-- Get visitorId for a player
function PlayerState.getVisitorId(player)
	local state = playerStates[player.UserId]
	return state and state.visitorId or PlayerState.hashUserId(player.UserId)
end

-- Get visitorId by userId
function PlayerState.getVisitorIdByUserId(userId)
	local state = playerStates[userId]
	return state and state.visitorId or PlayerState.hashUserId(userId)
end

-- Get sessionId for a player (per-join UUID)
function PlayerState.getSessionId(player)
	local state = playerStates[player.UserId]
	return state and state.sessionId
end

-- Get sessionId by userId
function PlayerState.getSessionIdByUserId(userId)
	local state = playerStates[userId]
	return state and state.sessionId
end

-- Get joinId for a player (for event tracking)
function PlayerState.getJoinId(player)
	local state = playerStates[player.UserId]
	return state and state.joinId
end

-- Get session duration for a player
function PlayerState.getSessionDuration(player)
	local state = playerStates[player.UserId]
	if state then
		return os.time() - state.joinTime
	end
	return 0
end

-- Get all active player states (for batch operations)
function PlayerState.getAllStates()
	return playerStates
end

-- Get all active sessions (for session reporting).
-- Field name is `playerId` (not `visitorId`) because the backend's session
-- schema expects `playerId`; the value is still the hashed visitor id.
function PlayerState.getAllSessions()
	local sessions = {}
	for userId, state in pairs(playerStates) do
		table.insert(sessions, {
			playerId = state.visitorId,
			sessionId = state.sessionId,
			playTime = os.time() - state.joinTime,
		})
	end
	return sessions
end

-- Cleanup player state on leave
function PlayerState.cleanupPlayer(player)
	local state = playerStates[player.UserId]
	playerStates[player.UserId] = nil
	return state
end

-- Debug logging
local function log(...)
	if Config.debug then
		print("[PLAY3 PlayerState]", ...)
	end
end

-- Auto-connect to player events
Players.PlayerAdded:Connect(function(player)
	PlayerState.initPlayer(player)
	log("Player state initialized:", player.Name)
end)

Players.PlayerRemoving:Connect(function(player)
	-- Defer cleanup so other PlayerRemoving handlers (e.g. Attribution's
	-- session_end reporter) can still read state during their callbacks.
	-- Handlers fire in connect order; PlayerState is required first by every
	-- other module, so without this defer it would always wipe state before
	-- downstream handlers run.
	task.defer(function()
		PlayerState.cleanupPlayer(player)
		log("Player state cleaned up:", player.Name)
	end)
end)

-- Initialize existing players (if script loads late)
for _, player in ipairs(Players:GetPlayers()) do
	if not playerStates[player.UserId] then
		PlayerState.initPlayer(player)
	end
end

return PlayerState
