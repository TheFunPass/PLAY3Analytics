--[[
	PLAY3 Combined SDK Configuration

	SETUP:
	1. Get your API keys from https://play3.ai
	2. Set ATTRIBUTION_API_KEY for deep link attribution tracking
	3. Set PLAY3_API_KEY for analytics (sessions, purchases, player analysis)
	4. That's it! The SDK will automatically track:
	   - Player attribution from deep links (p3_ tokens)
	   - Player sessions (join time, play duration)
	   - All purchases (dev products and gamepasses)
	   - Player profile analysis (avatar, social, account info)
]]

return {
	-- ============ API ENDPOINTS ============
	-- Attribution API (deep link tracking) - reels.play3.ai
	ATTRIBUTION_API_URL = "https://reels.play3.ai",

	-- PLAY3 API (sessions, purchases, player analysis) - BigQuery backend
	PLAY3_API_URL = "https://play3-ai-assistant-605640375727.us-central1.run.app",

	-- ============ API KEYS ============
	-- Your attribution API key (for deep link attribution tracking)
	-- Get from: https://reels.play3.ai/brand (Brand Dashboard > Deeplinks > API Keys)
	-- Leave as placeholder if you're not using deep link attribution.
	ATTRIBUTION_API_KEY = "YOUR_ATTRIBUTION_API_KEY_HERE",

	-- Your PLAY3 API key (for sessions, purchases, player analysis)
	-- Get from: https://play3.ai
	PLAY3_API_KEY = "YOUR_PLAY3_API_KEY_HERE",

	-- ============ TIMING SETTINGS ============
	-- Session reporting interval (seconds) - batches all player sessions
	SESSION_INTERVAL = 60,

	-- Delay between HTTP requests (seconds) - prevents rate limiting
	HTTP_DELAY = 0.1,

	-- Player analysis queue delay (seconds) - space out analysis requests
	PLAYER_ANALYSIS_DELAY = 0.5,

	-- ============ FEATURE FLAGS ============
	-- Enable/disable specific tracking features
	ENABLE_ATTRIBUTION = true,      -- Track deep link attribution
	ENABLE_SESSIONS = true,         -- Track player sessions
	ENABLE_PURCHASES = true,        -- Track purchases
	ENABLE_PLAYER_ANALYSIS = true,  -- Track player profiles

	-- ============ DEBUG ============
	-- Enable debug logging (set to false in production)
	debug = true,
}
