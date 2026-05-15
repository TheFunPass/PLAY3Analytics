--[[
	PLAY3 SDK - Device Tracker
	Receives device info from each player's client and caches it per-player.

	The detection actually happens on the client (Client/DeviceInfoClient.client.lua)
	because server-side UserInputService has no input devices and would report
	false for everything. The client fires `PLAY3Remotes.DeviceInfo` to us.

	Used by Analytics/PlayerAnalyzer to set `account.deviceType` correctly.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Parent.Config)

local DeviceTracker = {}

local playerDevices = {}

local function log(...)
	if Config.debug then
		print("[PLAY3 DeviceTracker]", ...)
	end
end

local function ensureRemote()
	local remotesFolder = ReplicatedStorage:FindFirstChild("PLAY3Remotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "PLAY3Remotes"
		remotesFolder.Parent = ReplicatedStorage
	end

	local remote = remotesFolder:FindFirstChild("DeviceInfo")
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = "DeviceInfo"
		remote.Parent = remotesFolder
	end
	return remote
end

-- Public: read cached device info (nil if client hasn't reported yet)
function DeviceTracker.getDevice(player)
	return playerDevices[player.UserId]
end

function DeviceTracker.hasDevice(player)
	return playerDevices[player.UserId] ~= nil
end

function DeviceTracker.clearPlayer(player)
	playerDevices[player.UserId] = nil
end

-- Auto-init on first require. Safe in edit mode (no-op).
if RunService:IsRunning() then
	local remote = ensureRemote()

	remote.OnServerEvent:Connect(function(player, data)
		if type(data) ~= "table" then return end

		playerDevices[player.UserId] = {
			deviceType    = type(data.deviceType) == "string" and data.deviceType or "Unknown",
			deviceSubType = type(data.deviceSubType) == "string" and data.deviceSubType or "unknown",
			inputType     = type(data.inputType) == "string" and data.inputType or "unknown",
			screenResX    = type(data.screenResX) == "number" and data.screenResX or 0,
			screenResY    = type(data.screenResY) == "number" and data.screenResY or 0,
			isMobile      = data.isMobile == true,
			isConsole     = data.isConsole == true,
			isVR          = data.isVR == true,
			receivedAt    = os.time(),
		}
		log("Device for", player.Name, "→", playerDevices[player.UserId].deviceType)
	end)

	Players.PlayerRemoving:Connect(function(player)
		-- Defer so downstream PlayerRemoving handlers can still read.
		task.defer(function()
			DeviceTracker.clearPlayer(player)
		end)
	end)
end

return DeviceTracker
