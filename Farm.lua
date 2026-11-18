-- CommodityTicker 2.8.0: "Best farm right now".
-- Ranks the commodities this character can gather (herbs within your Herbalism skill, ore/stone
-- within Mining, leather within Skinning, from Professions.lua + PROF_PICKS) plus Blue Pearl, using
-- only prices already on disk or in SavedVariables: the out-of-game Blizzard AH feed (Feed.lua) and your
-- own AH scans. Nothing is fetched from the web, nothing runs on a timer (no OnUpdate).
--
-- Columns: icon, name, price, 24h trend, sell speed (estimate), score.
--  * Sell speed (estimate) = how much of the listed quantity disappeared per hour across the real
--    snapshots of the last 24 h: sum of every fall in listed quantity between consecutive
--    snapshots, divided by the hours covered and by the average listed quantity. A fall can be a
--    sale, a cancel or an expiry, so it's an estimate, never a sales count. Fewer than
--    CT.FARM_MIN_POINTS snapshots with a quantity, or under CT.FARM_MIN_HOURS covered = "-".
--  * Score = price x sell speed, scaled so the best item on the list is 100. It's a ranking only,
--    not gold per hour. No sell speed = no score ("-").
local _, ns = ...
local CT = ns.CT

local Farm = { rows = {}, sortKey = "score", sortDesc = true, offset = 0 }
ns.Farm = Farm
CT.Farm = Farm

local format, floor, max, min, abs = string.format, math.floor, math.max, math.min, math.abs

CT.FARM_EXTRA = { 4611 }        -- Blue Pearl: always a candidate (sells fast for Brett)
CT.FARM_GATHER = { [182] = true, [186] = true, [393] = true } -- Herbalism, Mining, Skinning
CT.FARM_WINDOW = 24 * 3600      -- trend and sell speed look at the last 24 h of real points
CT.FARM_MIN_POINTS = 3          -- snapshots with a listed quantity needed for a sell speed
CT.FARM_MIN_HOURS = 2           -- ...covering at least this many hours
CT.FARM_TREND_MIN_AGE = 3600    -- 24h trend needs an earlier price at least 1 h older
CT.FARM_COLS = { "name", "price", "trend", "speed", "score" }
CT.FARM_SCORE_HELP = "Score = price x sell speed (estimate), scaled so the best item listed is 100. " ..
  "A ranking only - not gold per hour. No sell-speed data = no score."
CT.FARM_SPEED_HELP = "Sell speed (estimate): share of the listed quantity that disappeared per hour over the " ..
  "last 24 h of real snapshots (feed or your own AH scans). Drops can be sales, cancels or expiries, " ..
  "so it's a proxy, not a sales count. '-' = fewer than 3 snapshots with a quantity."

------------------------------------------------------------------------
-- Data (pure; no frames)
------------------------------------------------------------------------
-- [id] = { skill =, prof = } for what the character can gather now, plus CT.FARM_EXTRA.
-- tierOnly = only the current tier (same rule as the ticker's profession picks).
function CT:FarmCandidates(tierOnly)
  if not self.profs then self.profs, self.profAPI = self:ReadProfessions() end
  local out = {}
  local data = ns.PROF_DATA and ns.PROF_DATA.professions or {}
  local picks = ns.PROF_PICKS or {}
  if tierOnly then
    for id, e in pairs(self:ProfessionItems()) do
      for line in pairs(CT.FARM_GATHER) do
        if data[line] and data[line].name == e.prof then out[id] = { skill = e.skill, prof = e.prof } end
      end
    end
  else
    for _, p in ipairs(self.profs or {}) do
      local d, classes = data[p.line], picks[p.line]
      if CT.FARM_GATHER[p.line] and d and classes then
        for id, need in pairs(d.items) do
          if classes[id] and need <= (p.skill or 0) then out[id] = { skill = need, prof = d.name } end
        end
      end
    end
  end
  for _, id in ipairs(CT.FARM_EXTRA) do out[id] = out[id] or { extra = true } end
  return out
end

-- Current unit price from the feed or your own AH scans only (newest wins). Never guild or
-- Auctionator, never the web. nil = not priced.
function CT:FarmPrice(id)
  local best
  local o = self:Market().items[id]
  if o and o.p and o.p > 0 and CT.AH_SOURCES[o.src] and not o.none then
    best = { price = o.p, t = o.t, src = o.src, qty = o.q }
  end
  local feed = self:Feed()
  local f = feed and feed.items[id]
  if f and f.min and f.min > 0 and (f.qty == nil or f.qty > 0) and (not best or (feed.updated or 0) > (best.t or 0)) then
    best = { price = f.min, t = feed.updated, src = "feed", qty = f.qty }
  end
  return best
end

local function inWindow(series, now, want)
  local out = {}
  for _, p in ipairs(series) do
    if p.t <= now and p.t >= now - CT.FARM_WINDOW and want(p) then out[#out + 1] = p end
  end
  return out
end
local function isFeed(p) return p.s == "feed" end
local function isAH(p) return CT.AH_SOURCES[p.s] and true or false end

-- 24h trend: current price vs the oldest real price of the same kind (feed vs AH) in the last
-- 24 h, at least an hour older. nil when there isn't one.
function CT:FarmTrend(id, pq, series)
  pq = pq or self:FarmPrice(id)
  if not pq then return nil end
  series = series or self:Series(id)
  local pts = inWindow(series, pq.t, pq.src == "feed" and isFeed or isAH)
  local base = pts[1]
  if not base or pq.t - base.t < CT.FARM_TREND_MIN_AGE then return nil end
  local pct = (pq.price - base.p) / base.p * 100
  return { pct = pct, prev = base.p, cur = pq.price, hours = (pq.t - base.t) / 3600,
    dir = pq.price > base.p and "up" or (pq.price < base.p and "down" or "same") }
end

-- Sell speed (estimate) from real listed quantities only. Feed snapshots are used when there are
-- enough of them, otherwise your own AH scans; the two are never mixed (different totals).
-- Returns { rate = share per hour, drop =, hours =, points =, avgQty =, src = } or nil, reason.
function CT:FarmSpeed(id, series, now)
  series = series or self:Series(id)
  now = now or time()
  local reason = "no listed-quantity history"
  for _, group in ipairs({ { isFeed, "feed" }, { isAH, "AH scans" } }) do
    local pts = inWindow(series, now, function(p) return group[1](p) and type(p.q) == "number" end)
    if #pts >= CT.FARM_MIN_POINTS then
      local hours = (pts[#pts].t - pts[1].t) / 3600
      if hours >= CT.FARM_MIN_HOURS then
        local drop, sum = 0, 0
        for i, p in ipairs(pts) do
          sum = sum + p.q
          if i > 1 and pts[i - 1].q > p.q then drop = drop + (pts[i - 1].q - p.q) end
        end
        local avg = sum / #pts
        if avg > 0 then
          return { rate = drop / hours / avg, drop = drop, hours = hours, points = #pts, avgQty = avg, src = group[2] }
        end
        reason = "nothing listed in the snapshots"
      else
        reason = format("snapshots cover under %d h", CT.FARM_MIN_HOURS)
      end
    elseif #pts > 0 then
      reason = format("only %d snapshot%s with a quantity", #pts, #pts == 1 and "" or "s")
    end
  end
  return nil, reason
end

-- One row per priced candidate. Unpriced items are left out.
function CT:FarmRows(tierOnly)
  local rows, top = {}, 0
  local feed = self:Feed()
  local now = max(time(), feed and feed.updated or 0)
  for id, c in pairs(self:FarmCandidates(tierOnly)) do
    local pq = self:FarmPrice(id)
    if pq then
      local series = self:Series(id)
      local sp, why = self:FarmSpeed(id, series, now)
      local r = { id = id, name = self:ItemName(id), price = pq.price, src = pq.src, t = pq.t, qty = pq.qty,
        skill = c.skill, prof = c.prof, extra = c.extra,
        trend = self:FarmTrend(id, pq, series), speed = sp, speedWhy = why }
      if sp then r.raw = pq.price * sp.rate; if r.raw > top then top = r.raw end end
      rows[#rows + 1] = r
    end
  end
  for _, r in ipairs(rows) do
    if r.raw then r.score = top > 0 and (r.raw / top * 100) or 0 end
  end
  return rows
end

local SORTVAL = {
  name = function(r) return r.name and r.name:lower() end,
  price = function(r) return r.price end,
  trend = function(r) return r.trend and r.trend.pct end,
  speed = function(r) return r.speed and r.speed.rate end,
  score = function(r) return r.score end,
}
-- Sort in place by a column; rows without a value always go last; ties by name.
function CT.SortFarmRows(rows, key, desc)
  local get = SORTVAL[key] or SORTVAL.score
  table.sort(rows, function(a, b)
    local va, vb = get(a), get(b)
    if va == nil and vb == nil then return (a.name or "") < (b.name or "") end
    if va == nil then return false end
    if vb == nil then return true end
    if va == vb then return (a.name or "") < (b.name or "") end
    if desc then return va > vb end
    return va < vb
  end)
  return rows
end

function CT.FarmSpeedText(sp)
  if not sp then return "|cff808080-|r" end
  local pct = sp.rate * 100
  if pct > 0 and pct < 1 then return "|cffc0c0c0<1%/h|r" end
  return format("|cffc0c0c0%d%%/h|r", floor(pct + 0.5))
end

function CT.FarmScoreText(score)
  if not score then return "|cff808080-|r" end
  return format("|cffffd100%d|r", floor(score + 0.5))
end

function CT.FarmTrendText(tr)
  if not tr then return "|cff808080-|r" end
  return CT.TrendPct(tr)
end

-- Chat version: /commodity farm list [n]
function CT:FarmPrint(n)
  n = n or 8
  local rows = CT.SortFarmRows(self:FarmRows(Farm.tierOnly), "score", true)
  if #rows == 0 then
    CT.Print("best farm: nothing to rank - no feed or AH price for the herbs/ore/leather you can gather (run the feed updater, then /commodity loadfeed).")
    return
  end
  CT.Print(format("best farm right now (%s; sell speed is an estimate):", self:ProfessionSummary()))
  for i = 1, min(n, #rows) do
    local r = rows[i]
    CT.Print(format("%d. %s  %s  24h %s  sells %s  score %s", i, r.name, CT.Money(r.price),
      CT.FarmTrendText(r.trend), CT.FarmSpeedText(r.speed), CT.FarmScoreText(r.score)))
  end
end

------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------
local W, ROWS, ROWH, PAD = 520, 12, 20, 12
local COLX = { icon = 0, name = 24, price = 196, trend = 300, speed = 360, score = 440 }
local COLW = { name = 168, price = 100, trend = 56, speed = 76, score = 50 }
local HEAD = { name = "Commodity", price = "Price", trend = "24h", speed = "Sells (est.)", score = "Score" }

local function tip(owner, title, lines)
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:ClearLines()
  GameTooltip:AddLine(title)
  for _, l in ipairs(lines) do GameTooltip:AddLine(l, 0.85, 0.85, 0.85, true) end
  GameTooltip:Show()
end

local function flat(b, w, h)
  if b.SetBackdrop then
    b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    b:SetBackdropColor(0.05, 0.08, 0.06, 0.9)
    b:SetBackdropBorderColor(0.22, 0.6, 0.3, 0.6)
  end
  b:SetSize(w, h)
end

function Farm:Create()
  if self.frame then return self.frame end
  local f = CreateFrame("Frame", "CommodityTickerFarmFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  self.frame = f
  f:SetSize(W, 92 + ROWS * ROWH + 44)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
  f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  if f.SetBackdrop then
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    f:SetBackdropColor(0.02, 0.03, 0.03, 0.94)
    f:SetBackdropBorderColor(0.15, 0.6, 0.25, 0.85)
  end
  tinsert(UISpecialFrames, "CommodityTickerFarmFrame") -- Escape closes it
  f:SetScript("OnHide", function() self.rows = {} end)  -- drop row data while closed

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", PAD, -10)
  title:SetText("|cff33ff99CT|r  Best farm right now")

  local close = CreateFrame("Button", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
  flat(close, 18, 18)
  close:SetPoint("TOPRIGHT", -8, -8)
  local cx = close:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  cx:SetPoint("CENTER", 0, 1)
  cx:SetText("|cff99eeaa×|r")
  close:SetScript("OnClick", function() f:Hide() end)
  self.closeBtn = close

  self.sub = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  self.sub:SetPoint("TOPLEFT", PAD, -28)
  self.sub:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
  self.sub:SetJustifyH("LEFT")
  self.sub:SetWordWrap(true)

  local tierOk, tier = pcall(CreateFrame, "CheckButton", nil, f, "UICheckButtonTemplate")
  if not tierOk or not tier then tier = CreateFrame("CheckButton", nil, f) end
  tier:SetSize(20, 20)
  tier:SetPoint("TOPLEFT", PAD - 4, -46)
  tier:SetScript("OnClick", function(b) self.tierOnly = b:GetChecked() and true or false; self.offset = 0; self:Update() end)
  local tl = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  tl:SetPoint("LEFT", tier, "RIGHT", 2, 0)
  tl:SetText("Current tier only")
  self.tierCB = tier

  local refresh = CreateFrame("Button", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
  flat(refresh, 70, 20)
  refresh:SetPoint("TOPRIGHT", -PAD, -46)
  local rl = refresh:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  rl:SetPoint("CENTER")
  rl:SetText("Refresh")
  refresh:SetScript("OnClick", function() self:Update() end)
  self.refreshBtn = refresh

  -- Column headers: click to sort, click again to flip.
  self.heads = {}
  local hy = -72
  for _, key in ipairs(CT.FARM_COLS) do
    local h = CreateFrame("Button", nil, f)
    h:SetSize(COLW[key], 16)
    h:SetPoint("TOPLEFT", PAD + COLX[key], hy)
    local fs = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetAllPoints(h)
    fs:SetJustifyH(key == "name" and "LEFT" or "RIGHT")
    h.label = fs
    h.key = key
    h:SetScript("OnClick", function() self:SortBy(key) end)
    h:SetScript("OnEnter", function(b)
      if key == "score" then tip(b, "Score", { CT.FARM_SCORE_HELP, "Click to sort." })
      elseif key == "speed" then tip(b, "Sells (estimate)", { CT.FARM_SPEED_HELP, "Click to sort." })
      elseif key == "trend" then tip(b, "24h trend", { "Current price vs the oldest real price of the same source in the last 24 h (at least 1 h older).", "Click to sort." })
      else tip(b, HEAD[key], { "Click to sort." }) end
    end)
    h:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.heads[key] = h
  end

  self.lines = {}
  for i = 1, ROWS do
    local row = CreateFrame("Button", nil, f)
    row:SetSize(W - PAD * 2, ROWH)
    row:SetPoint("TOPLEFT", PAD, hy - 18 - (i - 1) * ROWH)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", COLX.icon, 0)
    row.cells = {}
    for _, key in ipairs(CT.FARM_COLS) do
      local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetPoint("LEFT", COLX[key], 0)
      fs:SetWidth(COLW[key])
      fs:SetJustifyH(key == "name" and "LEFT" or "RIGHT")
      fs:SetWordWrap(false)
      row.cells[key] = fs
    end
    row:SetScript("OnEnter", function(b) self:RowTooltip(b) end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(b) if b.id and ns.Lookup and ns.Lookup.ShowItem then ns.Lookup:ShowItem(b.id) end end)
    self.lines[i] = row
  end
  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta) self:Scroll(-delta) end)

  self.foot = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  self.foot:SetPoint("BOTTOMLEFT", PAD, 10)
  self.foot:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
  self.foot:SetJustifyH("LEFT")
  self.foot:SetWordWrap(true)
  self.foot:SetText("Score = price x sell speed (est.), best = 100. Not gold per hour. Hover a column or row for details; click a row for its graph.")
  return f
end

function Farm:SortBy(key)
  if self.sortKey == key then self.sortDesc = not self.sortDesc
  else self.sortKey, self.sortDesc = key, key ~= "name" end
  CT.SortFarmRows(self.rows, self.sortKey, self.sortDesc)
  self:Draw()
end

function Farm:Scroll(step)
  local maxOff = max(0, #self.rows - ROWS)
  self.offset = max(0, min(maxOff, (self.offset or 0) + step))
  self:Draw()
end

function Farm:RowTooltip(b)
  local r = b.data
  if not r then return end
  local lines = {
    format("Price: %s (%s, %s)", CT.Money(r.price), CT.SourceLabel(r.src), CT.Ago(r.t)),
    r.qty and format("Listed now: %d", r.qty) or "Listed now: unknown",
  }
  if r.trend then
    lines[#lines + 1] = format("24h: %s vs %s %.0f h earlier", CT.TrendPct(r.trend), CT.PlainMoney(r.trend.prev), r.trend.hours)
  else
    lines[#lines + 1] = "24h: no earlier price in the last 24 h"
  end
  if r.speed then
    local s = r.speed
    lines[#lines + 1] = format("Sells (est.): listed quantity fell by %d in total over %.0f h across %d %s snapshots (avg %d listed).",
      s.drop, s.hours, s.points, s.src, floor(s.avgQty + 0.5))
    lines[#lines + 1] = "Falls can be sales, cancels or expiries - an estimate, not a sales count."
  else
    lines[#lines + 1] = "Sells (est.): - (" .. tostring(r.speedWhy or "not enough data") .. ")"
  end
  lines[#lines + 1] = r.extra and "Always listed (Blue Pearl)." or format("%s %d needed.", r.prof or "", r.skill or 0)
  tip(b, r.name, lines)
end

function Farm:Draw()
  if not self.frame then return end
  for key, h in pairs(self.heads) do
    local mark = (self.sortKey == key) and (self.sortDesc and " |cff33ff99v|r" or " |cff33ff99^|r") or ""
    h.label:SetText(HEAD[key] .. mark)
  end
  for i, row in ipairs(self.lines) do
    local r = self.rows[(self.offset or 0) + i]
    row.data, row.id = r, r and r.id
    if r then
      row.icon:SetTexture(CT:ItemIcon(r.id) or CT.ICON_PLACEHOLDER)
      row.icon:Show()
      row.cells.name:SetText(r.name)
      row.cells.price:SetText(CT.Money(r.price))
      row.cells.trend:SetText(CT.FarmTrendText(r.trend))
      row.cells.speed:SetText(CT.FarmSpeedText(r.speed))
      row.cells.score:SetText(CT.FarmScoreText(r.score))
      row:Show()
    else
      row.icon:Hide()
      for _, fs in pairs(row.cells) do fs:SetText("") end
      row:Hide()
    end
  end
end

function Farm:Update()
  if not self.frame then return end
  if self.tierCB then self.tierCB:SetChecked(self.tierOnly and true or false) end
  self.rows = CT.SortFarmRows(CT:FarmRows(self.tierOnly), self.sortKey, self.sortDesc)
  self.offset = min(self.offset or 0, max(0, #self.rows - ROWS))
  local feed = CT:Feed()
  local sub = CT:ProfessionSummary() .. " + Blue Pearl. "
  if feed then
    sub = sub .. format("Feed snapshot %s (%s)", CT.MelStamp(feed.updated), CT.Ago(feed.updated))
  else
    sub = sub .. "No feed loaded - own AH scans only"
  end
  if #self.rows == 0 then
    sub = sub .. ". Nothing priced yet: run the feed updater, then /commodity loadfeed, or open the AH."
  else
    sub = sub .. format(". %d priced.", #self.rows)
  end
  self.sub:SetText(sub)
  self:Draw()
end

function Farm:Open()
  self:Create()
  self.frame:Show()
  self:Update()
end

function Farm:Toggle()
  if self.frame and self.frame:IsShown() then self.frame:Hide() else self:Open() end
end

-- Called from CT:Refresh(): only does work while the window is open.
function Farm:OnDataChanged()
  if self.frame and self.frame:IsShown() then self:Update() end
end
