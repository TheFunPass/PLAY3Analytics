--!strict
--[[
	PLAY3 SDK - Player Analysis
	Sends comprehensive player profile to backend on join
	Backend stores this as baseline and tracks history
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local GroupService = game:GetService("GroupService")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local LocalizationService = game:GetService("LocalizationService")
local PolicyService = game:GetService("PolicyService")

-- Don't run in edit mode
if not RunService:IsRunning() then
	return
end

local Config = require(script.Parent.Parent.Config)
local HashLib = require(script.Parent.HashLib.init)

------------------------------------------------------------
-- CONFIGURATION
------------------------------------------------------------
local API_URL = Config.API_URL .. "/game-events/player-analysis"
local API_KEY = Config.API_KEY

local ASSET_LOOKUP_DELAY = 0.15
local MAX_ITEMS_TO_SCAN = 20
local HTTP_SEND_DELAY = 0.5
local EXPENSIVE_ITEM_THRESHOLD = 10000 -- Robux

------------------------------------------------------------
-- STATE & CACHING
------------------------------------------------------------
local assetInfoCache: { [number]: any } = {}
local requestQueue = {}
local isProcessingQueue = false

------------------------------------------------------------
-- HASH (for playerId obfuscation using SHA256)
------------------------------------------------------------
local function hashPlayerId(userId: number): string
	return HashLib.sha256(tostring(userId))
end

------------------------------------------------------------
-- HTTP QUEUE SYSTEM
------------------------------------------------------------
local function processQueue()
	if isProcessingQueue then return end
	isProcessingQueue = true

	while #requestQueue > 0 do
		local payload = table.remove(requestQueue, 1)

		local success, result = pcall(function()
			return HttpService:PostAsync(
				API_URL,
				HttpService:JSONEncode(payload),
				Enum.HttpContentType.ApplicationJson,
				false,
				{ ["x-api-key"] = API_KEY }
			)
		end)

		if success then
			print("[PLAY3 Analytics] Player analysis sent for:", payload.playerId:sub(1, 12) .. "...")
		else
			warn("[PLAY3 Analytics] Failed:", tostring(result))
		end

		task.wait(HTTP_SEND_DELAY)
	end

	isProcessingQueue = false
end

local function addToQueue(payload)
	table.insert(requestQueue, payload)
	task.spawn(processQueue)
end

------------------------------------------------------------
-- DEVICE TYPE DETECTION
------------------------------------------------------------
local function getDeviceType(): string
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "Mobile"
	elseif UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "Console"
	else
		return "Desktop"
	end
end

------------------------------------------------------------
-- ASSET SCANNING
------------------------------------------------------------
local function getAssetInfo(assetId: number)
	if assetInfoCache[assetId] then return assetInfoCache[assetId] end

	local success, info = pcall(function()
		return MarketplaceService:GetProductInfo(assetId, Enum.InfoType.Asset)
	end)

	if success and info then
		local data = {
			name = info.Name or "Unknown",
			price = info.PriceInRobux or 0,
			isLimited = info.IsLimited or false,
			isLimitedUnique = info.IsLimitedUnique or false,
			isRobloxCreated = info.Creator and info.Creator.Name == "Roblox" or false
		}
		assetInfoCache[assetId] = data
		return data
	end
	return nil
end

local function scanAvatar(player: Player)
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
		scannedItems = {}
	}

	local success, desc = pcall(function()
		return Players:GetHumanoidDescriptionFromUserId(player.UserId)
	end)

	if not success or not desc then return result end

	local accessories = desc:GetAccessories(true)
	local scanCount = math.min(#accessories, MAX_ITEMS_TO_SCAN)
	result.totalItemsWorn = #accessories

	for i = 1, scanCount do
		local assetId = accessories[i].AssetId
		local info = getAssetInfo(assetId)

		if info then
			result.totalWornValue += info.price

			if info.price > result.highestItemValue then
				result.highestItemValue = info.price
				result.highestItemName = info.name
			end

			if info.price >= EXPENSIVE_ITEM_THRESHOLD then
				result.expensiveItemsOwned += 1
			end

			if info.isLimited then
				result.limitedCount += 1
			end

			if info.isLimitedUnique then
				result.limitedUniqueCount += 1
			end

			if info.isRobloxCreated then
				result.robloxItemCount += 1
			else
				result.ugcItemCount += 1
			end

			table.insert(result.scannedItems, {
				name = info.name,
				price = info.price,
				isLimited = info.isLimited
			})
		end
		task.wait(ASSET_LOOKUP_DELAY)
	end
	return result
end

------------------------------------------------------------
-- SOCIAL DATA
------------------------------------------------------------
local function getSocialData(player: Player)
	local social = {
		friendsCount = 0,
		groupCount = 0,
		highRankGroupCount = 0
	}

	-- Groups
	local gSuccess, groups = pcall(function()
		return GroupService:GetGroupsAsync(player.UserId)
	end)
	if gSuccess and groups then
		social.groupCount = #groups
		for _, group in ipairs(groups) do
			if group.Rank and group.Rank > 200 then
				social.highRankGroupCount += 1
			end
		end
	end

	-- Friends (limited pages)
	local fSuccess, pages = pcall(function()
		return Players:GetFriendsAsync(player.UserId)
	end)
	if fSuccess and pages then
		local count = 0
		local maxPages = 3
		for _ = 1, maxPages do
			local items = pages:GetCurrentPage()
			count += #items
			if pages.IsFinished then break end
			local nextOk = pcall(function() pages:AdvanceToNextPageAsync() end)
			if not nextOk then break end
		end
		social.friendsCount = count
	end

	return social
end

------------------------------------------------------------
-- CORE ANALYSIS (ON JOIN)
------------------------------------------------------------
local function onPlayerAdded(player: Player)
	task.spawn(function()
		print("[PLAY3 Analytics] Analyzing player:", player.Name)

		local avatarData = scanAvatar(player)
		local socialData = getSocialData(player)
		local deviceType = getDeviceType()

		-- Get age bracket (wrapped in pcall as property may not exist)
		local ageBracket = "unknown"
		pcall(function()
			if player.AgeBracket == Enum.AgeBracket.AgeUnder13 then
				ageBracket = "Under13"
			elseif player.AgeBracket == Enum.AgeBracket.Age13OrOver then
				ageBracket = "13+"
			end
		end)

		-- Amendment PA-2026-001: Get country code
		local country = "unknown"
		pcall(function()
			country = LocalizationService:GetCountryRegionForPlayerAsync(player)
		end)

		-- Amendment PA-2026-001: Get policy signals
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

		-- Amendment PA-2026-001: Get network ping
		local pingMs = 0
		pcall(function()
			pingMs = math.floor(player:GetNetworkPing() * 1000) -- Convert to ms
		end)

		-- Amendment PA-2026-001: Check if VIP server
		local isVIPServer = game.PrivateServerId ~= "" and game.PrivateServerId ~= nil

		-- Build payload matching expected schema
		local payload = {
			gameId = tostring(game.GameId),
			timestamp = DateTime.now():ToIsoDate(),
			playerId = hashPlayerId(player.UserId),
			eventType = "player_analysis",

			account = {
				isPremium = (player.MembershipType == Enum.MembershipType.Premium),
				accountAgeDays = player.AccountAge,
				locale = player.LocaleId or "en-us",
				ageBracket = ageBracket,
				deviceType = deviceType,
				-- Amendment PA-2026-001 fields (nested in account for schema compatibility)
				country = country,
				hasVerifiedBadge = player.HasVerifiedBadge or false,
				pingMs = pingMs,
				isVIPServer = isVIPServer,
				policySignals = policySignals,
			},

			-- History: Placeholder - requires backend/datastore integration
			history = {
				previousVisits = 0,      -- TODO: Track in datastore
				previousPurchases = 0,   -- TODO: Track in datastore
				lifetimeSpend = 0,       -- TODO: Track in datastore
				totalSessions = 0,       -- TODO: Track in datastore
				highestCheckpoint = 0    -- TODO: Game-specific
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
				expensiveItemsOwned = avatarData.expensiveItemsOwned
			},

			scannedItems = avatarData.scannedItems
		}

		addToQueue(payload)
	end)
end

------------------------------------------------------------
-- CONNECT
------------------------------------------------------------
Players.PlayerAdded:Connect(onPlayerAdded)

-- Handle existing players
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

print("[PLAY3 Analytics] Player analyzer ready")