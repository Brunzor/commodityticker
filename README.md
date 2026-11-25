# CommodityTicker for WoW: Forever

Version 2.8.8: the level-38 watch list also includes the four Un'Goro power crystals (Blue, Green, Red and Yellow Power Crystal). The out-of-game feed (script 3.0.1) rewrites Feed.lua from the current auction house snapshot when the watch list gains items, so they are priced straight away instead of waiting for the next hourly snapshot; history for those items starts at that snapshot (earlier points are not invented). The settings window has a search box above the item list: type part of a name to filter the list (not case-sensitive), press Esc or click the x to clear it; it also clears when you close the window. Blue Pearl, Giant Egg and Wintersbite could not be removed from the main ticker because they were saved as live-tracked items and unticking them in the settings window never untracked them. Unticking now always removes an item (and `/commodity track` clears an earlier removal), and a one-time clean-up drops those three from an existing saved selection. They stay in the item database and can be added back with `/commodity add` or from the settings list. Best farm no longer forces Blue Pearl once you have removed it. Version 2.8.7: the level-38 watch list also includes the elemental reagents (Elemental Earth, Fire, Air and Water; Core of Earth, Heart of Fire, Globe of Water and Breath of Wind; Essence of Earth, Fire, Water, Air and Undeath; and Living Essence). Essence of Eternity is not a Forever item and is not listed. Version 2.8.6: the out-of-game feed (`tools/update_feed.py`, feed script 3.0.0) now reads Blizzard's official auction house API directly, using your own free API client in `tools/blizzard.json` (see [Price feed setup](#price-feed-setup-blizzard-api)). `Feed.lua` and `feed_state.json` keep the same format, so existing price history carries on. Graph tooltips label feed points "Blizzard AH feed". Version 2.8.5: the level-38 watch list also includes the mining ores (Copper through Thorium and Dark Iron), Arcane Crystal, and Arcanite Bar. Small and Rich Thorium veins are the same item (Thorium Ore). Version 2.8.4: you can turn CommodityTicker's own auction-house scanning on or off with a settings checkbox (**Scan the AH myself (off = use TSM/Auctionator/feed)**), by clicking the coloured **AH** badge on the ticker, or with `/commodity auto`. All three stay in sync and print the new state. Version 2.8.3: when auto-refresh at the auction house is off (`/commodity auto off`), prices already scanned by TradeSkillMaster (TSM 4.15 `TSM_API.GetCustomPriceValue`) or Auctionator (`Auctionator.API.v1.GetAuctionPriceByItemID`) are shown, labelled as TSM or Auctionator. If those addons are not loaded or have no figure, the feed is used. Nothing is invented. Version 2.8.2: the level-38 watch list includes the three tradeable Warrior Whirlwind-quest charms (Burning Charm, Cresting Charm and Thundering Charm). They are stackable auction-house consumables, not soulbound quest items; Essence of the Exile is a quest item and is not listed. Version 2.8.1: the out-of-game feed also writes alchemy recipe outputs up to skill 300 (potions, elixirs, flasks, the Philosopher's Stone, and other previously excluded craft products) into a separate `craft` table in `Feed.lua`, for flip pricing. They are not commodities — the ticker, lists, farm panel, profession defaults and lookup ignore them. Version 2.8.0: a **Best farm right now** window (`/commodity farm`, or the **Best farm** button in the settings window) ranks what you can gather plus Blue Pearl by price and an estimated sell speed — see [Best farm right now](#best-farm-right-now-280). Version 2.7.0: hover the full lookup graph to see a point's time and price — a crosshair snaps to the nearest real point by time, with a tooltip showing the Melbourne time, price, source (feed or your own AH scan) and listed count. Every real point on the full graph has a small dot. The small hover-panel graph and the ticker sparklines are unchanged. Version 2.5.0: in list view you can drag the right edge, the bottom edge, or the corner to resize (width and how many rows are shown) without opening Edit Mode — lock the ticker to turn that off. Version 2.4.9: guild shares only merge into history and fill gaps — they never overwrite a price you already have from your own AH scan or the feed. The lookup window shows a stock-style market price and spread when both figures exist, plus a last-day average from real history points. The out-of-game feed defaults to every 30 minutes (minimum 5) and appends history instead of wiping it. Version 2.4.8: trends no longer stick at 0% after guild share — your own messages (including hyphenated character names) are ignored, and a same-price guild quote does not hide the feed's change. Version 2.4.7: trend shows a colour-coded percent only (no `^` / `v` arrows, no `-` or `=`). Default ticker width is 760 px and scroll speed is 10. Mini ticker graphs downsample history and skip the glow line so they use far less memory. Your auction-house commodity prices are shared with your guild by default, silently, over addon messages (not guild chat). Turn it off with `/commodity share off` or the settings checkbox. Your own AH scans and the loaded feed are sent — never bags, bank, or gold. 2.4.6: item tooltips only add what the list or ticker doesn't already show — earlier price, source, age, listed count, and history. The scrolling ticker's hover still includes bag, bank and value, which aren't on the tape. List mode has checkboxes (and `/commodity columns`) to hide columns and pack the list. The scrolling and rotating ticker can show a mini price graph beside each item (`/commodity tickergraph`, on by default). 2.4.5: up/down marks are large `^` / `v` (the game font has no triangle glyphs, which showed as coloured boxes). 2.4.4: prices use gold, silver and copper coin icons (numbers only, no `00g 00s 00c` padding), lined up in columns in list mode. 2.4.3: the lookup window is restyled to match the ticker (item icon, a clear price + trend row, wrapped text, quieter buttons). List mode puts the trend arrow and percent in their own columns, with larger marks, and shows a slim scrollbar when the list is shorter than the item count (including if you drag the bottom edge in Edit Mode). 2.4.2: empty bag and bank counts show `-` instead of `0` or `?`, and the price graphs use a softer line so they look less jagged.

Version 2.4.1: `/ct` is the short slash command (same as `/commodity`).

Version 2.4.0: a new **list** mode: a static list with each item's icon, price and trend, a small price graph, how many you have in your bags and bank, and what that's worth.
(2.3.0: current-tier profession picks and up / down / same trend marks. 2.2.0: settings window, profession-based default list, up to 4 tickers.)
(2.1.0: move and resize in Edit Mode; new default position; no overlapping items.)

A slim stock-ticker bar for **commodity** prices on your auction house: herbs, ore, bars, stone, leather, cloth, reagents and other trade goods. It has price graphs, a lookup window and live tracking.
Built for the WoW: Forever client (`## Interface: 16001`, modern `C_AuctionHouse` API). No libraries, no dependencies.

CommodityTicker replaces **HerbTicker**. Your HerbTicker settings, bar position, lists and saved prices carry over (see "Moving from HerbTicker"), and the old `/herbticker` and `/hticker` commands still work.

## What it can and can't do

- **WoW addons can't go online.** No addon can fetch a website or web API from inside the game.
- **Real-time prices come only from your own auction house.** While the AH window is open, CommodityTicker asks for your watch list and tracked items with one `SearchForItemKeys` query, retried up to 3 times because Forever's first answer is often empty.
  - It repeats every 5 minutes by default (`/commodity interval`, 1–120).
  - It never refreshes while an item is in the Sell box, within 45 seconds of a search you made yourself, or while the AH is busy.
  - It also picks up prices from your own AH browsing.
  - It never buys, posts or does a full-AH scan.
- **With the AH closed, it shows the best data it already has:** your last AH price or the out-of-game feed, whichever is newer. The source and age are always shown, and prices older than 6 hours turn grey. It never makes up a price.
- **Optional out-of-game feed:** `tools/update_feed.py` downloads Blizzard's official auction house snapshot for **Americas Normal Horde** (Blizzard publishes a new one about once an hour). It writes **every commodity** listed there (about 400 items today, and never gear) into `Feed.lua`, plus alchemy craft outputs in a separate `craft` table (2.8.1; not shown on the ticker), which the game reads at login or `/reload`, or mid-session with **Load feed** once the feed-slot addons are installed.
  - Lookup works on items you haven't added. The ticker itself still shows only your watch list.
  - The script defaults to every 30 minutes in `--loop` mode (`--every N`, minimum 5). History is appended only when Blizzard has a fresh snapshot; a poll in between downloads nothing and does not wipe older points. Setup steps: see [Price feed setup](#price-feed-setup-blizzard-api).
  - **Personal use only.** The data comes through your own Blizzard API client; don't republish it.
- **Other addons' scans:** if Auctionator is installed and CommodityTicker has no price for an item, it uses Auctionator's. When auto-refresh is off (`/commodity auto off`), TradeSkillMaster is tried first (`dbminbuyout`, then `dbmarket`), then Auctionator, then the feed. Each call is feature-detected and wrapped in pcall.

## Install (fresh, or moving from HerbTicker)

1. **Exit the game** completely.
2. Extract the zip into `World of Warcraft\_forever_\Interface\AddOns\`. You should end up with `...\AddOns\CommodityTicker\CommodityTicker.toc`. The first run of `update_feed` also creates `CTFeed01`–`CTFeed24` next to it (leave them enabled). Fully restart WoW once so the game sees those folders.
3. **Coming from HerbTicker?** Double-click `AddOns\CommodityTicker\tools\migrate_from_herbticker.bat` (needs Python 3). It copies, and never moves or deletes:
   - `WTF\Account\<account>\SavedVariables\HerbTicker.lua` to `CommodityTicker.lua` (settings, position, lists and prices).
   - `AddOns\HerbTicker\tools\feed_state.json`, `discord.json` and `discord_state.json` into `CommodityTicker\tools\`. This keeps your feed history, your Discord webhook config, and the Discord message ID, so the same message keeps being edited.
   - It refuses to run while WoW is running and never overwrites existing CommodityTicker files.
4. **Delete the old `Interface\AddOns\HerbTicker` folder.**
5. Start the game. On the character screen, open **AddOns** and check that **CommodityTicker** is ticked. If it says "out of date", tick **Load out of date AddOns**.
6. On first login you'll see one chat line: `imported your HerbTicker settings, bar position, lists and prices`. From then on everything is saved in `CommodityTicker.lua` (as `CommodityTickerDB`).

**No Python, or skipped step 3?** Leave the HerbTicker folder in place for one login. CommodityTicker reads HerbTicker's data and then turns the old addon off: it hides the old bar, stops its events and disables it for future logins. It prints one line telling you to delete the old folder. Delete it after you log out.

Commodities only still applies after migration: if your old saved list contains a non-commodity, CommodityTicker drops it at login and prints one chat line per item.

## Lookup

- **Opening it:** use `/commodity lookup <item>` (or `/commodity l`), or `/commodity lookup` with no item to open the **lookup window**. You can also click an item on the ticker.
- **What you can type:** a name (full or partial), an item ID, or a shift-click on an item link (into chat or into the window's search box).
- **With the AH open:** it queries that one item live and adds the result to its history. If a refresh is already running, the lookup runs right after it.
- **With the AH closed:** it shows the best known price and says where it came from and how old it is, e.g. `Copper Ore: 1s 16c (Feed, 42m ago, 6289 listed)`. If nothing is known, it says `no price data yet`.
- **Window buttons:** **Track live**, **Add to ticker**, and **Check AH now** (enabled only while the AH is open).
- **Commodities only:** gear, weapons, recipes, potions and other consumables, quest items and unknown IDs are refused with one line saying why, e.g. `can't look up Fine Sword: this ticker is for commodities only (herbs, ore, bars, stone, leather, cloth, reagents and other trade goods) - it's equippable gear.`

## Graphs

- **Where they appear:**
  - Hover over an item on the ticker to see a small graph.
  - Click the item, or use `/commodity graph <item>`, to see the full graph in the lookup window.
- **One line, real points only:**
  - A point is added each time you see a price at the AH (refresh, lookup, or your own browsing) and each time the feed script writes a new price from a fresh Blizzard snapshot.
  - **Green** points are your AH observations; **blue** points are from the feed.
  - Nothing is interpolated or invented.
  - Repeated AH events for the same item within 60 seconds update the latest point instead of adding a new one.
- **Little or no history:**
  - With no points, the graph says there's no history yet.
  - With one point, it shows a dot and says there isn't enough history for a line.
- **How much is kept:** 14 days or 200 points per item, whichever is less.
- **Labels:** the highest and lowest prices, and the first and last times in **Melbourne time** (AEDT/AEST).
- **Hover (full graph, 2.7.0):** move the mouse over the lookup graph. A crosshair snaps to the nearest real point by time (never an in-between price), and a tooltip shows its Melbourne time, price, source and listed count. Each real point has a small dot. Clicks and window dragging work as before. The small hover-panel graph and ticker sparklines don't have this.
- **Feed history:** the feed keeps up to 24 earlier prices per item from previous script runs.

## Best farm right now (2.8.0)

Open it with `/commodity farm` (run it again to close it) or the **Best farm** button at the top of the settings window. `/commodity farm list` prints the top 8 to chat (`/commodity farm list 5` for 5).

- **What's listed:** every herb your Herbalism skill can pick (and ore/stone/gems or leather if you have Mining or Skinning), from the same sourced profession data and pick lists as the ticker, plus **Blue Pearl**. Tick **Current tier only** to use the ticker's current-tier rule instead (required skill within 50 of yours). Items with no price are hidden.
- **Prices:** only what's already on your PC: the out-of-game feed (Feed.lua, written by `tools/update_feed.py`) and your own AH scans, whichever is newer. Guild-shared and Auctionator prices aren't used, and nothing is fetched from the web.
- **Columns:** icon, name, price (coin icons), **24h** (current price vs the oldest real price of the same source in the last 24 hours, at least an hour older), **Sells (est.)**, and **Score**. Click any column header to sort, and click again to flip the order. Hover a header for what it means, or a row for the numbers behind it. Click a row to open its price graph.
- **Sells (est.)** is an estimate built only from real listed quantities. It adds up every fall in the listed quantity between consecutive snapshots in the last 24 hours, then divides by the hours covered and by the average listed quantity. The result is the share of the listing that disappeared per hour (e.g. `6%/h`). Feed snapshots are used when there are at least 3 of them; otherwise your own AH scans are used. The two are never mixed. A fall can be a sale, a cancel or an expiry, so this is a proxy, not a sales count. With fewer than 3 snapshots carrying a quantity, or less than 2 hours covered, it shows `-`.
- **Score** = price × sell speed, scaled so the best item on the list is 100. It's a ranking only, not gold per hour. No sell speed means no score (`-`), and those rows sort last.
- **Light:** no timers and no OnUpdate. The list is rebuilt when you open the window, press **Refresh**, tick the box, or new prices arrive while it's open. Row data is dropped when you close it.

## Live tracking

- **Start or stop:** `/commodity track <item>`, the **Track live** button in the lookup window, `/commodity untrack <item>`, or `/commodity tracked` to list them.
- **Where tracked items appear:** pinned to the front of the ticker in blue with a `>` marker, and labelled `[live]` on hover.
- **How often they update:** they are included in every AH refresh at the **same interval** (default 5 minutes). There is no separate, faster timer, and the same Sell box, 45-second and busy-AH rules apply.
- **"Live" means while the AH is open.** With the AH closed, a tracked item shows its last AH price or the feed price, with its age.

## Load feed (feed may be stale)

The game can't watch `Feed.lua` on disk. After a first full restart (so the `CTFeed01`–`CTFeed24` slot addons register), **Load feed** re-reads a copy of the file mid-session without a `/reload`. Each slot works once per session; after that, `/reload` resets them.

- **When it shows:** a small orange **Load feed** button appears at the right-hand end of the bar once the loaded feed is older than the script's interval. If `update_feed` is still running, a newer file *may* be waiting; the button can't confirm that.
- **What it does:** click it (or `/commodity loadfeed`) to load the next unused slot. If the slots aren't visible yet or have run out, `/commodity reload` falls back to a `/reload`. Add `force` to skip the freshness check.
- **When it stays hidden:** when no feed is loaded, when the feed is turned off, when the bar is hidden, or when the loaded feed is still fresh.
- **In combat:** the button is greyed out and won't load. CommodityTicker reminds you once combat ends.
- **It never reloads or loads a slot on its own.**

## Settings window (2.2.0)

Open it with `/commodity settings` (or `config`), or **right-click** any ticker (it opens on that ticker). Esc closes it.

- **Top row:** one button per ticker, plus **+ New ticker** (greyed out at 4).
- **Name / Rename / Delete ticker:** the main ticker can be renamed but not deleted (hide it instead).
- **Look:** Show this ticker, Drag to move outside Edit Mode, Mode (scroll, rotate or list), Width, Scale, Scroll speed, List rows (list mode), Reset position.
- **Lists on this ticker:** tick any mix of
  - **Profession picks (current-tier herbs/ore/leather/cloth/enchanting mats)**: see below,
  - the old **level-38** and **level-50+** presets,
  - plus anything you add yourself.
- **The item list:** your current-tier picks, then items whose skill isn't confirmed for Forever (orange), then your own items, then everything else your professions can gather or use at your skill (older tiers, recipe reagents), then the presets. Tick to put an item on this ticker; untick to take it off. Scroll with the mouse wheel or Up/Down.
- **Add commodity:** type a name or ID (or shift-click an item into the box). Gear, consumables and recipes are refused, as with `/commodity add`.

The window, Edit Mode and the slash commands all change the same saved settings, so they always agree.

## Default list: your professions (current tier only)

CommodityTicker reads your two **primary** professions and their skill at login and whenever a skill changes (it uses `GetProfessions`/`GetProfessionInfo`, or the Classic `GetSkillLineInfo` list if that's what the client has). The default main ticker ("profession picks") then shows only the trade commodities people actually track, and only your **current tier** of them:

| Your profession | Auto-added |
| --- | --- |
| Herbalism | herbs (plus Forever's Swiftthistle / Frilled Lichen bonus herbs) |
| Mining | ore, stone, smelted bars, and gems from the veins |
| Skinning | raw leather, hides and scales |
| Enchanting | dusts, essences and shards (plus Forever's Mote of Magic) |
| Tailoring | raw cloth: Linen, Wool, Silk, Mageweave, Runecloth, Felcloth |
| Alchemy, Blacksmithing, Leatherworking, Engineering | nothing automatically |

**Current tier rule:** an item is added when the skill it needs is within 50 points below your skill: `skill - 50 < required <= skill`. If nothing falls in that window (some professions have gaps), the highest tier you've unlocked is used instead: `top - 50 < required <= top`, where `top` is the highest required skill at or below yours. At skill 1 that's the starting tier.

Example, Herbalism 225 / Alchemy 225: Khadgar's Whisker, Wintersbite, Firebloom, Wildvine, Purple Lotus and Arthas' Tears (required 185-220). No Peacebloom, Earthroot or Liferoot, and no Alchemy reagents. Sungrass joins at Herbalism 230.

- **Never auto-added:** potions and other consumables, vendor-sold reagents, bolts and thread, rods and oils, Cooking/First Aid/Fishing items, crafting-profession reagents, and **unverified** items (orange in the window). You can still tick any of them in the settings window, where they're listed under your picks ("more from your professions", then the presets).
- **Skill-ups** move the window: new current-tier items are added (one chat line), and items that fall below the window drop off.
- **Items you added yourself** (ticked in the window, `/commodity add`, or the lookup window's button) stay, whatever your skill.
- **Removed items stay removed** until you tick or `add` them again.
- **Where the data comes from:** `Professions.lua`, built from the WoW: Forever profession pages on wowforevercodex.com (fetched 11 Nov 2026; URLs at the top of the file). The commodity classes (`PROF_PICKS`, at the end of the file) are hand-checked against those item IDs; no skills or items were added by hand. `/commodity profs` prints what was detected.
- **Upgrading:** if you're on the profession default, the tighter list applies at your next login. Your own items, tracked items and other tickers' lists are untouched.

## Multiple tickers

You can have up to **4** tickers, each with its own lists, position, width, scale, speed, mode and Edit Mode outline (`CommodityTicker: <name>`). New tickers start empty, 26 px below the previous default spot, so they don't stack.

- Create one in the window (**+ New ticker**) or with `/commodity bar new Herbs`.
- **Slash commands act on the picked ticker.** Pick one with `/commodity bar 2` or `/commodity bar Herbs`, or by selecting it in the window or in Edit Mode. `/commodity bars` lists them. Without picking, commands change the main ticker (the pick resets to the main ticker at login).
  - Commands that follow the pick: `add`, `remove`, `list`, `show`, `hide`, `toggle`, `lock`, `unlock`, `mode`, `speed`, `width`, `scale`, `reset`, and the lookup window's **Add to ticker** button (its tooltip names the ticker).
- **One AH refresh for all tickers:** an item on two tickers is queried once.
- **Tracked items** are pinned to the main ticker only. Hover graphs, click-to-lookup, middle-click refresh and the Reload button work on every ticker (the Reload button sits on the first visible one).

## List mode and the 2.4.0 look

All three modes share one compact info-bar look: a dark fill with a thin green border, the item icon, the item name, and the price with coin icons and a colour-coded trend percent (green `+5%`, red `5%`, yellow `0%`; blank if there is no earlier price). In list mode the percent sits in its own column so the figures line up. Uncached icons show a question mark until the game knows the item. Each ticker has its own mode. Your current tickers stay on scroll but already use the new look after a `/reload`.

- **scroll** (default): the moving tape. Each item shows icon, name, price and trend, packed with small gaps. Strings are never cut to a fixed width, so long names like "Ghost Mushroom" show in full. There are no counts or graph on the tape, to keep it readable while it moves.
- **rotate**: one item at a time, with icon, name, price, trend, a small graph, and `BAG 7  BANK 113  VALUE 13g`.
  - If the bar is too narrow, the graph is dropped first, then the counts shorten to `B7 K113 V13g`.
  - About 600 px wide shows everything for most items.
- **list**: a static list of compact one-line rows, with **BAG**, **BANK** and **VALUE** column headers. Each row shows:

  `[icon] Ghost Mushroom  [graph]  1g 8s   +5%    7   113   13g 2s`

  - **Columns are packed.** Each column is only as wide as its widest entry (or header), with the numbers right-aligned under the headers, so short names don't leave a gap. The list sizes itself to that packed width by default (no fixed default). Herbs at Herbalism 245 come out at roughly 380–420 px.
  - **Making it wider:** use the width slider, Edit Mode or `/commodity width <px>`. The extra space goes to the name column. It never gets narrower than the packed width, so nothing clips. `/commodity width auto` packs it again. The list's width is saved separately from the tape width.
  - **Rows:** alternating rows are lightly tinted.
  - **Graph:** the item's real price history. Two or more points draw a line; one point is a dot; none says `no history`.
  - **BAG / BANK / VALUE:**
    - **BAG** is what you carry.
    - **BANK** is the game's count including the bank minus your bags, so nothing is counted twice. It includes the reagent bank where the client counts it with the bank, but not the warband/account bank.
    - BAG and BANK show `-` when the count is zero. BANK shows `?` only while bank data isn't available yet (you haven't opened the bank this session, and nothing on the list has a bank count). If any item already shows a bank count, empty banks show `-`. While BANK is `?`, VALUE gets a `+` ("at least").
    - **VALUE** = (bags + bank) × the row's current unit price, in the usual money format. It's market value, not a vendor price. With no price it says `no price`. With no count API at all, BAG and BANK show `-`.
    - Counts update on bag and bank changes.
  - **Size:** the list grows to fit up to **List rows** rows (default 8, 3–30; `/commodity rows <n>`), then a slim scrollbar appears and the mouse wheel (or dragging the thumb) scrolls. The header shows e.g. `1-8/14`. In Edit Mode, drag the bottom edge to change how many rows are shown.
- **Switching:** in the settings window, the **Mode** button cycles scroll → rotate → list. Or use `/commodity mode scroll|rotate|list` (`static` and `rows` also mean list).
- **Using it:** click a row or item for the full graph and lookup; hover a list row for bags, bank, total and value spelled out; right-click for settings; middle-click to refresh at the AH. Drag (when unlocked) or use Edit Mode to move it.

## Moving and resizing (Edit Mode)

Use WoW's own Edit Mode, the same way you move the rest of your HUD:

1. Press **Esc → Edit Mode**. Each ticker gets a blue Edit Mode outline labelled **CommodityTicker: <name>** (e.g. `CommodityTicker: Main`). Hidden tickers show while Edit Mode is open so you can find them.
2. **Drag** it to move it.
3. **Click** it to select it (yellow outline) and open its settings box for that ticker:
   - **Width** (150–2000 px) and **Scale** (0.5–2), the same ranges as the slash commands. You can also drag the **yellow right-hand edge** to change the width.
   - **Show the ticker outside Edit Mode**: untick to hide it during play (same as `/commodity hide`).
   - **Allow dragging outside Edit Mode**: same as `/commodity unlock` / `lock`.
   - **Reset position** puts it back at its default spot. **Lists & more...** opens the settings window.
4. Close Edit Mode as usual. Clicking a Blizzard frame, or another addon's Edit Mode frame, deselects the ticker.

Everything is saved in the same settings the slash commands use (position, width, scale, shown), so the two always agree. The position is the same for all your Edit Mode layouts.

**Default spot:** 2.1.0 moves the default from the very top edge, where it covered top-of-screen text, to 95 px below it (between the top-centre HUD widgets and the red error and zone text). If your bar was still on the old default spot, it moves there once on first login. A position you chose yourself is never moved.

**Fallbacks:** `/commodity unlock` (then drag the bar), `/commodity width <px>`, `/commodity scale <0.5-2>`, `/commodity reset`. `/commodity editmode` tells you whether Edit Mode support is active on your client. If Edit Mode isn't available, the addon still loads and these commands work as before.

**Limitations (Forever / Blizzard):**
- Blizzard has no public way for addons to join Edit Mode's own list of systems. The ticker is movable and resizable inside Edit Mode, but it isn't a named row in Blizzard's settings, it doesn't snap to the grid, and it isn't saved per Edit Mode layout.
- Moving and resizing are blocked in combat (Edit Mode isn't used in combat anyway).

## Using the bar

- **Drag** to move it outside Edit Mode (when unlocked; `/commodity lock` stops accidental drags).
- **Trend** after every price (colour-coded percent only; no `^` / `v` arrows and no `-` / `=` signs):
  - **up**: green `+N%`
  - **down**: red `N%`
  - **unchanged**: yellow `0%`
  - **no earlier price yet**: blank (nothing is invented).

  It compares the current price with the newest **real** earlier price for that item: your own AH points first (or the feed's history for feed prices), otherwise the last different price seen, otherwise another source's earlier point. Changes under 0.5% show as `<1%`. Hover, the lookup window and chat lines show the same percent plus `(was <price>)`.
- **Hover** to pause it: you get a mini graph for the item under the mouse, or a summary table elsewhere on the bar.
- **Left-click** an item to open its graph and lookup.
- **Right-click** to open the settings window for that ticker. (It no longer cycles the level-38/level-50+ lists; use the window or `/commodity list`.)
- **Middle-click** at the AH to refresh now.

| Command | What it does |
| --- | --- |
| `/commodity`, `/ct` or `/cticker` | Help |
| `/commodity lookup <item>` (`l`, `price`) | Price check and graph; live if the AH is open |
| `/commodity graph <item>` (`g`, `history`) | Open the price graph |
| `/commodity farm` / `farm list [n]` | Best farm right now window / top n in chat |
| `/commodity track <item>`, `untrack <item>`, `tracked` | Live tracking |
| `/commodity settings` (`config`) | Open the settings window |
| `/commodity bar`, `bar <n or name>`, `bar new <name>`, `bar rename <name>`, `bar delete [n]`, `bars` | Show, pick, create, rename, delete or list tickers (up to 4) |
| `/commodity profs` | Detected professions and how many commodities they cover |
| `/commodity add <item>`, `remove <item>` | Put a commodity on the picked ticker, or take one off |
| Esc → Edit Mode | Move, resize (width and scale) and show/hide the bar |
| `/commodity editmode` | Whether Edit Mode support is active |
| `/commodity show`, `hide`, `toggle`, `lock`, `unlock` | Bar visibility; lock/unlock = dragging outside Edit Mode |
| `/commodity scan` | Refresh now (the AH must be open) |
| `/commodity auto on` or `off` | Automatic refresh while the AH is open |
| `/commodity interval 5` | Minutes between refreshes (1–120, default 5) |
| `/commodity list` | What the picked ticker shows |
| `/commodity list profession`, `now`, `later`, `both`, `custom` (combine with `+`) | Set the picked ticker's lists, e.g. `list profession+now` |
| `/commodity mode scroll`, `rotate` or `list` (`static`, `rows`), `rows 8`, `speed 10`, `width 760`, `scale 1` | Bar look (width and scale are also in Edit Mode) |
| `/commodity feed on` or `off` | Use or ignore `Feed.lua` |
| `/commodity arrows on` or `off` | Leftover command; trend is a colour-coded percent only |
| `/commodity loadfeed` | Re-read the on-disk feed mid-session (no `/reload`) |
| `/commodity reload` (`force`) | Try loadfeed first, then `/reload` if the feed may be stale |
| `/commodity status`, `prices`, `reset`, `clear`, `version` | Status, print prices, reset position, forget saved prices, version |
| `/herbticker ...` or `/hticker ...` | Old HerbTicker names; they run the same commands |

## Commodities only

`add`, `lookup`, `graph` and `track` accept only stackable trade goods and reagents that can't be equipped. Items on the presets and in `Professions.lua` are always accepted.

If the game hasn't cached an item yet, it's accepted only when the commodity feed lists it. Everything else is refused, with one line giving the reason.

## Preset lists (edit `Data.lua` to change)

- **now (level 38):** Blue Pearl, Grave Moss, Wintersbite, Firebloom, Goldthorn, Liferoot, Purple Lotus, Fadeleaf, Khadgar's Whisker, Wildvine, Kingsblood, Frilled Lichen, Rosecap, Iron Bar, Black Vitriol
- **later (level 50+):** Black Lotus, Stranglevine, Icecap, Plaguebloom, Mountain Silversage, Ghost Mushroom, Dreamfoil, Gromsblood, Golden Sansam, Death Lotus, Demonsage, Marefoil

## Limitations (2.4.0)

- **List mode:**
  - Bank counts depend on what the client has cached (see List mode).
  - The count APIs are feature-detected: `C_Item.GetItemCount`, falling back to `GetItemCount(item, includeBank)`. If neither exists the row says `counts n/a`.
  - Edit Mode changes width and scale. In list mode, width is the list width and never goes below the packed width. The list's height comes from the **List rows** setting, not from dragging.
  - Column widths are measured from the game's own text widths. Right after login a width can be an estimate for a moment, and it's re-measured shortly after.
  - Each visible row redraws its graph when prices or counts change. Keep the row count modest on slow PCs.
- **Updating:** 2.5.0 adds no new files, so on top of 2.3.0 or later a `/reload` is enough.

- **Profession detection** depends on the client's API. If neither `GetProfessions` nor `GetSkillLineInfo` answers, the window says profession info isn't available, the profession list is empty, and the presets and your own items still work. Skill may read 0 for a few seconds after login; it's re-read 3 s later and on every skill change.
- **Tiers** come from the sourced skill numbers: the vein/herb/beast skill for gathering, and the lowest recipe that uses an item for enchanting mats and cloth. A 50-point window is a simple rule; it isn't a measure of what sells.
- **Trend** compares real saved points only. An item seen once, or only on a fresh feed with no history, has no percent. The figure is a colour-coded percent, with no `^` / `v` / `-` / `=` marks.
- **Data is a snapshot** of Forever's profession pages on 11 Nov 2026. Forever changes (new herbs, moved skills) need a new `Professions.lua`. Unverified items are never auto-added.
- **Edit Mode:** each ticker is movable/resizable in Edit Mode but isn't a row in Blizzard's own list, doesn't snap, and isn't saved per layout (see above).
- **New files:** 2.2.0 added `Professions.lua`, `Lists.lua` and `Settings.lua`; 2.3.0 adds none. Coming from 2.1 or older, **exit and restart WoW** after installing (the game only loads new addon files at startup). From 2.2.0, logging out to the character screen or a full restart is safest; `/reload` also picks up changed files.
- Settings are account-wide (like the bar position before); your professions are read for whichever character is logged in.

## Notes

- **Saved data:** `WTF\Account\<account>\SavedVariables\CommodityTicker.lua`, separately for each realm and faction. The game writes it at logout or `/reload`.
- **Prices** are the **lowest buyout per unit**. **Change %** compares each price with the previous different price seen.
- **Browse list:** a refresh at the AH replaces what Blizzard's Browse list is showing. If that gets in the way, use `/commodity auto off` and run `/commodity scan` when you want a refresh.

## Price feed setup (Blizzard API)

The feed script talks to Blizzard's official Game Data API with your own free API client. It takes about two minutes:

1. Sign in at the [Blizzard developer portal](https://develop.battle.net/access/clients) with your Battle.net account and click **Create Client**. Any name works (e.g. "CommodityTicker"). Leave the redirect URL blank and tick "I do not have a service URL".
2. In `CommodityTicker\tools\`, copy `blizzard.json.example` to `blizzard.json`.
3. Open `blizzard.json` in Notepad and replace `PASTE_YOUR_CLIENT_ID_HERE` and `PASTE_YOUR_CLIENT_SECRET_HERE` with the **Client ID** and **Client Secret** from the portal. Save it.
4. Double-click `tools\start_feed.bat` (or `update_feed.bat` for a single update).

**Which auction house:** the defaults are right for Australian Forever realms on the Normal ruleset, Horde side: `"region": "us"` (Oceanic realms are in Blizzard's Americas region), `"ruleset_id": 2` (Normal) and `"auction_house_id": 114` (Americas Normal Horde). Forever has one auction house per ruleset and faction, shared by every realm in the region, so there's no realm ID to set. For Alliance use 111, for Blackwater 117. You can also set `"faction"` and leave out `"auction_house_id"`, or pass `--faction`, `--auction-house`, `--region` or `--ruleset` on the command line.

**Keep the secret secret.** `blizzard.json`, the cached sign-in token (`blizzard_token.json`) and the item cache (`item_cache.json`) stay on your PC and are listed in `.gitignore`. Never share, upload or commit them. If the secret leaks, open the client on the developer portal and generate a new one. `BLIZZARD_CLIENT_ID` and `BLIZZARD_CLIENT_SECRET` environment variables work too and override the file.

**How often:** Blizzard publishes a new snapshot about once an hour. Each poll asks "anything newer than the last one?", so polls in between download nothing, and a history point is only added for a genuinely new snapshot. The first run also downloads Blizzard's item list once (names and item classes, refreshed weekly) so that only commodities (Trade Goods and Reagents) reach the ticker.

**Prices:** `min` is the cheapest buyout per unit. `market` is the quantity-weighted average of the cheapest 25% of listed units, ignoring units priced over 1.5x that first estimate. `qty` is every unit listed with a buyout. Bid-only auctions are ignored.

## Discord (optional)

The Windows script can post your **watch list** prices into a **private** Discord channel through a channel webhook, editing one message in place. The in-game addon doesn't use any of this.

1. **Create a webhook.** In your private server, open Channel Settings → Integrations → Webhooks → New Webhook, then click **Copy Webhook URL**.
2. **Save the URL.** In `CommodityTicker\tools\`, copy `discord.json.example` to `discord.json`. Replace `PASTE_YOUR_DISCORD_WEBHOOK_URL_HERE` with your URL. Set `"lists"` to `"now"`, `"later"` or `"both"`.
   - You can also pass `--webhook`, or set `COMMODITYTICKER_DISCORD_WEBHOOK`. The old `HERBTICKER_DISCORD_WEBHOOK` variable still works.
   - If you ran the migration script, your old `discord.json` was copied for you.
3. **Preview it.** `tools\test_discord.bat` prints the message and posts nothing.
4. **Post it.** `tools\post_discord.bat` posts or edits from the `Feed.lua` already on disk, without downloading.
5. **Keep it updated.** Every successful `update_feed.bat` run also updates Discord. Use `update_feed.bat --loop` for updates every 30 minutes (or `--every 5`).

**Keep the webhook secret.** `discord.json` and `discord_state.json` stay on your PC. Never share, upload or commit them: anyone with the URL can post in your channel. If the URL leaks, delete the webhook in Discord and make a new one.

**What the message shows:**
- One embed titled "CommodityTicker · Americas Normal Horde", listing only your watch list, not the whole feed.
- For each item: the lowest buyout per unit, the ▲/▼ change against the previous different price, and the quantity listed.
- When the prices were taken, fetched and updated, in Melbourne time.
- "not in feed" or "none listed" where that applies.

**Edit-in-place:**
- The message ID is saved in `discord_state.json`, and later runs edit that same message.
- If you delete the message, the next run posts a new one.
- Nothing is posted when the download fails, Blizzard hasn't published a new snapshot yet, or the update was skipped by the 30-minute gap.
- With no webhook configured, the updater just writes `Feed.lua`.

**Personal use only.** Keep it in your own private channel. Don't run a public price bot, and don't republish the auction data.

**Troubleshooting:**
- **"no webhook configured":** `discord.json` is missing or still has the placeholder.
- **"doesn't look like https://discord.com/api/webhooks/...":** re-copy the full URL.
- **"webhook was deleted or is invalid":** make a new webhook.
- **"editing failed ... not posting a duplicate":** a temporary Discord problem; the next run retries.
- **Wrong times:** check your PC clock.

| Command (in `CommodityTicker\tools`) | What it does |
| --- | --- |
| `update_feed.bat` | Fetch prices, write `Feed.lua`, update Discord if a webhook is set |
| `update_feed.bat --loop` (`--every 5`) | Repeat every 30 minutes (or every N, minimum 5). History is appended, not wiped. |
| `update_feed.bat --no-discord` | Fetch without posting this time |
| `post_discord.bat` | Post or edit Discord from the current `Feed.lua`, no fetch |
| `test_discord.bat` | Print the Discord message without sending (dry run) |
| `migrate_from_herbticker.bat` | One-time copy of HerbTicker saved data and tools config (game closed) |
