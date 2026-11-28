-- CommodityTicker UI: up to CT.MAX_BARS slim, movable, scrolling (or rotating) price tickers,
-- or (2.4.0) a static list with icon, price + trend, sparkline, bag/bank counts and value,
-- each showing its own list; a shared hover panel with a mini price graph per item, and the
-- stale-feed Reload button (on the first visible ticker).
local _, ns = ...
local CT = ns.CT

local UI = { ready = false }
ns.UI = UI
CT.UI = UI -- exposed for restyling and tests

local floor, format, max = math.floor, string.format, math.max
local GAP = 18      -- pixels between ticker items (2.4: compact)
local LOOP_GAP = 40 -- pixels between the end of the tape and its repeat
local LABEL_W = 22  -- fixed width of the "CT" label on the left
local AGE_W = 96    -- fixed width of the age + AH-badge column on the right
local AH_W = 26     -- clickable AH scan toggle sitting in that column
local PAD = 6
UI.GAP, UI.LOOP_GAP, UI.LABEL_W, UI.AGE_W, UI.AH_W = GAP, LOOP_GAP, LABEL_W, AGE_W, AH_W

-- Plain-text width estimate, used when the client hasn't laid a string out yet
-- (GetStringWidth can return 0 or a stale width right after SetText).
local function plainText(s)
  s = tostring(s or "")
  s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "  "):gsub("|H.-|h(.-)|h", "%1"):gsub("||", "|")
  return s
end
local CHAR_W = 6
function UI.EstimateWidth(text) return #plainText(text) * CHAR_W end

-- Width of a FontString's current text. Returns width, reliable.
function UI.MeasureString(fs, text)
  local est = UI.EstimateWidth(text)
  local w = (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth()) or 0
  if not w or w <= 0 then w = fs:GetStringWidth() or 0 end
  if w <= 0 or (est > 0 and w < est * 0.5) then
    return est, false -- not laid out yet (or stale): use the estimate and re-measure shortly
  end
  return w, true
end

-- Shared item typography (2.4.0): list rows, the tape and rotate all use these.
local function iconTag(id, size)
  return format("|T%s:%d:%d:0:0|t", tostring(CT:ItemIcon(id) or CT.ICON_PLACEHOLDER), size or 14, size or 14)
end
UI.IconTag = iconTag

-- Name part: tracked marker + name, grey when the price is stale or unknown.
local function nameText(e, q)
  local name = CT:ItemName(e.id, e.name)
  local nameCol = e.tracked and "|cff66ccff" or "|cffffffff"
  local mark = e.tracked and "|cff66ccff>|r" or ""
  if not q or (not q.price and not q.none) then return mark .. "|cff9d9d9d" .. name .. "|r" end
  if q.t and (time() - q.t) > CT.db.settings.staleHours * 3600 then nameCol = "|cff9d9d9d" end
  return mark .. nameCol .. name .. "|r"
end

-- Price only (list column). Tape/rotate still append the compact trend after this.
local function priceOnly(e, q)
  if not q or (not q.price and not q.none) then return "|cff9d9d9d--|r" end
  if q.none then
    return "|cffff8000none listed|r" .. (q.price and (" |cff9d9d9d(last " .. CT.PlainMoney(q.price) .. ")|r") or "")
  end
  return CT.Money(q.price)
end

-- Price part: price + 2.3 trend mark, or "none listed" / "--".
local function priceText(e, q)
  local p = priceOnly(e, q)
  if not q or (not q.price and not q.none) or q.none then return p end
  return p .. " " .. CT.TrendText(CT:Trend(e.id, q), true)
end
UI.NameText, UI.PriceText, UI.PriceOnly = nameText, priceText, priceOnly

-- One tape / rotate item: icon, name, price, trend.
local function itemText(e)
  local q = CT:Quote(e.id)
  return iconTag(e.id) .. " " .. nameText(e, q) .. " " .. priceText(e, q)
end
UI.ItemText = itemText

local function freshest(entries)
  local newest
  for _, e in ipairs(entries or CT:Watched()) do
    local q = CT:Quote(e.id)
    if q and q.t and (not newest or q.t > newest) then newest = q.t end
  end
  return newest
end

-- One ticker bar. Bar 1's frame keeps the 2.x name CommodityTickerFrame.
local Bar = {}
Bar.__index = Bar
UI.Bar = Bar
UI.bars = {}

function Bar:Cfg() return CT:BarCfg(self.index) end

local function newBar(index)
  local self = setmetatable({ index = index, offset = 0, rotIndex = 1, rotTimer = 0 }, Bar)
  local fname = index == 1 and "CommodityTickerFrame" or ("CommodityTickerFrame" .. index)
  local f = CreateFrame("Frame", fname, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  self.frame = f
  f.ctBar = self
  f:SetHeight(20)
  f:SetFrameStrata("MEDIUM")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  if f.SetBackdrop then
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    f:SetBackdropColor(0.02, 0.03, 0.03, 0.85) -- compact dark info-bar fill (2.4)
    f:SetBackdropBorderColor(0.15, 0.6, 0.25, 0.7)
  end

  -- Fixed-width label and status columns, so the scrolling tape's clip region
  -- never depends on string measurement and can't paint over either of them.
  local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  label:SetPoint("LEFT", f, "LEFT", PAD, 0)
  label:SetWidth(LABEL_W)
  label:SetJustifyH("LEFT")
  label:SetText(index == 1 and "|cff33ff99CT|r" or ("|cff33ff99CT|r|cff9d9d9d" .. index .. "|r"))
  self.label = label

  -- Coloured AH badge: green when we scan the AH ourselves, orange when we
  -- read TSM / Auctionator / the feed. Click to toggle (same as /commodity auto).
  local ahBtn = CreateFrame("Button", nil, f)
  ahBtn:SetSize(AH_W, 16)
  ahBtn:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
  ahBtn:SetFrameLevel((f.GetFrameLevel and f:GetFrameLevel() or 0) + 4)
  ahBtn:EnableMouse(true)
  ahBtn:RegisterForClicks("LeftButtonUp")
  local ahLabel = ahBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  ahLabel:SetAllPoints()
  ahLabel:SetJustifyH("RIGHT")
  ahBtn.label = ahLabel
  ahBtn:SetScript("OnClick", function()
    CT:SetAuto(not (CT.db and CT.db.settings and CT.db.settings.auto))
  end)
  ahBtn:SetScript("OnEnter", function(btn)
    if GameTooltip then
      GameTooltip:SetOwner(btn, "ANCHOR_TOP")
      GameTooltip:ClearLines()
      local on = CT.db and CT.db.settings and CT.db.settings.auto
      if on then
        GameTooltip:AddLine("AH scanning is on")
        GameTooltip:AddLine("Click to turn it off and use prices from TSM, Auctionator or the feed. Also /commodity auto off.", 0.82, 0.78, 0.68, true)
      else
        GameTooltip:AddLine("AH scanning is off")
        GameTooltip:AddLine("Prices come from TSM, Auctionator or the feed. Click to scan the AH myself while it is open. Also /commodity auto on.", 0.82, 0.78, 0.68, true)
      end
      GameTooltip:Show()
    end
  end)
  ahBtn:SetScript("OnLeave", function()
    if GameTooltip then GameTooltip:Hide() end
  end)
  self.ahBtn = ahBtn

  local age = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  age:SetPoint("RIGHT", ahBtn, "LEFT", -2, 0)
  age:SetWidth(AGE_W - AH_W - 2)
  age:SetJustifyH("RIGHT")
  age:SetWordWrap(false)
  self.age = age
  self:UpdateAutoBadge()

  local clip = CreateFrame("Frame", nil, f)
  clip:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + LABEL_W + 4, -1)
  clip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(PAD + AGE_W + 4), 1)
  clip:SetClipsChildren(true)
  self.clip = clip

  -- Two copies of the tape so the scroll loops seamlessly; each item is its own
  -- FontString so hovering can tell which commodity is under the mouse.
  self.tapes = {}
  for i = 1, 2 do
    local t = CreateFrame("Frame", nil, clip)
    t:SetHeight(16)
    t.items = {}
    self.tapes[i] = t
  end
  self.rot = clip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  self.rot:SetPoint("LEFT", clip, "LEFT", 0, 0)
  self.rot:SetWordWrap(false)
  -- rotate mode extras (2.4): a small sparkline and BAG / BANK / VALUE, styled like a list row
  self.rotSpark = ns.Graph.Create(clip, 44, 12, true, true)
  self.rotSpark:SetPoint("LEFT", self.rot, "RIGHT", 6, 0)
  self.rotSpark:Hide()
  self.rotCounts = clip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  self.rotCounts:SetPoint("LEFT", self.rotSpark, "RIGHT", 8, 0)
  self.rotCounts:SetWordWrap(false)

  f:SetScript("OnDragStart", function(fr)
    if self:Cfg().locked or (CT.InCombat and CT:InCombat()) then return end
    self.moving = true; self.dragged = true; fr:StartMoving()
  end)
  f:SetScript("OnDragStop", function(fr)
    if not self.moving then return end
    fr:StopMovingOrSizing()
    self.moving = false
    self:SavePosition()
  end)
  f:SetScript("OnShow", function() self:ScheduleRemeasure() end)
  f:SetScript("OnMouseDown", function() self.dragged = false end)
  f:SetScript("OnMouseUp", function(_, button)
    if button == "RightButton" then
      CT:SetTargetBar(self.index)
      if ns.Settings then ns.Settings:Open(self.index) end
    elseif button == "MiddleButton" then
      CT:StartScan(true)
    elseif button == "LeftButton" and not self.dragged then
      local e = self:HoveredItem()
      if e and ns.Lookup then CT:SetTargetBar(self.index); CT.lookupID = e.id; ns.Lookup:ShowItem(e.id) end
    end
  end)
  f:SetScript("OnEnter", function() self.hover = true; UI.hoverBar = self; self:UpdateHover(true) end)
  f:SetScript("OnLeave", function()
    self.hover = false; self.hoverID = nil
    GameTooltip:Hide(); UI:HideHoverPanel()
  end)
  f:SetScript("OnUpdate", function(_, elapsed) self:OnUpdate(elapsed) end)
  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta) if self:Cfg().mode == "list" then self:ScrollList(-delta) end end)
  return self
end

function UI:Init()
  self:CreateHoverPanel()
  self.ready = true
  self:SyncBars()
  self:CreateReloadButton()
  self:Rebuild()
end

-- Make one Bar per configured ticker (frames are reused; extra ones are just hidden).
function UI:SyncBars()
  local n = CT:NumBars()
  for i = 1, max(n, #self.bars) do
    local b = self.bars[i]
    if i <= n and not b then
      b = newBar(i)
      self.bars[i] = b
    end
    if b then b.active = i <= n end
  end
  self.frame = self.bars[1].frame -- 2.x compatibility (bar 1)
  if ns.EditMode then ns.EditMode:SyncBars(self.bars) end
  for _, b in ipairs(self.bars) do if not b.active then b.frame:Hide() end end
end

------------------------------------------------------------------------
-- Hover panel: item, price, source/age and a mini graph of real history
------------------------------------------------------------------------
function UI:CreateHoverPanel()
  local p = CreateFrame("Frame", "CommodityTickerHoverPanel", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  p:SetSize(270, 132)
  p:SetFrameStrata("TOOLTIP")
  if p.SetBackdrop then
    p:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    p:SetBackdropColor(0, 0, 0, 1)
    p:SetBackdropBorderColor(0.15, 0.6, 0.25, 1)
  end
  p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  p.title:SetPoint("TOPLEFT", 8, -6)
  p.line = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  p.line:SetPoint("TOPLEFT", p.title, "BOTTOMLEFT", 0, -2)
  p.line:SetWidth(254); p.line:SetJustifyH("LEFT")
  p.graph = ns.Graph.Create(p, 254, 64, true)
  p.graph:SetPoint("TOPLEFT", 8, -40)
  p.foot = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  p.foot:SetPoint("BOTTOMLEFT", 8, 6)
  p.foot:SetWidth(254); p.foot:SetJustifyH("LEFT")
  p:Hide()
  self.hoverPanel = p
end

function UI:ShowHoverPanel(e, bar)
  local p = self.hoverPanel
  p:ClearAllPoints()
  p:SetPoint("TOP", (bar or self.bars[1]).frame, "BOTTOM", 0, -2)
  -- Title keeps the name: the panel sits under the bar, and a scrolling tape has many items.
  p.title:SetText((e.tracked and "|cff66ccff[live] |r" or "") .. CT:ItemName(e.id, e.name))
  local mode = bar and bar:Cfg() and bar:Cfg().mode
  local countsOn = mode == "rotate" and bar.rotCounts and bar.rotCounts.shown
  local x = UI.ItemExtras(e, { name = true, price = true, trend = true, bag = countsOn, bank = countsOn, value = countsOn })
  local lineBits = {}
  if x.was then lineBits[#lineBits + 1] = x.was end
  if x.meta then lineBits[#lineBits + 1] = x.meta end
  if x.bankHint then lineBits[#lineBits + 1] = "|cffff9933" .. x.bankHint .. "|r" end
  p.line:SetText(table.concat(lineBits, "  ·  "))
  p.graph:SetSeries(CT:Series(e.id))
  local footBits = {}
  if x.countLine then footBits[#footBits + 1] = x.countLine end
  if x.history then footBits[#footBits + 1] = x.history end
  p.foot:SetText(table.concat(footBits, "  ·  "))
  p:Show()
end

function UI:HideHoverPanel() if self.hoverPanel then self.hoverPanel:Hide() end end

-- 2.x helpers (bar 1)
function UI:HoveredItem() return (self.hoverBar or self.bars[1]):HoveredItem() end

-- Which watch-list entry is under the mouse (nil over the label/age area).
function Bar:HoveredItem()
  if not self.parts or #self.parts == 0 or self:Cfg().mode == "list" then return nil end
  if self:Cfg().mode == "rotate" then return self.parts[self.rotIndex] and self.parts[self.rotIndex].entry end
  local left = self.clip:GetLeft()
  local cx = GetCursorPosition and GetCursorPosition()
  if not left or not cx or not self.tapeWidth then return nil end
  local scale = self.clip:GetEffectiveScale() or 1
  local x = cx / scale - left
  if x < 0 or x > (self.clip:GetWidth() or 0) then return nil end
  local pos = (x - self.offset) % self.tapeWidth
  for _, part in ipairs(self.parts) do
    if part.x0 and pos >= part.x0 - GAP / 2 and pos < part.x1 + GAP / 2 then return part.entry end
  end
end

function Bar:UpdateHover(force)
  if self:Cfg().mode == "list" then
    if force then
      UI:HideHoverPanel()
      GameTooltip:SetOwner(self.frame, "ANCHOR_TOP")
      GameTooltip:ClearLines()
      GameTooltip:AddLine("CommodityTicker: " .. CT:BarName(self.index), 0.2, 1, 0.6)
      GameTooltip:AddLine("Click a row for the full graph and lookup. Right-click: settings. Wheel: scroll. Drag the right or bottom edge (or the corner) to resize. Esc > Edit Mode also works.", 0.8, 0.8, 0.8, true)
      GameTooltip:Show()
    end
    return
  end
  local e = self:HoveredItem()
  local id = e and e.id
  if not force and id == self.hoverID then return end
  self.hoverID = id
  if e then
    GameTooltip:Hide()
    UI:ShowHoverPanel(e, self)
  else
    UI:HideHoverPanel()
    self:ShowTooltip()
  end
end

------------------------------------------------------------------------
-- Reload button (feed may be stale) - never reloads on its own. One button,
-- shown at the right-hand end of the first visible ticker.
------------------------------------------------------------------------
function UI:CreateReloadButton()
  local b = CreateFrame("Button", "CommodityTickerReloadButton", self.bars[1].frame, BackdropTemplateMixin and "BackdropTemplate" or nil)
  b:SetSize(64, 18)
  b:SetPoint("LEFT", self.bars[1].frame, "RIGHT", 2, 0)
  if b.SetBackdrop then
    b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    b:SetBackdropColor(0.25, 0.15, 0, 0.85)
    b:SetBackdropBorderColor(1, 0.5, 0, 0.9)
  end
  local t = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  t:SetPoint("CENTER")
  b.label = t
  b:RegisterForClicks("LeftButtonUp")
  b:SetScript("OnClick", function() CT:ReloadForFeed(false) end)
  b:SetScript("OnEnter", function(btn)
    local _, feed, written = CT:FeedMayBeStale()
    GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("Load the price feed from disk", 1, 0.82, 0)
    if feed and written then
      GameTooltip:AddLine(format("The feed in memory was written %s; update_feed runs every %d min.",
        CT.Ago(written), CT:FeedInterval(feed) / 60), 1, 1, 1, true)
    end
    GameTooltip:AddLine("Click to re-read the feed mid-session (uses one load-on-demand slot, no /reload). If the slots aren't available, this falls back to a /reload.", 0.8, 0.8, 0.8, true)
    if CT:InCombat() then GameTooltip:AddLine("Not available in combat.", 1, 0.3, 0.3) end
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:Hide()
  self.reloadButton = b
end

function UI:UpdateReloadButton()
  local b = self.reloadButton
  if not b then return end
  local host
  for _, bar in ipairs(self.bars) do
    if bar.active and bar:Cfg().shown then host = bar; break end
  end
  if not host or self:IsEditing() or not CT:FeedMayBeStale() then b:Hide(); return end
  if b.host ~= host then
    b.host = host
    b:SetParent(host.frame)
    b:ClearAllPoints()
    b:SetPoint("LEFT", host.frame, "RIGHT", 2, 0)
  end
  local label = (CT.HasFeedLoadAPI and CT:HasFeedLoadAPI()) and "Load feed" or "Reload"
  if CT:InCombat() then
    b:Disable()
    b.label:SetText("|cff808080" .. label .. "|r")
  else
    b:Enable()
    b.label:SetText("|cffff9900" .. label .. "|r")
  end
  b:Show()
end

------------------------------------------------------------------------
-- Layout and the tape
------------------------------------------------------------------------
-- Save where the bar is now into its point (relative to UIParent).
function Bar:SavePosition()
  local point, _, relPoint, x, y = self.frame:GetPoint(1)
  if not point then return end
  self:Cfg().point = { point, relPoint or point, floor((x or 0) + 0.5), floor((y or 0) + 0.5) }
end
function UI:SavePosition() self.bars[1]:SavePosition() end

-- Re-run the layout shortly when some item widths were only estimated.
function Bar:ScheduleRemeasure()
  if self.remeasurePending or not C_Timer then return end
  self.remeasureTries = (self.remeasureTries or 0) + 1
  if self.remeasureTries > 6 then return end
  self.remeasurePending = true
  C_Timer.After(0.2 * self.remeasureTries, function()
    self.remeasurePending = false
    if UI.ready and self.active then self:Rebuild() end
  end)
end

function UI:IsEditing() return ns.EditMode and ns.EditMode.editing or false end

function Bar:ApplyLayout()
  local c, f = self:Cfg(), self.frame
  f:SetWidth(c.width)
  f:SetScale(c.scale)
  if self.moving then return end
  f:ClearAllPoints()
  local p = c.point or CT.DefaultBarPoint(self.index)
  f:SetPoint(p[1] or "TOP", UIParent, p[2] or "TOP", p[3] or 0, p[4] or -95)
end
function UI:ApplyLayout() for _, b in ipairs(self.bars) do if b.active then b:ApplyLayout() end end end

local function emptyText(index)
  local c = CT:BarCfg(index)
  if c.sources and c.sources.profession and not (CT.profs and #CT.profs > 0) then
    return "|cff9d9d9dNo professions detected - right-click for settings|r"
  end
  return "|cff9d9d9dNothing on this ticker - right-click for settings|r"
end

function Bar:Rebuild()
  local c = self:Cfg()
  if not c then self.frame:Hide(); return end
  self:ApplyLayout()
  -- In Edit Mode the bar is always shown so it can be found and placed.
  if c.shown or UI:IsEditing() then self.frame:Show() else self.frame:Hide() end

  local entries = CT:Watched(self.index)
  if c.mode == "list" then
    local s = CT.db.settings
    local newest = freshest(entries)
    local status = newest and CT.Age(newest) or "no data"
    if CT.scan then status = "|cff33ff99refreshing...|r" end
    self:UpdateAutoBadge()
    self.age:SetText(status)
    self.parts = {}
    for _, t in ipairs(self.tapes) do t:Hide() end
    self.rot:Hide(); self.rotSpark:Hide(); self.rotCounts:Hide()
    self:RebuildList(entries)
    return
  end
  if self.listOn then self:SetListLayout(false) end
  local parts = {}
  for _, e in ipairs(entries) do parts[#parts + 1] = { entry = e, text = itemText(e) } end
  if #parts == 0 then parts[1] = { text = emptyText(self.index) } end
  self.parts = parts

  local s = CT.db.settings
  local newest = freshest(entries)
  local status = newest and CT.Age(newest) or "no data"
  if CT.scan then status = "|cff33ff99refreshing...|r" end
  self:UpdateAutoBadge()
  self.age:SetText(status)

  if c.mode == "rotate" then
    for _, t in ipairs(self.tapes) do t:Hide() end
    if self.rotIndex > #parts then self.rotIndex = 1 end
    self:ShowRot(self.rotIndex)
  else
    self.rot:Hide(); self.rotSpark:Hide(); self.rotCounts:Hide()
    local allMeasured = true
    for ti, tape in ipairs(self.tapes) do
      local x = 0
      for i, part in ipairs(parts) do
        local fs = tape.items[i]
        if not fs then
          fs = tape:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
          fs:SetWordWrap(false)
          fs:SetJustifyH("LEFT")
          tape.items[i] = fs
        end
        fs:Show()
        fs:SetWidth(0) -- let the string size to its text before measuring
        fs:SetText(part.text)
        local w, ok = UI.MeasureString(fs, part.text)
        if not ok then allMeasured = false end
        w = math.ceil(w)
        w = w + 4 -- a little slack; the string itself stays unbounded so it never clips
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", tape, "LEFT", x, 0)
        -- optional mini graph after the item (2.4.6), scrolls with the tape
        local sparkW = 0
        local wantSpark = c.tickerGraph and part.entry
        if wantSpark then
          if not fs.spark then
            fs.spark = ns.Graph.Create(tape, 44, 12, true, true)
          end
          fs.spark:ClearAllPoints()
          fs.spark:SetPoint("LEFT", tape, "LEFT", x + w + 4, 0)
          fs.spark:SetSeries(CT:Series(part.entry.id))
          fs.spark:Show()
          sparkW = 4 + 44
        elseif fs.spark then
          fs.spark:Hide()
        end
        if ti == 1 then part.x0 = x; part.x1 = x + w + sparkW end
        x = x + w + sparkW + GAP
      end
      for i = #parts + 1, #tape.items do
        tape.items[i]:Hide()
        if tape.items[i].spark then tape.items[i].spark:Hide() end
      end
      tape:SetWidth(math.max(1, x))
      tape:Show()
      self.tapeWidth = x - GAP + LOOP_GAP
    end
    if self.offset < -self.tapeWidth then self.offset = 0 end
    self:PlaceTape()
    if allMeasured then self.remeasureTries = 0 else self:ScheduleRemeasure() end
  end
  if self.hover and not UI:IsEditing() then self:UpdateHover(true) end
end


------------------------------------------------------------------------
-- 2.4.0: inventory counts and item icons (feature-detected, never invented)
------------------------------------------------------------------------
CT.ICON_PLACEHOLDER = "Interface\\Icons\\INV_Misc_QuestionMark"

local function rawCount(id, includeBank)
  if C_Item and type(C_Item.GetItemCount) == "function" then
    -- (item, includeBank, includeUses, includeReagentBank): reagent bank only counts with the bank
    local ok, n = pcall(C_Item.GetItemCount, id, includeBank, false, includeBank)
    if ok and type(n) == "number" then return n end
  end
  if type(GetItemCount) == "function" then
    local ok, n = pcall(GetItemCount, id, includeBank)
    if ok and type(n) == "number" then return n end
  end
  return nil
end

-- { bags =, bank = (nil if unknown), bankKnown =, total = } or nil when the client has no count API.
-- bags = carried; bank = (count incl. bank) - bags, so nothing is counted twice. The bank figure is
-- trusted once you've opened the bank this session, or when the client already reports bank items.
-- If the client already reports bank items for anything on a ticker, empty banks
-- are real zeros (not "unknown"). Without that, a 0 bank is indistinguishable
-- from "the bank hasn't been read yet", so we keep it unknown until you open the bank.
function CT:DetectBankData()
  if self.bankSeen then return end
  local n = self.NumBars and self:NumBars() or 1
  for i = 1, n do
    for _, e in ipairs(self:Watched(i) or {}) do
      local bags = rawCount(e.id, false)
      local all = rawCount(e.id, true)
      if type(bags) == "number" and type(all) == "number" and all > bags then
        self.bankSeen = true
        return
      end
    end
  end
end

function CT:ItemCounts(id)
  local bags = rawCount(id, false)
  if not bags then return nil end
  local r = { bags = bags, bankKnown = false }
  local all = rawCount(id, true)
  if all and all > bags then self.bankSeen = true end
  if all and all >= bags and (self.bankSeen or all > bags) then
    r.bank, r.bankKnown = all - bags, true
  end
  r.total = bags + (r.bank or 0)
  return r
end

-- Icon file ID/path, or nil if the client doesn't know it yet (caller shows the placeholder).
function CT:ItemIcon(id)
  if C_Item and type(C_Item.GetItemIconByID) == "function" then
    local ok, icon = pcall(C_Item.GetItemIconByID, id)
    if ok and icon then return icon end
  end
  if C_Item and type(C_Item.GetItemInfoInstant) == "function" then
    local ok, _, _, _, _, icon = pcall(C_Item.GetItemInfoInstant, id)
    if ok and icon then return icon end
  end
  if type(GetItemIcon) == "function" then
    local ok, icon = pcall(GetItemIcon, id)
    if ok and icon then return icon end
  end
  return nil
end

-- Held value at the current unit price: (bags + bank) x price. nil when there's no price.
function CT:HeldValue(id, counts, q)
  q = q or self:Quote(id)
  if not counts or not q or not q.price or q.price <= 0 then return nil end
  return counts.total * q.price
end

------------------------------------------------------------------------
-- 2.4.0: static list mode - compact info-bar rows (Brett's pick: concept A rows + concept B
-- BAG / BANK / VALUE columns). Columns are measured and packed: each is only as wide as its
-- widest text (or header), so there's no dead space; extra width (if you widen the list) goes to
-- the name column. Everything visual is in LIST_STYLE + CreateListRow / LayoutList.
------------------------------------------------------------------------
UI.LIST_STYLE = {
  rowH = 20, headH = 16, icon = 16, sparkW = 52, sparkH = 16,
  gap = 6, numGap = 10, markGap = 3, moneyGap = 6, coin = 12, coinPad = 1,
  pad = 5, slack = 4, -- slack: a few px so text never clips
  markSize = 16, scrollW = 8,                          -- 16 px text marks fill the row; slim scrollbar
  tint = { 1, 1, 1, 0.045 },                           -- alternating row tint
  head = "|cff7fbf8f",                                 -- column header colour (muted CT green)
}
local ST = UI.LIST_STYLE
UI.ROW_H, UI.HEAD_H = ST.rowH, ST.headH

-- Everything a row shows, as data (no layout).
function UI.ListRowData(e)
  local q = CT:Quote(e.id)
  local icon = CT:ItemIcon(e.id)
  local counts = CT:ItemCounts(e.id)
  local tr = (q and q.price and not q.none) and CT:Trend(e.id, q) or nil
  local priceNote, pg, ps, pc = "", "", "", ""
  if q and q.price and not q.none then
    pg, ps, pc = CT.MoneyParts(q.price)
  else
    priceNote = priceOnly(e, q)
  end
  return {
    entry = e, quote = q, icon = icon, iconPath = icon or CT.ICON_PLACEHOLDER, iconKnown = icon ~= nil,
    text = itemText(e), name = nameText(e, q), price = priceOnly(e, q),
    trend = tr,
    priceG = pg, priceS = ps, priceC = pc, priceNote = priceNote,
    trendMark = (q and q.price and not q.none) and CT.TrendMark(tr, ST.markSize) or "",
    trendPct = CT.TrendPct(tr),
    series = CT:Series(e.id), counts = counts, value = CT:HeldValue(e.id, counts, q),
  }
end

-- Column texts for one row's data.
-- Returns bag, bank, joinedValue, gold, silver, copper, valueNote.
-- joinedValue stays usable as a single string (rotate mode, tests); gold/silver/copper
-- are the aligned list cells, with zero denominations left blank (never 00g/00s/00c).
function UI.CountTexts(d)
  local c = d.counts
  if not c then return "|cff9d9d9d-|r", "|cff9d9d9d-|r", "", "", "", "", "" end
  local function qty(n)
    if not n or n == 0 then return "|cff9d9d9d-|r" end
    return tostring(n)
  end
  local bag = qty(c.bags)
  local bank = c.bankKnown and qty(c.bank) or "|cff9d9d9d?|r"
  local more = (c.bankKnown or c.total == 0) and "" or "|cff9d9d9d+|r"
  if not d.value then
    local note = "|cff9d9d9dno price|r"
    return bag, bank, note, "", "", "", note
  end
  local g, s, cu = CT.MoneyParts(d.value)
  if more ~= "" then
    if cu ~= "" then cu = cu .. more
    elseif s ~= "" then s = s .. more
    elseif g ~= "" then g = g .. more
    end
  end
  local letter = CT.PlainMoney(d.value) .. (more ~= "" and "+" or "")
  return bag, bank, letter, g, s, cu, ""
end

function Bar:IsList() return self:Cfg().mode == "list" end

local function listFS(parent, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetJustifyH(justify or "LEFT")
  fs:SetWordWrap(false)
  return fs
end

function Bar:CreateListRow(i)
  local f = self.frame
  local row = CreateFrame("Frame", nil, f)
  row:SetHeight(ST.rowH)
  row:EnableMouse(true)
  row:RegisterForDrag("LeftButton")
  row.bg = row:CreateTexture(nil, "BACKGROUND")
  row.bg:SetAllPoints()
  row.bg:SetColorTexture(ST.tint[1], ST.tint[2], ST.tint[3], (i % 2 == 0) and ST.tint[4] or 0)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(ST.icon, ST.icon)
  row.name = listFS(row, "LEFT")
  row.spark = ns.Graph.Create(row, ST.sparkW, ST.sparkH, true, true)
  local function coinTex(parent, path)
    local tex = parent:CreateTexture(nil, "ARTWORK")
    tex:SetSize(ST.coin, ST.coin)
    tex:SetTexture(path)
    tex:Hide()
    return tex
  end
  row.price = listFS(row, "RIGHT")
  row.priceG = listFS(row, "RIGHT")
  row.priceS = listFS(row, "RIGHT")
  row.priceC = listFS(row, "RIGHT")
  row.priceCoinG = coinTex(row, CT.COIN_GOLD)
  row.priceCoinS = coinTex(row, CT.COIN_SILVER)
  row.priceCoinC = coinTex(row, CT.COIN_COPPER)
  row.mark = listFS(row, "CENTER")
  do
    local path, _, flags = row.mark.GetFont and row.mark:GetFont()
    if type(path) ~= "string" or path == "" then path = "Fonts\\FRIZQT__.TTF" end
    if row.mark.SetFont then row.mark:SetFont(path, ST.markSize, type(flags) == "string" and flags or "") end
  end
  row.chg = listFS(row, "RIGHT")
  row.bag = listFS(row, "RIGHT")
  row.bank = listFS(row, "RIGHT")
  row.value = listFS(row, "RIGHT")
  row.valueG = listFS(row, "RIGHT")
  row.valueS = listFS(row, "RIGHT")
  row.valueC = listFS(row, "RIGHT")
  row.valueCoinG = coinTex(row, CT.COIN_GOLD)
  row.valueCoinS = coinTex(row, CT.COIN_SILVER)
  row.valueCoinC = coinTex(row, CT.COIN_COPPER)
  -- dragging a row moves the whole list; wheel scrolls it; clicks act like the tape
  row:SetScript("OnDragStart", function() local h = f:GetScript("OnDragStart"); if h then h(f) end end)
  row:SetScript("OnDragStop", function() local h = f:GetScript("OnDragStop"); if h then h(f) end end)
  row:SetScript("OnMouseDown", function() self.dragged = false end)
  row:SetScript("OnMouseUp", function(_, button)
    if button == "RightButton" then
      CT:SetTargetBar(self.index)
      if ns.Settings then ns.Settings:Open(self.index) end
    elseif button == "MiddleButton" then
      CT:StartScan(true)
    elseif button == "LeftButton" and not self.dragged and row.entry and ns.Lookup then
      CT:SetTargetBar(self.index); CT.lookupID = row.entry.id; ns.Lookup:ShowItem(row.entry.id)
    end
  end)
  row:EnableMouseWheel(true)
  row:SetScript("OnMouseWheel", function(_, delta) self:ScrollList(-delta) end)
  row:SetScript("OnEnter", function(r) self:ShowRowTooltip(r) end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.rows[i] = row
  return row
end

-- Measure a string with the bar's hidden measuring FontString.
function Bar:Measure(text)
  local m = self.measureFS
  if not m then
    m = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    m:SetWordWrap(false); m:Hide()
    self.measureFS = m
  end
  m:SetWidth(0)
  m:SetText(text)
  local w, ok = UI.MeasureString(m, text)
  if not ok then self.listEstimated = true end
  return math.ceil(w)
end

function Bar:ScrollList(delta)
  local n = self.listEntries and #self.listEntries or 0
  local vis = self.listVisible or n
  local old = self.listOffset or 0
  self.listOffset = math.max(0, math.min(math.max(0, n - vis), old + delta))
  if self.listOffset ~= old then self:LayoutList() end
end

-- Slim right-edge scrollbar, only while the list is shorter than the item count.
function Bar:EnsureListScroll()
  if self.listScroll then return self.listScroll end
  local f = self.frame
  local sb = CreateFrame("Frame", nil, f)
  sb:SetWidth(ST.scrollW)
  sb:EnableMouse(true)
  sb:EnableMouseWheel(true)
  local track = sb:CreateTexture(nil, "BACKGROUND")
  track:SetAllPoints()
  track:SetColorTexture(0.08, 0.12, 0.08, 0.55)
  sb.track = track
  local thumb = CreateFrame("Frame", nil, sb)
  thumb:SetWidth(ST.scrollW)
  local tex = thumb:CreateTexture(nil, "ARTWORK")
  tex:SetAllPoints()
  tex:SetColorTexture(0.22, 0.72, 0.34, 0.85)
  thumb.tex = tex
  thumb:EnableMouse(true)
  thumb:SetScript("OnMouseDown", function()
    self.scrollDrag = true
    sb:SetScript("OnUpdate", function() self:ListScrollDrag() end)
  end)
  thumb:SetScript("OnMouseUp", function()
    self.scrollDrag = false
    sb:SetScript("OnUpdate", nil)
  end)
  sb:SetScript("OnMouseUp", function()
    self.scrollDrag = false
    sb:SetScript("OnUpdate", nil)
  end)
  sb:SetScript("OnMouseWheel", function(_, delta) self:ScrollList(-delta) end)
  sb:SetScript("OnMouseDown", function()
    if self.scrollDrag then return end
    local _, cy = GetCursorPosition()
    local scale = f:GetEffectiveScale() or 1
    local top = sb:GetTop()
    if not top or not cy or scale <= 0 then return end
    local y = top - cy / scale
    local t0, th = sb.thumbY or 0, sb.thumbH or 12
    local vis = self.listVisible or 1
    if y < t0 then self:ScrollList(-vis) elseif y > t0 + th then self:ScrollList(vis) end
  end)
  sb.thumb = thumb
  self.listScroll = sb
  return sb
end

function Bar:ListScrollDrag()
  local sb = self.listScroll
  if not sb or not self.scrollDrag then return end
  local _, cy = GetCursorPosition()
  local scale = self.frame:GetEffectiveScale() or 1
  local top = sb:GetTop()
  if not top or not cy or scale <= 0 then return end
  local y = top - cy / scale
  local travel, maxOff = sb.travel or 0, sb.maxOff or 0
  local rel = 0
  if travel > 0 then rel = (y - (sb.thumbH or 12) / 2) / travel end
  local off = math.max(0, math.min(maxOff, math.floor(rel * maxOff + 0.5)))
  if off ~= (self.listOffset or 0) then
    self.listOffset = off
    self:LayoutList()
  end
end

function Bar:UpdateListScroll()
  local n = self.listEntries and #self.listEntries or 0
  local vis = self.listVisible or n
  if n <= vis then
    if self.listScroll then self.listScroll:Hide() end
    return
  end
  local sb = self:EnsureListScroll()
  local f = self.frame
  sb:ClearAllPoints()
  sb:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -ST.headH)
  sb:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 2)
  sb:SetWidth(ST.scrollW)
  sb:Show()
  local maxOff = n - vis
  local off = self.listOffset or 0
  local trackH = (f:GetHeight() or 0) - ST.headH - 5
  if trackH < 8 then trackH = vis * ST.rowH end
  local thumbH = math.max(12, math.floor(trackH * vis / n + 0.5))
  if thumbH > trackH then thumbH = trackH end
  local travel = math.max(0, trackH - thumbH)
  local thumbY = (maxOff > 0) and math.floor(travel * off / maxOff + 0.5) or 0
  sb.thumb:ClearAllPoints()
  sb.thumb:SetPoint("TOPLEFT", sb, "TOPLEFT", 0, -thumbY)
  sb.thumb:SetHeight(thumbH)
  sb.thumb:SetWidth(ST.scrollW)
  sb.maxOff, sb.trackH, sb.thumbH, sb.travel, sb.thumbY = maxOff, trackH, thumbH, travel, thumbY
end

-- Natural (packed) width of the list for the current data; used as the minimum width.
function Bar:ListNaturalWidth() return self.listNatural end

function Bar:LayoutList()
  local f, c = self.frame, self:Cfg()
  self.rows = self.rows or {}
  self.listEstimated = false
  local entries = self.listEntries or {}
  local n = #entries
  -- data + column widths over ALL entries, so scrolling never re-flows the columns
  local data = {}
  local sl = ST.slack
  local function cellW(text)
    if not text or text == "" then return 0 end
    return self:Measure(text) + sl
  end
  -- Packed g/s/c width; a zero-width denomination is dropped so we never reserve room for 00g.
  local function packMoney(wG, wS, wC)
    local total, x, xG, xS, xC = 0, 0, 0, 0, 0
    local function add(w)
      if w <= 0 then return 0 end
      if total > 0 then x = x + ST.moneyGap end
      local at = x
      x = x + w
      total = x
      return at
    end
    xG, xS, xC = add(wG), add(wS), add(wC)
    return total, xG, xS, xC
  end
  local wName, wMark, wChg = 0, 0, 0
  local wPG, wPS, wPC = 0, 0, 0
  local wVG, wVS, wVC = 0, 0, 0
  local wBag = self:Measure("BAG") + sl
  local wBank = self:Measure("BANK") + sl
  local wNoteP, wNoteV = 0, self:Measure("VALUE") + sl
  for i, e in ipairs(entries) do
    local d = UI.ListRowData(e)
    d.bagT, d.bankT, d.valueT, d.valueG, d.valueS, d.valueC, d.valueNote = UI.CountTexts(d)
    data[i] = d
    wName = max(wName, cellW(d.name))
    if d.priceNote and d.priceNote ~= "" then
      wNoteP = max(wNoteP, cellW(d.priceNote))
    else
      wPG, wPS, wPC = max(wPG, cellW(d.priceG)), max(wPS, cellW(d.priceS)), max(wPC, cellW(d.priceC))
    end
    wMark = max(wMark, cellW(d.trendMark))
    wChg = max(wChg, cellW(d.trendPct))
    wBag = max(wBag, cellW(d.bagT))
    wBank = max(wBank, cellW(d.bankT))
    if d.valueNote and d.valueNote ~= "" then
      wNoteV = max(wNoteV, cellW(d.valueNote))
    else
      wVG, wVS, wVC = max(wVG, cellW(d.valueG)), max(wVS, cellW(d.valueS)), max(wVC, cellW(d.valueC))
    end
  end
  local coinW = ST.coin + ST.coinPad
  if wPG > 0 then wPG = wPG + coinW end
  if wPS > 0 then wPS = wPS + coinW end
  if wPC > 0 then wPC = wPC + coinW end
  if wVG > 0 then wVG = wVG + coinW end
  if wVS > 0 then wVS = wVS + coinW end
  if wVC > 0 then wVC = wVC + coinW end
  local wPrice, xPGrel, xPSrel, xPCrel = packMoney(wPG, wPS, wPC)
  wPrice = max(wPrice, wNoteP)
  local wVal, xVGrel, xVSrel, xVCrel = packMoney(wVG, wVS, wVC)
  wVal = max(wVal, wNoteV)
  local cols = CT.ListCols(c)
  if not cols.price then wPrice, wPG, wPS, wPC, xPGrel, xPSrel, xPCrel = 0, 0, 0, 0, 0, 0, 0 end
  if not cols.trend then wMark, wChg = 0, 0 end
  if not cols.bag then wBag = 0 end
  if not cols.bank then wBank = 0 end
  if not cols.value then wVal, wVG, wVS, wVC, xVGrel, xVSrel, xVCrel = 0, 0, 0, 0, 0, 0, 0 end
  local needScroll = n > (c.listRows or 8)
  local sbW = needScroll and (ST.scrollW + 4) or 0
  local headLeft = self:Measure(self.label:GetText() or "") + 4 + self:Measure(self.age:GetText() or "") + 4
    + self:Measure(self.listInfo:GetText() or "")
  local x = ST.pad
  local function place(on, w, gap)
    if not on then return 0 end
    local at = x
    x = x + w + (gap or 0)
    return at
  end
  local xIcon = place(cols.icon, ST.icon, ST.gap)
  local xName = place(true, wName, ST.gap)
  local xSpark = place(cols.spark, ST.sparkW, ST.gap)
  local xPrice = place(cols.price, wPrice, ST.numGap)
  local xMark = place(cols.trend and wMark > 0, wMark, ST.markGap)
  local xChg = place(cols.trend, wChg, ST.numGap)
  local xBag = place(cols.bag, wBag, ST.numGap)
  local xBank = place(cols.bank, wBank, ST.numGap)
  local xVal = place(cols.value, wVal, 0)
  local natural = x + ST.pad + sbW
  local numsW = ST.pad + sbW
  if cols.bag then numsW = numsW + wBag + ST.numGap end
  if cols.bank then numsW = numsW + wBank + ST.numGap end
  if cols.value then numsW = numsW + wVal end
  natural = max(natural, headLeft + ST.pad + ST.gap + numsW, n == 0 and 260 or 0)
  natural = math.ceil(natural)
  self.listNatural = natural
  local want = c.listWidth or 0
  local width = max(natural, want)
  wName = wName + (width - natural) -- extra width (you widened it) goes to the name column
  -- name grew: shift everything after it
  local shift = width - natural
  if shift ~= 0 then
    if cols.spark then xSpark = xSpark + shift end
    if cols.price then xPrice, xPGrel, xPSrel, xPCrel = xPrice + shift, xPGrel, xPSrel, xPCrel end
    if cols.trend then xMark, xChg = xMark + shift, xChg + shift end
    if cols.bag then xBag = xBag + shift end
    if cols.bank then xBank = xBank + shift end
    if cols.value then xVal = xVal + shift end
  end
  f:SetWidth(width)

  -- column x positions: optional icon/graph/price/trend + BAG / BANK / VALUE | scrollbar
  self.listCols = { icon = xIcon, name = xName, spark = xSpark, price = xPrice, mark = xMark, chg = xChg,
    bag = xBag, bank = xBank, value = xVal, shown = cols,
    priceG = xPrice + xPGrel, priceS = xPrice + xPSrel, priceC = xPrice + xPCrel,
    valueG = xVal + xVGrel, valueS = xVal + xVSrel, valueC = xVal + xVCrel,
    wName = wName, wPrice = wPrice, wMark = wMark, wChg = wChg, wBag = wBag, wBank = wBank, wVal = wVal, width = width,
    wPG = wPG, wPS = wPS, wPC = wPC, wVG = wVG, wVS = wVS, wVC = wVC }

  -- headers aligned with the number columns (hidden when that column is off)
  local hd = self.listHeads
  local function head(fs, on, x, w)
    if not on then fs:Hide(); return end
    fs:ClearAllPoints(); fs:SetPoint("TOPLEFT", f, "TOPLEFT", x, -3); fs:SetWidth(w); fs:Show()
  end
  head(hd.bag, cols.bag, xBag, wBag); head(hd.bank, cols.bank, xBank, wBank); head(hd.value, cols.value, xVal, wVal)

  local vis = math.max(1, math.min(n, c.listRows or 8))
  self.listVisible = vis
  self.listOffset = math.max(0, math.min(self.listOffset or 0, math.max(0, n - vis)))
  f:SetHeight(ST.headH + vis * ST.rowH + 3)
  for i = 1, vis do
    local row = self.rows[i] or self:CreateListRow(i)
    local d = data[self.listOffset + i]
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -ST.headH - (i - 1) * ST.rowH)
    row:SetPoint("TOPRIGHT", f, "TOPRIGHT", -(needScroll and (ST.scrollW + 2) or 1), -ST.headH - (i - 1) * ST.rowH)
    if d then self:FillRow(row, d); row:Show() else row.entry = nil; row:Hide() end
  end
  for i = vis + 1, #self.rows do self.rows[i]:Hide(); self.rows[i].entry = nil end
  if n > vis then
    self.listInfo:SetText(format("|cff9d9d9d%d-%d/%d|r", self.listOffset + 1, self.listOffset + vis, n))
  else
    self.listInfo:SetText("")
  end
  if self.listEstimated then self:ScheduleRemeasure() else self.remeasureTries = 0 end
  self:UpdateListScroll()
end

-- Place one row's widgets in the measured columns and fill them.
function Bar:FillRow(row, d)
  local L = self.listCols
  row.entry, row.data = d.entry, d
  row.iconPath, row.counts, row.heldValue = d.iconPath, d.counts, d.value
  local function at(w, x, width)
    w:ClearAllPoints(); w:SetPoint("LEFT", row, "LEFT", x - 1, 0)
    if width then w:SetWidth(width) end
  end
  row.icon:SetTexture(d.iconPath)
  if row.icon.SetDesaturated then row.icon:SetDesaturated(not d.iconKnown) end
  at(row.icon, L.icon)
  at(row.name, L.name, L.wName); row.name:SetText(d.name)
  at(row.spark, L.spark); row.spark:SetSeries(d.series)
  local coinW = ST.coin + ST.coinPad
  local function placeMoney(noteFS, gFS, sFS, cFS, gIcon, sIcon, cIcon,
      x0, wG, wS, wC, xG, xS, xC, g, s, cu, note, wBlock, letter)
    local function one(fs, icon, x, w, text)
      if w > 0 then
        local nw = math.max(0, w - coinW)
        if text and text ~= "" then
          fs:Show(); at(fs, x, nw); fs:SetText(text)
          icon:Show()
          icon:ClearAllPoints()
          icon:SetPoint("LEFT", row, "LEFT", x - 1 + nw, 0)
          icon:SetSize(ST.coin, ST.coin)
        else
          fs:Hide(); fs:SetText(""); icon:Hide()
        end
      else
        fs:Hide(); fs:SetText(""); icon:Hide()
      end
    end
    if note and note ~= "" then
      noteFS:Show(); at(noteFS, x0, wBlock); noteFS:SetText(note)
      gFS:Hide(); sFS:Hide(); cFS:Hide()
      gIcon:Hide(); sIcon:Hide(); cIcon:Hide()
    else
      -- hidden combined string (letter form) for tests
      noteFS:Hide(); at(noteFS, x0, wBlock); noteFS:SetText(letter or "")
      one(gFS, gIcon, xG, wG, g); one(sFS, sIcon, xS, wS, s); one(cFS, cIcon, xC, wC, cu)
    end
  end
  local priceLetter = (d.priceNote == "" and d.quote and d.quote.price) and CT.PlainMoney(d.quote.price) or (d.price or "")
  placeMoney(row.price, row.priceG, row.priceS, row.priceC,
    row.priceCoinG, row.priceCoinS, row.priceCoinC,
    L.price, L.wPG, L.wPS, L.wPC, L.priceG, L.priceS, L.priceC,
    d.priceG, d.priceS, d.priceC, d.priceNote, L.wPrice, priceLetter)
  at(row.mark, L.mark, L.wMark); row.mark:SetText(d.trendMark or "")
  at(row.chg, L.chg, L.wChg); row.chg:SetText(d.trendPct or "")
  at(row.bag, L.bag, L.wBag); row.bag:SetText(d.bagT)
  at(row.bank, L.bank, L.wBank); row.bank:SetText(d.bankT)
  placeMoney(row.value, row.valueG, row.valueS, row.valueC,
    row.valueCoinG, row.valueCoinS, row.valueCoinC,
    L.value, L.wVG, L.wVS, L.wVC, L.valueG, L.valueS, L.valueC,
    d.valueG, d.valueS, d.valueC, d.valueNote, L.wVal, d.valueT)
  local cols = (L and L.shown) or CT.ListCols(self:Cfg())
  if cols.icon then row.icon:Show() else row.icon:Hide() end
  row.name:Show()
  if cols.spark then row.spark:Show() else row.spark:Hide() end
  local function showMoney(on, noteFS, gFS, sFS, cFS, gIcon, sIcon, cIcon)
    if on then return end
    noteFS:Hide(); gFS:Hide(); sFS:Hide(); cFS:Hide()
    gIcon:Hide(); sIcon:Hide(); cIcon:Hide()
  end
  showMoney(cols.price, row.price, row.priceG, row.priceS, row.priceC, row.priceCoinG, row.priceCoinS, row.priceCoinC)
  if cols.trend then row.mark:Show(); row.chg:Show() else row.mark:Hide(); row.chg:Hide(); row.mark:SetText(""); row.chg:SetText("") end
  if cols.bag then row.bag:Show() else row.bag:Hide(); row.bag:SetText("") end
  if cols.bank then row.bank:Show() else row.bank:Hide(); row.bank:SetText("") end
  showMoney(cols.value, row.value, row.valueG, row.valueS, row.valueC, row.valueCoinG, row.valueCoinS, row.valueCoinC)
end


-- 2.5.0: drag the list's right edge, bottom edge or corner to resize (no Edit Mode needed).
local function clampListWidth(w)
  local lo, hi = 150, 2000
  if ns.EditMode and ns.EditMode.WIDTH_MIN then
    lo, hi = ns.EditMode.WIDTH_MIN, ns.EditMode.WIDTH_MAX
  end
  w = floor((w or 0) + 0.5)
  if w < lo then return lo end
  if w > hi then return hi end
  return w
end

local function clampListRows(n)
  n = floor((n or 8) + 0.5)
  if n < 3 then return 3 end
  if n > 30 then return 30 end
  return n
end

function Bar:CanListResize()
  if not self.listOn then return false end
  if self:Cfg().locked then return false end
  if CT.InCombat and CT:InCombat() then return false end
  if ns.EditMode and ns.EditMode.editing then return false end
  return true
end

function Bar:EnsureListResize()
  if self.resizeW then return end
  local f = self.frame
  local function grip(kind)
    local g = CreateFrame("Frame", nil, f)
    g:EnableMouse(true)
    g.ctListResize = kind
    local tex = g:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    if tex.SetColorTexture then tex:SetColorTexture(0.2, 0.8, 0.4, 0) end
    g.tex = tex
    g:SetScript("OnEnter", function(s)
      if s.tex and s.tex.SetColorTexture then s.tex:SetColorTexture(0.2, 0.8, 0.4, 0.35) end
      GameTooltip:SetOwner(s, kind == "height" and "ANCHOR_BOTTOM" or "ANCHOR_RIGHT")
      GameTooltip:ClearLines()
      if kind == "width" then
        GameTooltip:AddLine("Drag to change the width", 1, 1, 1)
      elseif kind == "height" then
        GameTooltip:AddLine("Drag to change how many list rows are shown", 1, 1, 1)
      else
        GameTooltip:AddLine("Drag to resize the list", 1, 1, 1)
      end
      GameTooltip:Show()
    end)
    g:SetScript("OnLeave", function(s)
      if not self.resizingList and s.tex and s.tex.SetColorTexture then
        s.tex:SetColorTexture(0.2, 0.8, 0.4, 0)
      end
      GameTooltip:Hide()
    end)
    g:SetScript("OnMouseDown", function() self:StartListResize(kind) end)
    g:SetScript("OnMouseUp", function() self:StopListResize() end)
    return g
  end
  self.resizeW = grip("width")
  self.resizeH = grip("height")
  self.resizeC = grip("both")
  local function mark(parent, point, w, h)
    local t = parent:CreateTexture(nil, "OVERLAY")
    t:SetSize(w, h)
    t:SetPoint(point, parent, point, 0, 0)
    if t.SetColorTexture then t:SetColorTexture(0.2, 0.8, 0.4, 0.7) end
    return t
  end
  -- Small always-visible L in the corner so the resize grip is findable.
  mark(self.resizeC, "BOTTOMRIGHT", 10, 2)
  mark(self.resizeC, "BOTTOMRIGHT", 2, 10)
  self:PlaceListResize()
end

function Bar:PlaceListResize()
  local w, h, c = self.resizeW, self.resizeH, self.resizeC
  if not w then return end
  w:ClearAllPoints()
  w:SetWidth(8)
  w:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", 2, -2)
  w:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", 2, 10)
  h:ClearAllPoints()
  h:SetHeight(8)
  h:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", 2, -2)
  h:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -10, -2)
  c:ClearAllPoints()
  c:SetSize(14, 14)
  c:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", 2, -2)
end

function Bar:SyncListResize()
  if not self.listOn and not self.resizeW then return end
  self:EnsureListResize()
  self:PlaceListResize()
  local show = self:CanListResize()
  if show then
    self.resizeW:Show(); self.resizeH:Show(); self.resizeC:Show()
  else
    self.resizeW:Hide(); self.resizeH:Hide(); self.resizeC:Hide()
  end
end

function Bar:StartListResize(kind)
  if not self:CanListResize() then return end
  local f = self.frame
  local left, top = f:GetLeft(), f:GetTop()
  if not left or not top then return end
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
  local c = self:Cfg()
  c.point = { "TOPLEFT", "BOTTOMLEFT", floor(left + 0.5), floor(top + 0.5) }
  self.resizeLeft, self.resizeTop = left, top
  self.resizeKind = kind
  self.resizingList = true
  self.moving = true
  self.dragged = true
  -- Auto width (0) starts from the current packed size so the first drag doesn't jump.
  if (kind == "width" or kind == "both") and (c.listWidth or 0) == 0 then
    c.listWidth = clampListWidth(f:GetWidth() or self.listNatural or 0)
  end
  local grip = kind == "width" and self.resizeW or (kind == "height" and self.resizeH or self.resizeC)
  if grip then grip:SetScript("OnUpdate", function() self:ListResizeStep() end) end
end

function Bar:ListResizeStep()
  if not self.resizingList then return end
  if CT.InCombat and CT:InCombat() then self:StopListResize(); return end
  local cx, cy = GetCursorPosition()
  local f = self.frame
  local scale = f:GetEffectiveScale() or 1
  if scale <= 0 then return end
  local c = self:Cfg()
  local kind = self.resizeKind
  local changed = false
  if (kind == "width" or kind == "both") and cx and self.resizeLeft then
    local w = clampListWidth(cx / scale - self.resizeLeft)
    if w ~= c.listWidth then
      c.listWidth = w
      changed = true
    end
  end
  if (kind == "height" or kind == "both") and cy and self.resizeTop then
    local ht = self.resizeTop - cy / scale
    local rows = clampListRows((ht - ST.headH - 3) / ST.rowH)
    if rows ~= (c.listRows or 8) then
      c.listRows = rows
      changed = true
    end
  end
  if changed then
    self:LayoutList()
    self:PlaceListResize()
  end
end

function Bar:StopListResize()
  if not self.resizingList then return end
  self:ListResizeStep()
  self.resizingList = false
  self.moving = false
  self.resizeKind = nil
  for _, g in ipairs({ self.resizeW, self.resizeH, self.resizeC }) do
    if g then
      g:SetScript("OnUpdate", nil)
      if g.tex and g.tex.SetColorTexture then g.tex:SetColorTexture(0.2, 0.8, 0.4, 0) end
    end
  end
  CT:Refresh()
end

-- Switch the frame between the one-line ticker and the list layout.
function Bar:SetListLayout(on)
  local f = self.frame
  if not self.listInfo then
    self.listInfo = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.listEmpty = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.listEmpty:SetPoint("TOPLEFT", f, "TOPLEFT", ST.pad, -ST.headH - 3)
    self.listHeads = {}
    for _, k in ipairs({ "bag", "bank", "value" }) do
      local h = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      h:SetJustifyH("RIGHT"); h:SetWordWrap(false)
      h:SetText(ST.head .. k:upper() .. "|r")
      h:Hide()
      self.listHeads[k] = h
    end
  end
  if self.listOn == on then
    self:SyncListResize()
    return
  end
  self.listOn = on
  self.label:ClearAllPoints(); self.age:ClearAllPoints()
  if self.ahBtn then self.ahBtn:ClearAllPoints() end
  if on then
    self.label:SetPoint("TOPLEFT", f, "TOPLEFT", ST.pad, -3)
    self.age:SetPoint("LEFT", self.label, "LEFT", self:Measure(self.label:GetText() or "") + 4, 0)
    self.age:SetJustifyH("LEFT")
    self.ahBtn:SetPoint("LEFT", self.age, "RIGHT", 2, 0)
    self.listInfo:ClearAllPoints()
    self.listInfo:SetPoint("LEFT", self.ahBtn, "RIGHT", 4, 0)
    self.clip:Hide()
    self.listInfo:Show()
  else
    self.label:SetPoint("LEFT", f, "LEFT", PAD, 0)
    self.ahBtn:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
    self.age:SetPoint("RIGHT", self.ahBtn, "LEFT", -2, 0)
    self.age:SetJustifyH("RIGHT")
    self.clip:Show()
    self.age:SetWidth(AGE_W - AH_W - 2)
    self.listInfo:Hide(); self.listEmpty:Hide()
    if self.listScroll then self.listScroll:Hide() end
    for _, h in pairs(self.listHeads) do h:Hide() end
    for _, r in ipairs(self.rows or {}) do r:Hide(); r.entry = nil end
    f:SetHeight(20)
  end
  self:SyncListResize()
end

-- Colour of the AH badge follows settings.auto. Always visible so it can be
-- clicked even when the auction house is closed.
function Bar:UpdateAutoBadge()
  local on = CT.db and CT.db.settings and CT.db.settings.auto
  local label = self.ahBtn and self.ahBtn.label
  if not label then return end
  if on then
    label:SetText("|cff33ff99AH|r")
  else
    label:SetText("|cffff8000AH|r")
  end
end

function Bar:RebuildList(entries)
  self:SetListLayout(true)
  self.age:SetWidth(self:Measure(self.age:GetText() or "") + 2)
  self.listEntries = entries
  if #entries == 0 then
    self.listEmpty:SetText(emptyText(self.index)); self.listEmpty:Show()
  else
    self.listEmpty:Hide()
  end
  self:LayoutList()
end

-- Extra tip lines that aren't already on the triggering list or ticker.
-- shown.name / shown.price / shown.trend / shown.bag / shown.bank / shown.value
function UI.ItemExtras(e, shown)
  shown = shown or {}
  local q = CT:Quote(e.id)
  local r = {}
  if q and q.price then
    local parts = {}
    if not shown.price then
      if q.none then
        parts[#parts + 1] = (CT.Money(q.price) .. " |cffff8000none listed|r")
      else
        parts[#parts + 1] = CT.Money(q.price)
      end
    end
    if not shown.trend and not q.none then
      parts[#parts + 1] = CT.TrendText(CT:Trend(e.id, q))
    end
    if #parts > 0 then r.quote = table.concat(parts, "  ") end
    if (shown.price or shown.trend) and not q.none then
      local tr = CT:Trend(e.id, q)
      if tr and tr.prev then
        r.was = "|cff9d9d9dWas|r " .. CT.Money(tr.prev)
      end
    end
  elseif (not q or (not q.price and not q.none)) and not shown.price then
    r.quote = "|cff9d9d9dNo price yet|r"
  end
  local bits = {}
  if q then
    if q.src then bits[#bits + 1] = CT.SourceLabel(q.src) end
    if q.t and q.t > 0 then bits[#bits + 1] = CT.Ago(q.t) end
    local qty = q.qty
    if not qty then
      local series = CT:Series(e.id)
      local last = series[#series]
      qty = last and last.q
    end
    if qty then bits[#bits + 1] = format("%d listed", qty) end
  end
  if #bits > 0 then
    r.meta = "|cff9d9d9d" .. table.concat(bits, " · ") .. "|r"
  end
  local needCounts = not (shown.bag and shown.bank and shown.value)
  local counts = CT:ItemCounts(e.id)
  if needCounts and counts then
    local d = { counts = counts, value = CT:HeldValue(e.id, counts, q) }
    local bag, bank, letter = UI.CountTexts(d)
    local parts = {}
    if not shown.bag then parts[#parts + 1] = format("%sBAG|r %s", ST.head, bag) end
    if not shown.bank then parts[#parts + 1] = format("%sBANK|r %s", ST.head, bank) end
    if not shown.value then parts[#parts + 1] = format("%sVALUE|r %s", ST.head, (letter ~= "" and letter) or "|cff9d9d9d-|r") end
    if #parts > 0 then r.countLine = table.concat(parts, "  ") end
    r.counts = counts
  end
  local c = r.counts or counts
  if c and not c.bankKnown then
    r.bankHint = "Open the bank once to fill the bank column"
  end
  r.history = ns.Graph.HistoryLine(CT:Series(e.id))
  return r
end

-- Row tooltip: only what the list row doesn't already show.
function Bar:ShowRowTooltip(row)
  local e = row.entry
  if not e then return end
  local tt = GameTooltip
  tt:SetOwner(row, "ANCHOR_RIGHT")
  tt:ClearLines()
  local cols = CT.ListCols(self:Cfg())
  local x = UI.ItemExtras(e, { name = true, price = cols.price, trend = cols.trend, bag = cols.bag, bank = cols.bank, value = cols.value })
  if x.quote then tt:AddLine(x.quote, 1, 1, 1) end
  if x.was then tt:AddLine(x.was, 1, 1, 1) end
  if x.meta then tt:AddLine(x.meta, 0.75, 0.75, 0.75) end
  if x.countLine then tt:AddLine(x.countLine, 0.85, 0.85, 0.85) end
  if x.history then tt:AddLine(x.history, 0.6, 0.6, 0.6) end
  if x.bankHint then tt:AddLine(x.bankHint, 1, 0.6, 0.2, true) end
  if not (x.quote or x.was or x.meta or x.countLine or x.history or x.bankHint) then
    tt:AddLine("|cff9d9d9dNo price history yet|r", 0.6, 0.6, 0.6)
  end
  tt:Show()
end

-- Bag/bank changes: refresh the counts on list-mode tickers (debounced; nothing protected).
local inv = CreateFrame("Frame")
for _, e in ipairs({ "BAG_UPDATE_DELAYED", "BAG_UPDATE", "PLAYERBANKSLOTS_CHANGED", "PLAYERREAGENTBANKSLOTS_CHANGED",
  "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "PLAYER_ENTERING_WORLD" }) do
  pcall(inv.RegisterEvent, inv, e)
end
inv:SetScript("OnEvent", function(_, event)
  if event == "BANKFRAME_OPENED" then CT.bankSeen = true end
  if not UI.ready or UI.countsPending then return end
  local any = false
  for _, b in ipairs(UI.bars) do if b.active and b.listOn then any = true end end
  if not any then return end
  UI.countsPending = true
  C_Timer.After(0.3, function()
    UI.countsPending = false
    for _, b in ipairs(UI.bars) do if b.active and b.listOn then b:LayoutList() end end
  end)
end)

function UI:Rebuild()
  if not self.ready then return end
  CT:DetectBankData()
  if #self.bars < CT:NumBars() then self:SyncBars() end
  for _, b in ipairs(self.bars) do
    if b.active then b:Rebuild() else b.frame:Hide() end
  end
  self:UpdateReloadButton()
  if ns.EditMode and ns.EditMode.UpdateDialog then ns.EditMode:UpdateDialog() end
end

-- Rotate mode: one item with icon, name, price, trend, sparkline and BAG / BANK / VALUE.
function Bar:ShowRot(i)
  local part = self.parts and self.parts[i]
  if not part then return end
  self.rot:SetText(part.text)
  self.rot:Show()
  local e = part.entry
  if not e then self.rotSpark:Hide(); self.rotCounts:Hide(); return end
  local d = UI.ListRowData(e)
  self.rotSpark:SetSeries(d.series)
  local bag, bank, valueLetter, _, _, _, valueNote = UI.CountTexts(d)
  local value = (valueNote and valueNote ~= "") and valueNote or (d.value and CT.Money(d.value) or valueLetter)
  if d.value and d.counts and not d.counts.bankKnown and d.counts.total > 0 then
    value = value .. "|cff9d9d9d+|r"
  end
  local h = UI.LIST_STYLE.head
  local full = d.counts and format("%sBAG|r %s  %sBANK|r %s  %sVALUE|r %s", h, bag, h, bank, h, value)
    or "|cff9d9d9dcounts n/a|r"
  -- fit to the bar: drop the sparkline first, then tighten the counts, before anything clips
  local room = self:Cfg().width - (PAD + LABEL_W + 4) - (PAD + AGE_W + 4)
  local textW = self:Measure(part.text)
  local countsW = self:Measure(full)
  local showSpark = (self:Cfg().tickerGraph ~= false) and (textW + 6 + 44 + 8 + countsW <= room)
  local counts = full
  if not showSpark and d.counts and textW + 8 + countsW > room then
    counts = format("%sB|r%s %sK|r%s %sV|r%s", h, bag, h, bank, h, value)
  end
  self.rotSpark:ClearAllPoints()
  self.rotSpark:SetPoint("LEFT", self.rot, "RIGHT", 6, 0)
  self.rotCounts:ClearAllPoints()
  if showSpark then
    self.rotSpark:Show()
    self.rotCounts:SetPoint("LEFT", self.rotSpark, "RIGHT", 8, 0)
  else
    self.rotSpark:Hide()
    self.rotCounts:SetPoint("LEFT", self.rot, "RIGHT", 8, 0)
  end
  self.rotCounts:SetText(counts)
  self.rotCounts:Show()
  self.rotData = d
end

function Bar:PlaceTape()
  local a, b = self.tapes[1], self.tapes[2]
  a:ClearAllPoints(); a:SetPoint("LEFT", self.clip, "LEFT", self.offset, 0)
  b:ClearAllPoints(); b:SetPoint("LEFT", self.clip, "LEFT", self.offset + self.tapeWidth, 0)
end

function Bar:OnUpdate(elapsed)
  local c = self:Cfg()
  if not c then return end
  if c.mode == "list" then return end -- static
  if self.hover then self:UpdateHover(false); return end -- paused while hovered
  if c.mode == "rotate" then
    self.rotTimer = self.rotTimer + elapsed
    if self.rotTimer >= CT.db.settings.rotateSecs and self.parts and #self.parts > 0 then
      self.rotTimer = 0
      self.rotIndex = self.rotIndex % #self.parts + 1
      self:ShowRot(self.rotIndex)
    end
    return
  end
  if not self.tapeWidth or self.tapeWidth <= LOOP_GAP then return end
  self.offset = self.offset - c.speed * elapsed
  if self.offset <= -self.tapeWidth then self.offset = self.offset + self.tapeWidth end
  self:PlaceTape()
end

-- Summary table (hovering the label or status area).
function Bar:ShowTooltip()
  local tt = GameTooltip
  tt:SetOwner(self.frame, "ANCHOR_BOTTOM")
  tt:ClearLines()
  tt:AddDoubleLine("CommodityTicker: " .. CT:BarName(self.index), CT:MarketKey(), 0.2, 1, 0.6, 0.8, 0.8, 0.8)
  tt:AddLine(CT.SourcesText(self:Cfg()), 0.6, 0.8, 1, true)
  for _, e in ipairs(CT:Watched(self.index)) do
    local q = CT:Quote(e.id)
    local name = (e.tracked and "> " or "") .. CT:ItemName(e.id, e.name)
    local right
    if q and q.price then
      right = CT.Money(q.price)
      if not q.none then right = right .. " " .. CT.TrendText(CT:Trend(e.id, q), true) end
      if q.none then right = right .. " |cffff8000none listed|r"
      elseif q.qty then right = right .. format(" |cff9d9d9dx%d|r", q.qty) end
      right = right .. format(" |cff9d9d9d%s, %s|r", CT.SourceLabel(q.src), CT.Age(q.t))
    elseif q and q.none then
      right = "|cffff8000none listed|r |cff9d9d9d" .. CT.Age(q.t) .. "|r"
    else
      right = "|cff9d9d9dno data yet|r"
    end
    tt:AddDoubleLine(name, right, 1, 1, 1, 1, 1, 1)
  end
  local m = CT:Market()
  tt:AddLine(" ")
  if CT.ahOpen then
    if CT.db.settings.auto then
      tt:AddLine(format("AH open: live refresh every %d min (next in %ds). Click the AH badge to turn it off.", CT.db.settings.interval, CT:NextAutoIn()), 0.6, 1, 0.6)
    else
      tt:AddLine("AH open: auto-refresh is off. Prices come from TSM, Auctionator or the feed. Click the AH badge to turn it on.", 1, 0.6, 0.2, true)
    end
  else
    tt:AddLine(format("Last AH refresh: %s. Live prices only update while the AH is open.",
      m.lastScan > 0 and CT.Ago(m.lastScan) or "never"), 0.8, 0.8, 0.8, true)
  end
  local feed = CT:Feed()
  if feed then
    tt:AddLine(format("Feed: %s, prices %s.", tostring(feed.source), CT.Ago(feed.updated)), 0.8, 0.8, 0.8)
    if CT:FeedMayBeStale() then
      tt:AddLine("A newer feed may be on disk if update_feed is running: click Load feed (or /commodity loadfeed).", 1, 0.6, 0.2, true)
    end
  end
  tt:AddLine("Hover an item for its graph. Click an item: full graph. > = tracked live.", 0.6, 0.6, 0.6, true)
  tt:AddLine("Right-click: settings (lists, tickers, look) - Middle-click: refresh at AH - Drag list edges to resize, or Esc > Edit Mode", 0.6, 0.6, 0.6, true)
  tt:Show()
end
function UI:ShowTooltip() (self.hoverBar or self.bars[1]):ShowTooltip() end
