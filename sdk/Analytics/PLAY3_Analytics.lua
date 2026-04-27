--[[
	PLAY3 Analytics - Session Tracking
	Reports player sessions to analytics backend
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

-- Don't run in edit mode
if not RunService:IsRunning() then
	return {}
end

local HashLib = require(script.Parent.HashLib.init)
local Config = require(script.Parent.Parent.Config)

local SECONDS_INTERVAL = Config.SESSION_INTERVAL or 60

-- Toggle Studio testing (only applies when game is running in Studio)
local ALLOW_STUDIO = true

-- Pull endpoint/key from Config
local SESSIONS_ENDPOINT = Config.API_URL .. "/game-events/sessions"
local API_KEY = Config.API_KEY or ""

local AnalyticsModule = {}
local playerSessions = {}

local function generateAnonId(player: Player)
	return HashLib.sha256(tostring(player.UserId))
end

local function getIsoTimestampUTC()
	return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function log(...)
	if Config.debug then
		print("[PLAY3 Analytics]", ...)
	end
end

Players.PlayerAdded:Connect(function(player)
	playerSessions[player.UserId] = {
		joinTime = os.time(),
		playerId = generateAnonId(player),
	}
	log("Player joined:", player.Name)
end)

Players.PlayerRemoving:Connect(function(player)
	playerSessions[player.UserId] = nil
	log("Player left:", player.Name)
end)

function AnalyticsModule:SendSessions()
	-- Allow Studio if toggle is on
	if RunService:IsStudio() and not ALLOW_STUDIO then
		return
	end

	local sessionsArr = {}
	for _, session in pairs(playerSessions) do
		table.insert(sessionsArr, {
			playerId = session.playerId,
			playTime = os.time() - session.joinTime,
		})
	end

	local payload = {
		gameId = tostring(game.GameId),
		timestamp = getIsoTimestampUTC(),
		playersCount = #Players:GetPlayers(),
		sessions = sessionsArr,
	}

	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = SESSIONS_ENDPOINT,
			Method = "POST",
			Headers = {
				["content-type"] = "application/json",
				["x-api-key"] = API_KEY,
			},
			Body = HttpService:JSONEncode(payload),
		})
	end)

	if not ok then
		warn("[PLAY3 Analytics] HTTP error:", res)
		return
	end

	if not res.Success then
		warn("[PLAY3 Analytics] Failed:", res.StatusCode, res.Body)
	else
		log("Sessions sent:", #sessionsArr, "players")
	end
end

task.spawn(function()
	while true do
		AnalyticsModule:SendSessions()
		task.wait(SECONDS_INTERVAL)
	end
end)

log("Session tracking started (interval:", SECONDS_INTERVAL, "s)")

return AnalyticsModule
