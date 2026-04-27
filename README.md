# PLAY3 Analytics SDK

Lightweight analytics for Roblox games. Automatically tracks player sessions and all in-game purchases.

## Features

- **Session Tracking** - Player join/leave times, play duration
- **Purchase Tracking** - All dev products and gamepass purchases
- **Anonymous** - Player IDs are SHA256 hashed
- **Lightweight** - Minimal performance impact

## Installation

### Option 1: Rojo (Recommended)

```bash
rojo build -o PLAY3Analytics.rbxm
```

Then insert the `.rbxm` file into your game.

### Option 2: Manual Installation

Place files in your Roblox hierarchy:

```
ReplicatedStorage/
└── PLAY3_ANALYTICS/
    ├── Config              (ModuleScript) ← sdk/Config.lua
    └── Analytics/          (Folder)
        ├── HashLib/
        │   ├── init        (ModuleScript) ← sdk/Analytics/HashLib/init.lua
        │   └── Base64      (ModuleScript) ← sdk/Analytics/HashLib/Base64.lua
        ├── PLAY3_Analytics (ModuleScript) ← sdk/Analytics/PLAY3_Analytics.lua
        ├── Profileanalyzer (ModuleScript) ← sdk/Analytics/Profileanalyzer.lua
        └── PurchaseTracker (ModuleScript) ← sdk/Analytics/PurchaseTracker.lua

ServerScriptService/
└── PLAY3_ANALYTICS_SERVER/
    └── Main                (Script) ← sdk/Main.server.lua
```

## Configuration

Edit `Config.lua`:

```lua
return {
    API_URL = "https://play3-ai-assistant-605640375727.us-central1.run.app",

    -- Your PLAY3 API key (required)
    API_KEY = "YOUR_API_KEY_HERE",  -- Get from https://play3.ai

    -- Session reporting interval (seconds)
    SESSION_INTERVAL = 60,

    -- Enable debug logging
    debug = false,
}
```

## What Gets Tracked

### Sessions (every 60 seconds)
- Game ID
- Player count
- Per-player: anonymous ID, play time

### Purchases (on each purchase)
- Game ID
- Anonymous player ID
- Product ID and type (devproduct/gamepass)
- Price (for gamepasses)

## Debug Mode

Set `debug = true` in Config to see logs:

```
[PLAY3 Analytics] Session tracking started (interval: 60s)
[PLAY3 Analytics] Sessions sent: 5 players
[PLAY3 Purchases] Product purchase: 123456789
[PLAY3 Purchases] Gamepass purchase: 987654321 price: 100
```

## License

MIT
