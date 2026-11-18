-- CommodityTicker lookup / graph window: search a commodity by name, ID or
-- shift-click, see its best known price (live at the AH when allowed) and a
-- price-over-time graph of real observations. Commodities only.
-- 2.4.3: same compact info-bar look as the ticker — icon, a clear price + trend
-- row, wrapped meta, and quiet green buttons instead of the default red ones.
local _, ns = ...
local CT = ns.CT

local Lookup = {}
ns.Lookup = Lookup

local format, max = string.format, math.max
local W, H = 460, 378
local PAD = 14

local function paintBtn(b, on)
  if not b.SetBackdropColor then return end
  if on then
    b:SetBackdropColor(0.06, 0.14, 0.09, 0.95)
    b:SetBackdropBorderColor(0.22, 0.7, 0.32, 0.9)
    if b.label and b.label.SetTextColor then b.label:SetTextColor(0.85, 1, 0.85) end
  else
    b:SetBackdropColor(0.05, 0.06, 0.05, 0.85)
    b:SetBackdropBorderColor(0.25, 0.28, 0.25, 0.5)
    if b.label and b.label.SetTextColor then b.label:SetTextColor(0.45, 0.5, 0.45) end
  end
end

local function button(parent, text, w)
  local b = CreateFrame("Button", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  b:SetSize(w, 22)
  if b.SetBackdrop then
    b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
  end
  local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetPoint("CENTER")
  b.label = fs
  if b.SetFontString then b:SetFontString(fs) end
  b:SetText(text)
  fs:SetText(text)
  paintBtn(b, true)
  b:SetScript("OnEnter", function(self)
    if self.IsEnabled and self:IsEnabled() == false then return end
    if self.SetBackdropColor then self:SetBackdropColor(0.12, 0.28, 0.16, 0.95) end
  end)
  b:SetScript("OnLeave", function(self)
    paintBtn(self, not (self.IsEnabled and self:IsEnabled() == false))
  end)
  b:SetScript("OnEnable", function(self) paintBtn(self, true) end)
  b:SetScript("OnDisable", function(self) paintBtn(self, false) end)
  return b
end

local function setMarkFont(fs, size)
  if not fs or not fs.GetFont or not fs.SetFont then return end
  local path, _, flags = fs:GetFont()
  if type(path) ~= "string" or path == "" then path = "Fonts\\FRIZQT__.TTF" end
  fs:SetFont(path, size or 16, type(flags) == "string" and flags or "")
end

function Lookup:Create()
  if self.frame then return self.frame end
  local f = CreateFrame("Frame", "CommodityTickerLookupFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  self.frame = f
  f:SetSize(W, H)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
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
  tinsert(UISpecialFrames, "CommodityTickerLookupFrame") -- Escape closes it

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", PAD, -10)
  title:SetText("|cff33ff99CT|r  Lookup")

  local close = CreateFrame("Button", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
  close:SetSize(18, 18)
  close:SetPoint("TOPRIGHT", -8, -8)
  if close.SetBackdrop then
    close:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    close:SetBackdropColor(0.08, 0.1, 0.08, 0.95)
    close:SetBackdropBorderColor(0.22, 0.7, 0.32, 0.8)
  end
  local cx = close:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  cx:SetPoint("CENTER", 0, 1)
  cx:SetText("|cff99eeaa×|r")
  close:SetScript("OnClick", function() f:Hide() end)
  close:SetScript("OnEnter", function(self)
    if self.SetBackdropColor then self:SetBackdropColor(0.18, 0.32, 0.2, 0.95) end
  end)
  close:SetScript("OnLeave", function(self)
    if self.SetBackdropColor then self:SetBackdropColor(0.08, 0.1, 0.08, 0.95) end
  end)

  local go = button(f, "Look up", 78)
  go:SetPoint("TOPRIGHT", -PAD, -34)
  go:SetScript("OnClick", function() CT:Lookup(self.box:GetText(), true); self.box:ClearFocus() end)

  local box = CreateFrame("EditBox", "CommodityTickerLookupBox", f, "InputBoxTemplate")
  box:SetHeight(20)
  box:SetPoint("TOPLEFT", PAD + 4, -35)
  box:SetPoint("RIGHT", go, "LEFT", -8, 0)
  box:SetAutoFocus(false)
  box:SetScript("OnEnterPressed", function(eb) CT:Lookup(eb:GetText(), true); eb:ClearFocus() end)
  box:SetScript("OnEscapePressed", function(eb) eb:ClearFocus() end)
  self.box = box

  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("TOPLEFT", PAD, -60)
  hint:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
  hint:SetJustifyH("LEFT")
  hint:SetWordWrap(true)
  hint:SetText("Shift-click, name or item ID. Herbs, ore, bars, cloth, leather and reagents.")
  self.hint = hint

  self.icon = f:CreateTexture(nil, "ARTWORK")
  self.icon:SetSize(28, 28)
  self.icon:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -12)

  self.name = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  self.name:SetPoint("TOPLEFT", self.icon, "TOPRIGHT", 8, 2)
  self.name:SetPoint("RIGHT", f, "RIGHT", -80, 0)
  self.name:SetJustifyH("LEFT")
  self.name:SetWordWrap(false)

  self.idText = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  self.idText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, 0)
  self.idText:SetPoint("TOP", self.name, "TOP", 0, -4)
  self.idText:SetJustifyH("RIGHT")

  self.price = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  self.price:SetPoint("TOPLEFT", self.name, "BOTTOMLEFT", 0, -4)
  self.price:SetJustifyH("LEFT")

  self.trendMark = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  self.trendMark:SetPoint("LEFT", self.price, "RIGHT", 10, 0)
  setMarkFont(self.trendMark, CT.TREND_MARK_SIZE or 16)

  self.trendPct = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  self.trendPct:SetPoint("LEFT", self.price, "RIGHT", 10, 0)

  self.spread = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  self.spread:SetPoint("TOPLEFT", self.price, "BOTTOMLEFT", 0, -2)
  self.spread:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
  self.spread:SetJustifyH("LEFT")
  self.spread:SetWordWrap(false)

  self.dayAvg = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  self.dayAvg:SetPoint("TOPLEFT", self.spread, "BOTTOMLEFT", 0, -2)
  self.dayAvg:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
  self.dayAvg:SetJustifyH("LEFT")
  self.dayAvg:SetWordWrap(false)

  self.meta = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  self.meta:SetPoint("TOPLEFT", self.dayAvg, "BOTTOMLEFT", 0, -4)
  self.meta:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
  self.meta:SetJustifyH("LEFT")
  self.meta:SetWordWrap(true)

  self.status = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  self.status:SetPoint("TOPLEFT", self.meta, "BOTTOMLEFT", 0, -8)
  self.status:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
  self.status:SetJustifyH("LEFT")
  self.status:SetWordWrap(true)

  self.graph = ns.Graph.Create(f, W - PAD * 2, 132, false)
  self.graph:SetPoint("TOPLEFT", self.status, "BOTTOMLEFT", 0, -8)
  self.graph:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)

  self.summary = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  self.summary:SetPoint("TOPLEFT", self.graph, "BOTTOMLEFT", 0, -6)
  self.summary:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
  self.summary:SetJustifyH("LEFT")
  self.summary:SetWordWrap(true)

  local btnW = math.floor((W - PAD * 2 - 16) / 3)
  self.trackBtn = button(f, "Track live", btnW)
  self.trackBtn:SetPoint("BOTTOMLEFT", PAD, 12)
  self.trackBtn:SetScript("OnClick", function()
    local id = self.id
    if not id then return end
    if CT:IsTracked(id) then CT:Untrack(tostring(id)) else CT:Track(tostring(id)) end
    self:Update()
  end)
  self.tickerBtn = button(f, "Add to ticker", btnW)
  self.tickerBtn:SetPoint("LEFT", self.trackBtn, "RIGHT", 8, 0)
  self.tickerBtn:SetScript("OnEnter", function(b)
    if b.SetBackdropColor and not (b.IsEnabled and b:IsEnabled() == false) then
      b:SetBackdropColor(0.12, 0.28, 0.16, 0.95)
    end
    GameTooltip:SetOwner(b, "ANCHOR_TOP")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("Ticker: " .. CT:BarName(CT:TargetBar()), 1, 1, 1)
    GameTooltip:AddLine("Pick another with /commodity bar <n> or in /commodity settings.", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  self.tickerBtn:SetScript("OnLeave", function(b)
    paintBtn(b, not (b.IsEnabled and b:IsEnabled() == false))
    GameTooltip:Hide()
  end)
  self.tickerBtn:SetScript("OnClick", function()
    local id = self.id
    if not id then return end
    if CT:OnTicker(id) then CT:RemoveFromTicker(tostring(id)) else CT:AddToTicker(tostring(id)) end
    self:Update()
  end)
  self.ahBtn = button(f, "Check AH now", btnW)
  self.ahBtn:SetPoint("LEFT", self.tickerBtn, "RIGHT", 8, 0)
  self.ahBtn:SetScript("OnClick", function() if self.id then CT:Lookup(tostring(self.id), true) end end)

  -- Shift-clicking an item while the search box has focus puts it in the box.
  local function onInsert(link)
    if box:HasFocus() and type(link) == "string" then box:SetText(link) end
  end
  if ChatFrameUtil and ChatFrameUtil.InsertLink then
    hooksecurefunc(ChatFrameUtil, "InsertLink", onInsert)
  elseif ChatEdit_InsertLink then
    hooksecurefunc("ChatEdit_InsertLink", onInsert)
  end

  f.icon, f.idText, f.price = self.icon, self.idText, self.price
  f.trendMark, f.trendPct, f.meta = self.trendMark, self.trendPct, self.meta
  f.spread, f.dayAvg = self.spread, self.dayAvg
  f.hint, f.status, f.summary = self.hint, self.status, self.summary
  f:Hide()
  return f
end

function Lookup:Open()
  self:Create()
  self.frame:Show()
  if not self.id then self:ShowEmpty() end
  self.box:SetFocus()
end

function Lookup:ShowHead(hasItem)
  if hasItem then
    self.icon:Show()
    self.idText:Show()
    self.name:ClearAllPoints()
    self.name:SetPoint("TOPLEFT", self.icon, "TOPRIGHT", 8, 2)
    self.name:SetPoint("RIGHT", self.frame, "RIGHT", -80, 0)
  else
    self.icon:Hide()
    self.idText:Hide()
    self.name:ClearAllPoints()
    self.name:SetPoint("TOPLEFT", self.hint, "BOTTOMLEFT", 0, -12)
    self.name:SetPoint("RIGHT", self.frame, "RIGHT", -PAD, 0)
    self.trendMark:SetText("")
    self.trendPct:SetText("")
    self.meta:SetText("")
  end
end

function Lookup:PlaceExtras(id, q)
  if not self.spread then return end
  local sp = id and CT:Spread(id, q) or nil
  if sp then
    local bits = { "|cff9d9d9dMarket|r " .. CT.Money(sp.market) }
    if sp.abs > 0 then
      bits[#bits + 1] = "|cff9d9d9dSpread|r " .. CT.Money(sp.abs) .. " (" .. sp.pctLabel .. ")"
    end
    self.spread:SetText(table.concat(bits, "    "))
    self.spread:Show()
  else
    self.spread:SetText("")
    self.spread:Hide()
  end
  local avg = id and CT:DayAverage(id) or nil
  if avg then
    self.dayAvg:SetText(format("|cff9d9d9dDay avg|r %s    |cff9d9d9d%d price%s in the last day|r",
      CT.Money(avg.price), avg.points, avg.points == 1 and "" or "s"))
    self.dayAvg:Show()
  else
    self.dayAvg:SetText("")
    self.dayAvg:Hide()
  end
  local above = self.price
  if self.spread:IsShown() then above = self.spread end
  -- dayAvg stays anchored under spread; if spread is hidden, hang it under the price
  self.dayAvg:ClearAllPoints()
  if self.spread:IsShown() then
    self.dayAvg:SetPoint("TOPLEFT", self.spread, "BOTTOMLEFT", 0, -2)
  else
    self.dayAvg:SetPoint("TOPLEFT", self.price, "BOTTOMLEFT", 0, -2)
  end
  self.dayAvg:SetPoint("RIGHT", self.frame, "RIGHT", -PAD, 0)
  local metaAbove = (self.dayAvg:IsShown() and self.dayAvg) or (self.spread:IsShown() and self.spread) or self.price
  self.meta:ClearAllPoints()
  self.meta:SetPoint("TOPLEFT", metaAbove, "BOTTOMLEFT", 0, -4)
  self.meta:SetPoint("RIGHT", self.frame, "RIGHT", -PAD, 0)
end

function Lookup:ShowEmpty()
  self:ShowHead(false)
  self.name:SetText("Look up a commodity")
  self.price:SetText("")
  self:PlaceExtras(nil)
  self.status:SetText(CT.ahOpen and "The auction house is open: lookups query it live." or "Auction house closed. Lookups use the feed and your last scan.")
  self.graph:SetSeries(nil)
  self.summary:SetText("")
  self.trackBtn:Disable(); self.tickerBtn:Disable(); self.ahBtn:Disable()
end

function Lookup:ShowError(msg)
  self:Create()
  self.frame:Show()
  self.id = nil
  self:ShowEmpty()
  self.name:SetText("|cffff6060Not shown|r")
  self.price:SetText(msg or "")
end

function Lookup:ShowItem(id, statusText)
  self:Create()
  self.id = id
  self.statusText = statusText
  self.frame:Show()
  self:Update()
end

function Lookup:Update()
  if not (self.frame and self.frame:IsShown() and self.id) then return end
  local id = self.id
  local name = CT:ItemName(id)
  self:ShowHead(true)
  local icon = CT:ItemIcon(id)
  self.icon:SetTexture(icon or CT.ICON_PLACEHOLDER)
  if self.icon.SetDesaturated then self.icon:SetDesaturated(not icon) end
  self.name:SetText((CT:IsTracked(id) and "|cff66ccffLive  |r" or "") .. name)
  self.idText:SetText(format("|cff9d9d9d%d|r", id))
  local q = CT:Quote(id)
  local tr = (q and q.price and not q.none) and CT:Trend(id, q) or nil
  if q and q.price and not q.none then
    self.price:SetText(CT.Money(q.price))
    self.trendMark:SetText("")
    self.trendPct:SetText(CT.TrendPct(tr))
    local bits = {}
    if tr then bits[#bits + 1] = "was " .. CT.PlainMoney(tr.prev) end
    if q.qty then bits[#bits + 1] = format("%d listed", q.qty) end
    bits[#bits + 1] = CT.SourceLabel(q.src)
    bits[#bits + 1] = CT.Ago(q.t)
    if q.t then bits[#bits + 1] = CT.MelStamp(q.t) end
    self.meta:SetText("|cff9d9d9d" .. table.concat(bits, "   ·   ") .. "|r")
    self:PlaceExtras(id, q)
  elseif q and q.none then
    self.price:SetText("|cffff8000None listed|r")
    self.trendMark:SetText("")
    self.trendPct:SetText("")
    self.meta:SetText("|cff9d9d9d" .. CT.SourceLabel(q.src) .. "  ·  " .. CT.Ago(q.t) ..
      (q.price and ("  ·  last " .. CT.PlainMoney(q.price)) or "") .. "|r")
    self:PlaceExtras(id, q)
  else
    self.price:SetText("|cff9d9d9dNo price yet|r")
    self.trendMark:SetText("")
    self.trendPct:SetText("")
    self.meta:SetText("|cff9d9d9dOpen the auction house to check it live, or run the feed updater and /reload.|r")
    self:PlaceExtras(nil)
  end
  local status = self.statusText
  if CT.scan and CT.scan.kind == "lookup" and CT.scan.ids[id] then
    status = "Checking the auction house..."
  elseif not status then
    status = CT.ahOpen and "Auction house open. Check AH now queries it live." or "Auction house closed. Live prices need it open."
  end
  self.statusText = nil
  self.status:SetText(status)
  local series = CT:Series(id)
  self.graph:SetSeries(series)
  self.summary:SetText(ns.Graph.Summary(series) .. format("  ·  keeps %d days / %d points", CT.HISTORY_DAYS, CT.HISTORY_POINTS))
  self.trackBtn:Enable()
  self.trackBtn:SetText(CT:IsTracked(id) and "Stop tracking" or "Track live")
  if self.trackBtn.label then self.trackBtn.label:SetText(self.trackBtn:GetText() or "") end
  self.tickerBtn:Enable()
  self.tickerBtn:SetText(CT:OnTicker(id) and "Remove from ticker" or "Add to ticker")
  if self.tickerBtn.label then self.tickerBtn.label:SetText(self.tickerBtn:GetText() or "") end
  if CT.ahOpen and not CT.scan then self.ahBtn:Enable() else self.ahBtn:Disable() end
end
