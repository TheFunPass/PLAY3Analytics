--[[
	PLAY3 Analytics SDK Configuration

	SETUP:
	1. Get your API key from https://play3.ai
	2. Set your API_KEY below
	3. That's it! Analytics will automatically track:
	   - Player sessions (join time, play duration)
	   - All purchases (dev products and gamepasses)
]]

return {
	API_URL = "https://play3-ai-assistant-605640375727.us-central1.run.app",

	-- Your PLAY3 API key (required)
	API_KEY = "YOUR_API_KEY_HERE",

	-- Session reporting interval (seconds)
	SESSION_INTERVAL = 60,

	-- Enable debug logging
	debug = false,
}
