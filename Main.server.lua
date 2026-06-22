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

	PUBLIC API:
		local SSS = game:GetService("ServerScriptService")

		-- Attribution (deep link tracking + custom events)
		local Attribution = require(SSS.PLAY3_SDK.Modules.Attribution)
		Attribution:TrackBadge(player, badgeId, "Badge Name")
		Attribution:TrackMilestone(player, "level_up", { level = 10 })
		if Attribution:IsAttributed(player) then
		    print("Source:", Attribution:GetSource(player))
		end

		-- Custom Metrics (works for ALL players, attributed or not).
		-- Counter, gauge, or event. Keys must be snake_case [a-z0-9_]{1,64}.
		local Metrics = require(SSS.PLAY3_SDK.Modules.Metrics)
		Metrics:Increment(player, "coins_earned", 50, { source = "boss_drop" })
		Metrics:Set(player, "level", 12)
		Metrics:Record(player, "boss_defeated", { bossId = "wraith" })

		-- Leaderboard (read brand's creator leaderboard data)
		local Leaderboard = require(SSS.PLAY3_SDK.Modules.Leaderboard)
		-- One-call setup for ScreenGui / custom client UI: creates a
		-- ReplicatedStorage.Play3LeaderboardUpdate RemoteEvent that
		-- client LocalScripts can subscribe to.
		Leaderboard:EnableClientReplication()

		-- LeaderboardBoard (in-world 3D billboard — plug-and-play)
		local LeaderboardBoard = require(SSS.PLAY3_SDK.Modules.LeaderboardBoard)
		-- Attach a leaderboard SurfaceGui to any BasePart in your world:
		LeaderboardBoard:MountToPart(workspace.MyBillboardPart)
		-- Or auto-mount every Part tagged "Play3Leaderboard":
		LeaderboardBoard:AutoMountTagged()
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

-- Boot Metrics so its built-in `_playtime_seconds` ticker starts firing for
-- every brand using the SDK, even when game code never calls Metrics:Increment.
-- Brands that have set ATTRIBUTION_API_KEY get a free Playtime leaderboard;
-- brands that haven't get a one-time log and no ticker (see setupOnce).
if not isPlaceholder(Config.ATTRIBUTION_API_KEY) then
	require(script.Parent.Modules.Metrics)
end
