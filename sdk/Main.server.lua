--[[
	PLAY3 Analytics SDK - Server Entry Point
	Automatically loads all analytics modules
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Wait for modules
local Play3Root = ReplicatedStorage:WaitForChild("PLAY3_ANALYTICS")
local Config = require(Play3Root:WaitForChild("Config"))

local function log(...)
	if Config.debug then
		print("[PLAY3 Analytics]", ...)
	end
end

-- Load Analytics modules
local AnalyticsFolder = Play3Root:WaitForChild("Analytics")

-- Session tracking
local SessionAnalytics = AnalyticsFolder:FindFirstChild("PLAY3_Analytics")
if SessionAnalytics then
	require(SessionAnalytics)
	log("Session tracking loaded")
end

-- Purchase tracking
local PurchaseTracker = AnalyticsFolder:FindFirstChild("PurchaseTracker")
if PurchaseTracker then
	require(PurchaseTracker)
	log("Purchase tracking loaded")
end

log("PLAY3 Analytics SDK ready.")
