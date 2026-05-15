--[[
	PLAY3 SDK - Purchase Tracking (standalone Server Script)
	Tracks all purchases (dev products and gamepasses).
	Sends to PLAY3 API for analytics; also forwards to Attribution API
	if the player is attributed (joinId present in PlayerState).
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")

if not RunService:IsRunning() then
	return
end

local Config = require(script.Parent.Parent.Config)
local PlayerState = require(script.Parent.Parent.Core.PlayerState)
local HttpQueue = require(script.Parent.Parent.Core.HttpQueue)

local function log(...)
	if Config.debug then
		print("[PLAY3 Purchases]", ...)
	end
end

local function getIsoTimestampUTC()
	return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function trackPurchase(userId, purchaseData)
	local visitorId = PlayerState.getVisitorIdByUserId(userId)
	local state = PlayerState.getStateByUserId(userId)

	HttpQueue.sendToPlay3("/game-events/purchases", {
		gameId = tostring(game.GameId),
		timestamp = getIsoTimestampUTC(),
		playerId = visitorId,
		purchase = purchaseData,
	}, {
		onSuccess = function()
			log("Purchase reported to PLAY3:", purchaseData.productType, purchaseData.productId)
		end,
	})

	if state and state.joinId then
		HttpQueue.sendToAttribution("/api/deeplinks/event", {
			joinId = state.joinId,
			eventType = "purchase",
			eventData = {
				productId = tostring(purchaseData.productId),
				price = purchaseData.price,
				productType = purchaseData.productType,
				currency = "robux",
			},
		}, {
			onSuccess = function()
				log("Purchase reported to Attribution:", purchaseData.productId)
			end,
		})
	end
end

MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, isPurchased)
	if not Config.ENABLE_PURCHASES then return end
	if not isPurchased then return end

	local player = Players:GetPlayerByUserId(userId)
	if not player then return end

	local price = 0
	pcall(function()
		local info = MarketplaceService:GetProductInfo(productId, Enum.InfoType.Product)
		price = info.PriceInRobux or 0
	end)

	trackPurchase(userId, {
		productId = productId,
		productType = "devproduct",
		price = price,
	})

	log("Dev product purchase:", player.Name, productId, "price:", price)
end)

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
	if not Config.ENABLE_PURCHASES then return end
	if not wasPurchased or not player then return end

	local price = 0
	pcall(function()
		local info = MarketplaceService:GetProductInfo(gamePassId, Enum.InfoType.GamePass)
		price = info.PriceInRobux or 0
	end)

	trackPurchase(player.UserId, {
		productId = gamePassId,
		productType = "gamepass",
		price = price,
	})

	log("Gamepass purchase:", player.Name, gamePassId, "price:", price)
end)

log("Purchase tracking started")
