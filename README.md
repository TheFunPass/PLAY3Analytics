# PLAY3 Analytics SDK

A drop-in analytics + deep-link attribution SDK for Roblox games. Player sessions, profile data, and purchases stream to the PLAY3 backend automatically; deep-link attribution is opt-in.

## What it tracks

| Module | Endpoint | When |
|---|---|---|
| **Sessions** | `POST /game-events/sessions` | Every 60 seconds — batched per-server snapshot |
| **Player Analysis** | `POST /game-events/player-analysis` | Once per player on join — account info, avatar, social, device |
| **Purchases** | `POST /game-events/purchases` | Every dev product or gamepass purchase |
| **Chat** | `POST /api/deeplinks/chats` | Public chat messages, batched every 30s. Filtered text only; whispers excluded |
| **Attribution** *(opt-in)* | `POST /api/deeplinks/ingest` + `/event` | Players who arrived via a `p3_` deep-link token |

Player IDs are SHA-256 hashed before leaving the game server (COPPA-friendly anonymous IDs).

## Install

Three ways, pick whichever fits your workflow.

### Option 1 — Drag & drop (no tools required)

The repo ships two pre-built model files. Download them, drag each into the right place in Studio's Explorer panel, set your API key, done.

1. Grab both files from this repo:
   - [**`PLAY3_SDK.rbxm`**](PLAY3_SDK.rbxm) — server-side logic
   - [**`PLAY3_SDK_Client.rbxm`**](PLAY3_SDK_Client.rbxm) — client-side device detection
2. **Drag** `PLAY3_SDK.rbxm` from your file manager onto `ServerScriptService` in Studio's Explorer panel.
3. **Drag** `PLAY3_SDK_Client.rbxm` onto `StarterPlayer.StarterPlayerScripts`.
4. Open `ServerScriptService.PLAY3_SDK.Config` and paste your API key over the placeholder (see [Configure](#configure)).
5. **Press F5** — analytics fires automatically.

> Note: Studio's `Insert from File…` context-menu option does **not** accept `.rbxm` model files — only `.rbxmx` or raw `.lua`. You have to drag the model file onto the target service directly. (If you'd rather not drag, use Option 3 below to clone the source.)

### Option 2 — Manual file placement

If you want to inspect or modify the source before installing:

1. `git clone https://github.com/TheFunPass/PLAY3Analytics.git` (or download the ZIP from the green Code button → Download ZIP).
2. In Studio, recreate this hierarchy by hand (right-click → Insert Object → Folder / Script / ModuleScript / LocalScript, then paste source from the matching file):
   ```
   ServerScriptService/
   └── PLAY3_SDK (Folder)
       ├── Main                       (Script)        ← Main.server.lua
       ├── Config                     (ModuleScript)  ← Config.lua
       ├── Core (Folder)
       │   ├── HashLib                (ModuleScript)  ← Core/HashLib/init.lua
       │   │   └── Base64             (ModuleScript)  ← Core/HashLib/Base64.lua
       │   ├── HttpQueue              (ModuleScript)  ← Core/HttpQueue.lua
       │   ├── PlayerState            (ModuleScript)  ← Core/PlayerState.lua
       │   └── DeviceTracker          (ModuleScript)  ← Core/DeviceTracker.lua
       ├── Analytics (Folder)
       │   ├── SessionTracker         (Script)        ← Analytics/SessionTracker.server.lua
       │   ├── PlayerAnalyzer         (Script)        ← Analytics/PlayerAnalyzer.server.lua
       │   └── PurchaseTracker        (Script)        ← Analytics/PurchaseTracker.server.lua
       └── Modules (Folder)
           └── Attribution            (ModuleScript)  ← Modules/Attribution.lua

   StarterPlayer/
   └── StarterPlayerScripts/
       └── PLAY3_SDK_Client (Folder)
           └── DeviceInfoClient       (LocalScript)   ← Client/DeviceInfoClient.client.lua
   ```
   The class of each instance matters — Scripts must be `Script` (not `ModuleScript`) so they auto-run.
3. Set your API key in `Config` and press F5.

### Option 3 — Rojo (recommended for ongoing development)

1. `git clone https://github.com/TheFunPass/PLAY3Analytics.git` into your project.
2. `rojo serve default.project.json` and connect via the Rojo Studio plugin to live-sync, **or** `rojo build default.project.json -o PLAY3Analytics.rbxlx` to produce a place file you can open directly.
3. The project mounts both pieces automatically:
   - `ServerScriptService.PLAY3_SDK`
   - `StarterPlayer.StarterPlayerScripts.PLAY3_SDK_Client`
4. Edit `Config.lua` on disk; live-sync handles the rest.

### Building the model files yourself

Both `.rbxm` files are committed, but if you fork and want to rebuild:

```bash
rojo build server.project.json -o PLAY3_SDK.rbxm
rojo build client.project.json -o PLAY3_SDK_Client.rbxm
```

## Configure

Open `Config.lua` and replace the two placeholders:

```lua
PLAY3_API_KEY = "your-play3-api-key",            -- analytics (sessions, purchases, player analysis)
ATTRIBUTION_API_KEY = "your-attribution-api-key", -- deep link attribution (optional)
```

Leave `ATTRIBUTION_API_KEY` as `"YOUR_ATTRIBUTION_API_KEY_HERE"` if you're not using deep-link attribution — Main will detect the placeholder and skip loading the Attribution module.

Feature flags (`ENABLE_SESSIONS`, `ENABLE_PURCHASES`, `ENABLE_PLAYER_ANALYSIS`, `ENABLE_ATTRIBUTION`, `ENABLE_CHAT_CAPTURE`) are also in `Config.lua`. Set `debug = false` before shipping to silence the log lines.

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

