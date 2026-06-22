--[[
	PLAY3 SDK - In-World Leaderboard Board

	Attaches a leaderboard SurfaceGui to any BasePart in the workspace.
	The brand designs the physical board (a wall-mounted billboard, a
	kiosk panel, a podium, whatever Part they want); this module owns the
	UI surface on top.

	USAGE — single call:
		local LeaderboardBoard = require(SSS.PLAY3_SDK.Modules.LeaderboardBoard)
		LeaderboardBoard:MountToPart(workspace.MyBillboardPart)

	USAGE — auto-mount via CollectionService tags (zero code per board):
		-- In Roblox Studio, tag any BasePart with "Play3Leaderboard" via the
		-- Tags editor (Studio Settings → Studio → Show Tags Editor)
		LeaderboardBoard:AutoMountTagged()

	OPTIONS (second arg to MountToPart):
		configId     string — when set, the board renders a brand-defined
		             custom leaderboard (via Modules/CustomLeaderboard) instead
		             of the default creator leaderboard. Get the configId
		             from your PLAY3 dashboard's Leaderboards page.
		face         Enum.NormalId — which face the GUI renders on
		             (default Front, the +Z face)
		title        string — header text (default "TOP CREATORS")
		limit        number — max rows (default 10, capped at 25)
		pixelsPerStud number — SurfaceGui resolution (default 50)
		theme        table — { panelBg, panelStroke, rowBg, accent,
		                       textPrimary, textMuted }
		                     overrides for the default dark + lime palette

	HOW IT WORKS:
		- Server-side render: all players see the same UI. The SurfaceGui
		  and its children replicate to clients automatically — no
		  RemoteEvent plumbing needed.
		- Calls Leaderboard:StartAutoRefresh() under the hood (idempotent),
		  so the board re-renders whenever a fresh snapshot arrives.
		- Roblox usernames are resolved server-side via
		  Players:GetNameFromUserIdAsync; results are cached so re-renders
		  with the same player set don't re-fetch.
		- Headshots use rbxthumb:// URLs (no async load, native Roblox
		  thumbnail pipeline, cached by the client).

	EMPTY STATE:
		If the leaderboard has no Roblox-linked creators yet, the board
		shows a polite "Leaderboard coming soon" message instead of empty
		rows. The board never just disappears.
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

-- Edit-mode safe — return a no-op module so brand `require`s don't error
-- in Studio when not playing.
if not RunService:IsRunning() then return {} end

local Config = require(script.Parent.Parent.Config)
local Leaderboard = require(script.Parent.Leaderboard)
local CustomLeaderboard = require(script.Parent.CustomLeaderboard)

local LeaderboardBoard = {}

local DEFAULT_TAG = "Play3Leaderboard"
local SURFACE_GUI_NAME = "Play3LeaderboardBoard"

-- ── DEFAULT THEME ──────────────────────────────────────────────────────
-- Glass-dark with PLAY3 lime. Brands override per-board via options.theme.
local DEFAULT_THEME = {
	panelBg     = Color3.fromRGB(10, 10, 20),
	panelStroke = Color3.fromRGB(48, 48, 58),
	rowBg       = Color3.fromRGB(20, 20, 35),
	accent      = Color3.fromRGB(173, 255, 0),
	textPrimary = Color3.fromRGB(255, 255, 255),
	textMuted   = Color3.fromRGB(160, 160, 175),
}

local function log(...)
	if Config and Config.debug then
		print("[PLAY3 LeaderboardBoard]", ...)
	end
end

local function formatCount(n)
	n = n or 0
	if n >= 1_000_000 then return string.format("%.1fM", n / 1_000_000) end
	if n >= 1_000 then return string.format("%.1fK", n / 1_000) end
	return tostring(n)
end

-- Server-side username cache. Roblox APIs are rate-limited so we hold onto
-- results across re-renders. Process-lifetime cache.
local nameCache = {}

-- Async-resolve a Roblox username into the given TextLabel without yielding
-- the calling thread. Used inside buildRow so render() never blocks
-- mid-build, which is what was causing duplicate rows (two concurrent
-- renders interleaving their builds while both yielded on the name lookup).
local function bindName(robloxUserId, label)
	if nameCache[robloxUserId] then
		label.Text = nameCache[robloxUserId]
		return
	end
	label.Text = "..."
	task.spawn(function()
		local ok, name = pcall(function()
			return Players:GetNameFromUserIdAsync(robloxUserId)
		end)
		local resolved = (ok and name) or "Player"
		nameCache[robloxUserId] = resolved
		if label and label.Parent then
			label.Text = resolved
		end
	end)
end

-- ── GUI BUILD ──────────────────────────────────────────────────────────

local function buildRoot(sg, opts, theme)
	-- Outer panel — fills the SurfaceGui canvas
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.fromScale(1, 1)
	panel.BackgroundColor3 = theme.panelBg
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Parent = sg

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = theme.panelStroke
	stroke.Thickness = 2
	stroke.Transparency = 0.3
	stroke.Parent = panel

	-- AspectRatioConstraint keeps the panel inside the surface bounds even
	-- if the Part has odd dimensions
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.03, 0)
	pad.PaddingBottom = UDim.new(0.03, 0)
	pad.PaddingLeft = UDim.new(0.04, 0)
	pad.PaddingRight = UDim.new(0.04, 0)
	pad.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0.015, 0)
	layout.Parent = panel

	-- Header
	local header = Instance.new("TextLabel")
	header.Name = "Header"
	header.LayoutOrder = 1
	header.Size = UDim2.new(1, 0, 0.08, 0)
	header.BackgroundTransparency = 1
	header.Text = opts.title or "TOP CREATORS"
	header.TextColor3 = theme.textPrimary
	header.Font = Enum.Font.GothamBold
	header.TextScaled = true
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Parent = panel

	local headerConstraint = Instance.new("UITextSizeConstraint")
	headerConstraint.MaxTextSize = 48
	headerConstraint.MinTextSize = 14
	headerConstraint.Parent = header

	-- Column header — labels the columns (Rank · Player · the metric) so
	-- players reading the board know what each value is. The metric label is
	-- filled in render() from the board's valueLabel/metricKey.
	local colHeader = Instance.new("Frame")
	colHeader.Name = "ColumnHeader"
	colHeader.LayoutOrder = 2
	colHeader.Size = UDim2.new(1, -10, 0.05, 0)
	colHeader.BackgroundTransparency = 1
	colHeader.Parent = panel

	local chPad = Instance.new("UIPadding")
	chPad.PaddingLeft = UDim.new(0.02, 0)
	chPad.PaddingRight = UDim.new(0.02, 0)
	chPad.Parent = colHeader

	local function colLabel(lblName, text, xScale, wScale, align)
		local l = Instance.new("TextLabel")
		l.Name = lblName
		local right = align == Enum.TextXAlignment.Right
		l.AnchorPoint = Vector2.new(right and 1 or 0, 0.5)
		l.Position = UDim2.new(right and 1 or xScale, 0, 0.5, 0)
		l.Size = UDim2.new(wScale, 0, 0.85, 0)
		l.BackgroundTransparency = 1
		l.Text = text
		l.TextColor3 = theme.textMuted
		l.Font = Enum.Font.GothamMedium
		l.TextScaled = true
		l.TextXAlignment = align
		l.TextTruncate = Enum.TextTruncate.AtEnd
		l.Parent = colHeader
		local c = Instance.new("UITextSizeConstraint")
		c.MaxTextSize = 18
		c.MinTextSize = 8
		c.Parent = l
	end
	-- Align roughly with buildRow: rank ~left, name at 0.22, value right.
	colLabel("ColRank", "#", 0, 0.1, Enum.TextXAlignment.Left)
	colLabel("ColName", "PLAYER", 0.22, 0.45, Enum.TextXAlignment.Left)
	colLabel("ColMetric", "SCORE", 1, 0.32, Enum.TextXAlignment.Right)

	-- Rows container — ScrollingFrame so the panel handles 1 to 100 rows
	-- without changing row height. AutomaticCanvasSize.Y grows the canvas
	-- to fit exactly the rows present, so 3 entries don't leave 7 empty
	-- slots and 50 entries enable a scroll bar.
	local rows = Instance.new("ScrollingFrame")
	rows.Name = "Rows"
	rows.LayoutOrder = 3
	rows.Size = UDim2.new(1, 0, 0.87, 0)
	rows.BackgroundTransparency = 1
	rows.BorderSizePixel = 0
	rows.CanvasSize = UDim2.new(0, 0, 0, 0)
	rows.AutomaticCanvasSize = Enum.AutomaticSize.Y
	rows.ScrollingDirection = Enum.ScrollingDirection.Y
	rows.ScrollBarThickness = 6
	rows.ScrollBarImageColor3 = theme.accent
	rows.ScrollBarImageTransparency = 0.4
	rows.Active = true
	rows.Parent = panel

	local rowsLayout = Instance.new("UIListLayout")
	rowsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowsLayout.Padding = UDim.new(0, 6)
	rowsLayout.FillDirection = Enum.FillDirection.Vertical
	rowsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	rowsLayout.Parent = rows

	return panel, rows
end

local ROW_HEIGHT_PX = 56  -- fixed pixel height inside the ScrollingFrame canvas

local function buildRow(entry, theme)
	local row = Instance.new("Frame")
	row.Name = "Row_" .. tostring(entry.rank)
	row.LayoutOrder = entry.rank
	-- Width: 1 scale minus a small inset so the scroll bar (6 px) doesn't
	-- crowd the row. Height: fixed pixels — the ScrollingFrame's canvas
	-- grows to fit, so we don't need to squish rows for higher row counts.
	row.Size = UDim2.new(1, -10, 0, ROW_HEIGHT_PX)
	row.BackgroundColor3 = theme.rowBg
	row.BackgroundTransparency = 0.2
	row.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = row

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.02, 0)
	pad.PaddingRight = UDim.new(0.02, 0)
	pad.Parent = row

	-- Rank
	local rankLabel = Instance.new("TextLabel")
	rankLabel.AnchorPoint = Vector2.new(0, 0.5)
	rankLabel.Position = UDim2.new(0, 0, 0.5, 0)
	rankLabel.Size = UDim2.new(0.1, 0, 0.7, 0)
	rankLabel.BackgroundTransparency = 1
	rankLabel.Text = "#" .. tostring(entry.rank)
	rankLabel.TextColor3 = theme.accent
	rankLabel.Font = Enum.Font.GothamBold
	rankLabel.TextScaled = true
	rankLabel.TextXAlignment = Enum.TextXAlignment.Center
	rankLabel.Parent = row

	-- Headshot (circular)
	local thumb = Instance.new("ImageLabel")
	thumb.AnchorPoint = Vector2.new(0, 0.5)
	thumb.Position = UDim2.new(0.11, 0, 0.5, 0)
	thumb.Size = UDim2.new(0, 0, 0.85, 0)
	thumb.SizeConstraint = Enum.SizeConstraint.RelativeYY  -- square based on height
	thumb.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	thumb.BackgroundTransparency = 0.5
	thumb.BorderSizePixel = 0
	thumb.Image = string.format(
		"rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150",
		entry.robloxUserId
	)
	thumb.Parent = row

	local thumbCorner = Instance.new("UICorner")
	thumbCorner.CornerRadius = UDim.new(1, 0)  -- circle
	thumbCorner.Parent = thumb

	-- Name
	local nameLabel = Instance.new("TextLabel")
	nameLabel.AnchorPoint = Vector2.new(0, 0.5)
	nameLabel.Position = UDim2.new(0.22, 0, 0.32, 0)
	nameLabel.Size = UDim2.new(0.55, 0, 0.4, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.TextColor3 = theme.textPrimary
	nameLabel.Font = Enum.Font.GothamSemibold
	nameLabel.TextScaled = true
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Parent = row
	bindName(entry.robloxUserId, nameLabel)

	-- Subtitle: only the creator leaderboard has "X vids • Y views" — custom
	-- leaderboards just have a single value, so we skip the subtitle and let
	-- the name label occupy the full vertical space.
	local isCustom = entry.value ~= nil and entry.points == nil
	if not isCustom then
		local sub = Instance.new("TextLabel")
		sub.AnchorPoint = Vector2.new(0, 0.5)
		sub.Position = UDim2.new(0.22, 0, 0.7, 0)
		sub.Size = UDim2.new(0.55, 0, 0.28, 0)
		sub.BackgroundTransparency = 1
		sub.Text = string.format(
			"%d %s  •  %s views",
			entry.videos or 0,
			(entry.videos or 0) == 1 and "vid" or "vids",
			formatCount(entry.totalViews)
		)
		sub.TextColor3 = theme.textMuted
		sub.Font = Enum.Font.Gotham
		sub.TextScaled = true
		sub.TextXAlignment = Enum.TextXAlignment.Left
		sub.TextTruncate = Enum.TextTruncate.AtEnd
		sub.Parent = row
	else
		-- No subtitle row — center the name vertically.
		nameLabel.Position = UDim2.new(0.22, 0, 0.5, 0)
		nameLabel.AnchorPoint = Vector2.new(0, 0.5)
		nameLabel.Size = UDim2.new(0.55, 0, 0.6, 0)
	end

	-- Right-side value label: creator boards show "X pts", custom boards
	-- show the metric value (numeric or formatted with the unit if the
	-- caller passed one).
	local valueLabel = Instance.new("TextLabel")
	valueLabel.AnchorPoint = Vector2.new(1, 0.5)
	valueLabel.Position = UDim2.new(1, 0, 0.5, 0)
	valueLabel.Size = UDim2.new(0.18, 0, 0.55, 0)
	valueLabel.BackgroundTransparency = 1
	valueLabel.TextColor3 = theme.accent
	valueLabel.Font = Enum.Font.GothamBold
	valueLabel.TextScaled = true
	valueLabel.TextXAlignment = Enum.TextXAlignment.Right
	if isCustom then
		local v = entry.value
		valueLabel.Text = (v == nil) and "—" or formatCount(tonumber(v) or 0)
	else
		valueLabel.Text = formatCount(entry.points) .. " pts"
	end
	valueLabel.Parent = row

	return row
end

local function buildEmptyState(rowsContainer, theme)
	local msg = Instance.new("TextLabel")
	msg.Name = "EmptyState"
	msg.Size = UDim2.new(1, 0, 1, 0)
	msg.BackgroundTransparency = 1
	msg.Text = "Leaderboard coming soon"
	msg.TextColor3 = theme.textMuted
	msg.Font = Enum.Font.GothamMedium
	msg.TextScaled = true
	msg.Parent = rowsContainer

	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MaxTextSize = 32
	constraint.MinTextSize = 12
	constraint.Parent = msg
end

local function render(sg, rowsContainer, board, theme, opts)
	-- Update the metric column label: custom boards show their own stat name
	-- (valueLabel, else a humanized metricKey); the creator board shows POINTS.
	local colMetric = sg:FindFirstChild("ColMetric", true)
	if colMetric then
		if opts.configId then
			local label = board and (board.valueLabel or board.metricKey) or "SCORE"
			label = tostring(label):gsub("^_+", ""):gsub("_+", " ")
			colMetric.Text = string.upper(label)
		else
			colMetric.Text = "POINTS"
		end
	end

	-- Clear all current children of the rows container
	for _, child in ipairs(rowsContainer:GetChildren()) do
		if child:IsA("Frame") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end

	if not board or not board.entries or #board.entries == 0 then
		buildEmptyState(rowsContainer, theme)
		return
	end

	local limit = math.min(opts.limit or 10, 100)
	local count = math.min(#board.entries, limit)

	for i = 1, count do
		local entry = board.entries[i]
		local row = buildRow(entry, theme)
		row.Parent = rowsContainer
	end
end

-- ── PUBLIC API ─────────────────────────────────────────────────────────

local mountedParts = {} -- weak-ish tracking to avoid double-mounting

--[[
	MountToPart(part, opts)

	Attaches a leaderboard SurfaceGui to the given BasePart. Safe to call
	multiple times on the same Part — replaces the existing GUI rather
	than stacking.

	Returns the SurfaceGui instance.
]]
function LeaderboardBoard:MountToPart(part, opts)
	if not part or not part:IsA("BasePart") then
		error("LeaderboardBoard:MountToPart expects a BasePart", 2)
	end
	opts = opts or {}
	local theme = setmetatable(opts.theme or {}, { __index = DEFAULT_THEME })

	-- Remove any previous PLAY3 leaderboard SurfaceGui on this part
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("SurfaceGui") and child.Name == SURFACE_GUI_NAME then
			child:Destroy()
		end
	end

	local sg = Instance.new("SurfaceGui")
	sg.Name = SURFACE_GUI_NAME
	sg.Face = opts.face or Enum.NormalId.Front
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = opts.pixelsPerStud or 50
	sg.LightInfluence = 0
	sg.AlwaysOnTop = false
	sg.Parent = part

	local _, rowsContainer = buildRoot(sg, opts, theme)

	-- Branch the data source. With opts.configId set, we route through
	-- CustomLeaderboard (per-config caches, /api/game/custom-leaderboard/:id);
	-- otherwise we read the brand's creator leaderboard. The render flow is
	-- identical for both — buildRow infers shape from each entry.
	local source = opts.configId and "custom" or "creator"
	local limit = opts.limit or 10

	-- Order matters: render BEFORE subscribing so StartAutoRefresh's
	-- first-time fetch doesn't fire the listener with the same board we're
	-- about to render explicitly (causing two interleaved renders).

	local initial
	local conn
	if source == "custom" then
		-- 1) Warm cache (idempotent, per configId)
		CustomLeaderboard:StartAutoRefresh(opts.configId)
		-- 2) Initial render — yields on cold cache
		initial = CustomLeaderboard:Get(opts.configId, { limit = limit })
		render(sg, rowsContainer, initial, theme, opts)
		-- 3) Subscribe — closure self-disconnects when Part dies
		conn = CustomLeaderboard:OnUpdate(opts.configId, function(board)
			if not sg.Parent then
				conn:Disconnect()
				return
			end
			render(sg, rowsContainer, board, theme, opts)
		end)
	else
		Leaderboard:StartAutoRefresh()
		initial = Leaderboard:GetTop({ limit = limit })
		render(sg, rowsContainer, initial, theme, opts)
		conn = Leaderboard:OnUpdate(function(board)
			if not sg.Parent then
				conn:Disconnect()
				return
			end
			render(sg, rowsContainer, board, theme, opts)
		end)
	end

	mountedParts[part] = sg
	log("Mounted leaderboard board on", part:GetFullName())

	return sg
end

--[[
	AutoMountTagged(tag)

	Mounts a leaderboard on every BasePart tagged with `tag` via
	CollectionService. Also auto-mounts any Part tagged later in the
	session. `tag` defaults to "Play3Leaderboard".

	Returns a CollectionService connection so callers can disconnect if
	they ever want to stop auto-mounting new parts.
]]
function LeaderboardBoard:AutoMountTagged(tag)
	tag = tag or DEFAULT_TAG

	for _, part in ipairs(CollectionService:GetTagged(tag)) do
		if part:IsA("BasePart") then
			self:MountToPart(part)
		end
	end

	local conn = CollectionService:GetInstanceAddedSignal(tag):Connect(function(part)
		if part:IsA("BasePart") then
			self:MountToPart(part)
		end
	end)

	log("Auto-mount enabled for tag:", tag)
	return conn
end

log("Module ready — call LeaderboardBoard:MountToPart(workspace.YourPart) or AutoMountTagged() to display")

return LeaderboardBoard
