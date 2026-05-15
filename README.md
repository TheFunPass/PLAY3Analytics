# PLAY3 Analytics SDK

A drop-in analytics + deep-link attribution SDK for Roblox games. Player sessions, profile data, and purchases stream to the PLAY3 backend automatically; deep-link attribution is opt-in.

## What it tracks

| Module | Endpoint | When |
|---|---|---|
| **Sessions** | `POST /game-events/sessions` | Every 60 seconds — batched per-server snapshot |
| **Player Analysis** | `POST /game-events/player-analysis` | Once per player on join — account info, avatar, social, device |
| **Purchases** | `POST /game-events/purchases` | Every dev product or gamepass purchase |
| **Attribution** *(opt-in)* | `POST /api/deeplinks/ingest` + `/event` | Players who arrived via a `p3_` deep-link token |

Player IDs are SHA-256 hashed before leaving the game server (COPPA-friendly anonymous IDs).

## Install (Rojo)

1. `git clone https://github.com/TheFunPass/PLAY3Analytics.git` into your project root (or add as a submodule).
2. Build into your place: `rojo build path/to/PLAY3Analytics/default.project.json -o PLAY3Analytics.rbxlx` and merge, **or** use `rojo serve` and the Studio plugin to live-sync.
3. The project mounts as:
   - `ServerScriptService.PLAY3_SDK` — server-side logic
   - `StarterPlayer.StarterPlayerScripts.PLAY3_SDK_Client` — device-detection LocalScript
4. Set your API keys in `Config.lua` (see below) and save the place.

## Configure

Open `Config.lua` and replace the two placeholders:

```lua
PLAY3_API_KEY = "your-play3-api-key",            -- analytics (sessions, purchases, player analysis)
ATTRIBUTION_API_KEY = "your-attribution-api-key", -- deep link attribution (optional)
```

Leave `ATTRIBUTION_API_KEY` as `"YOUR_ATTRIBUTION_API_KEY_HERE"` if you're not using deep-link attribution — Main will detect the placeholder and skip loading the Attribution module.

Feature flags (`ENABLE_SESSIONS`, `ENABLE_PURCHASES`, `ENABLE_PLAYER_ANALYSIS`, `ENABLE_ATTRIBUTION`) are also in `Config.lua`. Set `debug = false` before shipping to silence the log lines.

## Layout

```
PLAY3_SDK/                          (ServerScriptService)
├── Main                            Script        — Attribution bootstrap (opt-in)
├── Config                          ModuleScript
├── Core/
│   ├── HashLib (+ Base64 child)    ModuleScript  — SHA-256 for anonymous IDs
│   ├── HttpQueue                   ModuleScript  — rate-limited HTTP client
│   ├── PlayerState                 ModuleScript  — per-player state cache
│   └── DeviceTracker               ModuleScript  — receives device info from client
├── Analytics/                      ← standalone Server Scripts (always on)
│   ├── SessionTracker              Script
│   ├── PlayerAnalyzer              Script
│   └── PurchaseTracker             Script
└── Modules/
    └── Attribution                 ModuleScript  — opt-in, has a public API

PLAY3_SDK_Client/                   (StarterPlayer.StarterPlayerScripts)
└── DeviceInfoClient                LocalScript   — detects device, reports to server
```

### Why split this way?

- **Analytics is unconditional.** Sessions, player analysis, and purchases live in `Analytics/` as standalone Server Scripts so they fire on game start regardless of any developer setup beyond pasting a key.
- **Attribution is conditional.** It needs its own API key and is opt-in. `Main` checks the config and `require`s it only when a real key is set, so unconfigured games don't spam an attribution endpoint they're not using.
- **Device detection is client-side.** Server-side `UserInputService` reports nothing useful (the server has no input devices), so a small LocalScript detects the player's device and reports back via a RemoteEvent. The server falls back to `IsTenFootInterface` for Console if the client hasn't responded.

## Public API (Attribution)

If you're using deep-link attribution, you can record custom events from anywhere in your server code:

```lua
local Attribution = require(game.ServerScriptService.PLAY3_SDK.Modules.Attribution)

-- One-line wrappers
Attribution:TrackBadge(player, badgeId, "Master Builder")
Attribution:TrackMilestone(player, "level_up", { level = 10 })
Attribution:TrackPurchase(player, productId, price, "robux", "devproduct")

-- Or fully custom
Attribution:TrackEvent(player, "quest_complete", { questId = "tutorial_01" })

-- Inspect attribution state
if Attribution:IsAttributed(player) then
    print("Source:", Attribution:GetSource(player))  -- youtube, tiktok, etc.
end
```

Attribution functions are no-ops for players who didn't arrive via a deep link, so you can call them unconditionally.

## Player privacy

`PlayerId`s sent to the backend are `sha256(player.UserId)` — anonymous, one-way. Raw UserIds never leave your server.

## Requirements

- Roblox Studio with HTTP requests allowed for the experience (`Game Settings → Security → Allow HTTP Requests`).
- API keys from PLAY3 (sessions/purchases/analysis) and optionally from `reels.play3.ai` (deep-link attribution).

## License

MIT — see [LICENSE](LICENSE).
