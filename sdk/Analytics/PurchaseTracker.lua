--[[
	PLAY3 Purchase Tracker
	Reports all purchases (dev products and gamepasses) to analytics backend
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

-- Don't run in edit mode
if not RunService:IsRunning() then
	return {}
end

local HashLib = require(script.Parent.HashLib.init)
local Config = require(script.Parent.Parent.Config)

-- Toggle Studio testing (only applies when game is running in Studio)
local ALLOW_STUDIO = true

-- Pull endpoint/key from Config
local PURCHASES_ENDPOINT = Config.API_URL .. "/game-events/purchases"
local API_KEY = Config.API_KEY or ""

local PurchaseTracker = {}
local playerPurchases = {} -- [userId] = { purchases array }

local function generateAnonId(userId)
	return HashLib.sha256(tostring(userId))
end

local function getIsoTimestampUTC()
	return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function log(...)
	if Config.debug then
		print("[PLAY3 Purchases]", ...)
	end
end

local function sendPurchaseEvent(userId, purchaseData)
	-- Allow Studio if toggle is on
	if RunService:IsStudio() and not ALLOW_STUDIO then
		return
	end

	local payload = {
		gameId = tostring(game.GameId),
		timestamp = getIsoTimestampUTC(),
		playerId = generateAnonId(userId),
		purchase = purchaseData,
	}

	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = PURCHASES_ENDPOINT,
			Method = "POST",
			Headers = {
				["content-type"] = "application/json",
				["x-api-key"] = API_KEY,
			},
			Body = HttpService:JSONEncode(payload),
		})
	end)

	if not ok then
		warn("[PLAY3 Purchases] HTTP error:", res)
		return
	end

	if not res.Success then
		warn("[PLAY3 Purchases] Failed:", res.StatusCode, res.Body)
	else
		log("Purchase reported:", purchaseData.productType, purchaseData.productId)
	end
end

-- Track Developer Product purchases
MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, isPurchased)
	if not isPurchased then return end

	local player = Players:GetPlayerByUserId(userId)
	if not player then return end

	-- Record locally
	local purchases = playerPurchases[userId] or {}
	table.insert(purchases, {
		productId = productId,
		productType = "devproduct",
		timestamp = os.time(),
	})
	playerPurchases[userId] = purchases

	-- Send to backend
	sendPurchaseEvent(userId, {
		productId = productId,
		productType = "devproduct",
		price = 0, -- Price unknown for dev products without API lookup
	})

	log("Product purchase:", player.Name, productId)
end)

-- Track GamePass purchases
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
	if not wasPurchased then return end
	if not player then return end

	local userId = player.UserId

	-- Try to get gamepass price
	local price = 0
	pcall(function()
		local info = MarketplaceService:GetProductInfo(gamePassId, Enum.InfoType.GamePass)
		price = info.PriceInRobux or 0
	end)

	-- Record locally
	local purchases = playerPurchases[userId] or {}
	table.insert(purchases, {
		productId = gamePassId,
		productType = "gamepass",
		price = price,
		timestamp = os.time(),
	})
	playerPurchases[userId] = purchases

	-- Send to backend
	sendPurchaseEvent(userId, {
		productId = gamePassId,
		productType = "gamepass",
		price = price,
	})

	log("Gamepass purchase:", player.Name, gamePassId, "price:", price)
end)

-- Cleanup on player leave
Players.PlayerRemoving:Connect(function(player)
	playerPurchases[player.UserId] = nil
end)

-- Public API
function PurchaseTracker:GetPlayerPurchases(player)
	return playerPurchases[player.UserId] or {}
end

function PurchaseTracker:GetTotalSpent(player)
	local purchases = playerPurchases[player.UserId] or {}
	local total = 0
	for _, p in ipairs(purchases) do
		total = total + (p.price or 0)
	end
	return total
end

log("Purchase tracking started")

return PurchaseTracker
