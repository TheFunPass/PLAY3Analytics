--[[
	PLAY3 SDK - Session Tracking (standalone Server Script)
	Reports batched player sessions to PLAY3 API
	Sends all active sessions every SESSION_INTERVAL seconds.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

if not RunService:IsRunning() then
	return
end

local Config = require(script.Parent.Parent.Config)
local PlayerState = require(script.Parent.Parent.Core.PlayerState)
local HttpQueue = require(script.Parent.Parent.Core.HttpQueue)

local function log(...)
	if Config.debug then
		print("[PLAY3 Sessions]", ...)
	end
end

local function getIsoTimestampUTC()
	return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function sendSessions()
	if not Config.ENABLE_SESSIONS then
		return
	end

	local sessions = PlayerState.getAllSessions()

	if #sessions == 0 then
		log("No active sessions to report")
		return
	end

	local payload = {
		gameId = tostring(game.GameId),
		timestamp = getIsoTimestampUTC(),
		playersCount = #Players:GetPlayers(),
		sessions = sessions,
	}

	HttpQueue.sendToPlay3("/game-events/sessions", payload, {
		onSuccess = function()
			log("Sessions sent:", #sessions, "players")
		end,
		onError = function(err)
			warn("[PLAY3 Sessions] Failed to send sessions:", err)
		end,
	})
end

if Config.ENABLE_SESSIONS then
	task.spawn(function()
		while true do
			sendSessions()
			task.wait(Config.SESSION_INTERVAL or 60)
		end
	end)
	log("Session tracking started (interval:", Config.SESSION_INTERVAL or 60, "s)")
end
