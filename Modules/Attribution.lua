--[[
	PLAY3 SDK - Attribution Tracking
	Tracks player attribution from deep links (p3_ tokens)
	Reports joins and events to Attribution API
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

-- Don't run in edit mode
if not RunService:IsRunning() then
	return {}
end

local Config = require(script.Parent.Parent.Config)
local PlayerState = require(script.Parent.Parent.Core.PlayerState)
local HttpQueue = require(script.Parent.Parent.Core.HttpQueue)

local Attribution = {}

-- Token prefix for validation
local TOKEN_PREFIX = "p3_"

-- Place ID
local PLACE_ID = tostring(game.PlaceId)

-- Debug logging
local function log(...)
	if Config.debug then
		print("[PLAY3 Attribution]", ...)
	end
end

-- Check if a string is a Play3 token
local function isPlay3Token(str)
	if not str or type(str) ~= "string" then
		return false
	end
	return string.sub(str, 1, #TOKEN_PREFIX) == TOKEN_PREFIX
end

-- Handle player joining with potential attribution
local function onPlayerAdded(player)
	if not Config.ENABLE_ATTRIBUTION then
		return
	end

	log("Checking attribution for:", player.Name)

	-- Get join data
	local joinData = player:GetJoinData()
	if not joinData then
		log("No join data for player")
		return
	end

	local launchData = joinData.LaunchData
	if not launchData then
		log("No launchData for player")
		return
	end

	log("LaunchData:", launchData)

	-- Check if this is a Play3 token
	if not isPlay3Token(launchData) then
		log("LaunchData is not a Play3 token")
		return
	end

	log("Valid Play3 token detected, sending to Attribution API...")

	-- Update player state with launch data
	PlayerState.updateState(player, {
		launchData = launchData,
	})

	-- Get visitorId (hashed for COPPA compliance)
	local visitorId = PlayerState.getVisitorId(player)

	-- Send to Attribution API
	HttpQueue.sendToAttribution("/api/deeplinks/ingest", {
		visitorId = visitorId,
		placeId = PLACE_ID,
		token = launchData,
	}, {
		onSuccess = function(response)
			local decodeSuccess, data = pcall(function()
				return HttpService:JSONDecode(response.Body)
			end)

			if decodeSuccess and data and data.success then
				log("Attribution recorded! JoinId:", data.joinId)
				log("Attributed:", data.attributed)

				-- Store joinId in player state
				PlayerState.setJoinId(player, data.joinId, data.attributed, data.source)
			elseif not decodeSuccess then
				warn("[PLAY3 Attribution] Failed to decode response:", response.Body)
			end
		end,
		onError = function(err)
			warn("[PLAY3 Attribution] Failed to record attribution:", err)
		end,
	})
end

-- Handle player leaving - send session end event
local function onPlayerRemoving(player)
	if not Config.ENABLE_ATTRIBUTION then
		return
	end

	local state = PlayerState.getState(player)
	if not state or not state.joinId then
		return
	end

	local duration = PlayerState.getSessionDuration(player)
	log("Player leaving:", player.Name, "- Session duration:", duration, "seconds")

	-- Send session end event
	HttpQueue.sendToAttribution("/api/deeplinks/event", {
		joinId = state.joinId,
		eventType = "session_end",
		eventData = {
			duration = duration,
			visitorId = state.visitorId,
		},
	})
end

-- ============ PUBLIC API ============

-- Track a custom event (badge, purchase, milestone, etc.)
function Attribution:TrackEvent(player, eventType, eventData)
	local joinId = PlayerState.getJoinId(player)

	if not joinId then
		log("Cannot track event - player not attributed:", player.Name)
		return false
	end

	log("Tracking event:", eventType, "for player:", player.Name)

	HttpQueue.sendToAttribution("/api/deeplinks/event", {
		joinId = joinId,
		eventType = eventType,
		eventData = eventData or {},
	})

	return true
end

-- Track a badge earned
function Attribution:TrackBadge(player, badgeId, badgeName)
	return self:TrackEvent(player, "badge", {
		badgeId = tostring(badgeId),
		badgeName = badgeName,
	})
end

-- Track a purchase (called automatically by PurchaseTracker, but can be called manually)
function Attribution:TrackPurchase(player, productId, price, currency, productType)
	return self:TrackEvent(player, "purchase", {
		productId = tostring(productId),
		price = price,
		currency = currency or "robux",
		productType = productType or "unknown",
	})
end

-- Track a milestone (level up, quest complete, etc.)
function Attribution:TrackMilestone(player, milestoneName, milestoneData)
	return self:TrackEvent(player, "milestone", {
		name = milestoneName,
		data = milestoneData,
	})
end

-- Check if a player was attributed
function Attribution:IsAttributed(player)
	local state = PlayerState.getState(player)
	return state and state.attributed or false
end

-- Get the attribution source for a player
function Attribution:GetSource(player)
	local state = PlayerState.getState(player)
	return state and state.source
end

-- Get the joinId for a player
function Attribution:GetJoinId(player)
	return PlayerState.getJoinId(player)
end

-- ============ INITIALIZATION ============

-- Connect player events
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Handle players that joined before script loaded
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

log("Attribution module initialized")
log("Place ID:", PLACE_ID)

return Attribution
