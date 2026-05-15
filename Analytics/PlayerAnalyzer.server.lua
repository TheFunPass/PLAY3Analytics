--[[
	PLAY3 SDK - Player Analysis (standalone Server Script)
	Sends comprehensive player profile to PLAY3 API on join.
	Includes avatar analysis, social data, account info.
	Uses delayed queue to prevent rate limiting.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local GroupService = game:GetService("GroupService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local LocalizationService = game:GetService("LocalizationService")
local PolicyService = game:GetService("PolicyService")

if not RunService:IsRunning() then
	return
end

local Config = require(script.Parent.Parent.Config)
local PlayerState = require(script.Parent.Parent.Core.PlayerState)
local HttpQueue = require(script.Parent.Parent.Core.HttpQueue)
local DeviceTracker = require(script.Parent.Parent.Core.DeviceTracker)

local analysisQueue = {}
local isProcessingAnalysis = false

local assetInfoCache = {}
local assetCacheOrder = {}
local MAX_CACHE_SIZE = 500

local ASSET_LOOKUP_DELAY = 0.15
local MAX_ITEMS_TO_SCAN = 20
local EXPENSIVE_ITEM_THRESHOLD = 10000

local function log(...)
	if Config.debug then
		print("[PLAY3 Analyzer]", ...)
	end
end

-- Device info comes from each player's client (Client/DeviceInfoClient).
-- Server-side UserInputService has no input devices and would report false
-- for everything, so we wait briefly for the client to report, then fall
-- back to the only thing the server CAN see (IsTenFootInterface = console).
local function resolveDevice(player)
	if DeviceTracker.hasDevice(player) then
		return DeviceTracker.getDevice(player)
	end

	-- Wait up to 3s for client to report. The avatar scan that runs before
	-- us already eats ~3s of task.waits, so this is usually a no-op.
	local waitUntil = os.time() + 3
	while os.time() < waitUntil do
		task.wait(0.25)
		if DeviceTracker.hasDevice(player) then
			return DeviceTracker.getDevice(player)
		end
	end

	-- Fallback: server-side check (only catches Console).
	local isTenFoot = false
	pcall(function() isTenFoot = GuiService:IsTenFootInterface() end)
	return {
		deviceType    = isTenFoot and "Console" or "Unknown",
		deviceSubType = "unknown",
		inputType     = "unknown",
		screenResX    = 0,
		screenResY    = 0,
		isMobile      = false,
		isConsole     = isTenFoot,
		isVR          = false,
	}
end

local function cleanupCache()
	while #assetCacheOrder > MAX_CACHE_SIZE do
		local oldestId = table.remove(assetCacheOrder, 1)
		assetInfoCache[oldestId] = nil
	end
end

local function getAssetInfo(assetId)
	if assetInfoCache[assetId] then
		return assetInfoCache[assetId]
	end

	local success, info = pcall(function()
		return MarketplaceService:GetProductInfo(assetId, Enum.InfoType.Asset)
	end)

	if success and info then
		local data = {
			name = info.Name or "Unknown",
			price = info.PriceInRobux or 0,
			isLimited = info.IsLimited or false,
			isLimitedUnique = info.IsLimitedUnique or false,
			isRobloxCreated = info.Creator and info.Creator.Name == "Roblox" or false,
		}
		assetInfoCache[assetId] = data
		table.insert(assetCacheOrder, assetId)
		cleanupCache()
		return data
	end
	return nil
end

local function scanAvatar(player)
	local result = {
		totalWornValue = 0,
		highestItemValue = 0,
		highestItemName = "",
		limitedCount = 0,
		limitedUniqueCount = 0,
		robloxItemCount = 0,
		ugcItemCount = 0,
		totalItemsWorn = 0,
		expensiveItemsOwned = 0,
		scannedItems = {},
	}

	local success, desc = pcall(function()
		return Players:GetHumanoidDescriptionFromUserId(player.UserId)
	end)

	if not success or not desc then
		return result
	end

	local accessories = desc:GetAccessories(true)
	local scanCount = math.min(#accessories, MAX_ITEMS_TO_SCAN)
	result.totalItemsWorn = #accessories

	for i = 1, scanCount do
		local assetId = accessories[i].AssetId
		local info = getAssetInfo(assetId)

		if info then
			result.totalWornValue = result.totalWornValue + info.price

			if info.price > result.highestItemValue then
				result.highestItemValue = info.price
				result.highestItemName = info.name
			end

			if info.price >= EXPENSIVE_ITEM_THRESHOLD then
				result.expensiveItemsOwned = result.expensiveItemsOwned + 1
			end

			if info.isLimited then
				result.limitedCount = result.limitedCount + 1
			end

			if info.isLimitedUnique then
				result.limitedUniqueCount = result.limitedUniqueCount + 1
			end

			if info.isRobloxCreated then
				result.robloxItemCount = result.robloxItemCount + 1
			else
				result.ugcItemCount = result.ugcItemCount + 1
			end

			table.insert(result.scannedItems, {
				name = info.name,
				price = info.price,
				isLimited = info.isLimited,
			})
		end

		task.wait(ASSET_LOOKUP_DELAY)
	end

	return result
end

local function getSocialData(player)
	local social = {
		friendsCount = 0,
		groupCount = 0,
		highRankGroupCount = 0,
	}

	local gSuccess, groups = pcall(function()
		return GroupService:GetGroupsAsync(player.UserId)
	end)
	if gSuccess and groups then
		social.groupCount = #groups
		for _, group in ipairs(groups) do
			if group.Rank and group.Rank > 200 then
				social.highRankGroupCount = social.highRankGroupCount + 1
			end
		end
	end

	local fSuccess, pages = pcall(function()
		return Players:GetFriendsAsync(player.UserId)
	end)
	if fSuccess and pages then
		local count = 0
		local maxPages = 3
		for _ = 1, maxPages do
			local items = pages:GetCurrentPage()
			count = count + #items
			if pages.IsFinished then
				break
			end
			local nextOk = pcall(function()
				pages:AdvanceToNextPageAsync()
			end)
			if not nextOk then
				break
			end
		end
		social.friendsCount = count
	end

	return social
end

local function processAnalysisQueue()
	if isProcessingAnalysis or #analysisQueue == 0 then
		return
	end

	isProcessingAnalysis = true

	while #analysisQueue > 0 do
		local player = table.remove(analysisQueue, 1)

		if not player or not player.Parent then
			continue
		end

		log("Analyzing player:", player.Name)

		local avatarData = scanAvatar(player)
		local socialData = getSocialData(player)
		local device = resolveDevice(player)

		local visitorId = PlayerState.getVisitorId(player)

		local ageBracket = "unknown"
		pcall(function()
			if player.AgeBracket == Enum.AgeBracket.AgeUnder13 then
				ageBracket = "Under13"
			elseif player.AgeBracket == Enum.AgeBracket.Age13OrOver then
				ageBracket = "13+"
			end
		end)

		local country = "unknown"
		pcall(function()
			country = LocalizationService:GetCountryRegionForPlayerAsync(player)
		end)

		local policySignals = {
			ArePaidRandomItemsRestricted = false,
			IsPaidItemTradingAllowed = false,
			IsSubjectToChinaPolicies = false,
		}
		pcall(function()
			local policyInfo = PolicyService:GetPolicyInfoForPlayerAsync(player)
			policySignals.ArePaidRandomItemsRestricted = policyInfo.ArePaidRandomItemsRestricted or false
			policySignals.IsPaidItemTradingAllowed = policyInfo.IsPaidItemTradingAllowed or false
			policySignals.IsSubjectToChinaPolicies = policyInfo.IsSubjectToChinaPolicies or false
		end)

		local pingMs = 0
		pcall(function()
			pingMs = math.floor(player:GetNetworkPing() * 1000)
		end)

		local isVIPServer = game.PrivateServerId ~= "" and game.PrivateServerId ~= nil

		local payload = {
			gameId = tostring(game.GameId),
			timestamp = DateTime.now():ToIsoDate(),
			playerId = visitorId,
			eventType = "player_analysis",

			account = {
				isPremium = (player.MembershipType == Enum.MembershipType.Premium),
				accountAgeDays = player.AccountAge,
				locale = player.LocaleId or "en-us",
				ageBracket = ageBracket,
				deviceType = device.deviceType,
				deviceSubType = device.deviceSubType,
				inputType = device.inputType,
				screenResX = device.screenResX,
				screenResY = device.screenResY,
				isMobile = device.isMobile,
				isConsole = device.isConsole,
				isVR = device.isVR,
				country = country,
				hasVerifiedBadge = player.HasVerifiedBadge or false,
				pingMs = pingMs,
				isVIPServer = isVIPServer,
				policySignals = policySignals,
			},

			history = {
				previousVisits = 0,
				previousPurchases = 0,
				lifetimeSpend = 0,
				totalSessions = 0,
				highestCheckpoint = 0,
			},

			social = socialData,

			avatar = {
				totalItemsWorn = avatarData.totalItemsWorn,
				totalWornValue = avatarData.totalWornValue,
				highestItemValue = avatarData.highestItemValue,
				highestItemName = avatarData.highestItemName,
				limitedCount = avatarData.limitedCount,
				limitedUniqueCount = avatarData.limitedUniqueCount,
				robloxItemCount = avatarData.robloxItemCount,
				ugcItemCount = avatarData.ugcItemCount,
				expensiveItemsOwned = avatarData.expensiveItemsOwned,
			},

			scannedItems = avatarData.scannedItems,
		}

		HttpQueue.sendToPlay3("/game-events/player-analysis", payload, {
			onSuccess = function()
				log("Player analysis sent for:", visitorId:sub(1, 12) .. "...")
			end,
		})

		task.wait(Config.PLAYER_ANALYSIS_DELAY or 0.5)
	end

	isProcessingAnalysis = false
end

local function queuePlayerAnalysis(player)
	if not Config.ENABLE_PLAYER_ANALYSIS then
		return
	end
	table.insert(analysisQueue, player)
	task.spawn(processAnalysisQueue)
end

Players.PlayerAdded:Connect(queuePlayerAnalysis)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(queuePlayerAnalysis, player)
end

log("Player analyzer ready")
