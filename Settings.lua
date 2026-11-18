-- CommodityTicker settings window (/commodity settings, or right-click a ticker).
-- Pick a ticker at the top (up to CT.MAX_BARS), then change its look and its lists, and tick
-- commodities on or off. Everything writes the same saved settings the slash commands and
-- Edit Mode use, so all three always agree. Plain frames only.
local _, ns = ...
local CT = ns.CT

local S = { rows = {}, tabs = {}, scroll = 0 }
ns.Settings = S
CT.Settings = S

local format, max, min, floor = string.format, math.max, math.min, math.floor
local ROWS = 13
local W, H = 600, 610

local function backdrop(f, dark)
  if f.SetBackdrop then
    f:SetBackdrop({ bgFile = dark and "Interface\\DialogFrame\\UI-DialogBox-Background-Dark" or "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 } })
  end
end

local function button(parent, text, w)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w or 90, 20)
  b:SetText(text)
  return b
end

local function text(parent, font, str)
  local t = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  t:SetJustifyH("LEFT")
  if str then t:SetText(str) end
  return t
end

local function check(parent, label, onClick)
  local ok, cb = pcall(CreateFrame, "CheckButton", nil, parent, "UICheckButtonTemplate")
  if not ok or not cb then cb = CreateFrame("CheckButton", nil, parent) end
  cb:SetSize(22, 22)
  cb.label = text(parent, "GameFontHighlightSmall", label)
  cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
  cb:SetScript("OnClick", function(b) onClick(b:GetChecked() and true or false) end)
  return cb
end

local function slider(parent, label, lo, hi, step, fmt, onChange)
  local t = text(parent, "GameFontNormalSmall", label)
  local sl = CreateFrame("Slider", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  sl:SetOrientation("HORIZONTAL")
  sl:SetSize(200, 16)
  if sl.SetBackdrop then
    sl:SetBackdrop({ bgFile = "Interface\\Buttons\\UI-SliderBar-Background", edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
      tile = true, tileSize = 8, edgeSize = 8, insets = { left = 3, right = 3, top = 6, bottom = 6 } })
  end
  sl:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
  sl:SetMinMaxValues(lo, hi)
  sl:SetValueStep(step)
  if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
  sl:EnableMouseWheel(true)
  sl.title = t
  sl.valueText = text(parent, "GameFontHighlightSmall")
  sl.valueText:SetPoint("BOTTOMRIGHT", sl, "TOPRIGHT", 0, 2)
  t:SetPoint("BOTTOMLEFT", sl, "TOPLEFT", 0, 2)
  sl:SetScript("OnValueChanged", function(s, v, userInput)
    v = floor(v / step + 0.5) * step
    s.valueText:SetText(format(fmt, v))
    if userInput and not S.updating then onChange(v) end
  end)
  sl:SetScript("OnMouseWheel", function(s, delta)
    local v = max(lo, min(hi, (s:GetValue() or lo) + delta * step))
    s:SetValue(v)
    onChange(v)
  end)
  return sl
end

local function cfg() return CT:BarCfg(S.bar or 1) end
local NEXT_MODE = { scroll = "rotate", rotate = "list", list = "scroll" }
local MODE_HINT = { scroll = "scrolling tape", rotate = "one at a time", list = "static rows" }

------------------------------------------------------------------------
function S:Create()
  if self.frame then return self.frame end
  local f = CreateFrame("Frame", "CommodityTickerSettingsFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  self.frame = f
  f:SetSize(W, H)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
  f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(s) s:StartMoving() end)
  f:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
  backdrop(f, true)
  if UISpecialFrames then tinsert(UISpecialFrames, "CommodityTickerSettingsFrame") end -- Esc closes it

  local title = text(f, "GameFontNormalLarge", "CommodityTicker settings")
  title:SetPoint("TOPLEFT", 16, -14)
  local ver = text(f, "GameFontDisableSmall", "v" .. CT.VERSION)
  ver:SetPoint("LEFT", title, "RIGHT", 8, 0)
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)
  close:SetScript("OnClick", function() f:Hide() end)
  -- 2.8.0: Best farm right now (also /commodity farm)
  self.farmBtn = button(f, "Best farm", 90)
  self.farmBtn:SetPoint("TOPRIGHT", -36, -12)
  self.farmBtn:SetScript("OnClick", function() if ns.Farm then ns.Farm:Open() end end)
  self.farmBtn:SetScript("OnEnter", function(b)
    GameTooltip:SetOwner(b, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Best farm right now")
    GameTooltip:AddLine("Ranks what you can gather (plus Blue Pearl) by price x sell speed (estimate). Also /commodity farm.", 0.85, 0.85, 0.85, true)
    GameTooltip:Show()
  end)
  self.farmBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- Ticker tabs + new ticker
  for i = 1, CT.MAX_BARS do
    local t = button(f, "", 104)
    t:SetPoint("TOPLEFT", 16 + (i - 1) * 108, -40)
    t:SetScript("OnClick", function() S:Select(i) end)
    self.tabs[i] = t
  end
  self.newBtn = button(f, "+ New ticker", 104)
  self.newBtn:SetPoint("TOPRIGHT", -16, -40)
  self.newBtn:SetScript("OnClick", function()
    local i, err = CT:CreateBar(nil, { profession = false, now = false, later = false })
    if i then S:Select(i) else CT.Print("can't create a ticker: " .. err) end
  end)

  -- Name / delete
  local nl = text(f, "GameFontNormalSmall", "Name")
  nl:SetPoint("TOPLEFT", 18, -72)
  local nb = CreateFrame("EditBox", "CommodityTickerSettingsName", f, "InputBoxTemplate")
  nb:SetSize(150, 20)
  nb:SetPoint("LEFT", nl, "RIGHT", 10, 0)
  nb:SetAutoFocus(false)
  nb:SetMaxLetters(24)
  nb:SetScript("OnEnterPressed", function(b) CT:RenameBar(S.bar, b:GetText()); b:ClearFocus(); S:Update() end)
  nb:SetScript("OnEscapePressed", function(b) b:ClearFocus(); S:Update() end)
  self.nameBox = nb
  self.renameBtn = button(f, "Rename", 70)
  self.renameBtn:SetPoint("LEFT", nb, "RIGHT", 6, 0)
  self.renameBtn:SetScript("OnClick", function() CT:RenameBar(S.bar, nb:GetText()); nb:ClearFocus(); S:Update() end)
  self.deleteBtn = button(f, "Delete ticker", 100)
  self.deleteBtn:SetPoint("LEFT", self.renameBtn, "RIGHT", 6, 0)
  self.deleteBtn:SetScript("OnClick", function()
    local ok, err = CT:DeleteBar(S.bar)
    if not ok then CT.Print(err) end
    S:Select(max(1, S.bar - 1))
  end)

  -- Left column: look
  local lx = 18
  local look = text(f, "GameFontNormal", "Look")
  look:SetPoint("TOPLEFT", lx, -102)
  self.shownCB = check(f, "Show this ticker", function(v) cfg().shown = v; CT:Refresh() end)
  self.shownCB:SetPoint("TOPLEFT", lx - 4, -120)
  self.dragCB = check(f, "Drag to move or resize outside Edit Mode", function(v) cfg().locked = not v; CT:Refresh() end)
  self.dragCB:SetPoint("TOPLEFT", lx - 4, -142)
  self.modeBtn = button(f, "Mode: scroll", 112)
  self.modeBtn:SetPoint("TOPLEFT", lx, -170)
  self.modeBtn:SetScript("OnClick", function()
    local c = cfg(); c.mode = NEXT_MODE[c.mode] or "scroll"; CT:Refresh(); S:Update()
  end)
  self.modeHint = text(f, "GameFontDisableSmall")
  self.modeHint:SetPoint("LEFT", self.modeBtn, "RIGHT", 6, 0)
  self.modeHint:SetWidth(96)
  self.modeHint:SetWordWrap(false)
  self.width = slider(f, "Width", 150, 2000, 10, "%d px", function(v) local c = cfg(); c[CT.WidthKey(c)] = v; CT:Refresh() end)
  self.width:SetPoint("TOPLEFT", lx, -218)
  self.scale = slider(f, "Scale", 0.5, 2, 0.05, "%.2f", function(v) cfg().scale = v; CT:Refresh() end)
  self.scale:SetPoint("TOPLEFT", lx, -258)
  self.speed = slider(f, "Scroll speed", 5, 200, 5, "%d px/s", function(v) cfg().speed = v; CT:Refresh() end)
  self.speed:SetPoint("TOPLEFT", lx, -298)
  self.rowsSl = slider(f, "List rows (scrollbar if more items)", 3, 30, 1, "%d", function(v) cfg().listRows = v; CT:Refresh() end)
  self.rowsSl:SetPoint("TOPLEFT", lx, -338)
  self.tickerGraphCB = check(f, "Show graph on the ticker", function(v)
    if S.updating then return end
    cfg().tickerGraph = v and true or false
    CT:Refresh()
  end)
  self.tickerGraphCB:SetPoint("TOPLEFT", lx - 4, -338)
  self.colTitle = text(f, "GameFontNormalSmall", "List columns")
  self.colTitle:SetPoint("TOPLEFT", lx, -360)
  self.colCB = {}
  local colRows = { { "icon", "spark", "price", "trend" }, { "bag", "bank", "value" } }
  local colY = { -376, -398 }
  local colW = 56
  for ri, keys in ipairs(colRows) do
    for ci, key in ipairs(keys) do
      local cb = check(f, CT.LIST_COL_LABELS[key], function(v)
        if S.updating then return end
        CT.EnsureListCols(cfg())
        cfg().listCols[key] = v and true or false
        CT:Refresh()
      end)
      cb:SetSize(20, 20)
      cb:SetPoint("TOPLEFT", lx - 4 + (ci - 1) * colW, colY[ri])
      self.colCB[key] = cb
    end
  end
  self.resetBtn = button(f, "Reset position", 120)
  self.resetBtn:SetPoint("TOPLEFT", lx, -364)
  self.resetBtn:SetScript("OnClick", function() local c = cfg(); c.point = CT.DefaultBarPoint(S.bar); c.shown = true; CT:Refresh(); S:Update() end)
  self.emHint = text(f, "GameFontDisableSmall", "Move or resize any ticker in WoW's Edit Mode: Esc > Edit Mode, then click the bar.")
  self.emHint:SetPoint("TOPLEFT", lx, -392)
  self.emHint:SetWidth(210)
  self.emHint:SetWordWrap(true)

  -- Right column: lists
  local rx = 250
  local lists = text(f, "GameFontNormal", "Lists on this ticker")
  lists:SetPoint("TOPLEFT", rx, -102)
  self.srcCB = {}
  local y = -120
  for _, key in ipairs({ "profession", "now", "later" }) do
    local cb = check(f, CT.SOURCE_LABELS[key], function(v) CT:SetSource(S.bar, key, v); S:Update() end)
    cb:SetPoint("TOPLEFT", rx - 4, y)
    self.srcCB[key] = cb
    y = y - 20
  end
  self.profText = text(f, "GameFontHighlightSmall")
  self.profText:SetPoint("TOPLEFT", rx, y - 4)
  self.profText:SetWidth(330)
  self.listHint = text(f, "GameFontDisableSmall", "Picks = your current tier of herbs, ore, leather, cloth, enchanting mats. Tick other items to add them; untick to remove.")
  self.listHint:SetPoint("TOPLEFT", rx, y - 20)
  self.listHint:SetWidth(330)
  self.listHint:SetWordWrap(true)

  local list = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
  list:SetPoint("TOPLEFT", rx - 2, y - 46)
  list:SetSize(334, ROWS * 18 + 6)
  if list.SetBackdrop then
    list:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    list:SetBackdropColor(0, 0, 0, 0.35)
    list:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)
  end
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta) S:Scroll(-delta * 3) end)
  self.list = list
  for r = 1, ROWS do
    local cb = check(list, "", function(v) S:Toggle(r, v) end)
    cb:SetPoint("TOPLEFT", 2, -3 - (r - 1) * 18)
    cb:SetSize(18, 18)
    cb.label:SetWidth(300)
    cb.label:SetWordWrap(false)
    self.rows[r] = cb
  end
  self.up = button(f, "Up", 44)
  self.up:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -4)
  self.up:SetScript("OnClick", function() S:Scroll(-ROWS) end)
  self.down = button(f, "Down", 50)
  self.down:SetPoint("LEFT", self.up, "RIGHT", 4, 0)
  self.down:SetScript("OnClick", function() S:Scroll(ROWS) end)
  self.pageText = text(f, "GameFontDisableSmall")
  self.pageText:SetPoint("LEFT", self.down, "RIGHT", 8, 0)

  local ab = CreateFrame("EditBox", "CommodityTickerSettingsAdd", f, "InputBoxTemplate")
  ab:SetSize(170, 20)
  ab:SetPoint("TOPLEFT", self.up, "BOTTOMLEFT", 6, -6)
  ab:SetAutoFocus(false)
  ab:SetScript("OnEnterPressed", function(b) S:AddTyped(); b:ClearFocus() end)
  ab:SetScript("OnEscapePressed", function(b) b:ClearFocus() end)
  self.addBox = ab
  self.addBtn = button(f, "Add commodity", 110)
  self.addBtn:SetPoint("LEFT", ab, "RIGHT", 6, 0)
  self.addBtn:SetScript("OnClick", function() S:AddTyped() end)
  self.autoCB = check(f, "Scan the AH myself (off = use TSM/Auctionator/feed)", function(v)
    if S.updating then return end
    CT:SetAuto(v and true or false)
  end)
  self.autoCB:SetPoint("BOTTOMLEFT", 14, 72)
  self.autoCB.label:SetWidth(226)
  self.autoCB.label:SetWordWrap(true)
  self.shareCB = check(f, "Share my prices with the guild", function(v)
    if S.updating then return end
    CT.db.settings.sharePrices = v and true or false
    if not v then CT.shareQueue = {} end
  end)
  self.shareCB:SetPoint("BOTTOMLEFT", 14, 36)

  self.status = text(f, "GameFontHighlightSmall")
  self.status:SetPoint("BOTTOMLEFT", 18, 14)
  self.status:SetWidth(W - 36)

  -- shift-click an item link while the add box has focus
  local function onInsert(link)
    if ab:IsShown() and ab.HasFocus and ab:HasFocus() and type(link) == "string" then ab:SetText(link) end
  end
  if ChatFrameUtil and ChatFrameUtil.InsertLink then hooksecurefunc(ChatFrameUtil, "InsertLink", onInsert)
  elseif ChatEdit_InsertLink then hooksecurefunc("ChatEdit_InsertLink", onInsert) end

  f:Hide()
  return f
end

function S:Open(i)
  self:Create()
  CT:UpdateProfessions(true)
  self.frame:Show()
  self:Select(i or CT:TargetBar())
end

function S:Select(i)
  if i > CT:NumBars() then i = CT:NumBars() end
  self.bar = i
  CT:SetTargetBar(i)
  self.scroll = 0
  self:Update()
end

function S:AddTyped()
  local t = self.addBox:GetText()
  if t == "" then return end
  local id, err = CT:CheckedItem(t, "add")
  if not id then self.status:SetText("|cffff6060" .. err .. "|r"); return end
  CT:SetOnBar(id, self.bar, true)
  self.addBox:SetText("")
  self.status:SetText("Added " .. CT:ItemName(id) .. " to \"" .. CT:BarName(self.bar) .. "\".")
  self:Update()
end

function S:Toggle(r, on)
  local row = self.shown and self.shown[r]
  if not row then return end
  if on and row.unverified then
    self.status:SetText(format("|cffffd100%s: its skill isn't confirmed for Forever yet, so it's added as one of your own items.|r", row.name))
  end
  CT:SetOnBar(row.id, self.bar, on)
  self:Update()
end

function S:Scroll(delta)
  local n = #(self.items or {})
  self.scroll = max(0, min(max(0, n - ROWS), self.scroll + delta))
  self:UpdateRows()
end

function S:UpdateRows()
  local items = self.items or {}
  self.shown = {}
  for r = 1, ROWS do
    local row = items[self.scroll + r]
    local cb = self.rows[r]
    if row then
      self.shown[r] = row
      cb:Show(); cb.label:Show()
      cb:SetChecked(row.on)
      local col = row.unverified and "|cffff9933" or (row.on and "|cffffffff" or "|cff9d9d9d")
      cb.label:SetText(format("%s%s|r |cff808080- %s%s|r", col, row.name, row.note,
        (row.removed and not row.on) and " (removed)" or ""))
    else
      cb:Hide(); cb.label:Hide()
    end
  end
  local n = #items
  self.pageText:SetText(n == 0 and "nothing to show" or format("%d-%d of %d", min(n, self.scroll + 1), min(n, self.scroll + ROWS), n))
end

function S:Update()
  if not self.frame or not self.frame:IsShown() then return end
  local n = CT:NumBars()
  if (self.bar or 1) > n then self.bar = n end
  local c = cfg()
  self.updating = true
  for i, t in ipairs(self.tabs) do
    if i <= n then
      t:Show()
      t:SetText((i == self.bar and "> " or "") .. i .. " " .. CT:BarName(i))
    else
      t:Hide()
    end
  end
  if n >= CT.MAX_BARS then self.newBtn:Disable() else self.newBtn:Enable() end
  if self.bar == 1 then self.deleteBtn:Disable() else self.deleteBtn:Enable() end
  if not (self.nameBox.HasFocus and self.nameBox:HasFocus()) then self.nameBox:SetText(CT:BarName(self.bar)) end
  self.shownCB:SetChecked(c.shown and true or false)
  self.dragCB:SetChecked(not c.locked)
  if self.shareCB then
    self.shareCB:SetChecked(CT.db.settings.sharePrices ~= false)
  end
  if self.autoCB then
    self.autoCB:SetChecked(CT.db.settings.auto ~= false)
  end
  local mode = MODE_HINT[c.mode] and c.mode or "scroll"
  self.modeBtn:SetText("Mode: " .. mode)
  self.modeHint:SetText(MODE_HINT[mode])
  self.rowsSl:SetValue(c.listRows or 8)
  local listMode = mode == "list"
  if listMode then self.rowsSl:Show(); self.rowsSl.title:Show(); self.rowsSl.valueText:Show()
  else self.rowsSl:Hide(); self.rowsSl.title:Hide(); self.rowsSl.valueText:Hide() end
  if self.tickerGraphCB then
    if listMode then
      self.tickerGraphCB:Hide(); self.tickerGraphCB.label:Hide()
    else
      self.tickerGraphCB:Show(); self.tickerGraphCB.label:Show()
      self.tickerGraphCB:SetChecked(c.tickerGraph ~= false)
    end
  end
  CT.EnsureListCols(c)
  if self.colCB then
    if listMode then
      self.colTitle:Show()
      for key, cb in pairs(self.colCB) do
        cb:Show(); cb.label:Show(); cb:SetChecked(c.listCols[key] and true or false)
      end
    else
      self.colTitle:Hide()
      for _, cb in pairs(self.colCB) do cb:Hide(); cb.label:Hide() end
    end
  end
  self.resetBtn:ClearAllPoints()
  self.emHint:ClearAllPoints()
  if listMode then
    self.resetBtn:SetPoint("TOPLEFT", 18, -426)
    self.emHint:SetPoint("TOPLEFT", 18, -452)
  else
    self.resetBtn:SetPoint("TOPLEFT", 18, -364)
    self.emHint:SetPoint("TOPLEFT", 18, -392)
  end
  self.width:SetValue(CT:EffectiveWidth(self.bar))
  self.scale:SetValue(c.scale)
  self.speed:SetValue(c.speed)
  for key, cb in pairs(self.srcCB) do cb:SetChecked(c.sources and c.sources[key] and true or false) end
  local profN = 0
  for _ in pairs(CT:ProfessionItems()) do profN = profN + 1 end
  self.profText:SetText(format("Professions: |cffffffff%s|r - %d current-tier picks", CT:ProfessionSummary(), profN))
  self.updating = false
  self.items = CT:Candidates(self.bar)
  self.scroll = max(0, min(self.scroll, max(0, #self.items - ROWS)))
  self:UpdateRows()
end

-- keep the window in step with slash commands / Edit Mode
local baseRefresh = CT.Refresh
function CT:Refresh(...)
  baseRefresh(self, ...)
  if S.frame and S.frame:IsShown() and not S.inUpdate then
    S.inUpdate = true
    S:Update()
    S.inUpdate = false
  end
end
