--[[
	PLAY3 SDK - Device Info Client (LocalScript)

	Detects this player's device and reports it to the server via
	`PLAY3Remotes.DeviceInfo`. Server-side UserInputService can't see any of
	this, so detection MUST happen on the client.

	Receiver: Core/DeviceTracker.lua (in ServerScriptService.PLAY3_SDK.Core)

	Detection priority (most specific first):
		1. VR             — UserInputService.VREnabled / VRService.VREnabled
		2. Console        — GuiService:IsTenFootInterface()
		3. Mobile         — TouchEnabled AND NOT MouseEnabled
		                    (uses Mouse rather than Keyboard as the discriminator
		                     so iPad + Bluetooth-keyboard stays "Mobile")
		4. Desktop        — MouseEnabled
		5. Console (alt)  — GamepadEnabled with no other inputs
		6. Unknown        — fallback
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local VRService = game:GetService("VRService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

if not RunService:IsRunning() then return end

local REMOTE_WAIT = 30

local function detectDeviceType()
	if UserInputService.VREnabled or VRService.VREnabled then
		return "VR"
	end

	local isTenFoot = false
	pcall(function() isTenFoot = GuiService:IsTenFootInterface() end)
	if isTenFoot then return "Console" end

	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		return "Mobile"
	end

	if UserInputService.MouseEnabled then
		return "Desktop"
	end

	if UserInputService.GamepadEnabled then
		return "Console"
	end

	return "Unknown"
end

local function detectSubType(deviceType)
	if deviceType == "Mobile" then
		local camera = Workspace.CurrentCamera
		if camera then
			local longest = math.max(camera.ViewportSize.X, camera.ViewportSize.Y)
			local shortest = math.max(math.min(camera.ViewportSize.X, camera.ViewportSize.Y), 1)
			local aspect = longest / shortest
			-- Phones tend to have aspect > ~1.7 (16:9, 19.5:9 etc.); tablets ~1.33–1.6.
			return aspect >= 1.7 and "phone" or "tablet"
		end
	elseif deviceType == "Console" then
		local ok, img = pcall(function()
			return UserInputService:GetImageForKeyCode(Enum.KeyCode.ButtonX)
		end)
		if ok and type(img) == "string" then
			if string.find(img, "Xbox") then return "xbox" end
			if string.find(img, "PlayStation") then return "playstation" end
		end
	end
	return "unknown"
end

local function detectInputType()
	if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "gamepad"
	end
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		return "touch"
	end
	return "keyboard"
end

local function buildPayload()
	local deviceType = detectDeviceType()
	local camera = Workspace.CurrentCamera
	local screenX = camera and camera.ViewportSize.X or 0
	local screenY = camera and camera.ViewportSize.Y or 0
	return {
		deviceType    = deviceType,
		deviceSubType = detectSubType(deviceType),
		inputType     = detectInputType(),
		screenResX    = math.floor(screenX),
		screenResY    = math.floor(screenY),
		isMobile      = deviceType == "Mobile",
		isConsole     = deviceType == "Console",
		isVR          = deviceType == "VR",
	}
end

local remotesFolder = ReplicatedStorage:WaitForChild("PLAY3Remotes", REMOTE_WAIT)
if not remotesFolder then
	warn("[PLAY3 DeviceInfoClient] PLAY3Remotes not found within", REMOTE_WAIT, "seconds")
	return
end

local deviceRemote = remotesFolder:WaitForChild("DeviceInfo", REMOTE_WAIT)
if not deviceRemote then
	warn("[PLAY3 DeviceInfoClient] DeviceInfo remote not found within", REMOTE_WAIT, "seconds")
	return
end

-- Brief delay so workspace.CurrentCamera is valid (it can be nil for the
-- first frame or two after the player loads).
task.wait(0.3)
deviceRemote:FireServer(buildPayload())

-- Re-fire when the player switches input modes mid-session (e.g. they pick up
-- a controller on PC). Caps the noise to actual changes only.
local lastFired
UserInputService.LastInputTypeChanged:Connect(function(lastType)
	local newType
	if lastType == Enum.UserInputType.Keyboard or lastType == Enum.UserInputType.MouseMovement then
		newType = "keyboard"
	elseif lastType == Enum.UserInputType.Touch then
		newType = "touch"
	elseif string.match(tostring(lastType), "Gamepad") then
		newType = "gamepad"
	end
	if newType and newType ~= lastFired then
		lastFired = newType
		deviceRemote:FireServer(buildPayload())
	end
end)
