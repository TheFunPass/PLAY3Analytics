--[[
	PLAY3 SDK - Leaderboard Drop-In Mount

	Drag this Script onto any BasePart in your workspace to instantly
	display a PLAY3 leaderboard on the Part's front face. No code edits
	required.

	HOW TO USE:
		1. In Studio's Explorer, find this script at
		   ServerScriptService.PLAY3_SDK.Addons.Leaderboard.Mount
		2. Drag it onto whatever Part you want as your leaderboard surface
		   (a wall, kiosk, billboard — any rectangular BasePart).
		3. Hit Play. The leaderboard renders on the Part's front face and
		   refreshes automatically every 30 minutes.

	HOW IT WORKS:
		The script mounts onto its parent. While it lives in its original
		Addons location, the parent is a Folder, not a Part — so it stays
		dormant. Once you parent it to a BasePart in workspace, the parent
		becomes a Part and the leaderboard mounts on it.

	NEED CUSTOMIZATION (face, title, limit, theme)?
		Edit the `options` table below before saving the script's new copy.

	NEED MULTIPLE BOARDS?
		Just duplicate this script and parent each copy to a different
		Part. Each copy mounts independently. Calling MountToPart on the
		same Part twice is idempotent (replaces the previous GUI).
]]

local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

-- Edit-mode safe — return immediately so Studio doesn't try to run this
-- against a half-loaded SDK.
if not RunService:IsRunning() then return end

local parent = script.Parent

-- While in the original Addons.Leaderboard location, script.Parent is a
-- Folder — that's the dormant state. Bail without warning so the SDK
-- doesn't print noise in games that never use this add-on.
if not parent or not parent:IsA("BasePart") then
	return
end

-- ── OPTIONS (tweak before deploying) ──────────────────────────────────
local options = {
	-- Which face of the Part to render on. Default = Enum.NormalId.Front.
	-- Other values: Top, Bottom, Left, Right, Back
	face = Enum.NormalId.Front,

	-- Header text
	title = "TOP CREATORS",

	-- Max rows to display (capped at 100 by the backend). Default 10.
	limit = 10,

	-- SurfaceGui resolution — higher = sharper, slightly more CPU per render
	pixelsPerStud = 50,

	-- Optional theme override (any subset of these):
	-- theme = {
	--     panelBg     = Color3.fromRGB(10, 10, 20),
	--     panelStroke = Color3.fromRGB(48, 48, 58),
	--     rowBg       = Color3.fromRGB(20, 20, 35),
	--     accent      = Color3.fromRGB(173, 255, 0),
	--     textPrimary = Color3.fromRGB(255, 255, 255),
	--     textMuted   = Color3.fromRGB(160, 160, 175),
	-- },
}
-- ──────────────────────────────────────────────────────────────────────

local sdk = ServerScriptService:WaitForChild("PLAY3_SDK", 30)
if not sdk then
	warn("[PLAY3 Leaderboard] PLAY3_SDK not found in ServerScriptService — install the SDK first")
	return
end

local LeaderboardBoard = require(sdk:WaitForChild("Modules"):WaitForChild("LeaderboardBoard"))
LeaderboardBoard:MountToPart(parent, options)
