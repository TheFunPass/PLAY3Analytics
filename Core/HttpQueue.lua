--[[
	PLAY3 SDK - Unified HTTP Queue
	Centralized HTTP request handling with rate limiting
	Prevents hitting Roblox's 500 req/min limit
]]

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Parent.Config)

local HttpQueue = {}

-- Request queue
local requestQueue = {}
local isProcessingQueue = false

-- Stats for debugging
local stats = {
	totalRequests = 0,
	successfulRequests = 0,
	failedRequests = 0,
}

-- Debug logging
local function log(...)
	if Config.debug then
		print("[PLAY3 HttpQueue]", ...)
	end
end

-- Process the queue
local function processQueue()
	if isProcessingQueue or #requestQueue == 0 then
		return
	end

	isProcessingQueue = true

	while #requestQueue > 0 do
		local request = table.remove(requestQueue, 1)
		stats.totalRequests = stats.totalRequests + 1

		local success, result = pcall(function()
			return HttpService:RequestAsync({
				Url = request.url,
				Method = "POST",
				Headers = {
					["Content-Type"] = "application/json",
					["X-API-Key"] = request.apiKey,
				},
				Body = HttpService:JSONEncode(request.payload),
			})
		end)

		if success and result.Success then
			stats.successfulRequests = stats.successfulRequests + 1
			log("Request sent:", request.endpoint, "- Status:", result.StatusCode)

			-- Call success callback if provided
			if request.onSuccess then
				task.spawn(function()
					pcall(request.onSuccess, result)
				end)
			end
		else
			stats.failedRequests = stats.failedRequests + 1
			local errorMsg = success and result.Body or tostring(result)
			warn("[PLAY3 HttpQueue] Request failed:", request.endpoint, "-", errorMsg)

			-- Call error callback if provided
			if request.onError then
				task.spawn(function()
					pcall(request.onError, errorMsg)
				end)
			end
		end

		-- Delay between requests to prevent rate limiting
		task.wait(Config.HTTP_DELAY or 0.1)
	end

	isProcessingQueue = false
end

-- Add request to queue
function HttpQueue.enqueue(url, apiKey, payload, options)
	options = options or {}

	table.insert(requestQueue, {
		url = url,
		apiKey = apiKey,
		payload = payload,
		endpoint = options.endpoint or url,
		onSuccess = options.onSuccess,
		onError = options.onError,
		priority = options.priority or 0,
	})

	-- Start processing if not already
	task.spawn(processQueue)
end

-- Convenience method for Attribution API
function HttpQueue.sendToAttribution(endpoint, payload, options)
	local url = Config.ATTRIBUTION_API_URL .. endpoint
	HttpQueue.enqueue(url, Config.ATTRIBUTION_API_KEY, payload, {
		endpoint = "Attribution:" .. endpoint,
		onSuccess = options and options.onSuccess,
		onError = options and options.onError,
	})
end

-- Convenience method for PLAY3 API
function HttpQueue.sendToPlay3(endpoint, payload, options)
	local url = Config.PLAY3_API_URL .. endpoint
	HttpQueue.enqueue(url, Config.PLAY3_API_KEY, payload, {
		endpoint = "PLAY3:" .. endpoint,
		onSuccess = options and options.onSuccess,
		onError = options and options.onError,
	})
end

-- Get queue stats
function HttpQueue.getStats()
	return {
		queueLength = #requestQueue,
		totalRequests = stats.totalRequests,
		successfulRequests = stats.successfulRequests,
		failedRequests = stats.failedRequests,
		isProcessing = isProcessingQueue,
	}
end

-- Flush queue immediately (use sparingly)
function HttpQueue.flush()
	task.spawn(processQueue)
end

log("HTTP Queue initialized")

return HttpQueue
