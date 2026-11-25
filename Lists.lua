-- CommodityTicker lists and tickers:
--  * primary-profession detection (modern GetProfessions/GetProfessionInfo, falling back to
--    Classic-style GetNumSkillLines/GetSkillLineInfo) and the profession commodity list
--    (2.3: current-tier herbs/ore/leather/cloth/enchanting mats, from Professions.lua + PROF_PICKS);
--  * up to CT.MAX_BARS ticker bars, each with its own list sources, custom items, removed items
--    and layout. Bar 1 keeps its settings at the top level of CommodityTickerDB.settings so
--    2.1.0 data, Edit Mode and the slash commands keep working unchanged.
local _, ns = ...
local CT = ns.CT
local format, max, min, floor = string.format, math.max, math.min, math.floor

CT.MAX_BARS = 4
CT.BAR_GAP = 26 -- default vertical spacing between bars (bar height 20 + 6)

local PRESETS = { "now", "later" }
CT.SOURCE_LABELS = {
  profession = "Profession picks (current-tier herbs/ore/leather/cloth/enchanting mats)",
  now = "Level-38 preset (old 'now' list)",
  later = "Level-50+ preset (old 'later' list)",
}

------------------------------------------------------------------------
-- Bars (tickers)
------------------------------------------------------------------------
local BAR_DEFAULTS = { shown = true, locked = false, mode = "scroll", speed = 10, width = 760, scale = 1, listRows = 8, listWidth = 0, tickerGraph = true }

-- List-mode columns the user can hide to make a ticker more compact. Name always stays.
CT.LIST_COL_KEYS = { "icon", "spark", "price", "trend", "bag", "bank", "value" }
CT.LIST_COL_LABELS = {
  icon = "Icon", spark = "Graph", price = "Price", trend = "Trend",
  bag = "Bag", bank = "Bank", value = "Value",
}
CT.LIST_COL_ALIASES = { graph = "spark", sparkline = "spark", mark = "trend", pct = "trend", bags = "bag" }

function CT.EnsureListCols(c)
  if not c then return nil end
  c.listCols = c.listCols or {}
  for _, k in ipairs(CT.LIST_COL_KEYS) do
    if c.listCols[k] == nil then c.listCols[k] = true end
  end
  return c.listCols
end

function CT.ListCols(c)
  return CT.EnsureListCols(c) or { icon = true, spark = true, price = true, trend = true, bag = true, bank = true, value = true }
end

-- 2.4: list mode has its own width (0 = packed/automatic); tape modes use 'width'.
function CT.WidthKey(c) return (c and c.mode == "list") and "listWidth" or "width" end
-- Width a ticker is actually drawn at (list: never narrower than its packed width).
function CT:EffectiveWidth(i)
  local c = self:BarCfg(i)
  if c.mode ~= "list" then return c.width end
  local b = ns.UI and ns.UI.bars and ns.UI.bars[i]
  return max(c.listWidth or 0, (b and b.listNatural) or 0)
end

function CT:NumBars() return 1 + #(self.db.settings.bars or {}) end

-- Bar config table: bar 1 is settings itself (2.1.0 fields), others live in settings.bars.
function CT:BarCfg(i)
  local s = self.db.settings
  if not i or i == 1 then return s end
  return s.bars[i - 1]
end

-- The bar's own custom items ([id] = name). Bar 1 keeps 2.x's settings.extra.
function CT:BarItems(i)
  local c = self:BarCfg(i)
  if not c then return {} end
  if not i or i == 1 then return c.extra end
  c.items = c.items or {}
  return c.items
end

function CT:BarName(i)
  local c = self:BarCfg(i)
  return (c and (i == 1 and c.barName or c.name)) or (i == 1 and "Main" or ("Ticker " .. i))
end

function CT.DefaultBarPoint(i)
  local p = CT.DEFAULT_POINT
  return { p[1], p[2], p[3], p[4] - (i - 1) * CT.BAR_GAP }
end

function CT:EnsureBar(c, i)
  for k, v in pairs(BAR_DEFAULTS) do if c[k] == nil then c[k] = v end end
  c.sources = c.sources or { profession = true }
  c.removed = c.removed or {}
  c.items = c.items or {}
  c.point = c.point or CT.DefaultBarPoint(i)
  c.name = c.name or ("Ticker " .. i)
  CT.EnsureListCols(c)
  return c
end

-- Ticker that slash commands and the lookup window act on (the one selected in the GUI).
function CT:TargetBar()
  local t = self.targetBar or 1
  if t > self:NumBars() then t = 1 end
  return t
end

function CT:SetTargetBar(i)
  if i and i >= 1 and i <= self:NumBars() then self.targetBar = i end
  return self:TargetBar()
end

function CT:FindBar(text)
  text = (text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  local n = tonumber(text)
  if n then return (n >= 1 and n <= self:NumBars()) and n or nil end
  for i = 1, self:NumBars() do if self:BarName(i):lower() == text then return i end end
  for i = 1, self:NumBars() do if self:BarName(i):lower():find(text, 1, true) then return i end end
end

function CT:CreateBar(name, sources)
  local s = self.db.settings
  if self:NumBars() >= CT.MAX_BARS then
    return nil, format("you already have %d tickers (the most CommodityTicker allows).", CT.MAX_BARS)
  end
  local i = self:NumBars() + 1
  local c = self:EnsureBar({}, i)
  c.name = (name and name ~= "") and name or ("Ticker " .. i)
  c.sources = sources or { profession = false, now = false, later = false }
  s.bars[#s.bars + 1] = c
  self.targetBar = i
  if ns.UI and ns.UI.ready then ns.UI:SyncBars() end
  self:Refresh()
  return i
end

function CT:DeleteBar(i)
  if not i or i == 1 then return false, "the main ticker can't be deleted - hide it instead." end
  if i > self:NumBars() then return false, "no such ticker." end
  table.remove(self.db.settings.bars, i - 1)
  if (self.targetBar or 1) >= i then self.targetBar = max(1, (self.targetBar or 1) - 1) end
  if ns.UI and ns.UI.ready then ns.UI:SyncBars() end
  self:Refresh()
  return true
end

function CT:RenameBar(i, name)
  name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then return false end
  name = name:sub(1, 24)
  local c = self:BarCfg(i)
  if not c then return false end
  if i == 1 then c.barName = name else c.name = name end
  if ns.EditMode and ns.EditMode.Rename then ns.EditMode:Rename(i) end
  self:Refresh()
  return true
end

------------------------------------------------------------------------
-- Professions
------------------------------------------------------------------------
local BY_NAME = {}
for line, p in pairs(ns.PROF_DATA and ns.PROF_DATA.professions or {}) do BY_NAME[p.name:lower()] = line end

-- Returns { {line=, name=, skill=, max=}, ... } for the (up to two) primary professions
-- that Professions.lua has data for, plus which API answered.
function CT:ReadProfessions()
  local found, seen, api = {}, {}, nil
  local data = ns.PROF_DATA and ns.PROF_DATA.professions or {}
  local function add(line, name, rank, maxRank)
    if line and data[line] and not seen[line] and tonumber(rank) then
      seen[line] = true
      found[#found + 1] = { line = line, name = data[line].name, skill = tonumber(rank), max = tonumber(maxRank) }
    end
  end
  if type(GetProfessions) == "function" and type(GetProfessionInfo) == "function" then
    local ok, p1, p2 = pcall(GetProfessions)
    if ok then
      api = "GetProfessions"
      for _, idx in ipairs({ p1 or false, p2 or false }) do
        if idx then
          local ok2, name, _, rank, maxRank, _, _, skillLine = pcall(GetProfessionInfo, idx)
          if ok2 then add(data[skillLine] and skillLine or BY_NAME[(name or ""):lower()], name, rank, maxRank) end
        end
      end
    end
  end
  if #found == 0 and type(GetNumSkillLines) == "function" and type(GetSkillLineInfo) == "function" then
    local ok, n = pcall(GetNumSkillLines)
    if ok and n then
      api = api and (api .. "+GetSkillLineInfo") or "GetSkillLineInfo"
      for i = 1, n do
        local ok2, name, isHeader, _, rank, _, _, maxRank = pcall(GetSkillLineInfo, i)
        if ok2 and name and not isHeader then add(BY_NAME[name:lower()], name, rank, maxRank) end
      end
    end
  end
  table.sort(found, function(a, b) return a.name < b.name end)
  return found, api
end

-- Everything the detected professions can gather or use at their current skill (2.2 behaviour).
-- Only offered in the settings window ("more from your professions"); never auto-added.
function CT:EligibleItems()
  local out = {}
  local data = ns.PROF_DATA and ns.PROF_DATA.professions or {}
  for _, p in ipairs(self.profs or {}) do
    local d = data[p.line]
    for id, need in pairs(d and d.items or {}) do
      if need <= p.skill and (not out[id] or need > out[id].skill) then
        out[id] = { skill = need, prof = d.name, kind = d.kind }
      end
    end
  end
  return out
end

-- 2.3.0 default ("profession picks"): current-tier trade commodities only.
--  * Only the classes in ns.PROF_PICKS, and only for a primary profession the character has:
--    Herbalism herbs, Mining ore/stone/bars/gems, Skinning raw leather/hides/scales,
--    Enchanting dusts/essences/shards, Tailoring raw cloth. Alchemy, Blacksmithing,
--    Leatherworking and Engineering reagents are never auto-added.
--  * Current tier = required skill in (skill - TIER_WINDOW, skill]. If nothing falls in that
--    window, the highest unlocked tier is used instead: (top - TIER_WINDOW, top], where top is the
--    highest required skill at or below yours (at skill 1 that's the starting tier).
-- [id] = { skill =, prof =, kind =, class = }
CT.TIER_WINDOW = 50
function CT:ProfessionItems()
  local out = {}
  local data = ns.PROF_DATA and ns.PROF_DATA.professions or {}
  local picks = ns.PROF_PICKS or {}
  for _, p in ipairs(self.profs or {}) do
    local d, classes = data[p.line], picks[p.line]
    if d and classes then
      local skill = max(1, p.skill or 0)
      local cand, top = {}, nil
      for id, need in pairs(d.items) do
        if classes[id] and need <= skill then
          cand[#cand + 1] = { id = id, need = need }
          if not top or need > top then top = need end
        end
      end
      if top then
        local hi = skill
        if top <= skill - CT.TIER_WINDOW then hi = top end -- window empty: slide down to the highest unlocked tier
        for _, c in ipairs(cand) do
          if c.need > hi - CT.TIER_WINDOW and c.need <= hi and (not out[c.id] or c.need > out[c.id].skill) then
            out[c.id] = { skill = c.need, prof = d.name, kind = d.kind, class = classes[c.id] }
          end
        end
      end
    end
  end
  return out
end

-- Items from the detected professions whose skill isn't confirmed for Forever yet. Never auto-added.
function CT:UnverifiedItems()
  local out = {}
  local data = ns.PROF_DATA and ns.PROF_DATA.professions or {}
  local elig = self:ProfessionItems()
  for _, p in ipairs(self.profs or {}) do
    for _, id in ipairs(data[p.line] and data[p.line].unverified or {}) do
      if not elig[id] then out[id] = data[p.line].name end
    end
  end
  return out
end

function CT:ProfessionSummary()
  if not self.profs or #self.profs == 0 then
    return self.profAPI and "no primary gathering/crafting profession found" or "profession info not available on this client"
  end
  local t = {}
  for _, p in ipairs(self.profs) do t[#t + 1] = format("%s %d", p.name, p.skill) end
  return table.concat(t, ", ")
end

-- Re-read professions; announce newly eligible items once.
function CT:UpdateProfessions(quiet)
  local before = self:ProfessionItems()
  self.profs, self.profAPI = self:ReadProfessions()
  local after = self:ProfessionItems()
  local new = {}
  if self.profsReady then
    for id in pairs(after) do if not before[id] then new[#new + 1] = self:ItemName(id) end end
  end
  self.profsReady = true
  if #new > 0 and not quiet then
    table.sort(new)
    CT.Print(format("skill up: %d new current-tier commodit%s on your ticker: %s.", #new, #new == 1 and "y" or "ies",
      table.concat(new, ", ", 1, min(#new, 6)) .. (#new > 6 and ", ..." or "")))
  end
  self:Refresh()
  return #new
end

------------------------------------------------------------------------
-- Watch lists
------------------------------------------------------------------------
function CT:DefaultEntry(id)
  for _, listName in ipairs(PRESETS) do
    for _, e in ipairs(ns.LISTS[listName]) do
      if e.id == id then return e, listName end
    end
  end
end

function CT:ProfessionDataName(id)
  return ns.PROF_DATA and ns.PROF_DATA.names and ns.PROF_DATA.names[id]
end

-- Is this item in the sourced profession data at all (any profession, any skill)?
function CT:InProfessionData(id)
  for _, p in pairs(ns.PROF_DATA and ns.PROF_DATA.professions or {}) do
    if p.items[id] then return true end
    for _, u in ipairs(p.unverified) do if u == id then return true end end
  end
  return false
end

-- Entries for one bar: tracked items first (bar 1 only), then profession picks, presets, custom.
function CT:BarEntries(i, profItems)
  local c = self:BarCfg(i)
  if not c then return {}, {} end
  local s = self.db.settings
  local out, seen = {}, {}
  local function push(id, name, list, extra)
    if seen[id] then return end
    seen[id] = true
    local e = { id = id, name = name, list = list, bar = i }
    if extra then for k, v in pairs(extra) do e[k] = v end end
    out[#out + 1] = e
  end
  if i == 1 then
    local tr = {}
    local gone = c.removed or {}
    for id, name in pairs(s.tracked) do
      if not gone[id] then tr[#tr + 1] = { id = id, name = name } end -- 2.8.8: removing an item always wins
    end
    table.sort(tr, function(a, b) return tostring(a.name) < tostring(b.name) end)
    for _, e in ipairs(tr) do push(e.id, e.name, "tracked", { tracked = true }) end
  end
  local src = c.sources or {}
  local removed = c.removed or {}
  if src.profession then
    profItems = profItems or self:ProfessionItems()
    local p = {}
    for id, info in pairs(profItems) do
      if not removed[id] then p[#p + 1] = { id = id, skill = info.skill, prof = info.prof } end
    end
    -- highest skill first: what you've just unlocked is what you're farming/using now
    table.sort(p, function(a, b) if a.skill ~= b.skill then return a.skill > b.skill end return a.id < b.id end)
    for _, e in ipairs(p) do push(e.id, self:ProfessionDataName(e.id) or self:ItemName(e.id), "profession", { prof = e.prof, skill = e.skill }) end
  end
  for _, listName in ipairs(PRESETS) do
    if src[listName] then
      for _, e in ipairs(ns.LISTS[listName]) do
        if not removed[e.id] then push(e.id, e.name, listName) end
      end
    end
  end
  local items = self:BarItems(i)
  local custom = {}
  for id, name in pairs(items) do custom[#custom + 1] = { id = id, name = name } end
  table.sort(custom, function(a, b) return tostring(a.name) < tostring(b.name) end)
  for _, e in ipairs(custom) do push(e.id, e.name, "extra") end
  return out, seen
end

-- Watched(i): one bar's entries. Watched(): every visible bar's items once (for AH refreshes,
-- feed history and lookups) - each item is only ever queried once per refresh.
function CT:Watched(i)
  if i then return self:BarEntries(i) end
  local out, seen = {}, {}
  local prof = self:ProfessionItems()
  for b = 1, self:NumBars() do
    local c = self:BarCfg(b)
    if c.shown or b == 1 then
      local entries = self:BarEntries(b, prof)
      for _, e in ipairs(entries) do
        if not seen[e.id] then seen[e.id] = true; out[#out + 1] = e end
      end
    end
  end
  -- tracked items are always refreshed, even with the main bar hidden
  local gone = self.db.settings.removed or {}
  for id, name in pairs(self.db.settings.tracked) do
    if not seen[id] and not gone[id] then seen[id] = true; out[#out + 1] = { id = id, name = name, list = "tracked", tracked = true, bar = 1 } end
  end
  return out, seen
end

function CT:IsWatched(id)
  local _, seen = self:Watched()
  return seen[id]
end

function CT:IsTracked(id) return self.db.settings.tracked[id] ~= nil end

-- On the target ticker (or bar i)?
function CT:OnTicker(id, i)
  i = i or self:TargetBar()
  local _, seen = self:BarEntries(i)
  return seen[id] or false
end

-- Put a commodity on a ticker (custom items; clears a previous removal).
function CT:AddToTicker(text, i)
  i = i or self:TargetBar()
  local id, nameOrErr = self:CheckedItem(text, "add")
  if not id then CT.Print(nameOrErr); return nil end
  local c = self:BarCfg(i)
  local name = self:ItemName(id, nameOrErr)
  c.removed = c.removed or {}
  c.removed[id] = nil
  -- kept as your own item, so it stays when your skill moves past its tier
  if not (i == 1 and self:IsTracked(id)) then self:BarItems(i)[id] = name end
  CT.Print(format("watching %s on ticker \"%s\".", name, self:BarName(i)))
  self:Refresh()
  return id
end

-- Take an item off a ticker. Profession/preset items are remembered as removed until re-added.
function CT:RemoveFromTicker(text, i)
  i = i or self:TargetBar()
  local id = self:ResolveItem(text)
  if not id then CT.Print("use: /commodity remove <item>"); return end
  local c = self:BarCfg(i)
  self:BarItems(i)[id] = nil
  if i == 1 then self.db.settings.tracked[id] = nil end
  c.removed = c.removed or {}
  c.removed[id] = true
  CT.Print(format("removed %s from ticker \"%s\". (/commodity add %d brings it back)", self:ItemName(id), self:BarName(i), id))
  self:Refresh()
end

-- Tick/untick from the GUI without chat spam. on=true adds, false removes.
function CT:SetOnBar(id, i, on)
  local c = self:BarCfg(i)
  if not c then return end
  c.removed = c.removed or {}
  if on then
    local ok = self:CommodityCheck(id)
    if not ok then return false end
    c.removed[id] = nil
    if not (i == 1 and self:IsTracked(id)) then self:BarItems(i)[id] = self:ProfessionDataName(id) or self:ItemName(id) end
  else
    self:BarItems(i)[id] = nil
    if i == 1 then self.db.settings.tracked[id] = nil end -- 2.8.8: a tracked item used to stay stuck on the main ticker
    c.removed[id] = true
  end
  self:Refresh()
  return true
end

function CT:SetSource(i, key, on)
  local c = self:BarCfg(i)
  if not c then return end
  c.sources = c.sources or {}
  c.sources[key] = on and true or false
  self:Refresh()
end

-- Everything the GUI can offer for a bar. Rows: { id, name, on, group, note, unverified, removed }
-- Groups: 1 current-tier picks, 2 unverified, 3 your items, 4 more from your professions, 5 presets.
local CLASS_LABEL = { herb = "herb", ore = "ore", stone = "stone", bar = "bar", gem = "gem", leather = "leather",
  enchant = "enchanting mat", cloth = "cloth" }
function CT:Candidates(i)
  local rows, seen = {}, {}
  local _, onBar = self:BarEntries(i)
  local c = self:BarCfg(i)
  local removed = c and c.removed or {}
  local function row(id, group, note, unverified)
    if seen[id] then return end
    seen[id] = true
    rows[#rows + 1] = { id = id, name = self:ProfessionDataName(id) or self:ItemName(id), on = onBar[id] and true or false,
      group = group, note = note, unverified = unverified, removed = removed[id] or false }
  end
  local function bySkill(t)
    local p = {}
    for id, info in pairs(t) do p[#p + 1] = { id = id, info = info } end
    table.sort(p, function(a, b) if a.info.skill ~= b.info.skill then return a.info.skill > b.info.skill end return a.id < b.id end)
    return p
  end
  for _, e in ipairs(bySkill(self:ProfessionItems())) do
    row(e.id, 1, format("%s %s %d - current tier", e.info.prof, CLASS_LABEL[e.info.class] or "", e.info.skill))
  end
  local un = {}
  for id, pname in pairs(self:UnverifiedItems()) do un[#un + 1] = { id = id, prof = pname } end
  table.sort(un, function(a, b) return a.id < b.id end)
  for _, e in ipairs(un) do row(e.id, 2, e.prof .. ": skill not confirmed for Forever - not auto-added", true) end
  for id in pairs(self:BarItems(i)) do row(id, 3, "added by you") end
  for _, e in ipairs(bySkill(self:EligibleItems())) do
    row(e.id, 4, format("%s %s %d", e.info.prof, e.info.kind == "gather" and "gather" or "use", e.info.skill))
  end
  for _, listName in ipairs(PRESETS) do
    for _, e in ipairs(ns.LISTS[listName]) do row(e.id, 5, listName == "now" and "level-38 preset" or "level-50+ preset") end
  end
  return rows -- already in group order
end

------------------------------------------------------------------------
-- Settings migration for 2.2.0 (called from InitDB, before defaults are filled)
------------------------------------------------------------------------
function CT:MigrateLists(s)
  if s.sources == nil then
    local l = s.lists
    if type(l) ~= "table" or (l.now and not l.later) or (not l.now and not l.later) then
      -- fresh install, or still on the old default (level-38 list): profession picks become the default
      s.sources = { profession = true, now = false, later = false }
    else
      -- they picked 'later' or 'both' themselves: keep that choice
      s.sources = { profession = false, now = l.now and true or false, later = l.later and true or false }
    end
  end
  s.bars = s.bars or {}
  for k = #s.bars, 1, -1 do if type(s.bars[k]) ~= "table" then table.remove(s.bars, k) end end
  while #s.bars > CT.MAX_BARS - 1 do table.remove(s.bars) end
  for k, c in ipairs(s.bars) do self:EnsureBar(c, k + 1) end
  s.barName = s.barName or "Main"
  CT.EnsureListCols(s)
end

------------------------------------------------------------------------
-- Events: re-read professions at login and when skills change
------------------------------------------------------------------------
local pf = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "SKILL_LINES_CHANGED", "CHAT_MSG_SKILL", "TRADE_SKILL_LIST_UPDATE", "LEARNED_SPELL_IN_TAB" }) do
  pcall(pf.RegisterEvent, pf, e)
end
pf:SetScript("OnEvent", function(_, event)
  if not CT.db then return end
  if event == "PLAYER_LOGIN" then
    CT:UpdateProfessions(true)
    -- skill info can arrive a moment after login
    C_Timer.After(3, function() CT:UpdateProfessions(true) end)
    return
  end
  if CT.profPending then return end
  CT.profPending = true
  C_Timer.After(1, function() CT.profPending = false; CT:UpdateProfessions() end)
end)
