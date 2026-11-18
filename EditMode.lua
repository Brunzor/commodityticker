-- CommodityTicker + WoW Edit Mode (Esc -> Edit Mode).
--
-- Blizzard has no public API to register an addon frame as an Edit Mode
-- "system", so this follows the pattern LibEditMode uses (without the library):
--   * a child frame from EditModeSystemSelectionTemplate covers the bar and is
--     shown only while EditModeManagerFrame is shown;
--   * EditModeManagerFrame OnShow/OnHide hooks enter/leave edit mode;
--   * hooksecurefunc(EditModeManagerFrame, "SelectSystem") unselects us when a
--     Blizzard frame is selected;
--   * our own small settings dialog (width, scale, show, lock) instead of the
--     Blizzard settings dialog.
-- Everything is saved to the same settings the slash commands use:
-- settings.point, settings.width, settings.scale, settings.shown, settings.locked.
-- If any of this is missing on the client, the addon still works through
-- /commodity unlock, width and scale.
local _, ns = ...
local CT = ns.CT

local EM = { editing = false, supported = false, entries = {} }
ns.EditMode = EM

local floor, max, min, format = math.floor, math.max, math.min, string.format
EM.WIDTH_MIN, EM.WIDTH_MAX = 150, 2000
EM.SCALE_MIN, EM.SCALE_MAX = 0.5, 2
local NAME = "CommodityTicker"

local function inCombat() return CT.InCombat and CT:InCombat() end
local function UI() return ns.UI end
-- The bar the dialog/handle act on (the selected one), and its config.
local function cur() return EM.entries[EM.current or 1] end
local function settings() return CT:BarCfg(EM.current or 1) end
local function curBar() local e = cur(); return e and e.bar end
function EM.SystemName(i) return NAME .. ": " .. CT:BarName(i) end

local function clampWidth(w) return max(EM.WIDTH_MIN, min(EM.WIDTH_MAX, floor(w + 0.5))) end
local function clampScale(v) return max(EM.SCALE_MIN, min(EM.SCALE_MAX, floor(v * 20 + 0.5) / 20)) end

------------------------------------------------------------------------
-- Selection overlay
------------------------------------------------------------------------
-- Plain fallback if EditModeSystemSelectionTemplate isn't available.
local function plainSelection(parent, title)
  local sel = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  if sel.SetBackdrop then
    sel:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 2 })
  end
  local label = sel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("CENTER")
  label:SetText(title or NAME)
  sel.plainLabel = label
  sel.plain = true
  return sel
end

function EM:CreateSelection(bar)
  local frame, index = bar.frame, bar.index
  local entry = { bar = bar, index = index }
  local ok, sel = pcall(CreateFrame, "Frame", nil, frame, "EditModeSystemSelectionTemplate")
  if not ok or not sel then sel = plainSelection(frame, EM.SystemName(index)) end
  entry.selection = sel
  sel.ctIndex = index
  sel:SetAllPoints(frame)
  if sel.SetFrameLevel and frame.GetFrameLevel then sel:SetFrameLevel((frame:GetFrameLevel() or 1) + 20) end
  -- 11.2+ templates read the label from system:GetSystemName(); older ones have a Label.
  sel.system = { GetSystemName = function() return EM.SystemName(entry.index) end }
  if type(sel.Label) == "table" and sel.Label.SetText then pcall(sel.Label.SetText, sel.Label, EM.SystemName(index)) end
  sel:EnableMouse(true)
  sel:RegisterForDrag("LeftButton")
  -- Thin local handlers instead of Blizzard's EditModeSystemMixin methods.
  sel:SetScript("OnMouseDown", function() EM:Select(entry.index) end)
  sel:SetScript("OnDragStart", function() EM:StartMove(entry.index) end)
  sel:SetScript("OnDragStop", function() EM:StopMove() end)
  sel:SetScript("OnEnter", function(s)
    GameTooltip:SetOwner(s, "ANCHOR_BOTTOM")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(EM.SystemName(entry.index), 0.2, 1, 0.6)
    GameTooltip:AddLine("Drag to move. Click for width and scale. Drag the right edge to change width, the bottom edge to change list rows.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  sel:SetScript("OnLeave", function() GameTooltip:Hide() end)
  sel:Hide()

  -- Right-edge width handle (Edit Mode only).
  local h = CreateFrame("Frame", nil, sel)
  h:SetPoint("TOPRIGHT", sel, "TOPRIGHT", 3, 3)
  h:SetPoint("BOTTOMRIGHT", sel, "BOTTOMRIGHT", 3, -3)
  h:SetWidth(8)
  h:EnableMouse(true)
  local tex = h:CreateTexture(nil, "OVERLAY")
  tex:SetAllPoints()
  if tex.SetColorTexture then tex:SetColorTexture(1, 0.82, 0, 0.6) end
  h.tex = tex
  h:SetScript("OnMouseDown", function() EM:StartResize(entry.index) end)
  h:SetScript("OnMouseUp", function() EM:StopResize() end)
  h:SetScript("OnEnter", function(s)
    GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("Drag to change the width", 1, 1, 1)
    GameTooltip:Show()
  end)
  h:SetScript("OnLeave", function() GameTooltip:Hide() end)
  h:Hide()
  h.ctHandle = "width"
  entry.handle = h

  -- Bottom-edge height handle (list mode, Edit Mode only): changes listRows.
  local vh = CreateFrame("Frame", nil, sel)
  vh:SetPoint("BOTTOMLEFT", sel, "BOTTOMLEFT", -3, -3)
  vh:SetPoint("BOTTOMRIGHT", sel, "BOTTOMRIGHT", -8, -3) -- leave the corner to the width handle
  vh:SetHeight(8)
  vh:EnableMouse(true)
  local vtex = vh:CreateTexture(nil, "OVERLAY")
  vtex:SetAllPoints()
  if vtex.SetColorTexture then vtex:SetColorTexture(1, 0.82, 0, 0.6) end
  vh.tex = vtex
  vh.ctHandle = "height"
  vh:SetScript("OnMouseDown", function() EM:StartHeightResize(entry.index) end)
  vh:SetScript("OnMouseUp", function() EM:StopHeightResize() end)
  vh:SetScript("OnEnter", function(s)
    GameTooltip:SetOwner(s, "ANCHOR_BOTTOM")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("Drag to change how many list rows are shown", 1, 1, 1)
    GameTooltip:Show()
  end)
  vh:SetScript("OnLeave", function() GameTooltip:Hide() end)
  vh:Hide()
  entry.heightHandle = vh

  self.entries[index] = entry
  if index == 1 then self.selection, self.handle = sel, h end -- 2.1 names (bar 1)
  return sel
end

local function showHighlighted(sel)
  sel.isSelected = false
  if not sel.plain and sel.ShowHighlighted and pcall(sel.ShowHighlighted, sel) then sel:Show(); return end
  if sel.SetBackdropColor then sel:SetBackdropColor(0.1, 0.45, 1, 0.25); sel:SetBackdropBorderColor(0.3, 0.6, 1, 0.9) end
  sel:Show()
end

local function showSelected(sel)
  sel.isSelected = true
  if not sel.plain and sel.ShowSelected and pcall(sel.ShowSelected, sel, true) then sel:Show(); return end
  if sel.SetBackdropColor then sel:SetBackdropColor(1, 0.82, 0, 0.25); sel:SetBackdropBorderColor(1, 0.82, 0, 1) end
  sel:Show()
end

-- Create selections for new bars; hide those of deleted bars.
local function hideHandles(e)
  if e.handle then e.handle:Hide() end
  if e.heightHandle then e.heightHandle:Hide() end
end

local function showHandles(e, i)
  if e.handle then e.handle:Show() end
  local bar = UI() and UI().bars and UI().bars[i]
  local list = bar and bar.IsList and bar:IsList()
  if e.heightHandle then
    if list then e.heightHandle:Show() else e.heightHandle:Hide() end
  end
end

function EM:SyncBars(bars)
  if not self.supported then return end
  for i, bar in ipairs(bars) do
    local e = self.entries[i]
    if not e and bar.active then pcall(self.CreateSelection, self, bar); e = self.entries[i] end
    if e then
      e.active = bar.active
      if type(e.selection.Label) == "table" and e.selection.Label.SetText then pcall(e.selection.Label.SetText, e.selection.Label, EM.SystemName(i)) end
      if e.selection.plainLabel then e.selection.plainLabel:SetText(EM.SystemName(i)) end
      if not bar.active then
        e.selection:Hide(); hideHandles(e)
        if self.current == i then self:Deselect() end
      elseif self.editing and not e.selection.isSelected then
        showHighlighted(e.selection)
      end
    end
  end
end

function EM:Rename(i)
  local e = self.entries[i]
  if not e then return end
  if type(e.selection.Label) == "table" and e.selection.Label.SetText then pcall(e.selection.Label.SetText, e.selection.Label, EM.SystemName(i)) end
  if e.selection.plainLabel then e.selection.plainLabel:SetText(EM.SystemName(i)) end
  if self.editing then
    if e.selection.isSelected then showSelected(e.selection) else showHighlighted(e.selection) end
  end
  self:UpdateDialog()
end

------------------------------------------------------------------------

------------------------------------------------------------------------
-- Enter / leave Edit Mode
------------------------------------------------------------------------
function EM:Enter()
  if not next(self.entries) then return end
  self.editing = true
  for _, e in pairs(self.entries) do
    if e.active ~= false then showHighlighted(e.selection) end
    hideHandles(e)
  end
  if UI() then
    for _, b in ipairs(UI().bars) do b.hover = false end
    UI():HideHoverPanel()
  end
  CT:Refresh() -- shows the bars even if they're hidden, so they can be placed
end

function EM:Exit()
  self:StopMove(); self:StopResize(); self:StopHeightResize()
  self.editing = false
  for _, e in pairs(self.entries) do
    e.selection:Hide(); e.selection.isSelected = false
    hideHandles(e)
  end
  self.current = nil
  if self.dialog then self.dialog:Hide() end
  CT:Refresh() -- honours each ticker's shown setting again
end

-- A bar was clicked in Edit Mode.
function EM:Select(i)
  i = i or 1
  if not self.editing or inCombat() then return end
  -- Tell other LibEditMode-style addons to drop their selection first.
  if EventRegistry and EventRegistry.TriggerEvent then
    self.selfTrigger = true
    pcall(EventRegistry.TriggerEvent, EventRegistry, "EditModeExternal.hideDialog")
    self.selfTrigger = false
  end
  if EditModeManagerFrame and EditModeManagerFrame.ClearSelectedSystem then
    pcall(EditModeManagerFrame.ClearSelectedSystem, EditModeManagerFrame)
  end
  for k, e in pairs(self.entries) do
    if k ~= i and e.selection.isSelected then showHighlighted(e.selection); hideHandles(e) end
  end
  self.current = i
  CT:SetTargetBar(i)
  local e = self.entries[i]
  showSelected(e.selection)
  showHandles(e, i)
  self:ShowDialog()
end

-- Something else got selected: go back to the blue "highlighted" state.
function EM:Deselect()
  self:StopMove(); self:StopResize(); self:StopHeightResize()
  for _, e in pairs(self.entries) do
    if self.editing and e.active ~= false then showHighlighted(e.selection) else e.selection:Hide() end
    hideHandles(e)
  end
  self.current = nil
  if self.dialog then self.dialog:Hide() end
end

------------------------------------------------------------------------
-- Move and resize (saved to the same settings as the slash commands)
------------------------------------------------------------------------
function EM:StartMove(i)
  i = i or 1
  if not self.editing or inCombat() then return end
  if self.current ~= i then self:Select(i) end
  local bar = curBar()
  bar.frame:SetMovable(true)
  bar.moving = true
  self.moving = true
  bar.frame:StartMoving()
end

function EM:StopMove()
  if not self.moving then return end
  self.moving = false
  local bar = curBar()
  bar.frame:StopMovingOrSizing()
  bar.moving = false
  bar:SavePosition()
  self:UpdateDialog()
end

function EM:StartResize(i)
  if not self.editing or inCombat() then return end
  if i and self.current ~= i then self:Select(i) end
  local bar = curBar()
  local f = bar.frame
  local left, top = f:GetLeft(), f:GetTop()
  if not left or not top then return end
  -- Pin the left edge so the bar grows to the right under the cursor.
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
  settings().point = { "TOPLEFT", "BOTTOMLEFT", floor(left + 0.5), floor(top + 0.5) }
  self.resizeLeft = left
  self.resizing = true
  bar.moving = true
  cur().handle:SetScript("OnUpdate", function() EM:ResizeStep() end)
end

function EM:ResizeStep()
  if not self.resizing then return end
  if inCombat() then self:StopResize(); return end
  local cx = GetCursorPosition()
  local f = curBar().frame
  local scale = f:GetEffectiveScale() or 1
  if not cx or scale <= 0 then return end
  local w = clampWidth(cx / scale - self.resizeLeft)
  local key = CT.WidthKey(settings())
  if w ~= settings()[key] then
    settings()[key] = w
    f:SetWidth(w)
    self:UpdateDialog()
  end
end

function EM:StopResize()
  if not self.resizing then return end
  self:ResizeStep()
  self.resizing = false
  local e = cur()
  if e then e.handle:SetScript("OnUpdate", nil); e.bar.moving = false end
  CT:Refresh()
end

local function clampRows(n)
  n = floor((n or 8) + 0.5)
  if n < 3 then return 3 end
  if n > 30 then return 30 end
  return n
end

function EM:StartHeightResize(i)
  if not self.editing or inCombat() then return end
  if i and self.current ~= i then self:Select(i) end
  local bar = curBar()
  if not (bar and bar.IsList and bar:IsList()) then return end
  local f = bar.frame
  local left, top = f:GetLeft(), f:GetTop()
  if not left or not top then return end
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
  settings().point = { "TOPLEFT", "BOTTOMLEFT", floor(left + 0.5), floor(top + 0.5) }
  self.resizeTop = top
  self.resizingH = true
  bar.moving = true
  cur().heightHandle:SetScript("OnUpdate", function() EM:HeightResizeStep() end)
end

function EM:HeightResizeStep()
  if not self.resizingH then return end
  if inCombat() then self:StopHeightResize(); return end
  local _, cy = GetCursorPosition()
  local bar = curBar()
  local f = bar.frame
  local scale = f:GetEffectiveScale() or 1
  if not cy or scale <= 0 or not self.resizeTop then return end
  local ui = ns.UI
  local headH = (ui and ui.HEAD_H) or 16
  local rowH = (ui and ui.ROW_H) or 20
  local h = self.resizeTop - cy / scale
  local rows = clampRows((h - headH - 3) / rowH)
  if rows ~= (settings().listRows or 8) then
    settings().listRows = rows
    if bar.LayoutList then bar:LayoutList() else f:SetHeight(headH + rows * rowH + 3) end
    self:UpdateDialog()
  end
end

function EM:StopHeightResize()
  if not self.resizingH then return end
  self:HeightResizeStep()
  self.resizingH = false
  local e = cur()
  if e then
    if e.heightHandle then e.heightHandle:SetScript("OnUpdate", nil) end
    e.bar.moving = false
  end
  CT:Refresh()
end

function EM:SetWidth(w)
  settings()[CT.WidthKey(settings())] = clampWidth(w)
  CT:Refresh()
end

function EM:SetScale(v)
  settings().scale = clampScale(v)
  CT:Refresh()
end

------------------------------------------------------------------------
-- Settings dialog (plain frames; not Blizzard's settings dialog)
------------------------------------------------------------------------
local function makeSlider(parent, label, lo, hi, step, y, onChange, fmt)
  local text = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  text:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
  text:SetText(label)
  local value = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  value:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, y)
  local sl = CreateFrame("Slider", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  sl:SetOrientation("HORIZONTAL")
  sl:SetSize(232, 16)
  sl:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y - 16)
  if sl.SetBackdrop then
    sl:SetBackdrop({ bgFile = "Interface\\Buttons\\UI-SliderBar-Background", edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
      tile = true, tileSize = 8, edgeSize = 8, insets = { left = 3, right = 3, top = 6, bottom = 6 } })
  end
  sl:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
  sl:SetMinMaxValues(lo, hi)
  sl:SetValueStep(step)
  if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end
  sl:EnableMouseWheel(true)
  sl.valueText, sl.fmt = value, fmt
  sl:SetScript("OnValueChanged", function(s, v, userInput)
    v = floor(v / step + 0.5) * step
    s.valueText:SetText(format(s.fmt, v))
    if userInput and not EM.updatingDialog then onChange(v) end
  end)
  sl:SetScript("OnMouseWheel", function(s, delta)
    local v = (s:GetValue() or lo) + delta * step
    v = max(lo, min(hi, v))
    s:SetValue(v)
    onChange(v)
  end)
  return sl
end

local function makeCheck(parent, label, y, onClick)
  local ok, cb = pcall(CreateFrame, "CheckButton", nil, parent, "UICheckButtonTemplate")
  if not ok or not cb then cb = CreateFrame("CheckButton", nil, parent) end
  cb:SetSize(22, 22)
  cb:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, y)
  local t = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  t:SetPoint("LEFT", cb, "RIGHT", 2, 0)
  t:SetText(label)
  cb.label = t
  cb:SetScript("OnClick", function(b) onClick(b:GetChecked() and true or false) end)
  return cb
end

function EM:CreateDialog()
  local d = CreateFrame("Frame", "CommodityTickerEditModeDialog", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  d:SetSize(260, 196)
  d:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
  d:SetFrameStrata("DIALOG")
  d:SetClampedToScreen(true)
  d:SetMovable(true)
  d:EnableMouse(true)
  d:RegisterForDrag("LeftButton")
  d:SetScript("OnDragStart", function(s) s:StartMoving() end)
  d:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
  if d.SetBackdrop then
    d:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
  end
  local title = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOP", d, "TOP", 0, -12)
  title:SetText(NAME)
  d.title = title
  local close = CreateFrame("Button", nil, d, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", d, "TOPRIGHT", -2, -2)
  close:SetScript("OnClick", function() EM:Deselect() end)

  d.widthSlider = makeSlider(d, "Width", EM.WIDTH_MIN, EM.WIDTH_MAX, 10, -36, function(v) EM:SetWidth(v) end, "%d px")
  d.scaleSlider = makeSlider(d, "Scale", EM.SCALE_MIN, EM.SCALE_MAX, 0.05, -78, function(v) EM:SetScale(v) end, "%.2f")
  d.showCheck = makeCheck(d, "Show the ticker outside Edit Mode", -118, function(v)
    settings().shown = v
    CT:Refresh()
  end)
  d.dragCheck = makeCheck(d, "Allow dragging outside Edit Mode", -140, function(v)
    settings().locked = not v
  end)
  local reset = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
  reset:SetSize(110, 20)
  reset:SetText("Reset position")
  reset:SetPoint("BOTTOMLEFT", d, "BOTTOMLEFT", 12, 12)
  reset:SetScript("OnClick", function()
    settings().point = CT.DefaultBarPoint(EM.current or 1)
    CT:Refresh()
  end)
  d.reset = reset
  local more = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
  more:SetSize(110, 20)
  more:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -12, 12)
  more:SetText("Lists & more...")
  more:SetScript("OnClick", function() if ns.Settings then ns.Settings:Open(EM.current or 1) end end)
  d.more = more
  d:Hide()
  self.dialog = d
  return d
end

function EM:ShowDialog()
  if not self.dialog then self:CreateDialog() end
  self.dialog:Show()
  self:UpdateDialog()
end

function EM:UpdateDialog()
  local d = self.dialog
  if not d or not d:IsShown() then return end
  local s = settings()
  if not s then d:Hide(); return end
  d.title:SetText(EM.SystemName(EM.current or 1))
  self.updatingDialog = true
  d.widthSlider:SetValue(CT:EffectiveWidth(EM.current or 1))
  d.scaleSlider:SetValue(s.scale)
  d.showCheck:SetChecked(s.shown and true or false)
  d.dragCheck:SetChecked(not s.locked)
  self.updatingDialog = false
  if self.current and self.entries[self.current] then
    showHandles(self.entries[self.current], self.current)
  end
end

------------------------------------------------------------------------
-- Hooks
------------------------------------------------------------------------
function EM:Hook()
  if self.hooked then return true end
  local mgr = _G.EditModeManagerFrame
  if not mgr or not mgr.HookScript then return false end
  self.hooked = true
  mgr:HookScript("OnShow", function() EM:Enter() end) -- Quick Keybind mode also toggles this
  mgr:HookScript("OnHide", function() EM:Exit() end)
  if mgr.SelectSystem and hooksecurefunc then
    hooksecurefunc(mgr, "SelectSystem", function() EM:Deselect() end)
  end
  if EventRegistry then
    if EventRegistry.RegisterCallback then
      pcall(EventRegistry.RegisterCallback, EventRegistry, "EditModeExternal.hideDialog", function()
        if not EM.selfTrigger then EM:Deselect() end
      end, EM)
    end
    if EventRegistry.RegisterFrameEventAndCallback then
      -- Switching layouts moves Blizzard frames, not ours; just re-apply our own saved spot.
      pcall(EventRegistry.RegisterFrameEventAndCallback, EventRegistry, "EDIT_MODE_LAYOUTS_UPDATED", function()
        if UI() and UI().ready then UI():ApplyLayout() end
      end, EM)
    end
  end
  return true
end

-- Called once from UI:SyncBars (and again whenever tickers are added or removed).
function EM:Init()
  if self.initDone then return self.supported end
  self.initDone = true
  local ok, err = pcall(function()
    if not _G.EditModeManagerFrame and C_AddOns and C_AddOns.LoadAddOn then
      pcall(C_AddOns.LoadAddOn, "Blizzard_EditMode")
    end
    if not self:Hook() then return end
    self.supported = true
  end)
  if not ok then
    self.supported = false
    self.error = err
  end
  -- Stop any move/resize if combat starts mid-drag.
  local ev = CreateFrame("Frame")
  ev:RegisterEvent("PLAYER_REGEN_DISABLED")
  ev:RegisterEvent("ADDON_LOADED")
  ev:SetScript("OnEvent", function(_, event, name)
    if event == "PLAYER_REGEN_DISABLED" then
      EM:StopMove(); EM:StopResize()
    elseif event == "ADDON_LOADED" and name == "Blizzard_EditMode" and not EM.supported then
      pcall(function()
        if EM:Hook() then
          EM.supported = true
          if UI() then EM:SyncBars(UI().bars) end
        end
      end)
    end
  end)
  return self.supported
end

local baseSync = EM.SyncBars
function EM:SyncBars(bars)
  self:Init()
  baseSync(self, bars)
  if self.supported and _G.EditModeManagerFrame and _G.EditModeManagerFrame.IsShown
    and _G.EditModeManagerFrame:IsShown() and not self.editing then
    self:Enter()
  end
end

function EM:Status()
  if self.supported then
    return "Edit Mode: supported - press Esc, choose Edit Mode, then click a CommodityTicker bar to move it or change its width and scale (each ticker has its own outline)."
  end
  return "Edit Mode: not available on this client - use /commodity unlock (drag to move), /commodity width <px> and /commodity scale <0.5-2>."
end
