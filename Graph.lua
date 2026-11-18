-- CommodityTicker graph: one price line over time, drawn with plain frames,
-- textures and Line objects. Only real points are drawn - no interpolation.
-- Lines use a soft glow under a sharper stroke so diagonals look less stair-stepped.
-- 2.7.0: the full (lookup) graph gets a dot on every real point and a hover
-- crosshair that snaps to the nearest real point by time, with a tooltip.
-- Sparklines and the small hover-panel graph have no hover layer.
local _, ns = ...
local CT = ns.CT

local Graph = {}
ns.Graph = Graph
CT.Graph = Graph -- exposed for tests

local floor, max, min, format = math.floor, math.max, math.min, string.format

local SRC_COLOR = {
  feed = { 0.35, 0.65, 1 },     -- feed points (Blizzard AH snapshot): blue
  default = { 0.3, 1, 0.45 },  -- your own AH observations: green
}

-- A 44 px sparkline cannot show 200 history points, and each segment was
-- two Line widgets (glow + stroke) on both looping tapes — that was the
-- ~100 MB+ addon memory. Sparks keep at most this many points and no glow.
Graph.SPARK_MAX_POINTS = 24

function Graph.FitPoints(points, maxN)
  local n = points and #points or 0
  if n <= maxN then return points end
  if maxN < 2 then maxN = 2 end
  local out = { points[1] }
  for i = 1, maxN - 2 do
    local idx = 1 + math.floor(i * (n - 1) / (maxN - 1) + 0.5)
    if idx <= 1 then idx = 2 end
    if idx >= n then idx = n - 1 end
    if out[#out] ~= points[idx] then out[#out + 1] = points[idx] end
  end
  if out[#out] ~= points[n] then out[#out + 1] = points[n] end
  return out
end

-- Index of the real point whose x is nearest to x (xs sorted ascending, as the
-- time axis is). Nearest by time only, stock-chart style: a tall spike at a
-- further time never steals the cursor. Ties go to the later point.
function Graph.NearestIndex(xs, x)
  local n = xs and #xs or 0
  if n == 0 or x == nil then return nil end
  if x <= xs[1] then return 1 end
  if x >= xs[n] then return n end
  local lo, hi = 1, n
  while hi - lo > 1 do
    local mid = floor((lo + hi) / 2)
    if xs[mid] <= x then lo = mid else hi = mid end
  end
  if (x - xs[lo]) < (xs[hi] - x) then return lo end
  return hi
end

local SOURCE_LABEL = { feed = "Blizzard AH feed" }
function Graph.SourceLabel(p)
  return SOURCE_LABEL[p and p.s] or "Your own AH scan"
end

local DOT_SIZE, HL_SIZE = 4, 7

-- Invisible layer over the plot. Mouse motion only where the client allows it,
-- so clicks and drags still reach the lookup window. OnUpdate runs only while
-- the cursor is over the chart.
local function makeHover(g)
  local plot = g.plot
  local o = CreateFrame("Frame", nil, g)
  o:SetAllPoints(plot)
  if o.SetFrameLevel and plot.GetFrameLevel then o:SetFrameLevel((plot:GetFrameLevel() or 1) + 5) end
  if o.EnableMouseMotion and o.SetMouseClickEnabled then
    o:EnableMouseMotion(true)
    o:SetMouseClickEnabled(false)
  else
    o:EnableMouse(true)
    -- Older clients: forward drags to the movable window we sit in.
    if o.RegisterForDrag then o:RegisterForDrag("LeftButton") end
    local function mover()
      local f = g:GetParent()
      while f do
        if f.IsMovable and f:IsMovable() then return f end
        f = f.GetParent and f:GetParent() or nil
      end
    end
    o:SetScript("OnDragStart", function() local f = mover(); if f then f:StartMoving() end end)
    o:SetScript("OnDragStop", function() local f = mover(); if f then f:StopMovingOrSizing() end end)
  end
  local function tex(layer, sub)
    local t = o:CreateTexture(nil, layer or "OVERLAY")
    if t.SetDrawLayer then t:SetDrawLayer(layer or "OVERLAY", sub or 0) end
    t:Hide()
    return t
  end
  o.vline = tex("OVERLAY", 1); o.vline:SetColorTexture(1, 1, 1, 0.35); o.vline:SetWidth(1)
  o.hline = tex("OVERLAY", 1); o.hline:SetColorTexture(1, 1, 1, 0.35); o.hline:SetHeight(1)
  o.hl = tex("OVERLAY", 7); o.hl:SetSize(HL_SIZE, HL_SIZE)
  local function update() Graph.HoverUpdate(g) end
  local function stop() g.hovering = false; o:SetScript("OnUpdate", nil); Graph.HoverHide(g) end
  o:SetScript("OnEnter", function() g.hovering = true; o:SetScript("OnUpdate", update); update() end)
  o:SetScript("OnLeave", stop)
  o:SetScript("OnHide", stop)
  return o
end

-- spark = tiny in-row sparkline: short messages, no labels.
function Graph.Create(parent, width, height, small, spark)
  local g = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  g:SetSize(width, height)
  if g.SetBackdrop then
    g:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    g:SetBackdropColor(0.03, 0.05, 0.04, 0.9)
    g:SetBackdropBorderColor(0.2, 0.35, 0.25, 0.9)
  end
  g.small = small or spark
  g.spark = spark
  g.padL, g.padR, g.padT, g.padB = (small or spark) and 4 or 46, spark and 3 or 6, (small or spark) and (spark and 2 or 4) or 8, (small or spark) and (spark and 2 or 4) or 18
  g.plot = CreateFrame("Frame", nil, g)
  g.plot:SetPoint("TOPLEFT", g.padL, -g.padT)
  g.plot:SetPoint("BOTTOMRIGHT", -g.padR, g.padB)
  g.lines, g.glows, g.dots, g.grid = {}, {}, {}, {}
  local font = "GameFontHighlightSmall"
  g.msg = g:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  g.msg:SetPoint("CENTER")
  g.msg:SetWidth(spark and width or (width - 20))
  if not (small or spark) then
    g.yMax = g:CreateFontString(nil, "OVERLAY", font); g.yMax:SetPoint("TOPRIGHT", g.plot, "TOPLEFT", -3, 2)
    g.yMin = g:CreateFontString(nil, "OVERLAY", font); g.yMin:SetPoint("BOTTOMRIGHT", g.plot, "BOTTOMLEFT", -3, -2)
    g.xMin = g:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); g.xMin:SetPoint("TOPLEFT", g.plot, "BOTTOMLEFT", 0, -3)
    g.xMax = g:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); g.xMax:SetPoint("TOPRIGHT", g.plot, "BOTTOMRIGHT", 0, -3)
  end
  if not (small or spark) then g.hover = makeHover(g) end
  for _, k in ipairs({ "Clear", "SetSeries", "HoverAt" }) do g[k] = Graph[k] end -- frames keep their own metatable
  return g
end

local function pool(list, i, make)
  local o = list[i]
  if not o then o = make(); list[i] = o end
  o:Show()
  return o
end

function Graph:Clear()
  for _, l in ipairs(self.lines) do l:Hide() end
  for _, l in ipairs(self.glows) do l:Hide() end
  for _, d in ipairs(self.dots) do d:Hide() end
  for _, d in ipairs(self.grid) do d:Hide() end
  if self.yMax then self.yMax:SetText(""); self.yMin:SetText(""); self.xMin:SetText(""); self.xMax:SetText("") end
  self.msg:SetText("")
  self.drawn = 0
  self.drawnLines = 0
  self.pts, self.ptX, self.ptY = nil, nil, nil
  if self.hover then
    self.hover.vline:Hide(); self.hover.hline:Hide(); self.hover.hl:Hide()
    self.hoverIdx = nil
    if self.tipShown then GameTooltip:Hide(); self.tipShown = false end
  end
end

-- Snap the crosshair to the real point nearest plot-x (pixels from the plot's
-- left edge). Returns the point index, or nil if there is nothing to show.
function Graph:HoverAt(x)
  local o = self.hover
  if not o or not self.ptX then return nil end
  local i = Graph.NearestIndex(self.ptX, x)
  if not i then return nil end
  if i == self.hoverIdx then return i end
  self.hoverIdx = i
  local plot, px, py, p = self.plot, self.ptX[i], self.ptY[i], self.pts[i]
  o.vline:ClearAllPoints()
  o.vline:SetPoint("TOP", plot, "TOPLEFT", px, 0)
  o.vline:SetPoint("BOTTOM", plot, "BOTTOMLEFT", px, 0)
  o.vline:Show()
  o.hline:ClearAllPoints()
  o.hline:SetPoint("LEFT", plot, "BOTTOMLEFT", 0, py)
  o.hline:SetPoint("RIGHT", plot, "BOTTOMRIGHT", 0, py)
  o.hline:Show()
  local c = SRC_COLOR[p.s] or SRC_COLOR.default
  o.hl:SetColorTexture(min(1, c[1] + 0.35), min(1, c[2] + 0.35), min(1, c[3] + 0.35), 1)
  o.hl:ClearAllPoints()
  o.hl:SetPoint("CENTER", plot, "BOTTOMLEFT", px, py)
  o.hl:Show()
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:ClearLines()
  GameTooltip:AddLine(CT.MelStamp(p.t), 1, 1, 1)
  GameTooltip:AddLine(CT.Money(p.p), 1, 1, 1)
  GameTooltip:AddLine(Graph.SourceLabel(p), c[1], c[2], c[3])
  if p.q then GameTooltip:AddLine(format("%d listed", p.q), 0.8, 0.8, 0.8) end
  GameTooltip:Show()
  self.tipShown = true
  return i
end

function Graph.HoverUpdate(g)
  local plot = g.plot
  local cx = GetCursorPosition()
  local left = plot:GetLeft()
  if not cx or not left then return end
  local scale = plot:GetEffectiveScale() or 1
  if scale <= 0 then scale = 1 end
  g:HoverAt(cx / scale - left)
end

function Graph.HoverHide(g)
  local o = g.hover
  if not o then return end
  o.vline:Hide(); o.hline:Hide(); o.hl:Hide()
  g.hoverIdx = nil
  if g.tipShown then GameTooltip:Hide(); g.tipShown = false end
end

local function color(p) return SRC_COLOR[p.s] or SRC_COLOR.default end

-- points: { {t=, p=, q=, s=}, ... } oldest first. Returns the number of points drawn.
function Graph:SetSeries(points)
  if self.spark and points and #points > Graph.SPARK_MAX_POINTS then
    points = Graph.FitPoints(points, Graph.SPARK_MAX_POINTS)
  end
  self:Clear()
  local n = points and #points or 0
  if n == 0 then
    self.msg:SetText(self.spark and "no history" or "No price history yet. Visit the auction house, or run the feed updater and /reload.")
    return 0
  end
  local plot = self.plot
  local w, h = plot:GetWidth() or 0, plot:GetHeight() or 0
  if w <= 0 then w = (self:GetWidth() or 0) - self.padL - self.padR end
  if h <= 0 then h = (self:GetHeight() or 0) - self.padT - self.padB end

  local tMin, tMax, pMin, pMax = points[1].t, points[n].t, points[1].p, points[1].p
  for _, p in ipairs(points) do pMin = min(pMin, p.p); pMax = max(pMax, p.p) end
  if pMax == pMin then
    local pad = max(1, floor(pMax * 0.05))
    pMin, pMax = max(0, pMin - pad), pMax + pad
  end
  local function xy(p)
    local x = (n == 1 or tMax == tMin) and (w / 2) or ((p.t - tMin) / (tMax - tMin) * w)
    local y = (p.p - pMin) / (pMax - pMin) * h
    return x, y
  end

  -- faint mid gridline (hidden on tiny sparklines - it just adds noise)
  if not self.spark then
    local gl = pool(self.grid, 1, function()
      local t = plot:CreateTexture(nil, "BACKGROUND"); t:SetColorTexture(1, 1, 1, 0.06); return t
    end)
    gl:ClearAllPoints(); gl:SetPoint("LEFT", plot, "LEFT", 0, 0); gl:SetPoint("RIGHT", plot, "RIGHT", 0, 0); gl:SetHeight(1)
  end

  -- A soft wider line under a sharper core line, so diagonals don't look stair-stepped.
  -- Still only connects real points - no extra prices.
  local coreT, glowT = 2.4, 4.5
  if self.spark then coreT, glowT = 2, 4
  elseif self.small then coreT, glowT = 2, 4 end

  local function drawSeg(list, i, thickness, r, g, b, a, x0, y0, x1, y1, sub)
    local line = pool(list, i, function()
      local l = plot:CreateLine(nil, "ARTWORK")
      if l.SetDrawLayer then l:SetDrawLayer("ARTWORK", sub or 0) end
      -- Smoother diagonals where the client supports it (feature-detected).
      if l.SetSnapToPixelGrid then l:SetSnapToPixelGrid(false) end
      if l.SetTexelSnappingBias then l:SetTexelSnappingBias(0) end
      return l
    end)
    if line.SetDrawLayer then line:SetDrawLayer("ARTWORK", sub or 0) end
    line:SetThickness(thickness)
    line:SetColorTexture(r, g, b, a)
    line:SetStartPoint("BOTTOMLEFT", plot, x0, y0)
    line:SetEndPoint("BOTTOMLEFT", plot, x1, y1)
    return line
  end

  local full = not self.spark and not self.small
  local ptX, ptY = full and {} or nil, full and {} or nil
  local px, py
  for i, p in ipairs(points) do
    local x, y = xy(p)
    if full then ptX[i], ptY[i] = x, y end
    if i > 1 and plot.CreateLine then
      local c = color(p)
      -- Sparks skip the glow line: half the Line widgets, still readable at 12 px tall.
      if not self.spark then
        drawSeg(self.glows, i - 1, glowT, c[1], c[2], c[3], 0.28, px, py, x, y, -1)
      end
      drawSeg(self.lines, i - 1, coreT, c[1], c[2], c[3], 1, px, py, x, y, 0)
      self.drawnLines = i - 1
    end
    -- Chunky square dots make the tiny sparkline look pixelated; only keep a dot
    -- when there's a single point (no line to show). Full graphs get a small dot
    -- on every real point (2.7.0) so you can see what the hover snaps to.
    local showDot = (n == 1) or full
    if showDot then
      local size = self.spark and 3 or (self.small and 3 or DOT_SIZE)
      local dot = pool(self.dots, i, function()
        local d = plot:CreateTexture(nil, "OVERLAY"); d:SetSize(size, size); return d
      end)
      dot:SetSize(size, size)
      local c = color(p)
      dot:SetColorTexture(c[1], c[2], c[3], 1)
      dot:ClearAllPoints()
      dot:SetPoint("CENTER", plot, "BOTTOMLEFT", x, y)
    end
    px, py = x, y
  end
  self.drawn = n
  if full then
    self.pts, self.ptX, self.ptY = points, ptX, ptY
    if self.hovering then
      Graph.HoverUpdate(self) -- new data while hovering: re-snap now
    end
  end

  if self.yMax then
    self.yMax:SetText(CT.PlainMoney(pMax))
    self.yMin:SetText(CT.PlainMoney(pMin))
    local sameDay = select(2, CT.MelTime(tMin)) == select(2, CT.MelTime(tMax))
      and select(3, CT.MelTime(tMin)) == select(3, CT.MelTime(tMax))
    self.xMin:SetText(CT.MelAxis(tMin, { timeOnly = sameDay, zone = false }))
    self.xMax:SetText(n > 1 and CT.MelAxis(tMax, { timeOnly = sameDay, zone = true }) or "")
  end
  if n == 1 then
    self.msg:ClearAllPoints()
    self.msg:SetPoint("TOP", self, "TOP", 0, -6)
    if not self.spark then self.msg:SetText("Only one price so far - not enough history for a line yet.") end
  else
    self.msg:ClearAllPoints()
    self.msg:SetPoint("CENTER")
  end
  return n
end

-- One-line summary of a series for labels under a graph (lookup).
function Graph.Summary(points)
  local n = #points
  if n == 0 then return "0 points" end
  local feed, ah = 0, 0
  for _, p in ipairs(points) do if p.s == "feed" then feed = feed + 1 else ah = ah + 1 end end
  local last = points[n]
  local qty = last.q and format(", %d listed", last.q) or ""
  return format("%d point%s (|cff33ff66%d AH|r, |cff59a6ff%d feed|r) - last %s %s%s", n, n == 1 and "" or "s",
    ah, feed, CT.PlainMoney(last.p), CT.MelStamp(last.t), qty)
end

-- History count only: no last price, time, or listed quantity (those are already
-- on the list/ticker, or on a shorter tip line).
function Graph.HistoryLine(points)
  local n = #(points or {})
  if n == 0 then return nil end
  local feed, ah = 0, 0
  for _, p in ipairs(points) do if p.s == "feed" then feed = feed + 1 else ah = ah + 1 end end
  return format("%d point%s (|cff33ff66%d AH|r, |cff59a6ff%d feed|r)", n, n == 1 and "" or "s", ah, feed)
end
