-- CommodityTicker core: saved data, migration from HerbTicker, commodity rules,
-- price sources, real price history, auction house refresh/lookup, slash commands.
-- Written for the WoW: Forever client (interface 16001, Mainline-style C_AuctionHouse API).
local ADDON, ns = ...

local CT = {}
ns.CT = CT
_G.CommodityTicker = CT

local floor, max, min, format, time = math.floor, math.max, math.min, string.format, time

CT.HISTORY_DAYS = 14     -- history kept per item...
CT.HISTORY_POINTS = 200  -- ...and at most this many points per item

local DEFAULTS = {
  shown = true,
  locked = false,
  auto = true,          -- refresh watch-list + tracked prices automatically while the AH is open
  interval = 5,         -- minutes between automatic AH refreshes (while the AH is open)
  mode = "scroll",      -- "scroll", "rotate" or "list" (2.4: static list with icons, sparklines, counts)
  listWidth = 0,        -- list mode width; 0 = packed to fit (automatic)
  listRows = 8,         -- list mode: rows shown before the list scrolls (3-30)
  listCols = { icon = true, spark = true, price = true, trend = true, bag = true, bank = true, value = true },
  tickerGraph = true,  -- 2.4.6: mini price graph on the scrolling / rotating ticker
  sharePrices = true,  -- 2.4.7: send our AH commodity prices to the guild (opt out with /commodity share off)
  speed = 10,           -- scroll speed, pixels per second
  rotateSecs = 4,
  width = 760,
  scale = 1,
  staleHours = 6,       -- prices older than this are drawn grey
  lists = { now = true, later = false }, -- legacy (2.1 and older); 2.2 uses sources per ticker
  extra = {},           -- [itemID] = name, added with /commodity add
  tracked = {},         -- [itemID] = name, tracked live with /commodity track
  removed = {},         -- [itemID] = true, hidden defaults
  useFeed = true,       -- read Feed.lua written by tools/update_feed.py
  trendIcons = true,    -- 2.4.5: large ^ / v / = (the game font has no triangle glyphs)
  useAuctionator = true,
  point = { "TOP", "TOP", 0, -95 }, -- below the top-centre HUD widgets, above error text and zone text
}
CT.VERSION = "2.8.7"
CT.DEFAULT_POINT = { "TOP", "TOP", 0, -95 }
CT.OLD_DEFAULT_POINT = { "TOP", "TOP", 0, -4 }  -- 2.0.0 and HerbTicker: covered top-of-screen text

local SRC_LABEL = {
  scan = "AH refresh", browse = "AH browse", search = "AH search", lookup = "AH lookup",
  feed = "Feed", auctionator = "Auctionator", tsm = "TSM", guild = "Guild",
}
CT.COMMODITY_HINT = "this ticker is for commodities only (herbs, ore, bars, stone, leather, cloth, reagents and other trade goods)"

local function copyDefaults(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      copyDefaults(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
end

local function deepCopy(v, seen)
  if type(v) ~= "table" then return v end
  seen = seen or {}
  if seen[v] then return seen[v] end
  local out = {}
  seen[v] = out
  for k, x in pairs(v) do out[deepCopy(k, seen)] = deepCopy(x, seen) end
  return out
end

function CT.Print(msg)
  print("|cff33ff99CommodityTicker|r: " .. tostring(msg))
end

------------------------------------------------------------------------
-- Formatting
------------------------------------------------------------------------
-- Blizzard coin icons, shown after each number (like the bag money display).
CT.COIN_GOLD = "Interface\\MoneyFrame\\UI-GoldIcon"
CT.COIN_SILVER = "Interface\\MoneyFrame\\UI-SilverIcon"
CT.COIN_COPPER = "Interface\\MoneyFrame\\UI-CopperIcon"
CT.COIN_SIZE = 12
CT.COIN_GOLD_TAG = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:1:0|t"
CT.COIN_SILVER_TAG = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:1:0|t"
CT.COIN_COPPER_TAG = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:1:0|t"

function CT.MoneyAmounts(copper)
  if copper == nil then return nil end
  copper = floor(copper + 0.5)
  if copper < 0 then copper = 0 end
  return floor(copper / 10000), floor((copper % 10000) / 100), copper % 100
end

-- Running text with coin icons, e.g. "63[gold] 82[silver] 55[copper]".
-- Zero denominations are omitted (never 00g/00s/00c); a true zero is 0[copper].
function CT.Money(copper)
  if copper == nil then return "|cff808080--|r" end
  local g, s, c = CT.MoneyAmounts(copper)
  local parts = {}
  if g > 0 then parts[#parts + 1] = "|cffffd700" .. g .. "|r" .. CT.COIN_GOLD_TAG end
  if s > 0 then parts[#parts + 1] = "|cffc7c7cf" .. s .. "|r" .. CT.COIN_SILVER_TAG end
  if c > 0 or #parts == 0 then parts[#parts + 1] = "|cffeda55f" .. c .. "|r" .. CT.COIN_COPPER_TAG end
  return table.concat(parts, " ")
end

-- Letter form for chat, tests and hidden combined strings: "63g 82s 55c".
function CT.PlainMoney(copper)
  if copper == nil then return "--" end
  local g, s, c = CT.MoneyAmounts(copper)
  local parts = {}
  if g > 0 then parts[#parts + 1] = g .. "g" end
  if s > 0 then parts[#parts + 1] = s .. "s" end
  if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
  return table.concat(parts, " ")
end

-- Coloured numbers only (no letters, no icons) for aligned list columns.
function CT.MoneyParts(copper)
  if copper == nil then return "", "", "" end
  local g, s, c = CT.MoneyAmounts(copper)
  local gT = g > 0 and ("|cffffd700" .. g .. "|r") or ""
  local sT = s > 0 and ("|cffc7c7cf" .. s .. "|r") or ""
  local cT = (c > 0 or (g == 0 and s == 0)) and ("|cffeda55f" .. c .. "|r") or ""
  return gT, sT, cT
end

function CT.JoinMoney(g, s, c)
  local parts = {}
  if g and g ~= "" then parts[#parts + 1] = g end
  if s and s ~= "" then parts[#parts + 1] = s end
  if c and c ~= "" then parts[#parts + 1] = c end
  return table.concat(parts, " ")
end

function CT.Age(t)
  if not t or t <= 0 then return "?" end
  local d = time() - t
  if d < 90 then return "now" end
  if d < 3600 then return floor(d / 60) .. "m" end
  if d < 86400 * 2 then return floor(d / 3600) .. "h" end
  return floor(d / 86400) .. "d"
end

function CT.Ago(t)
  local a = CT.Age(t)
  if a == "now" then return "just now" end
  if a == "?" then return "unknown age" end
  return a .. " ago"
end

function CT.Change(cur, prev)
  if not cur or not prev or prev <= 0 or cur == prev then return nil end
  return (cur - prev) / prev * 100
end

function CT.ChangeText(pct)
  if not pct then return "" end
  if pct > 0 then return format("|cff20ff20+%d%%|r", floor(pct + 0.5)) end
  return format("|cffff4040%d%%|r", floor(pct - 0.5))
end

-- Trend (2.4.7): colour-coded percent only. No ^ / v arrows and no - / = signs
-- (those crowded the list and tape). Up keeps a leading +; down is just the
-- red percent; unchanged is yellow 0%. No earlier price: blank.
CT.TREND_UP_MARK = ""
CT.TREND_DOWN_MARK = ""
CT.TREND_SAME_MARK = ""
CT.TREND_NONE_MARK = ""
CT.TREND_MARK_SIZE = 16

local function pctText(pct)
  local a = math.abs(pct)
  if a < 0.5 then return "<1%" end
  return format("%d%%", floor(a + 0.5))
end

-- Kept for callers; marks are no longer drawn.
function CT.TrendMark(tr, size)
  return CT.TREND_NONE_MARK
end

-- Just the percent ("+20%", "20%", "0%"), or "" when there is no earlier price.
function CT.TrendPct(tr)
  if not tr then return "" end
  if tr.dir == "up" then
    return "|cff20ff20+" .. pctText(tr.pct) .. "|r"
  elseif tr.dir == "down" then
    return "|cffff4040" .. pctText(tr.pct) .. "|r"
  end
  return "|cffffd1000%|r"
end

-- Text for a trend from CT:Trend. compact = ticker form; otherwise adds "was <price>".
function CT.TrendText(tr, compact)
  if not tr then
    return compact and "" or "|cff808080no earlier price yet|r"
  end
  local was = compact and "" or format(" |cff9d9d9d(was %s)|r", CT.PlainMoney(tr.prev))
  if tr.dir == "same" then
    return CT.TrendPct(tr) .. (compact and "" or " |cff9d9d9d(unchanged)|r")
  end
  return CT.TrendPct(tr) .. was
end

function CT:Trend(id, q)
  q = q or self:Quote(id)
  if not q or not q.price or q.price <= 0 or (q.none and q.src ~= "feed") then return nil end
  local isFeed = q.src == "feed"
  local curT = isFeed and q.t or (q.seen or q.t)
  local prev, other
  if curT and id then
    local series = self:Series(id)
    for k = #series, 1, -1 do
      local p = series[k]
      if p.t < curT and p.p and p.p > 0 then
        if (p.s == "feed") == isFeed then prev = p.p; break end
        other = other or p.p
      end
    end
  end
  if not prev and q.prev and q.prev > 0 then prev = q.prev end
  prev = prev or other
  if not prev then return nil end
  local cur = q.price
  local dir = cur > prev and "up" or (cur < prev and "down" or "same")
  return { dir = dir, pct = (cur - prev) / prev * 100, prev = prev, cur = cur }
end

------------------------------------------------------------------------
-- Australia/Melbourne time (AEDT UTC+11 / AEST UTC+10), pure arithmetic so it
-- doesn't depend on the PC's time zone. DST: 2:00 AEST first Sunday of October
-- until 3:00 AEDT first Sunday of April.
------------------------------------------------------------------------
local function daysFromCivil(y, m, d)
  y = (m <= 2) and (y - 1) or y
  local era = floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function civilFromDays(z)
  z = z + 719468
  local era = floor(z / 146097)
  local doe = z - era * 146097
  local yoe = floor((doe - floor(doe / 1460) + floor(doe / 36524) - floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + floor(yoe / 4) - floor(yoe / 100))
  local mp = floor((5 * doy + 2) / 153)
  local d = doy - floor((153 * mp + 2) / 5) + 1
  local m = (mp < 10) and (mp + 3) or (mp - 9)
  if m <= 2 then y = y + 1 end
  return y, m, d
end

local function firstSunday(y, m)
  local days = daysFromCivil(y, m, 1)
  local wd = (days + 4) % 7 -- 0 = Sunday (1970-01-01 was a Thursday)
  return days + (7 - wd) % 7
end

function CT.MelbourneOffset(t)
  local y = civilFromDays(floor(t / 86400))
  local dstEnd = firstSunday(y, 4) * 86400 + 3 * 3600 - 11 * 3600
  local dstStart = firstSunday(y, 10) * 86400 + 2 * 3600 - 10 * 3600
  if t < dstEnd or t >= dstStart then return 11, "AEDT" end
  return 10, "AEST"
end

local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- Returns "3:22 pm AEDT", "Wed 11 Nov"
function CT.MelTime(t)
  if not t then return "?", "?" end
  local off, zone = CT.MelbourneOffset(t)
  local lt = t + off * 3600
  local days = floor(lt / 86400)
  local secs = lt - days * 86400
  local y, m, d = civilFromDays(days)
  local h, mi = floor(secs / 3600), floor((secs % 3600) / 60)
  local h12 = h % 12
  if h12 == 0 then h12 = 12 end
  local clock = format("%d:%02d %s %s", h12, mi, h < 12 and "am" or "pm", zone)
  return clock, format("%s %d %s", WEEKDAYS[(days + 4) % 7 + 1], d, MONTHS[m]), y
end

function CT.MelStamp(t)
  local clock, day = CT.MelTime(t)
  return day .. " " .. clock
end

-- Shorter axis labels for the lookup graph. Same calendar day: just the time
-- (zone on the right-hand label only). Different days: "11 Nov 6:23 pm".
function CT.MelAxis(t, opts)
  if not t then return "?" end
  opts = opts or {}
  local clock, day = CT.MelTime(t)
  local time = opts.zone and clock or (clock:gsub(" %u+$", ""))
  if opts.timeOnly then return time end
  local shortDay = day:match("^%a+ (%d+ %a+)$") or day
  return shortDay .. " " .. time
end

------------------------------------------------------------------------
-- Feed (written by tools/update_feed.py; HerbTicker's old global accepted too)
------------------------------------------------------------------------
function CT:RawFeed()
  local feed = _G.CommodityTickerFeed or _G.HerbTickerFeed
  if type(feed) ~= "table" or type(feed.items) ~= "table" or not feed.updated then return nil end
  return feed
end

function CT:Feed()
  if not self.db.settings.useFeed then return nil end
  local feed = self:RawFeed()
  if not feed then return nil end
  local _, faction = self:MarketKey()
  if feed.faction and faction ~= "?" and feed.faction ~= faction then return nil end
  return feed
end

-- Alchemy outputs (potions, elixirs, flasks, Philosopher's Stone, ...) live in
-- feed.craft. They are not commodities: the ticker, lists, farm panel,
-- profession defaults and lookup never use this table.
function CT:CraftFeed()
  local feed = self:Feed()
  if not feed or type(feed.craft) ~= "table" then return nil end
  return feed.craft
end

function CT:CraftQuote(id)
  local craft = self:CraftFeed()
  local f = craft and craft[id]
  if not f or not f.min or f.min <= 0 then return nil end
  local feed = self:Feed()
  return {
    price = f.min, prev = f.prevMin, market = f.market, qty = f.qty,
    t = feed and feed.updated, src = "feed", none = (f.qty or 0) == 0, craft = true,
  }
end

------------------------------------------------------------------------
-- Watch list (default lists + added items) and tracked items
------------------------------------------------------------------------
-- (watch lists, bars and professions live in Lists.lua)

------------------------------------------------------------------------
-- Commodities only: stackable crafting materials (herbs, pearls, ore, bars,
-- stone, leather, cloth, elemental and vendor reagents, other trade goods).
-- Never gear, weapons, recipes, consumables or other one-off items.
------------------------------------------------------------------------
local COMMODITY_CLASSES = { [5] = true, [7] = true } -- Enum.ItemClass Reagent, Tradegoods
local REFUSED_CLASS = {
  [0] = "a consumable", [1] = "a bag", [2] = "a weapon", [4] = "armour", [6] = "ammunition",
  [8] = "an item enhancement", [9] = "a recipe", [11] = "a quiver", [12] = "a quest item",
  [13] = "a key", [15] = "a miscellaneous item", [16] = "a glyph", [17] = "a battle pet",
}

function CT:CommodityCheck(id)
  if not id then return false, "unknown item" end
  if self:DefaultEntry(id) then return true end -- default lists are hand-checked commodities
  if self:InProfessionData(id) then return true end -- Professions.lua keeps AH trade goods/reagents only
  local info = C_Item and C_Item.GetItemInfoInstant
  local itemID, equipLoc, classID
  if info then
    local _a, _b, _c
    itemID, _a, _b, equipLoc, _c, classID = info(id)
  end
  if not itemID then
    -- Not in the client's item data: accept only if the feed lists it as a
    -- commodity (feed.items). Alchemy outputs in feed.craft are not commodities.
    local feed = self:RawFeed()
    if feed and feed.items[id] then return true end
    return false, "unknown item ID"
  end
  if equipLoc and equipLoc ~= "" and not equipLoc:find("NON_EQUIP") then return false, "it's equippable gear" end
  if not COMMODITY_CLASSES[classID] then
    return false, "it's " .. (REFUSED_CLASS[classID] or "not a trade good")
  end
  if C_Item.GetItemMaxStackSizeByID then
    local stack = C_Item.GetItemMaxStackSizeByID(id)
    if stack and stack <= 1 then return false, "it doesn't stack" end
  end
  return true
end

-- Drop any added/tracked item that isn't a commodity (e.g. saved by an older version).
function CT:PruneNonCommodities()
  local tables = { self.db.settings.extra, self.db.settings.tracked }
  for b = 2, self:NumBars() do tables[#tables + 1] = self:BarItems(b) end
  for _, t in ipairs(tables) do
    for id, name in pairs(t) do
      local ok, why = self:CommodityCheck(id)
      if not ok then
        t[id] = nil
        CT.Print(format("stopped watching %s: %s (%s).", tostring(name), CT.COMMODITY_HINT, why))
      end
    end
  end
end

function CT:ItemName(id, fallback)
  if C_Item and C_Item.GetItemNameByID then
    local n = C_Item.GetItemNameByID(id)
    if n then return n end
  end
  local e = self:DefaultEntry(id)
  if e then return e.name end
  local pn = self:ProfessionDataName(id)
  if pn then return pn end
  local s = self.db and self.db.settings
  if s and (s.tracked[id] or s.extra[id]) then return s.tracked[id] or s.extra[id] end
  if s and s.bars then
    for _, c in ipairs(s.bars) do if c.items and c.items[id] then return c.items[id] end end
  end
  local feed = self:RawFeed()
  if feed and feed.items[id] and feed.items[id].n then return feed.items[id].n end
  return fallback or ("item " .. id)
end

-- Text -> itemID. Accepts an item link, an item ID or a (partial) name.
function CT:ResolveItem(text)
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil, "type an item name or ID (or shift-click an item)" end
  local id = tonumber(text:match("item:(%d+)") or text:match("^(%d+)$"))
  if id then return id, text:match("%[(.-)%]") or self:ItemName(id) end
  local want = text:lower()
  local exact, partial, seen = nil, {}, {}
  local function consider(cid, name)
    if not name or seen[cid] then return end
    seen[cid] = true
    local ln = name:lower()
    if ln == want then exact = exact or { cid, name }
    elseif ln:find(want, 1, true) then partial[#partial + 1] = { cid, name } end
  end
  for _, listName in ipairs({ "now", "later" }) do
    for _, e in ipairs(ns.LISTS[listName]) do consider(e.id, e.name) end
  end
  for cid, name in pairs(self.db.settings.tracked) do consider(cid, name) end
  for cid, name in pairs(self.db.settings.extra) do consider(cid, name) end
  for b = 2, self:NumBars() do for cid, name in pairs(self:BarItems(b)) do consider(cid, name) end end
  for cid, name in pairs(ns.PROF_DATA and ns.PROF_DATA.names or {}) do consider(cid, name) end
  local feed = self:RawFeed()
  if feed then for cid, f in pairs(feed.items) do consider(cid, f.n) end end
  if exact then return exact[1], exact[2] end
  if #partial == 1 then return partial[1][1], partial[1][2] end
  if #partial > 1 then
    table.sort(partial, function(a, b) return a[2] < b[2] end)
    local names = {}
    for i = 1, min(5, #partial) do names[i] = partial[i][2] end
    return nil, format("%d matches: %s%s - be more specific", #partial, table.concat(names, ", "), #partial > 5 and ", ..." or "")
  end
  if C_Item and C_Item.GetItemInfoInstant then
    local cid = C_Item.GetItemInfoInstant(text) -- works for names the client has cached
    if cid then return cid, self:ItemName(cid, text) end
  end
  return nil, "no commodity called \"" .. text .. "\" in the feed or your lists (try its item ID, or shift-click it)"
end

------------------------------------------------------------------------
-- Price storage (per realm + faction auction house) and real history
------------------------------------------------------------------------
function CT:MarketKey()
  local realm = (GetRealmName and GetRealmName()) or "?"
  local faction = (UnitFactionGroup and UnitFactionGroup("player")) or "?"
  return realm .. " - " .. faction, faction
end

function CT:Market()
  local key = self:MarketKey()
  local m = self.db.markets[key]
  if not m then
    m = { items = {}, lastScan = 0 }
    self.db.markets[key] = m
  end
  m.hist = m.hist or {}
  return m
end

local function trimHistory(h, now)
  local cutoff = now - CT.HISTORY_DAYS * 86400
  local i = 1
  while h[i] and h[i].t < cutoff do i = i + 1 end
  if i > 1 then for _ = 1, i - 1 do table.remove(h, 1) end end
  while #h > CT.HISTORY_POINTS do table.remove(h, 1) end
end

-- Append one real observation. Repeated AH events for the same item within
-- 60 seconds update the latest point instead of adding near-duplicates.
function CT:AddPoint(id, t, price, qty, src)
  if not id or not t or not price or price <= 0 then return end
  local hist = self:Market().hist
  local h = hist[id]
  if not h then h = {}; hist[id] = h end
  local isFeed = src == "feed"
  for i = #h, 1, -1 do
    local p = h[i]
    if p.t == t and (p.s == "feed") == isFeed then return end -- already have it
    if p.t < t then break end
  end
  local last = h[#h]
  if last and not isFeed and last.s ~= "feed" and t >= last.t and t - last.t < 60 then
    last.t, last.p, last.q, last.s = t, price, qty, src
  else
    h[#h + 1] = { t = t, p = price, q = qty, s = src }
    if last and last.t > t then table.sort(h, function(a, b) return a.t < b.t end) end
  end
  trimHistory(h, time())
end

-- Feed history points for one item (from the compact "h" string the script writes).
function CT:FeedPoints(id)
  local feed = self:Feed()
  local f = feed and feed.items[id]
  if not f then return {} end
  local out = {}
  if type(f.h) == "string" then
    for dt, p, q in f.h:gmatch("(%d+):(%d+):(%d*)") do
      out[#out + 1] = { t = feed.updated - tonumber(dt) * 60, p = tonumber(p), q = tonumber(q), s = "feed" }
    end
  end
  if f.min and f.min > 0 then
    local have = false
    for _, p in ipairs(out) do if p.t == feed.updated then have = true end end
    if not have then out[#out + 1] = { t = feed.updated, p = f.min, q = f.qty, s = "feed" } end
  end
  table.sort(out, function(a, b) return a.t < b.t end)
  return out
end

-- Copy the loaded feed's points into saved history for items you watch or track,
-- so they outlive the feed file's short window.
function CT:MergeFeedHistory()
  local hist = self:Market().hist
  for id, h in pairs(hist) do
    trimHistory(h, time())
    if #h == 0 then hist[id] = nil end
  end
  if not self:Feed() then return end
  for _, e in ipairs(self:Watched()) do
    for _, p in ipairs(self:FeedPoints(e.id)) do self:AddPoint(e.id, p.t, p.p, p.q, "feed") end
  end
end

-- All real points for an item, oldest first: saved AH/feed history plus the
-- loaded feed's points. Nothing is interpolated or invented.
function CT:Series(id)
  local out, seen = {}, {}
  local function add(p)
    local key = p.t .. ":" .. ((p.s == "feed") and "f" or "a")
    if not seen[key] and p.p and p.p > 0 then seen[key] = true; out[#out + 1] = p end
  end
  for _, p in ipairs(self:Market().hist[id] or {}) do add(p) end
  for _, p in ipairs(self:FeedPoints(id)) do add(p) end
  table.sort(out, function(a, b) return a.t < b.t end)
  local cutoff = time() - CT.HISTORY_DAYS * 86400
  local trimmed = {}
  for _, p in ipairs(out) do if p.t >= cutoff then trimmed[#trimmed + 1] = p end end
  while #trimmed > CT.HISTORY_POINTS do table.remove(trimmed, 1) end
  return trimmed
end

-- Record one observed price (copper per unit) from the in-game auction house.
function CT:Record(id, price, qty, src, at)
  if not id or not price or price <= 0 then return end
  local when = at or time()
  if when > time() + 300 then return end
  if when < time() - CT.HISTORY_DAYS * 86400 then return end
  local items = self:Market().items
  local o = items[id]
  -- Guild shares merge into history. They never overwrite a price you already
  -- have from your own AH scan or the feed.
  if src == "guild" and o and o.p and o.p > 0 and o.src and o.src ~= "guild" then
    self:AddPoint(id, when, price, qty, src)
    self.dirty = true
    return
  end
  if o and o.t and when < o.t then
    -- Older than the current quote: keep the current, still store the point.
    self:AddPoint(id, when, price, qty, src)
    return
  end
  if not o then
    o = {}
    items[id] = o
  elseif o.p and o.p ~= price then
    o.pp, o.pt = o.p, o.t
  end
  o.p, o.q, o.t, o.src, o.none = price, qty, when, src, nil
  self:AddPoint(id, when, price, qty, src)
  self.dirty = true
end

function CT:MarkNoneListed(id)
  local items = self:Market().items
  local o = items[id] or {}
  items[id] = o
  o.q, o.none, o.nt = 0, true, time()
  self.dirty = true
end

-- Best current view of an item: newest of own AH data, the feed file, or Auctionator.
-- Guild prices only fill a gap; they never replace a price you already have.
-- When our own AH auto-refresh is off, prices already scanned by TSM or
-- Auctionator are used first (never invented); if those addons are missing
-- or have no figure, we fall back to the usual own / feed / Auctionator path.
function CT:Quote(id)
  if self.db and self.db.settings and self.db.settings.auto == false then
    local addon = self:AddonScanPrice(id)
    if addon and addon.price then
      return addon
    end
  end
  local own, guild
  local o = self:Market().items[id]
  if o and o.p then
    local q = { price = o.p, prev = o.pp, qty = o.q, t = max(o.t or 0, o.nt or 0), seen = o.t, src = o.src, none = o.none }
    if o.src == "guild" then guild = q else own = q end
  elseif o and o.none then
    own = { qty = 0, t = o.nt, src = "scan", none = true }
  end

  local best = own
  local feed = self:Feed()
  if feed then
    local f = feed.items[id]
    if f and (not best or not best.t or (feed.updated or 0) > best.t) then
      best = {
        price = f.min, prev = f.prevMin, market = f.market, qty = f.qty,
        t = feed.updated, src = "feed", none = (f.qty or 0) == 0,
      }
    end
  end

  -- Fill in only when you have no usable own or feed price.
  if guild and guild.price then
    if not best or (best.none and not best.price) then
      best = guild
    end
  end

  if best and best.none and not best.price and feed and feed.items[id] then
    best.price = feed.items[id].min -- "none listed" now; show the feed's older price as "last"
  end
  if not best or not best.price then
    local a = self:AuctionatorPrice(id)
    if a then best = a end
  end
  return best
end

function CT:QuoteLine(id)
  local name = self:ItemName(id)
  local q = self:Quote(id)
  if not q or (not q.price and not q.none) then
    return name .. ": no price data yet (open the AH, or run the feed updater and /reload)."
  end
  if q.none then
    return format("%s: none listed (%s, %s)%s", name, CT.SourceLabel(q.src), CT.Ago(q.t),
      q.price and (" - last price " .. CT.Money(q.price)) or "")
  end
  local ch = CT.TrendText(self:Trend(id, q))
  return format("%s: %s %s (%s, %s%s)", name, CT.Money(q.price), ch,
    CT.SourceLabel(q.src), CT.Ago(q.t), q.qty and format(", %d listed", q.qty) or "")
end

------------------------------------------------------------------------
-- Feed staleness and the Reload button (never automatic)
------------------------------------------------------------------------
function CT:FeedInterval(feed)
  local every = tonumber(feed and feed.every) or 30
  if every < 5 then every = 5 end
  return every * 60
end

-- Stock-style spread: lowest listing (current price) vs the feed's market price.
-- Only when both exist. nil if we don't have a market figure.
function CT:Spread(id, q)
  q = q or self:Quote(id)
  local price = q and q.price
  local market = q and q.market
  if not market or market <= 0 then
    local feed = self:Feed()
    local f = feed and feed.items and feed.items[id]
    if f and f.market and f.market > 0 then market = f.market end
  end
  if not price or price <= 0 or not market or market <= 0 then return nil end
  local diff = market - price
  local mid = (market + price) / 2
  if mid <= 0 then return nil end
  local raw = math.abs(diff) / mid * 100
  local pctLabel
  if raw > 0 and raw < 1 then
    pctLabel = format("%.1f%%", raw)
  else
    pctLabel = format("%d%%", floor(raw + 0.5))
  end
  return { min = price, market = market, diff = diff, abs = math.abs(diff), pct = raw, pctLabel = pctLabel }
end

-- Mean of real history points from the last 24 hours. Nothing is invented.
function CT:DayAverage(id)
  local cutoff = time() - 86400
  local sum, n = 0, 0
  for _, p in ipairs(self:Series(id)) do
    if p.t and p.t >= cutoff and p.p and p.p > 0 then
      sum = sum + p.p
      n = n + 1
    end
  end
  if n == 0 then return nil end
  return { price = floor(sum / n + 0.5), points = n }
end

function CT:FeedMayBeStale()
  local feed = self:Feed()
  if not feed or not next(feed.items) then return false end
  local written = tonumber(feed.fetched) or tonumber(feed.updated)
  if not written then return false end
  return time() - written >= self:FeedInterval(feed), feed, written
end

function CT:InCombat()
  return (InCombatLockdown and InCombatLockdown()) or (UnitAffectingCombat and UnitAffectingCombat("player")) or false
end

-- Mid-session feed slots (CTFeed01..CTFeed24). Each can be LoadAddOn'd once
-- per session to re-execute a copy of Feed.lua without ReloadUI.
CT.FEED_SLOT_COUNT = 24
CT.FEED_SLOT_PREFIX = "CTFeed"

function CT:FeedSlotName(i)
  return format("%s%02d", self.FEED_SLOT_PREFIX, i)
end

function CT:HasFeedLoadAPI()
  return (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
end

function CT:AddOnIsLoaded(name)
  if C_AddOns and C_AddOns.IsAddOnLoaded then return C_AddOns.IsAddOnLoaded(name) and true or false end
  if IsAddOnLoaded then return IsAddOnLoaded(name) and true or false end
  return false
end

function CT:LoadSlotAddOn(name)
  local fn = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
  if not fn then return nil, "NO_API" end
  return fn(name)
end

function CT:SlotsLeft()
  return math.max(0, self.FEED_SLOT_COUNT - (self.feedSlot or 0))
end

-- Try to re-read the on-disk feed via the next unused load-on-demand slot.
-- Returns ok, kind  where kind is loaded|same|combat|no_api|missing|disabled|empty|exhausted
function CT:LoadFeedFromDisk()
  if self:InCombat() then return false, "combat" end
  if not self:HasFeedLoadAPI() then return false, "no_api" end
  self.feedSlot = self.feedSlot or 0
  if self.feedSlot >= self.FEED_SLOT_COUNT then return false, "exhausted" end
  local before = self:RawFeed()
  local start = self.feedSlot + 1
  local missingAll, anyDisabled, loadedEmpty = true, false, false
  for i = start, self.FEED_SLOT_COUNT do
    local name = self:FeedSlotName(i)
    self.feedSlot = i
    if self:AddOnIsLoaded(name) then
      missingAll = false
    else
      local loaded, reason = self:LoadSlotAddOn(name)
      if loaded then
        missingAll = false
        local after = self:RawFeed()
        if after and after ~= before then
          self:Refresh()
          local same = before
            and tonumber(after.fetched) == tonumber(before.fetched)
            and tonumber(after.updated) == tonumber(before.updated)
            and after.proof == before.proof
          return true, same and "same" or "loaded"
        end
        loadedEmpty = true
      elseif reason == "DISABLED" then
        missingAll = false
        anyDisabled = true
      elseif reason ~= "MISSING" then
        missingAll = false
      end
    end
  end
  if loadedEmpty then return false, "empty" end
  if missingAll and start == 1 then return false, "missing" end
  if anyDisabled then return false, "disabled" end
  return false, "exhausted"
end

function CT:LoadFeedMessage(ok, kind)
  local left = self:SlotsLeft()
  local slots = format("%d slot%s left this session", left, left == 1 and "" or "s")
  if ok and kind == "loaded" then
    return "loaded the price feed from disk without a /reload (" .. slots .. ")."
  elseif ok and kind == "same" then
    return "re-read the feed from disk; it's the same snapshot you already have (" .. slots .. ")."
  elseif kind == "combat" then
    return "in combat - not loading the feed from disk."
  elseif kind == "no_api" then
    return "this client can't load addons mid-session, so a /reload is still needed to re-read the feed."
  elseif kind == "missing" then
    return "the mid-session feed slots aren't visible to the game yet. Fully restart WoW once, then try again. Until then, /reload still works."
  elseif kind == "disabled" then
    return "the CTFeed addons are disabled in the addon list. Enable them, restart WoW, then try again."
  elseif kind == "exhausted" then
    return "no mid-session feed slots left this session. /reload to reset them (and to re-read Feed.lua)."
  elseif kind == "empty" then
    return "the feed slots are empty. Run the feed updater, then try again — or /reload to load Feed.lua the usual way."
  end
  return "could not load the feed from disk."
end

-- Called by the Reload / Load feed button and /commodity reload. Never called on a timer.
-- Tries a mid-session slot first; falls back to ReloadUI if that can't work.
function CT:ReloadForFeed(force)
  if not force then
    if not self:Feed() then
      CT.Print("no feed data is loaded, so there's nothing to refresh. Run tools/update_feed first, or use /commodity reload force.")
      return
    elseif not self:FeedMayBeStale() then
      CT.Print("the loaded feed is still fresh. Use /commodity reload force (or /reload) to reload anyway.")
      return
    end
  end
  if self:InCombat() then
    self.reloadWanted = true
    CT.Print("in combat - not reloading. When combat ends, click Load feed or Reload again (or /commodity reload).")
    self:Refresh()
    return
  end
  local ok, kind = self:LoadFeedFromDisk()
  if ok then
    CT.Print(self:LoadFeedMessage(ok, kind))
    return
  end
  if kind and kind ~= "combat" then
    CT.Print(self:LoadFeedMessage(false, kind))
  end
  ReloadUI()
end

-- TSM item strings for regular items are "i:<id>" (TSM_API docs,
-- https://api.tradeskillmaster.com/addon/). Prefer ToItemString when present.
function CT:TSMItemString(id)
  if not id then return nil end
  local fallback = "i:" .. tostring(id)
  local api = rawget(_G, "TSM_API")
  if not (api and api.ToItemString) then return fallback end
  for _, raw in ipairs({ "item:" .. tostring(id), fallback }) do
    local ok, converted = pcall(api.ToItemString, raw)
    if ok and type(converted) == "string" and converted ~= "" then
      return converted
    end
  end
  return fallback
end

-- TSM 4.x public API: GetCustomPriceValue(priceSource, itemString) in copper.
-- Try the current lowest listing first, then the realm market value.
function CT:TSMPrice(id)
  local api = rawget(_G, "TSM_API")
  if not (api and type(api.GetCustomPriceValue) == "function") then return nil end
  local itemString = self:TSMItemString(id)
  if not itemString then return nil end
  for _, key in ipairs({ "dbminbuyout", "dbmarket" }) do
    local ok, value = pcall(api.GetCustomPriceValue, key, itemString)
    if ok and type(value) == "number" and value > 0 then
      return { price = value, src = "tsm" } -- TSM does not expose a scan age
    end
  end
  return nil
end

function CT:AuctionatorPrice(id)
  if not (self.db and self.db.settings and self.db.settings.useAuctionator) then return nil end
  local api = _G.Auctionator and Auctionator.API and Auctionator.API.v1
  if not api or not api.GetAuctionPriceByItemID then return nil end
  local ok, price = pcall(api.GetAuctionPriceByItemID, "CommodityTicker", id)
  if not ok or type(price) ~= "number" or price <= 0 then return nil end
  local t
  if api.GetAuctionAgeByItemID then
    local ok2, days = pcall(api.GetAuctionAgeByItemID, "CommodityTicker", id)
    if ok2 and type(days) == "number" then t = time() - days * 86400 end
  end
  return { price = price, t = t, src = "auctionator" }
end

-- Order when our own AH scanning is off: TSM, then Auctionator.
-- Each call is feature-detected and pcall'd; missing addons return nil.
function CT:AddonScanPrice(id)
  return self:TSMPrice(id) or self:AuctionatorPrice(id)
end

function CT.SourceLabel(src) return SRC_LABEL[src] or tostring(src) end


------------------------------------------------------------------------
-- Guild price sharing (2.4.7)
-- Silent addon messages on the GUILD channel only (the usual in-game
-- pattern: a short registered prefix, compact payloads, and a send
-- budget so the client is not disconnected). On by default; turn off
-- with /commodity share off or the settings checkbox. Only our own
-- auction-house observations are sent — never bag or bank counts, gold,
-- the feed file, Auctionator data, or prices we heard from someone else
-- (no rebroadcast, which would loop).
------------------------------------------------------------------------
CT.SHARE_PREFIX = "CTShare"       -- RegisterAddonMessagePrefix: at most 16 characters
CT.SHARE_MAX = 255
CT.SHARE_PROTO = 1
CT.SHARE_BURST = 5                -- stay under the client's 10-message burst
CT.SHARE_GAP = 1.1                -- seconds; the client refills one token per second
CT.SHARE_FRESH = 6 * 3600         -- only advertise AH prices this fresh
CT.SHARE_PRICE_MAX = 1000000000   -- 100,000 gold in copper; reject nonsense
CT.AH_SOURCES = { scan = true, lookup = true, browse = true, search = true }

function CT:ShareEnabled()
  return self.db and self.db.settings and self.db.settings.sharePrices ~= false
end

function CT:ShareAPI()
  if C_ChatInfo and C_ChatInfo.SendAddonMessage and C_ChatInfo.RegisterAddonMessagePrefix then
    return "C_ChatInfo"
  end
  if SendAddonMessage and RegisterAddonMessagePrefix then
    return "legacy"
  end
  return nil
end

function CT:CanShare()
  if not self:ShareEnabled() then return false, "sharing is off" end
  if not self:ShareAPI() then return false, "this client has no addon-message API" end
  if not (IsInGuild and IsInGuild()) then return false, "not in a guild" end
  return true
end

function CT:RegisterShare()
  if self.shareRegistered then return end
  local api = self:ShareAPI()
  if not api then return end
  if api == "C_ChatInfo" then
    pcall(C_ChatInfo.RegisterAddonMessagePrefix, CT.SHARE_PREFIX)
  else
    pcall(RegisterAddonMessagePrefix, CT.SHARE_PREFIX)
  end
  if self.eventFrame and self.eventFrame.RegisterEvent then
    self.eventFrame:RegisterEvent("CHAT_MSG_ADDON")
    self.eventFrame:RegisterEvent("PLAYER_GUILD_UPDATE")
  end
  self.shareRegistered = true
end

function CT:ShareIsSelf(sender)
  if not sender or sender == "" then return true end
  local me = UnitName and UnitName("player")
  if not me or me == "" then return false end
  local function norm(s)
    return (tostring(s or ""):gsub("%s+", "")):lower()
  end
  me = tostring(me)
  if norm(sender) == norm(me) then return true end
  -- Character names can contain hyphens (e.g. Brun-Rager). Never split on the
  -- first '-'; treat "Name-Realm" as us only when it starts with Name + '-'.
  if norm(sender):sub(1, #me + 1) == norm(me) .. "-" then return true end
  if norm(me):sub(1, #sender + 1) == norm(sender) .. "-" then return true end
  if Ambiguate then
    for _, mode in ipairs({ "short", "none", "mail", "all" }) do
      local ok, a = pcall(Ambiguate, sender, mode)
      -- Compare to the full character name only. Ambiguate("short") can
      -- clip a hyphenated name at the first '-', so Brun-Rager and
      -- Brun-Rage would otherwise look like the same person.
      if ok and a and a ~= "" and norm(a) == norm(me) then return true end
    end
  end
  local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName())
  if realm and realm ~= "" then
    realm = realm:gsub("%s+", "")
    if norm(sender) == norm(me .. "-" .. realm) then return true end
  end
  return false
end

function CT:ShareSendOk(r)
  if r == true or r == nil then return true end
  if Enum and Enum.SendAddonMessageResult then
    if r == Enum.SendAddonMessageResult.Success then return true end
    if r == Enum.SendAddonMessageResult.AddonMessageThrottle then return false, "throttle" end
    return false, "send failed"
  end
  if type(r) == "number" then
    if r == 0 then return true end
    return false, "send failed"
  end
  return false, "send failed"
end

function CT:ShareSend(text)
  local result
  if C_ChatInfo and C_ChatInfo.SendAddonMessage then
    result = C_ChatInfo.SendAddonMessage(CT.SHARE_PREFIX, text, "GUILD")
  elseif SendAddonMessage then
    result = SendAddonMessage(CT.SHARE_PREFIX, text, "GUILD")
  else
    return false, "no API"
  end
  return self:ShareSendOk(result)
end

function CT:ShareEnqueue(text)
  if type(text) ~= "string" or text == "" or #text > CT.SHARE_MAX then return end
  self.shareQueue = self.shareQueue or {}
  if #self.shareQueue >= 30 then table.remove(self.shareQueue, 1) end
  self.shareQueue[#self.shareQueue + 1] = text
  self:ShareFlush()
end

function CT:ShareFlush()
  if self.shareFlushing then return end
  if not self:CanShare() then
    self.shareQueue = {}
    return
  end
  local q = self.shareQueue
  if not q or #q == 0 then return end
  self.shareTokens = self.shareTokens or CT.SHARE_BURST
  self.shareTokenAt = self.shareTokenAt or GetTime()
  local now = GetTime()
  local gained = math.floor((now - self.shareTokenAt) / CT.SHARE_GAP)
  if gained > 0 then
    self.shareTokens = min(CT.SHARE_BURST, self.shareTokens + gained)
    self.shareTokenAt = self.shareTokenAt + gained * CT.SHARE_GAP
  end
  self.shareFlushing = true
  while #q > 0 do
    if self.shareTokens < 1 then
      if not self.shareWait then
        self.shareWait = true
        C_Timer.After(CT.SHARE_GAP, function()
          self.shareWait = false
          self:ShareFlush()
        end)
      end
      break
    end
    local msg = table.remove(q, 1)
    local ok, why = self:ShareSend(msg)
    if not ok then
      table.insert(q, 1, msg)
      if why == "throttle" then
        self.shareTokens = 0
        if not self.shareWait then
          self.shareWait = true
          C_Timer.After(CT.SHARE_GAP, function()
            self.shareWait = false
            self:ShareFlush()
          end)
        end
      end
      break
    end
    self.shareTokens = self.shareTokens - 1
  end
  self.shareFlushing = false
end

function CT:ShareableQuotes(ids)
  local out, seen = {}, {}
  local cutoff = time() - CT.SHARE_FRESH
  local function add(id, p, q, t, src)
    if not id or not p or p <= 0 or not t or t < cutoff then return end
    local ok = self:CommodityCheck(id)
    if not ok then return end
    local e = seen[id]
    if e then
      if t > e.t then e.p, e.q, e.t, e.src = p, q or 0, t, src end
      return
    end
    e = { id = id, p = p, q = q or 0, t = t, src = src }
    seen[id] = e
    out[#out + 1] = e
  end
  local function considerMarket(id)
    local o = self:Market().items[id]
    if not o or not o.p or o.p <= 0 or o.none then return end
    if not (CT.AH_SOURCES[o.src] or o.src == "feed") then return end
    add(id, o.p, o.q, o.t, o.src)
  end
  if ids then
    for id in pairs(ids) do considerMarket(id) end
  else
    for id in pairs(self:Market().items) do considerMarket(id) end
  end
  -- Desktop scrape (Feed.lua): share it when present, but a newer AH quote wins.
  local feed = self:Feed()
  if feed and feed.items then
    local function want(id)
      if ids then return ids[id] end
      return self:IsWatched(id) or self:IsTracked(id)
    end
    for id, f in pairs(feed.items) do
      if want(id) and f.min and f.min > 0 then
        add(id, f.min, f.qty or 0, feed.updated or 0, "feed")
      end
    end
  end
  return out
end

function CT:ShareQuotes(quotes)
  if not self:CanShare() then return 0 end
  if not quotes or #quotes == 0 then return 0 end
  table.sort(quotes, function(a, b) return a.id < b.id end)
  local T = time()
  local header = "P" .. CT.SHARE_PROTO .. "|" .. T .. "|"
  local chunks, cur = {}, header
  for _, q in ipairs(quotes) do
    local age = max(0, floor((T - q.t) / 60))
    local bit = format("%d:%d:%d:%d", q.id, q.p, q.q or 0, age)
    if #header + #bit > CT.SHARE_MAX then
      -- a single quote should never exceed 255 characters
    elseif #cur + ((cur == header) and 0 or 1) + #bit > CT.SHARE_MAX then
      chunks[#chunks + 1] = cur
      cur = header .. bit
    elseif cur == header then
      cur = header .. bit
    else
      cur = cur .. "," .. bit
    end
  end
  if cur ~= header then chunks[#chunks + 1] = cur end
  for _, c in ipairs(chunks) do self:ShareEnqueue(c) end
  return #chunks
end

function CT:ShareScan(got)
  if not got then return 0 end
  return self:ShareQuotes(self:ShareableQuotes(got))
end

function CT:ShareSnapshot(force)
  if not self:CanShare() then return 0 end
  local now = GetTime()
  if not force and self.shareDidSnapshot then return 0 end
  if self.shareSnapAt and now - self.shareSnapAt < 60 then return 0 end
  self.shareDidSnapshot = true
  self.shareSnapAt = now
  return self:ShareQuotes(self:ShareableQuotes())
end

function CT:AcceptShared(id, price, qty, at)
  if not id or not price or price <= 0 or price > CT.SHARE_PRICE_MAX then return false end
  qty = qty or 0
  if qty < 0 or qty ~= floor(qty) then return false end
  if not at or at > time() + 300 then return false end
  if at < time() - CT.HISTORY_DAYS * 86400 then return false end
  local ok = self:CommodityCheck(id)
  if not ok then return false end
  self:Record(id, price, qty, "guild", at)
  return true
end

function CT:OnAddonMessage(prefix, message, channel, sender)
  if prefix ~= CT.SHARE_PREFIX then return end
  if channel ~= "GUILD" then return end
  if self:ShareIsSelf(sender) then return end
  if type(message) ~= "string" then return end
  local proto, rest = message:match("^P(%d+)|(.*)$")
  proto = tonumber(proto)
  if proto ~= CT.SHARE_PROTO or not rest then return end
  local T, body = rest:match("^(%d+)|(.*)$")
  T = tonumber(T)
  if not T or not body or body == "" then return end
  local now = time()
  if T > now + 300 then return end
  if T < now - CT.SHARE_FRESH - 600 then return end
  local applied = 0
  for part in body:gmatch("[^,]+") do
    local id, price, qty, age = part:match("^(%d+):(%d+):(%d+):(%d+)$")
    id, price, qty, age = tonumber(id), tonumber(price), tonumber(qty), tonumber(age)
    if id and price and qty and age and self:AcceptShared(id, price, qty, T - age * 60) then
      applied = applied + 1
    end
  end
  if applied > 0 then self:Refresh() end
end

function CT:ShareStatus()
  local on = self:ShareEnabled()
  local line = "guild share: " .. (on and "|cff20ff20on|r" or "|cffff4040off|r") .. " (guild only"
  if on then
    local ok, why = self:CanShare()
    if not ok then
      line = line .. "; " .. why
    else
      local n = #self:ShareableQuotes()
      line = line .. format("; %d recent price%s ready to send", n, n == 1 and "" or "s")
    end
  end
  return line .. ")"
end


------------------------------------------------------------------------
-- Auction house refresh and lookup (same guards for both)
------------------------------------------------------------------------
local SORTS = {
  { sortOrder = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0, reverseSort = false },
}

local function sellBoxBusy()
  local ok, busy = pcall(function()
    local ahf = _G.AuctionHouseFrame
    if not ahf or not ahf:IsShown() then return false end
    for _, name in ipairs({ "ItemSellFrame", "CommoditiesSellFrame" }) do
      local sf = ahf[name]
      if sf and sf:IsShown() and sf.GetItem and sf:GetItem() then return true end
    end
    return false
  end)
  return ok and busy
end

function CT:CanQuery()
  if not self.ahOpen then return false, "open the auction house first (live prices only come from the AH)." end
  if not (C_AuctionHouse and C_AuctionHouse.SearchForItemKeys and C_AuctionHouse.MakeItemKey) then
    return false, "this client has no C_AuctionHouse.SearchForItemKeys."
  end
  if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
    return false, "the auction house is busy; try again in a moment."
  end
  if sellBoxBusy() then return false, "an item is in the Sell box; not interrupting." end
  return true
end

function CT:SendScanQuery()
  local scan = self.scan
  if not scan then return end
  local keys = {}
  for id in pairs(scan.ids) do
    if not scan.got[id] then keys[#keys + 1] = C_AuctionHouse.MakeItemKey(id) end
  end
  if #keys == 0 then return self:FinishScan() end
  scan.sentAt = GetTime()
  scan.answered = false
  self.ourQueryAt = GetTime()
  C_AuctionHouse.SearchForItemKeys(keys, SORTS)
  local token, attempt = scan.token, scan.attempt
  -- Safety net: finish (or retry) if the server never answers.
  C_Timer.After(8, function()
    if self.scan and self.scan.token == token and self.scan.attempt == attempt and not self.scan.answered then
      self:CheckScan()
    end
  end)
end

-- kind "refresh": watch list + tracked items. kind "lookup": one item.
function CT:StartScan(manual, ids, kind)
  kind = kind or "refresh"
  if self.scan then
    if manual and kind == "refresh" then CT.Print("a refresh is already running; try again in a few seconds.") end
    return false, "a refresh is already running"
  end
  local ok, why = self:CanQuery()
  if not ok then
    if manual and kind == "refresh" then CT.Print("can't refresh: " .. why) end
    return false, why
  end
  local count = 0
  if not ids then
    ids = {}
    for _, e in ipairs(self:Watched()) do ids[e.id] = true end
  end
  for _ in pairs(ids) do count = count + 1 end
  if count == 0 then
    if manual then CT.Print("watch list is empty.") end
    return false, "nothing to refresh"
  end
  self.scanToken = (self.scanToken or 0) + 1
  self.scan = { ids = ids, got = {}, attempt = 1, manual = manual, token = self.scanToken, count = count, kind = kind }
  self:SendScanQuery()
  self:Refresh()
  return true
end

-- Forever's first SearchForItemKeys often returns every row as "None available"
-- (see ForeverPlusPlus docs), so resend up to 3 times.
function CT:CheckScan()
  local scan = self.scan
  if not scan then return end
  if not self.ahOpen then self.scan = nil; return end
  local missing = 0
  for id in pairs(scan.ids) do if not scan.got[id] then missing = missing + 1 end end
  if missing > 0 and scan.attempt < 3 then
    scan.attempt = scan.attempt + 1
    local token = scan.token
    C_Timer.After(1.5, function()
      if not (self.scan and self.scan.token == token) then return end
      local ok = self:CanQuery()
      if ok then self:SendScanQuery() else self:FinishScan() end
    end)
    return
  end
  self:FinishScan()
end

function CT:FinishScan()
  local scan = self.scan
  if not scan then return end
  self.scan = nil
  local got, none = 0, 0
  for id in pairs(scan.ids) do
    if scan.got[id] then got = got + 1 else none = none + 1; self:MarkNoneListed(id) end
  end
  if scan.kind == "refresh" then
    self:Market().lastScan = time()
    if scan.manual then CT.Print(format("refreshed %d prices; %d not listed right now.", got, none)) end
  elseif scan.kind == "lookup" then
    for id in pairs(scan.ids) do CT.Print(self:QuoteLine(id)) end
  end
  if got > 0 then self:ShareScan(scan.got) end
  self:Refresh()
  local pending = self.pendingLookup
  self.pendingLookup = nil
  if pending and self.ahOpen then
    C_Timer.After(1, function()
      if self.ahOpen and not self.scan and self:StartScan(true, { [pending] = true }, "lookup") and ns.Lookup then
        ns.Lookup:ShowItem(pending, "Checking the auction house...")
      end
    end)
  end
end

function CT:Wants(id)
  if not id then return false end
  if self.scan and self.scan.ids[id] then return true end
  if self.lookupID == id then return true end
  return self:IsWatched(id) and true or false
end

function CT:ReadBrowseResults(results)
  if type(results) ~= "table" then return end
  local scan = self.scan
  local ours = scan and self.ourQueryAt and GetTime() - self.ourQueryAt < 10
  local src = ours and ((scan.kind == "lookup") and "lookup" or "scan") or "browse"
  local any = false
  for _, r in ipairs(results) do
    local id = r.itemKey and r.itemKey.itemID
    if id and self:Wants(id) and (r.totalQuantity or 0) > 0 and (r.minPrice or 0) > 0 then
      self:Record(id, r.minPrice, r.totalQuantity, src)
      if scan and scan.ids[id] then scan.got[id] = true end
      any = true
    end
  end
  if any then self:Refresh() end
  if ours then scan.answered = true end
  if ours and not self.checkPending then
    self.checkPending = true
    C_Timer.After(1, function() self.checkPending = false; self:CheckScan() end)
  end
end

function CT:ReadCommodityResults(itemID)
  if not itemID or not self:Wants(itemID) then return end
  local ok, info = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, itemID, 1)
  if not ok or type(info) ~= "table" or not info.unitPrice then return end
  local qty
  if C_AuctionHouse.GetCommoditySearchResultsQuantity then
    local ok2, q = pcall(C_AuctionHouse.GetCommoditySearchResultsQuantity, itemID)
    if ok2 then qty = q end
  end
  self:Record(itemID, info.unitPrice, qty, "search")
  self:ShareScan({ [itemID] = true })
  self:Refresh()
end

-- Turn our own AH auto-refresh on or off. The settings checkbox, the AH badge
-- on the ticker, and /commodity auto all call this so they stay in sync and
-- print the new state. Automatic queries (on AH open, and the 15s AutoTick)
-- honour this; a manual /commodity scan or middle-click still runs.
function CT:SetAuto(on)
  local s = self.db and self.db.settings
  if not s then return end
  s.auto = on and true or false
  CT.Print("auto-refresh at the AH " .. (s.auto and "|cff20ff20on|r" or "|cffff4040off|r"))
  self:Refresh()
end

function CT:AutoTick()
  if not (self.ahOpen and self.db.settings.auto) or self.scan then return end
  local interval = max(1, self.db.settings.interval) * 60
  if time() - (self:Market().lastScan or 0) < interval then return end
  -- Don't overwrite a list the player is looking at: wait 45s after their own searches.
  if self.userQueryAt and GetTime() - self.userQueryAt < 45 then return end
  self:StartScan(false)
end

function CT:NextAutoIn()
  local interval = max(1, self.db.settings.interval) * 60
  return max(0, interval - (time() - (self:Market().lastScan or 0)))
end

------------------------------------------------------------------------
-- Lookup and tracking (commodities only)
------------------------------------------------------------------------
function CT:CheckedItem(text, verb)
  local id, nameOrErr = self:ResolveItem(text)
  if not id then return nil, nameOrErr end
  local ok, why = self:CommodityCheck(id)
  if not ok then
    return nil, format("can't %s %s: %s - %s.", verb, nameOrErr or ("item " .. id), CT.COMMODITY_HINT, why)
  end
  return id, nameOrErr
end

-- One-off price check. Live at the AH when allowed, otherwise best known data.
function CT:Lookup(text, quiet)
  local id, nameOrErr = self:CheckedItem(text, "look up")
  if not id then
    CT.Print(nameOrErr)
    if ns.Lookup then ns.Lookup:ShowError(nameOrErr) end
    return nil
  end
  self.lookupID = id
  local live, why = false, nil
  if self.ahOpen then
    live, why = self:StartScan(true, { [id] = true }, "lookup")
    if not live and self.scan then
      -- A refresh is running: check this item right after it, instead of refusing.
      self.pendingLookup = id
      if not quiet then CT.Print(self:QuoteLine(id) .. " (checking the AH after the current refresh...)") end
      if ns.Lookup then ns.Lookup:ShowItem(id, "Checking the auction house after the current refresh...") end
      return id, true
    end
  end
  if not live then
    local line = self:QuoteLine(id)
    if self.ahOpen and why then line = line .. " (AH not queried: " .. why .. ")" end
    if not quiet then CT.Print(line) end
  else
    if not quiet then CT.Print("checking " .. nameOrErr .. " at the auction house...") end
  end
  if ns.Lookup then ns.Lookup:ShowItem(id, live and "Checking the auction house..." or (self.ahOpen and why and ("AH not queried: " .. why)) or nil) end
  return id, live
end

function CT:Track(text)
  local id, nameOrErr = self:CheckedItem(text, "track")
  if not id then CT.Print(nameOrErr); return nil end
  local name = self:ItemName(id, nameOrErr)
  self.db.settings.tracked[id] = name
  CT.Print(format("tracking %s live: it's refreshed with every AH refresh (every %d min while the AH is open). With the AH closed it shows the feed.",
    name, self.db.settings.interval))
  self:Refresh()
  return id
end

function CT:Untrack(text)
  local id = self:ResolveItem(text)
  if not id or not self.db.settings.tracked[id] then CT.Print("that item isn't tracked."); return end
  local name = self.db.settings.tracked[id]
  self.db.settings.tracked[id] = nil
  CT.Print("stopped tracking " .. tostring(name) .. ".")
  self:Refresh()
end

-- AddToTicker / RemoveFromTicker: see Lists.lua (they act on the selected ticker)

------------------------------------------------------------------------
-- Saved data and migration from HerbTicker
------------------------------------------------------------------------
function CT:InitDB()
  local migrated = false
  if type(CommodityTickerDB) ~= "table" and type(HerbTickerDB) == "table" then
    CommodityTickerDB = deepCopy(HerbTickerDB)
    CommodityTickerDB.migratedFrom = "HerbTicker"
    CommodityTickerDB.migratedAt = time()
    migrated = true
  end
  if type(CommodityTickerDB) ~= "table" then CommodityTickerDB = {} end
  -- HerbTickerDB is declared in our TOC only so tools/migrate_from_herbticker can
  -- hand it over; clear it so it isn't saved again under the new addon.
  if type(HerbTickerDB) == "table" and not (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("HerbTicker")) then
    HerbTickerDB = nil
  end
  self.db = CommodityTickerDB
  self.db.settings = self.db.settings or {}
  self.db.markets = self.db.markets or {}
  self:MigrateLists(self.db.settings) -- 2.2.0: profession default, multiple tickers
  copyDefaults(self.db.settings, DEFAULTS)
  self:MigrateDefaultPoint()
  self:MigrateDefaultLook()
  self.db.version = 4
  return migrated
end

-- One time: a bar still on the old default spot (TOP, 0, -4) moves to the new
-- default. A position you chose yourself is never touched.
function CT:MigrateDefaultPoint()
  local s = self.db.settings
  if s.pointMigrated then return false end
  s.pointMigrated = true
  local p, o = s.point, CT.OLD_DEFAULT_POINT
  if type(p) == "table" and p[1] == o[1] and p[2] == o[2] and tonumber(p[3]) == o[3] and tonumber(p[4]) == o[4] then
    s.point = { unpack(CT.DEFAULT_POINT) }
    return true
  end
  return false
end

-- One time: tickers still on the old 460 px / 40 px/s defaults move to 760 / 10.
-- A width or speed you chose yourself is never touched.
CT.OLD_DEFAULT_WIDTH = 460
CT.OLD_DEFAULT_SPEED = 40

function CT:MigrateDefaultLook()
  local s = self.db.settings
  if s.lookMigrated247 then return false end
  s.lookMigrated247 = true
  local function one(c)
    if not c then return end
    if tonumber(c.width) == CT.OLD_DEFAULT_WIDTH then c.width = 760 end
    if tonumber(c.speed) == CT.OLD_DEFAULT_SPEED then c.speed = 10 end
  end
  one(s)
  if type(s.bars) == "table" then
    for _, b in ipairs(s.bars) do one(b) end
  end
  return true
end

-- If the old HerbTicker addon is still installed and enabled, hide it and turn it off
-- for next login, so only one ticker runs.
function CT:RetireHerbTicker()
  local loaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("HerbTicker")
  if not loaded then return end
  if _G.HerbTickerFrame then _G.HerbTickerFrame:Hide() end
  if _G.HerbTicker and _G.HerbTicker.eventFrame then _G.HerbTicker.eventFrame:UnregisterAllEvents() end
  if C_AddOns.DisableAddOn then pcall(C_AddOns.DisableAddOn, "HerbTicker") end
  SlashCmdList["HERBTICKER"] = function(msg) CT:Slash(msg) end -- old commands reach the new addon
  CT.Print("the old HerbTicker addon is still installed: it's hidden now and disabled from next login. Delete its folder from Interface\\AddOns when convenient.")
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local ev = CreateFrame("Frame")
CT.eventFrame = ev
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
  "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
  "COMMODITY_SEARCH_RESULTS_UPDATED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "GET_ITEM_INFO_RECEIVED" }) do
  ev:RegisterEvent(e)
end

local function hookUserQueries()
  if CT.hooked or not C_AuctionHouse or not hooksecurefunc then return end
  CT.hooked = true
  for _, fn in ipairs({ "SendBrowseQuery", "SendSearchQuery", "SearchForFavorites", "RequestMoreBrowseResults" }) do
    if C_AuctionHouse[fn] then
      hooksecurefunc(C_AuctionHouse, fn, function() CT.userQueryAt = GetTime() end)
    end
  end
end

ev:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    if ... ~= ADDON then return end
    CT.justMigrated = CT:InitDB()
  elseif event == "PLAYER_LOGIN" then
    hookUserQueries()
    CT:RetireHerbTicker()
    if CT.justMigrated then
      CT.Print("imported your HerbTicker settings, bar position, lists and prices. Commands are now /commodity (old /herbticker still works).")
    end
    CT:PruneNonCommodities()
    CT:MergeFeedHistory()
    CT:RegisterShare()
    if ns.UI then ns.UI:Init() end
    C_Timer.NewTicker(15, function() CT:AutoTick() end)
    C_Timer.NewTicker(20, function() CT:Refresh() end) -- keeps ages ("5m", "2h") current
    C_Timer.After(8, function() CT:ShareSnapshot() end)
  elseif event == "AUCTION_HOUSE_SHOW" then
    CT.ahOpen = true
    hookUserQueries()
    C_Timer.After(2.5, function() CT:AutoTick() end)
    CT:Refresh()
  elseif event == "AUCTION_HOUSE_CLOSED" then
    CT.ahOpen = false
    CT.scan = nil -- closed mid-refresh: keep what arrived, don't mark the rest "none listed"
    CT.pendingLookup = nil
    CT:Refresh()
  elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
    if C_AuctionHouse and C_AuctionHouse.GetBrowseResults then
      CT:ReadBrowseResults(C_AuctionHouse.GetBrowseResults())
    end
  elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
    CT:ReadBrowseResults((...))
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    -- A name just arrived from the server: the ticker text gets longer, so lay it out again.
    local id = ...
    if CT.db and CT:IsWatched(id) and not CT.itemInfoPending then
      CT.itemInfoPending = true
      C_Timer.After(0.5, function() CT.itemInfoPending = false; CT:Refresh() end)
    end
  elseif event == "PLAYER_REGEN_DISABLED" then
    CT:Refresh()
  elseif event == "PLAYER_REGEN_ENABLED" then
    if CT.reloadWanted then
      CT.reloadWanted = false
      CT.Print("combat over - click Load feed or Reload on the ticker (or /commodity loadfeed) to re-read the feed.")
    end
    CT:Refresh()
  elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    CT:ReadCommodityResults((...))
  elseif event == "CHAT_MSG_ADDON" then
    CT:OnAddonMessage(...)
  elseif event == "PLAYER_GUILD_UPDATE" then
    if CT:CanShare() then
      C_Timer.After(3, function() CT:ShareSnapshot(true) end)
    else
      CT.shareQueue = {}
      CT.shareDidSnapshot = false
    end
  end
end)

function CT:Refresh()
  if ns.UI and ns.UI.ready then ns.UI:Rebuild() end
  if ns.Lookup and ns.Lookup.Update then ns.Lookup:Update() end
  if ns.Farm and ns.Farm.OnDataChanged then ns.Farm:OnDataChanged() end
end

------------------------------------------------------------------------
-- Slash commands: /commodity, /ct (also /cticker; old /herbticker, /hticker still work)
------------------------------------------------------------------------
local HELP = {
  "/commodity  (or /ct) - show this help. Commodities only: herbs, ore, bars, stone, leather, cloth, reagents, trade goods.",
  "/commodity settings  (or config, or right-click a ticker) - the settings window: tickers, lists, professions, look",
  "/commodity lookup <name, ID or shift-click>  (or /commodity l) - price check + graph; live if the AH is open",
  "/commodity graph <item>     - open the price-history graph for an item",
  "/commodity farm  (or farm list) - best farm right now: what you can gather, ranked by price x sell speed (estimate)",
  "/commodity track <item> || untrack <item> || tracked - live-track items (refreshed while the AH is open)",
  "Tickers: /commodity bars - list them; bar <n or name> - pick the ticker the commands below change; bar new <name>; bar rename <name>; bar delete",
  "/commodity add <item> || remove <item>  - put an item on / take it off the picked ticker",
  "/commodity list profession||now||later||both||custom (combine with +) - what the picked ticker shows; /commodity profs - your professions",
  "Move: drag the ticker, or Esc > Edit Mode. List view: drag the right or bottom edge (or the corner) to resize. /commodity editmode for status.",
  "/commodity show || hide || toggle || lock || unlock || reset  - the picked ticker (lock/unlock = dragging outside Edit Mode)",
  "/commodity mode scroll||rotate||list, speed <px/s>, width <px>, scale <0.5-2>  - the picked ticker",
  "/commodity rows <3-30>       - list mode: rows shown before it scrolls",
  "/commodity columns [icon|graph|price|trend|bag|bank|value] [on|off]  - show or hide list columns (name always stays)",
  "/commodity tickergraph on||off - show a mini price graph on the scrolling and rotating ticker",
  "/commodity scan             - refresh now (auction house must be open)",
  "/commodity auto on||off      - auto-refresh while the AH is open (off: use TSM or Auctionator scans if present, else the feed). Also the settings checkbox and the AH badge on the ticker",
  "/commodity interval <min>   - minutes between auto-refreshes (1-120, default 5)",
  "/commodity share on||off     - share your AH commodity prices with your guild (on by default, guild only)",
  "/commodity feed on||off      - use Feed.lua from tools/update_feed.py",
  "/commodity arrows on||off    - leftover command; trend is a colour-coded percent only (no ^ / v / - / =)",
  "/commodity loadfeed         - re-read the on-disk feed mid-session via a load-on-demand slot (no /reload)\n" ..
  "/commodity reload           - try loadfeed first, then /reload if the loaded feed may be stale ('force' skips the check)",
  "/commodity status || prices || clear (forget prices here) || version",
}

local function onOff(v) return v and "|cff20ff20on|r" or "|cffff4040off|r" end

local function sourcesText(c)
  local t = {}
  if c.sources.profession then t[#t + 1] = "profession picks" end
  if c.sources.now then t[#t + 1] = "level-38 preset" end
  if c.sources.later then t[#t + 1] = "level-50+ preset" end
  t[#t + 1] = "your added items"
  return table.concat(t, " + ")
end
CT.SourcesText = sourcesText

function CT:BarCommand(rest)
  local sub, arg = rest:match("^(%S*)%s*(.-)$")
  sub = (sub or ""):lower()
  if sub == "new" or sub == "add" or sub == "create" then
    local i, err = self:CreateBar(arg)
    if i then CT.Print(format("created ticker %d \"%s\" (picked). Choose its list in /commodity settings or with /commodity list.", i, self:BarName(i)))
    else CT.Print("can't create a ticker: " .. err) end
  elseif sub == "delete" or sub == "remove" or sub == "del" then
    local i = arg ~= "" and self:FindBar(arg) or self:TargetBar()
    local name = i and self:BarName(i)
    local ok, err = self:DeleteBar(i)
    CT.Print(ok and ("deleted ticker \"" .. name .. "\".") or ("can't delete: " .. (err or "no such ticker.")))
  elseif sub == "rename" then
    local i = self:TargetBar()
    if self:RenameBar(i, arg) then CT.Print(format("ticker %d is now \"%s\".", i, self:BarName(i))) else CT.Print("use: /commodity bar rename <name>") end
  elseif sub == "" then
    local i = self:TargetBar()
    CT.Print(format("picked ticker: %d \"%s\" - %s", i, self:BarName(i), sourcesText(self:BarCfg(i))))
  else
    local i = self:FindBar(rest)
    if i then
      self:SetTargetBar(i)
      CT.Print(format("picked ticker %d \"%s\": add/remove/list/show/hide/width/scale/mode now change it.", i, self:BarName(i)))
    else
      CT.Print("no ticker called \"" .. rest .. "\". /commodity bars lists them.")
    end
  end
end

function CT:ListCommand(c, rest)
  rest = rest:lower()
  if rest == "" then
    local i = self:TargetBar()
    CT.Print("ticker \"" .. self:BarName(i) .. "\" shows: " .. sourcesText(c))
    local names = {}
    for _, e in ipairs(self:Watched(i)) do names[#names + 1] = e.name or self:ItemName(e.id) end
    CT.Print(format("%d item%s: %s%s", #names, #names == 1 and "" or "s", table.concat(names, ", ", 1, min(#names, 25)),
      #names > 25 and ", ..." or ""))
    return
  end
  local want, okAny = { profession = false, now = false, later = false }, false
  for tok in rest:gmatch("[^%s%+,]+") do
    if tok == "profession" or tok == "professions" or tok == "prof" then want.profession = true; okAny = true
    elseif tok == "now" then want.now = true; okAny = true
    elseif tok == "later" then want.later = true; okAny = true
    elseif tok == "both" or tok == "all" then want.now, want.later = true, true; okAny = true
    elseif tok == "custom" or tok == "none" or tok == "mine" then okAny = true
    else CT.Print("use: /commodity list profession||now||later||both||custom (combine with +)"); return end
  end
  if okAny then c.sources = want end
  CT.Print("ticker \"" .. self:BarName(self:TargetBar()) .. "\" shows: " .. sourcesText(c))
end

function CT:Slash(msg)
  local s = self.db.settings
  local c = self:BarCfg(self:TargetBar()) -- layout/list commands act on the picked ticker
  local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = (cmd or ""):lower()
  if cmd == "" or cmd == "help" then
    for _, line in ipairs(HELP) do CT.Print(line) end
  elseif cmd == "settings" or cmd == "config" or cmd == "options" or cmd == "gui" then
    if ns.Settings then ns.Settings:Open(self:TargetBar()) end
  elseif cmd == "bar" or cmd == "ticker" then self:BarCommand(rest)
  elseif cmd == "bars" or cmd == "tickers" then
    for i = 1, self:NumBars() do
      local bc = self:BarCfg(i)
      CT.Print(format("%s%d \"%s\"%s - %s", i == self:TargetBar() and "> " or "  ", i, self:BarName(i),
        bc.shown and "" or " (hidden)", sourcesText(bc)))
    end
  elseif cmd == "profs" or cmd == "professions" then
    CT:UpdateProfessions(true)
    local n = 0
    for _ in pairs(self:ProfessionItems()) do n = n + 1 end
    CT.Print(format("professions: %s - %d current-tier commodities (required skill within %d of yours; herbs, ore/bars/stone/gems, leather, cloth, enchanting mats).", self:ProfessionSummary(), n, CT.TIER_WINDOW))
  elseif cmd == "lookup" or cmd == "l" or cmd == "price" then
    if rest == "" then if ns.Lookup then ns.Lookup:Open() end else self:Lookup(rest) end
  elseif cmd == "graph" or cmd == "g" or cmd == "history" then
    if rest == "" then if ns.Lookup then ns.Lookup:Open() end
    else
      local id, err = self:CheckedItem(rest, "graph")
      if not id then CT.Print(err) else self.lookupID = id; if ns.Lookup then ns.Lookup:ShowItem(id) end end
    end
  elseif cmd == "farm" then
    if rest:lower():match("^list") or rest:lower():match("^print") then
      self:FarmPrint(tonumber(rest:match("(%d+)")) or 8)
    elseif ns.Farm then ns.Farm:Toggle() end
  elseif cmd == "track" then
    if rest == "" then CT.Print("use: /commodity track <item>") else self:Track(rest) end
  elseif cmd == "untrack" then self:Untrack(rest)
  elseif cmd == "tracked" then
    local names = {}
    for _, name in pairs(s.tracked) do names[#names + 1] = tostring(name) end
    table.sort(names)
    CT.Print(#names > 0 and ("tracked live: " .. table.concat(names, ", ")) or "nothing tracked. /commodity track <item>")
  elseif cmd == "editmode" or cmd == "edit" then
    CT.Print(ns.EditMode and ns.EditMode:Status() or "Edit Mode support isn't loaded.")
  elseif cmd == "version" then CT.Print("version " .. CT.VERSION)
  elseif cmd == "show" then c.shown = true
  elseif cmd == "hide" then c.shown = false
  elseif cmd == "toggle" then c.shown = not c.shown
  elseif cmd == "lock" then c.locked = true; CT:Refresh(); CT.Print("locked.")
  elseif cmd == "unlock" then c.locked = false; CT:Refresh(); CT.Print("unlocked - drag to move, or drag the list edges to resize.")
  elseif cmd == "scan" or cmd == "refresh" then self:StartScan(true)
  elseif cmd == "auto" then
    if rest == "on" then self:SetAuto(true)
    elseif rest == "off" then self:SetAuto(false)
    else self:SetAuto(not s.auto) end
  elseif cmd == "interval" then
    local n = tonumber(rest)
    if n and n >= 1 and n <= 120 then
      s.interval = n
      CT.Print(format("auto-refresh every %d min while the AH is open.", n))
    else
      CT.Print("interval must be 1-120 minutes (current " .. s.interval .. ").")
    end
  elseif cmd == "list" or cmd == "lists" then
    self:ListCommand(c, rest)
  elseif cmd == "add" then
    if rest == "" then CT.Print("use: /commodity add <item name, ID or shift-click>") return end
    self:AddToTicker(rest)
  elseif cmd == "remove" or cmd == "del" then
    self:RemoveFromTicker(rest)
  elseif cmd == "mode" then
    if rest == "scroll" or rest == "rotate" then c.mode = rest
    elseif rest == "list" or rest == "static" or rest == "rows" then c.mode = "list" end
    CT.Print("mode: " .. c.mode .. "  (scroll, rotate or list)")
  elseif cmd == "rows" then
    local n = tonumber(rest); if n and n >= 3 and n <= 30 then c.listRows = floor(n) end
    CT.Print("list rows: " .. c.listRows .. " (list mode shows this many before it scrolls; 3-30)")
  elseif cmd == "columns" or cmd == "cols" or cmd == "column" then
    self:ColumnsCommand(c, rest)
  elseif cmd == "tickergraph" or cmd == "tapegraph" then
    if rest == "on" then c.tickerGraph = true elseif rest == "off" then c.tickerGraph = false
    elseif rest == "" then c.tickerGraph = not c.tickerGraph end
    CT.Print("ticker graph: " .. (c.tickerGraph and "on" or "off") .. "  (mini price graph on the scrolling and rotating ticker)")
  elseif cmd == "speed" then
    local n = tonumber(rest); if n and n >= 5 and n <= 200 then c.speed = n end
    CT.Print("speed: " .. c.speed .. " px/s")
  elseif cmd == "width" then
    local key = CT.WidthKey(c)
    local n = tonumber(rest)
    if n and n >= 150 and n <= 2000 then c[key] = n
    elseif rest == "auto" and key == "listWidth" then c.listWidth = 0 end
    self:Refresh()
    if key == "listWidth" then
      CT.Print(format("list width: %s (drawn at %d px; never narrower than its packed width - /commodity width auto to pack it)",
        c.listWidth == 0 and "auto" or tostring(c.listWidth), self:EffectiveWidth(self:TargetBar())))
    else
      CT.Print("width: " .. c.width)
    end
  elseif cmd == "scale" then
    local n = tonumber(rest); if n and n >= 0.5 and n <= 2 then c.scale = n end
    CT.Print("scale: " .. c.scale)
  elseif cmd == "arrows" or cmd == "trend" then
    if rest == "on" then s.trendIcons = true elseif rest == "off" then s.trendIcons = false end
    CT.Print("trend arrows: " .. onOff(s.trendIcons) .. "  (unused: trend is a colour-coded percent only, with no ^ / v / - / =)")
    self:Refresh()
  elseif cmd == "share" then
    local a = (rest or ""):lower()
    if a == "on" then s.sharePrices = true
    elseif a == "off" then s.sharePrices = false; self.shareQueue = {}
    elseif a ~= "" and a ~= "status" then
      CT.Print("use: /commodity share on|off")
    end
    CT.Print(self:ShareStatus())
  elseif cmd == "feed" then
    if rest == "on" then s.useFeed = true elseif rest == "off" then s.useFeed = false end
    local f = self:RawFeed()
    if f then
      local n, c = 0, 0
      for _ in pairs(f.items or {}) do n = n + 1 end
      for _ in pairs(f.craft or {}) do c = c + 1 end
      CT.Print(format("feed %s: %s, %s - %d commodities%s, prices %s (file written %s).", onOff(s.useFeed),
        tostring(f.source), tostring(f.label), n,
        c > 0 and format(", %d alchemy craft (not on the ticker)", c) or "",
        CT.Ago(f.updated), CT.Ago(f.fetched)))
    else
      CT.Print("feed " .. onOff(s.useFeed) .. ": no Feed.lua data loaded.")
    end
  elseif cmd == "loadfeed" or cmd == "load" then
    local ok, kind = self:LoadFeedFromDisk()
    CT.Print(self:LoadFeedMessage(ok, kind))
    return
  elseif cmd == "reload" then
    self:ReloadForFeed(rest:lower() == "force")
    return
  elseif cmd == "reset" then
    c.point = CT.DefaultBarPoint(self:TargetBar()); c.shown = true
  elseif cmd == "clear" then
    self.db.markets[self:MarketKey()] = nil
    CT.Print("forgot saved prices and history for " .. self:MarketKey() .. ".")
  elseif cmd == "status" then
    local m = self:Market()
    local nt = 0
    for _ in pairs(s.tracked) do nt = nt + 1 end
    CT.Print(format("market %s - last AH refresh %s - auto %s every %d min - AH %s - %d tracked",
      self:MarketKey(), m.lastScan > 0 and CT.Ago(m.lastScan) or "never", onOff(s.auto), s.interval,
      self.ahOpen and "open" or "closed", nt))
    CT.Print(self:ShareStatus())
  elseif cmd == "prices" then
    for _, e in ipairs(self:Watched()) do CT.Print(self:QuoteLine(e.id)) end
  else
    CT.Print("unknown command. /commodity for help.")
  end
  self:Refresh()
end

function CT:ColumnsCommand(c, rest)
  CT.EnsureListCols(c)
  rest = (rest or ""):lower()
  rest = rest:match("^%s*(.-)%s*$") or rest
  local function report()
    local bits = {}
    for _, k in ipairs(CT.LIST_COL_KEYS) do
      bits[#bits + 1] = CT.LIST_COL_LABELS[k] .. " " .. (c.listCols[k] and "on" or "off")
    end
    CT.Print("list columns: " .. table.concat(bits, ", ") .. "  (name always stays)")
  end
  if rest == "" or rest == "show" then
    report()
    CT.Print("use: /commodity columns <icon|graph|price|trend|bag|bank|value> on|off  (or 'all on')")
    return
  end
  if rest == "all" or rest == "all on" then
    for _, k in ipairs(CT.LIST_COL_KEYS) do c.listCols[k] = true end
    report()
    return
  end
  if rest == "all off" then
    for _, k in ipairs(CT.LIST_COL_KEYS) do c.listCols[k] = false end
    report()
    return
  end
  local tokens = {}
  for w in rest:gmatch("%S+") do tokens[#tokens + 1] = w end
  local on
  local last = tokens[#tokens]
  if last == "on" or last == "off" then
    on = (last == "on")
    tokens[#tokens] = nil
  end
  local keys, seen = {}, {}
  for _, w in ipairs(tokens) do
    local k = CT.LIST_COL_ALIASES[w] or w
    if k == "all" then
      for _, kk in ipairs(CT.LIST_COL_KEYS) do
        if not seen[kk] then keys[#keys + 1] = kk; seen[kk] = true end
      end
    elseif CT.LIST_COL_LABELS[k] then
      if not seen[k] then keys[#keys + 1] = k; seen[k] = true end
    else
      CT.Print("unknown column \"" .. w .. "\". Use icon, graph, price, trend, bag, bank or value.")
      return
    end
  end
  if #keys == 0 then
    CT.Print("use: /commodity columns <icon|graph|price|trend|bag|bank|value> on|off")
    return
  end
  for _, k in ipairs(keys) do
    if on == nil then c.listCols[k] = not c.listCols[k] else c.listCols[k] = on and true or false end
  end
  report()
end

SLASH_COMMODITYTICKER1 = "/commodity"
SLASH_COMMODITYTICKER2 = "/ct"
SLASH_COMMODITYTICKER3 = "/cticker"
SLASH_COMMODITYTICKER4 = "/herbticker"
SLASH_COMMODITYTICKER5 = "/hticker"
SlashCmdList["COMMODITYTICKER"] = function(msg) CT:Slash(msg) end
