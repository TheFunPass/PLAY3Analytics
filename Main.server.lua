--[[
	PLAY3 Combined SDK - Server Entry Point

	SETUP:
	1. Place this folder in ServerScriptService (name it PLAY3_SDK).
	2. Edit Config.lua with your API keys.
	3. That's it.

	Architecture:
	- Analytics scripts (Sessions, PlayerAnalyzer, Purchases) live in Analytics/
	  as standalone Server Scripts. They self-fire on game start regardless of
	  whether Main runs.
	- Attribution is opt-in: it requires a separate ATTRIBUTION_API_KEY.
	  This script bootstraps it only when configured.

	PUBLIC API (Attribution only):
		local SSS = game:GetService("ServerScriptService")
		local Attribution = require(SSS.PLAY3_SDK.Modules.Attribution)

		Attribution:TrackBadge(player, badgeId, "Badge Name")
		Attribution:TrackMilestone(player, "level_up", { level = 10 })

		if Attribution:IsAttributed(player) then
		    print("Source:", Attribution:GetSource(player))
		end
]]

local RunService = game:GetService("RunService")

if not RunService:IsRunning() then
	return
end

local Config = require(script.Parent.Config)

local function isPlaceholder(key)
	return type(key) ~= "string" or key == "" or key:match("^YOUR_") ~= nil
end

if isPlaceholder(Config.PLAY3_API_KEY) then
	warn("[PLAY3 SDK] PLAY3_API_KEY is not set in Config.lua — analytics requests will be rejected. Get a key at https://play3.ai")
end

if Config.ENABLE_ATTRIBUTION and not isPlaceholder(Config.ATTRIBUTION_API_KEY) then
	require(script.Parent.Modules.Attribution)
	if Config.debug then
		print("[PLAY3 SDK] Attribution enabled")
	end
elseif Config.debug then
	print("[PLAY3 SDK] Attribution disabled (no ATTRIBUTION_API_KEY configured)")
end
