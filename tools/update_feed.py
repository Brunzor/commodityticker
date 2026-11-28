#!/usr/bin/env python3
"""CommodityTicker feed updater (optional, runs OUTSIDE the game).

WoW addons cannot make web requests, so this script downloads one auction
house snapshot from Blizzard's official Game Data API (WoW Forever, published
about once an hour), keeps only COMMODITIES (herbs, pearls and other trade
goods, ore, bars, stone, leather, cloth, enchanting/elemental mats, engineering
parts, cooking mats, reagents - never gear, weapons, recipes or quest items).
Alchemy recipe outputs up to skill 300 (potions, elixirs, flasks, the
Philosopher's Stone, and other craft products) are stored in a separate `craft`
table so they are not treated as commodities. Keeps up to 30 days of real price history per item in feed_state.json,
writes a downsampled history into ../Feed.lua (all points from the last
two days, hourly back to 14 days, then one point every four hours), The game reads that file at login or /reload,
and can also re-read a copied slot mid-session via /commodity loadfeed.

Setup: create a free API client at https://develop.battle.net/access/clients,
copy tools/blizzard.json.example to tools/blizzard.json and paste in the client
ID and secret (or set BLIZZARD_CLIENT_ID / BLIZZARD_CLIENT_SECRET). blizzard.json
is git-ignored - never share it.

Each poll asks Blizzard "has the snapshot changed since <last one>?"
(If-Modified-Since), so polls between hourly snapshots usually download nothing.
If the watch list has gained items that are not in the last snapshot, the current
snapshot is downloaded anyway and Feed.lua is rewritten so those items are priced
straight away. History in feed_state.json is kept and only gets a new point when
Blizzard publishes a fresh snapshot - a poll does not wipe old prices, and a
rewrite for new watch-list items does not invent earlier points.
A change to the history-export policy also rewrites Feed.lua from the
current snapshot (no extra history point) so a longer history is picked up.

  python update_feed.py                      # one update, Americas Normal Horde
  python update_feed.py --loop               # update every 30 min until Ctrl+C
  python update_feed.py --loop --every 5     # every 5 min (minimum); saved for later runs
  python update_feed.py --faction Alliance   # or --auction-house 111, --region eu, --ruleset 1

Optional Discord ticker (see README "Discord"): put a channel webhook URL in
tools/discord.json, then every successful update also edits one message there
(watch list only, not the whole commodity table).

  python update_feed.py --discord            # post/edit from the current Feed.lua, no fetch
  python update_feed.py --discord --dry-run  # print the Discord message, send nothing
  python update_feed.py --loop --lists both  # repeating updates, Discord shows both lists
"""
import argparse, base64, gzip, hashlib, json, os, re, sys, time, urllib.error, urllib.parse, urllib.request
from email.utils import formatdate, parsedate_to_datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import commodityticker_discord as discord

FEED_SCRIPT_VERSION = "3.0.2"   # 3.0.2: 30-day history in feed_state; Feed.lua writes 30 days, downsampled
                                 # 3.0.1: rewrite Feed.lua from the current snapshot when the watch list gains items
                                 # 3.0.0: Blizzard Game Data API instead of a third-party price page
HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.dirname(HERE)
FEED = os.path.join(ADDON, "Feed.lua")
STATE = os.path.join(HERE, "feed_state.json")
DATA = os.path.join(ADDON, "Data.lua")
CONFIG = os.path.join(HERE, "blizzard.json")             # git-ignored: client id/secret + market
TOKEN_CACHE = os.path.join(HERE, "blizzard_token.json")  # git-ignored: OAuth token until it expires
ITEM_CACHE = os.path.join(HERE, "item_cache.json")       # git-ignored: item names + classes
DEFAULT_EVERY = 30  # minutes
MIN_EVERY = 5       # minutes; do not poll more often than this
UA = f"CommodityTicker-feed/{FEED_SCRIPT_VERSION} (personal WoW Forever addon)"

OAUTH_URL = "https://oauth.battle.net/token"
API_HOST = "https://{region}.api.blizzard.com"
REGIONS = ("us", "eu", "kr", "tw")   # Oceanic (AU/NZ) realms are in the US (Americas) region
# WoW Forever has no connected realms: each ruleset has its own region-wide auction houses.
RULESET_NAMES = {1: "pvp", 2: "normal", 3: "rp", 15: "rppvp"}
# Auction house ids per ruleset and faction (US region). The API names each house only
# "Horde Auction House" etc., so these come from matching real prices:
#   Normal 111/114/117 confirmed (114 = Americas Normal Horde, matched against real Horde AH prices),
#   PvP 110/113/116 (the other large group). Anything else: set auction_house_id yourself.
KNOWN_HOUSES = {
    ("us", 2): {"alliance": 111, "horde": 114, "blackwater": 117},
    ("us", 1): {"alliance": 110, "horde": 113, "blackwater": 116},
}
DEFAULTS = {"region": "us", "ruleset_id": 2, "faction": "Horde", "auction_house_id": None}
ENV = {"client_id": "BLIZZARD_CLIENT_ID", "client_secret": "BLIZZARD_CLIENT_SECRET", "region": "BLIZZARD_REGION",
       "ruleset_id": "BLIZZARD_RULESET_ID", "faction": "BLIZZARD_FACTION", "auction_house_id": "BLIZZARD_AUCTION_HOUSE_ID"}
STALE_304_AFTER = 2 * 3600   # if the last snapshot is older than this, ask without If-Modified-Since
ITEM_CLASSES_MAX_AGE = 7 * 86400

# Blizzard item classes that are AH commodities / crafting materials:
# class 7 Trade Goods (1 Parts, 5 Cloth, 6 Leather, 7 Metal & Stone, 8 Cooking, 9 Herb,
# 10 Elemental, 11 Other - gems, pearls, venom sacs..., 12 Enchanting) and class 5 Reagent.
# Left out of items: 0 Consumable, 1 Container, 2 Weapon, 4 Armor, 6 Projectile, 9 Recipe,
# 11 Quiver, 12 Quest, 13 Key, 15 Miscellaneous. Consumable alchemy outputs are still
# captured, but only in the craft table (see ALCHEMY_OUTPUTS).
COMMODITY_CLASSES = (7, 5)
HISTORY_DAYS = 30        # kept in feed_state.json (same window as the addon)
HISTORY_POINTS = 1000    # safety cap after the time window; 30 days of hourly snapshots is 720
FEED_HISTORY_DAYS = 30   # earlier points written into Feed.lua, downsampled to keep the file small
FEED_FULL_SECONDS = 2 * 86400     # last two days: every snapshot
FEED_HOURLY_SECONDS = 14 * 86400  # then one point per hour through 14 days
FEED_LONG_BUCKET = 4 * 3600       # then one point per four hours through 30 days
HIST_POLICY = "30d-2full-14h-4h"  # bump when the Feed.lua history export changes
# Market price: quantity-weighted mean of the cheapest 25% of listed units, ignoring
# units priced over 1.5x that first estimate (one silly listing can't skew it).
MARKET_SHARE = 0.25
OUTLIER_FACTOR = 1.5

# Alchemy recipe products at skill <= 300, from wowforevercodex.com (11 Nov 2026),
# reagents checked against Wowhead Forever tooltips (12 Nov 2026). At write time,
# those already in a commodity category stay in `items`; the rest (potions,
# elixirs, flasks, Philosopher's Stone, ...) go in `craft` and are kept off the ticker.
ALCHEMY_OUTPUTS = frozenset({
    2454, 2455, 2456, 2457, 2458, 2459, 3382, 3383, 3384, 3385,
    3386, 3387, 3388, 3389, 3390, 3391, 3577, 3823, 3824, 3825,
    3826, 3827, 3828, 3829, 4596, 4623, 5631, 5633, 5634, 5996,
    5997, 6037, 6048, 6049, 6050, 6051, 6052, 6149, 6370, 6371,
    6372, 6373, 6662, 7068, 7076, 7078, 7080, 7082, 8949, 8951,
    8956, 9030, 9036, 9061, 9088, 9144, 9149, 9154, 9155, 9172,
    9179, 9187, 9197, 9206, 9210, 9224, 9233, 9264, 10592, 12190,
    12360, 12803, 12808, 13423, 13442, 13443, 13444, 13445, 13447, 13452,
    13453, 13454, 13455, 13456, 13457, 13458, 13459, 13460, 13461, 13462,
    13503, 13506, 13510, 13511, 13512, 13513, 17708, 18253, 18294, 20002,
    20004, 20007, 20008, 21546, 246948, 247239, 247240, 247241, 247242, 247754,
    247755, 249409, 249410, 249430, 249431, 250327, 250328, 250329, 250330, 250331,
    250332, 250333, 250334, 250335, 250336, 250337, 250338, 250339, 250340, 250341,
    250342, 250343, 250344, 250345, 250346, 250347, 250348, 250349, 250350, 250351,
    250353, 250354, 250932, 250933, 250934, 250935, 250936, 250937, 250938, 250939,
    250940, 250941, 250942, 250943, 250944, 250945, 250946, 250947, 250948, 250949,
    250950, 250951, 250953, 250954, 250955, 251290, 274273, 274274, 274275, 274276,
    279956, 279970, 279990,
})
# Essence of Air: a commodity (elemental) and a transmute product. Force it into
# `items` even if Blizzard's item data gives it an unexpected class.
EXTRA_COMMODITY_IDS = frozenset({7082})


class FeedError(Exception):
    """A problem worth one clear line on the console (bad config, API refused, ...)."""


def load_json(path, default):
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return default
    return default


def save_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, separators=(",", ":"))
    os.replace(tmp, path)


def load_state():
    return load_json(STATE, {})


def save_state(state):
    save_json(STATE, state)


def clamp_every(n):
    try:
        n = int(n)
    except (TypeError, ValueError):
        n = DEFAULT_EVERY
    return max(MIN_EVERY, n)


def watched_ids():
    with open(DATA, encoding="utf-8") as f:
        return {int(x) for x in re.findall(r"id\s*=\s*(\d+)", f.read())}


# ------------------------------------------------------------------ config
def _placeholder(v):
    s = str(v or "").strip()
    return not s or s.upper().startswith("PASTE") or s.lower().startswith("your")


def load_config(overrides=None):
    """tools/blizzard.json, then BLIZZARD_* environment variables, then command-line overrides."""
    cfg = dict(DEFAULTS)
    file_cfg = load_json(CONFIG, {})
    if not isinstance(file_cfg, dict):
        raise FeedError("tools/blizzard.json isn't valid JSON - copy blizzard.json.example again")
    for k, v in file_cfg.items():
        if k in ENV and not _placeholder(v):
            cfg[k] = v
    for k, var in ENV.items():
        if os.environ.get(var):
            cfg[k] = os.environ[var]
    for k, v in (overrides or {}).items():
        if v is not None:
            cfg[k] = v
    cfg["region"] = str(cfg["region"]).lower()
    if cfg["region"] not in REGIONS:
        raise FeedError(f"region must be one of {', '.join(REGIONS)} (Australian realms use us)")
    try:
        cfg["ruleset_id"] = int(cfg["ruleset_id"])
    except (TypeError, ValueError):
        raise FeedError("ruleset_id must be a number (2 = Normal)")
    cfg["faction"] = str(cfg.get("faction") or "Horde").capitalize()
    ah = cfg.get("auction_house_id")
    if ah in (None, ""):
        ah = KNOWN_HOUSES.get((cfg["region"], cfg["ruleset_id"]), {}).get(cfg["faction"].lower())
        if ah is None:
            raise FeedError("set auction_house_id in tools/blizzard.json for this region/ruleset/faction")
        cfg["custom_house"] = False
    else:
        cfg["custom_house"] = int(ah) != KNOWN_HOUSES.get((cfg["region"], cfg["ruleset_id"]), {}).get(cfg["faction"].lower())
    cfg["auction_house_id"] = int(ah)
    return cfg


def market_key(cfg):
    """e.g. us-normal-horde; history in feed_state.json is kept per market."""
    rules = RULESET_NAMES.get(cfg["ruleset_id"], f"ruleset{cfg['ruleset_id']}")
    key = f"{cfg['region']}-{rules}-{cfg['faction'].lower()}"
    return key + f"-ah{cfg['auction_house_id']}" if cfg.get("custom_house") else key


def market_label(cfg):
    region = {"us": "Americas", "eu": "Europe", "kr": "Korea", "tw": "Taiwan"}[cfg["region"]]
    rules = {1: "PvP", 2: "Normal", 3: "RP", 15: "RP-PvP"}.get(cfg["ruleset_id"], f"ruleset {cfg['ruleset_id']}")
    return f"{region} {rules} {cfg['faction']} (auction house {cfg['auction_house_id']})"


def auctions_url(cfg, suffix=""):
    """Public endpoint URL without any token (safe to write into Feed.lua)."""
    return (API_HOST.format(region=cfg["region"]) + f"/data/wow/ruleset/{cfg['ruleset_id']}/auctions/"
            f"{cfg['auction_house_id']}{suffix}?namespace=dynamic-forever-{cfg['region']}")


# ------------------------------------------------------------------ HTTP / API
def http_request(method, url, headers, data=None, timeout=120):
    """(status, headers dict lower-cased, body bytes). 304 and HTTP errors are returned, not raised."""
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read()
            hdrs = {k.lower(): v for k, v in r.headers.items()}
            status = r.status
    except urllib.error.HTTPError as e:
        hdrs = {k.lower(): v for k, v in (e.headers or {}).items()}
        body, status = e.read() or b"", e.code
    if body[:2] == b"\x1f\x8b":
        body = gzip.decompress(body)
    return status, hdrs, body


class Blizzard:
    """Minimal Game Data API client. The secret only ever goes into the OAuth request."""

    def __init__(self, cfg):
        self.cfg = cfg
        if _placeholder(cfg.get("client_id")) or _placeholder(cfg.get("client_secret")):
            raise FeedError("no Blizzard API client set up - copy tools/blizzard.json.example to "
                            "tools/blizzard.json and paste in your client ID and secret (see README)")
        # The cache is tied to the client id (hashed, so the id itself isn't written down).
        self.client_tag = hashlib.sha256(str(cfg["client_id"]).encode()).hexdigest()[:16]
        self._token, self._expires = None, 0

    def token(self, fresh=False):
        now = time.time()
        if not fresh and self._token and now < self._expires - 300:
            return self._token
        if not fresh:
            c = load_json(TOKEN_CACHE, {})
            if c.get("client") == self.client_tag and now < c.get("expires_at", 0) - 300 and c.get("access_token"):
                self._token, self._expires = c["access_token"], c["expires_at"]
                return self._token
        basic = base64.b64encode(f"{self.cfg['client_id']}:{self.cfg['client_secret']}".encode()).decode()
        status, _, body = http_request("POST", OAUTH_URL, {
            "Authorization": "Basic " + basic, "Content-Type": "application/x-www-form-urlencoded", "User-Agent": UA,
        }, data=b"grant_type=client_credentials", timeout=30)
        if status in (400, 401):
            raise FeedError("Blizzard refused the client ID/secret (check tools/blizzard.json)")
        if status != 200:
            raise FeedError(f"Blizzard sign-in failed (HTTP {status})")
        tok = json.loads(body)
        self._token, self._expires = tok["access_token"], now + int(tok.get("expires_in", 3600))
        try:
            save_json(TOKEN_CACHE, {"client": self.client_tag, "access_token": self._token, "expires_at": self._expires})
            os.chmod(TOKEN_CACHE, 0o600)
        except OSError:
            pass  # memory-only is fine
        return self._token

    def get(self, path, namespace, params=None, if_modified_since=None):
        """(status, json or None, Last-Modified). 304 -> (304, None, lm)."""
        q = {"namespace": namespace, "locale": "en_US"}
        q.update(params or {})
        url = API_HOST.format(region=self.cfg["region"]) + path + "?" + urllib.parse.urlencode(q)
        for attempt in (0, 1):
            headers = {"Authorization": "Bearer " + self.token(fresh=attempt == 1), "Accept-Encoding": "gzip",
                       "Cache-Control": "no-cache", "User-Agent": UA}
            if if_modified_since:
                headers["If-Modified-Since"] = if_modified_since
            status, hdrs, body = http_request("GET", url, headers)
            if status == 401 and attempt == 0:
                continue  # token expired early: get a fresh one once
            break
        lm = hdrs.get("last-modified")
        if status == 304:
            return 304, None, lm
        if status != 200:
            raise FeedError(f"Blizzard API returned HTTP {status} for {path}")
        try:
            return 200, json.loads(body), lm
        except ValueError:
            raise FeedError(f"Blizzard API sent something unreadable for {path}")


def _ts(lm):
    try:
        return int(parsedate_to_datetime(lm).timestamp())
    except (TypeError, ValueError):
        return None


def _name(v):
    if isinstance(v, dict):
        return v.get("en_US") or v.get("en_GB") or next(iter(v.values()), "")
    return v or ""


# ------------------------------------------------------------------ prices
def summarize(auctions, commodities=()):
    """item id -> {min, market, qty} in copper per unit, from buyout (per-stack) and unit_price listings.

    Bid-only auctions are ignored (no buyout = no price). min is the cheapest unit,
    qty the total listed units, market as described at MARKET_SHARE."""
    units = {}
    for a in auctions or ():
        buyout = a.get("buyout")
        item = (a.get("item") or {}).get("id")
        if not buyout or not item:
            continue
        q = max(1, int(a.get("quantity") or 1))
        units.setdefault(item, []).append((buyout // q, q))
    for c in commodities or ():
        price = c.get("unit_price")
        item = (c.get("item") or {}).get("id")
        if not price or not item:
            continue
        units.setdefault(item, []).append((int(price), max(1, int(c.get("quantity") or 1))))
    out = {}
    for item, lst in units.items():
        lst.sort()
        total = sum(q for _, q in lst)
        want = max(1, int(total * MARKET_SHARE))
        picked, n = [], 0
        for price, q in lst:
            take = min(q, want - n)
            picked.append((price, take))
            n += take
            if n >= want:
                break
        est = sum(p * q for p, q in picked) / n
        kept = [(p, q) for p, q in picked if p <= est * OUTLIER_FACTOR] or picked
        market = int(round(sum(p * q for p, q in kept) / sum(q for _, q in kept)))
        out[item] = {"min": lst[0][0], "market": market, "qty": total}
    return out


def new_watched_ids(state, watched):
    """Watch-list ids added since Feed.lua was last written.

    Unlisted watch-list items are not treated as new on every poll: only a change
    to Data.lua (or a state file from before this field existed) triggers a rewrite.
    """
    prev = set(state.get("watched") or [])
    return [i for i in sorted(watched) if i not in prev]


def fetch_snapshot(api, cfg, state, refresh=False):
    """Newest snapshot for the configured house, or None when Blizzard hasn't published a new one.

    refresh=True downloads the current snapshot even if Last-Modified is unchanged, so
    newly added watch-list items, or a history-export policy change, can be written into Feed.lua straight away.
    """
    ns = f"dynamic-forever-{cfg['region']}"
    path = f"/data/wow/ruleset/{cfg['ruleset_id']}/auctions/{cfg['auction_house_id']}"
    same_market = state.get("market") == market_key(cfg)
    ims = state.get("lm") if same_market else None
    # Blizzard's cache has been seen answering 304 after a new snapshot was out; past
    # two hours we ask unconditionally and compare Last-Modified ourselves.
    if ims and time.time() - (_ts(ims) or 0) > STALE_304_AFTER:
        ims = None
    if refresh:
        ims = None
    status, auctions, lm = api.get(path, ns, if_modified_since=ims)
    if status == 304:
        return None
    updated = _ts(lm) or int(time.time())
    if same_market and lm and lm == state.get("lm") and not refresh:
        return None
    _, comm, _ = api.get(path + "/commodities", ns)
    rows = summarize((auctions or {}).get("auctions") or [], (comm or {}).get("auctions") or [])
    if not rows:
        raise FeedError("the auction house snapshot was empty - check auction_house_id")
    return {"updated": updated, "lm": lm, "rows": rows}


# ------------------------------------------------------------------ item classes / names
def load_items(api, need_ids, now=None):
    """Item id -> {n, c} (name, class). Commodity classes come from the item search (a few
    requests, refreshed weekly); other ids we care about are looked up one by one, once."""
    now = now or time.time()
    cache = load_json(ITEM_CACHE, {})
    if cache.get("v") != 1:
        cache = {"v": 1, "classes_at": 0, "items": {}}
    items = cache["items"]
    ns = f"static-forever-{api.cfg['region']}"
    changed = False
    if now - cache.get("classes_at", 0) > ITEM_CLASSES_MAX_AGE:
        for cls in COMMODITY_CLASSES:
            page = 1
            while True:
                _, res, _ = api.get("/data/wow/search/item", ns, {"item_class.id": cls, "orderby": "id",
                                                                 "_pageSize": 1000, "_page": page})
                for r in res.get("results", []):
                    d = r.get("data") or {}
                    if "id" in d:
                        items[str(d["id"])] = {"n": _name(d.get("name")), "c": (d.get("item_class") or {}).get("id", cls)}
                if page >= int(res.get("pageCount") or 1):
                    break
                page += 1
        cache["classes_at"] = int(now)
        changed = True
    def lookup(i):
        try:
            _, d, _ = api.get(f"/data/wow/item/{i}", ns)
        except FeedError:
            return i, {"n": "", "c": None}  # Blizzard doesn't know it: never a commodity by class
        except OSError:
            return i, None                  # network hiccup: try again next snapshot
        return i, {"n": _name(d.get("name")), "c": (d.get("item_class") or {}).get("id")}

    missing = sorted(i for i in need_ids if str(i) not in items)
    if missing:
        api.token()  # sign in once before the parallel lookups
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=4) as pool:   # well under Blizzard's 100 requests/second
            for i, info in pool.map(lookup, missing):
                if info:
                    items[str(i)] = info
                    changed = True
    if changed:
        save_json(ITEM_CACHE, cache)
    return {int(k): v for k, v in items.items()}


def commodities(rows, watched, info):
    """Commodity rows only (plus watch-list items, which are hand-checked commodities)."""
    return {i: r for i, r in rows.items()
            if (info.get(i, {}).get("c") in COMMODITY_CLASSES) or i in watched or i in EXTRA_COMMODITY_IDS}


def craft_outputs(rows, commodity_ids):
    """Alchemy outputs that are not already commodities (potions, elixirs, flasks, ...)."""
    return {i: r for i, r in rows.items() if i in ALCHEMY_OUTPUTS and i not in commodity_ids}


# ------------------------------------------------------------------ Feed.lua
def lua_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'


def downsample_for_feed(hist, updated):
    """Earlier points for Feed.lua: full resolution for 2 days, hourly to 14, then 4-hourly."""
    cutoff = updated - FEED_HISTORY_DAYS * 86400
    full_after = updated - FEED_FULL_SECONDS
    hourly_after = updated - FEED_HOURLY_SECONDS
    out = []
    last_key = None
    last_i = None
    for row in hist:
        t = row[0]
        if t < cutoff or t >= updated:
            continue
        if t >= full_after:
            out.append(row)
            last_key = None
            continue
        width = 3600 if t >= hourly_after else FEED_LONG_BUCKET
        key = (width, (t // width) * width)
        if key != last_key:
            out.append(row)
            last_key = key
            last_i = len(out) - 1
        else:
            out[last_i] = row
    return out


def history_string(hist, updated):
    """Earlier real points as 'minutesBefore:price:qty,...' (the current price is min/qty)."""
    earlier = downsample_for_feed(hist, updated)
    return ",".join(f"{(updated - t) // 60}:{p}:{'' if q is None else q}" for t, p, q in earlier)


def item_line(item, v):
    prev = f",prevMin={v['prevMin']}" if v.get("prevMin") else ""
    h = f",h={lua_str(v['h'])}" if v.get("h") else ""
    return f"[{item}]={{n={lua_str(v['name'])},min={v['min']},market={v['market']},qty={v['qty']}{prev}{h}}},"


def write_feed(market, faction, label, url, updated, items, every_min, craft=None):
    craft = craft or {}
    out = [
        "-- Written by tools/update_feed.py - do not edit. Data: Blizzard Game Data API (WoW Forever auction house).",
        "-- items: commodities only. craft: alchemy outputs up to skill 300 (potions, elixirs, flasks,",
        "-- Philosopher's Stone, ...) for flip pricing; the ticker never reads this table.",
        "-- Personal use only. n=name, h=earlier points (minutes before 'updated':price:qty).",
        "CommodityTickerFeed = {",
        f"  source = {lua_str('Blizzard API')}, market = {lua_str(market)}, faction = {lua_str(faction)},",
        f"  label = {lua_str(label or market)}, url = {lua_str(url)},",
        f"  updated = {updated}, fetched = {int(time.time())}, every = {every_min}, -- every: script interval (min)",
        "  items = {",
    ]
    for item in sorted(items):
        out.append(item_line(item, items[item]))
    out.append("  },")
    out.append("  craft = {")
    for item in sorted(craft):
        out.append(item_line(item, craft[item]))
    out += ["  },", "}", ""]
    tmp = FEED + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out))
    os.replace(tmp, FEED)


def sync_slots():
    """Copy the current Feed.lua into CTFeed01..24 so a mid-session load sees the same snapshot."""
    try:
        import feed_slots
        if os.path.isfile(FEED):
            feed_slots.sync_from_feed(FEED)
    except Exception as e:
        print(f"Feed slots not updated: {e}")


def update(cfg, force=False, every_min=DEFAULT_EVERY, api=None):
    state = load_state()
    market = market_key(cfg)
    every_min = clamp_every(every_min)
    last = state.get("fetched", 0)
    gap = every_min * 60
    watched = watched_ids()
    same = state.get("market") == market
    missing = new_watched_ids(state, watched) if same else []
    policy_stale = same and state.get("hist_policy") != HIST_POLICY
    rewrite = bool(missing) or policy_stale
    if not force and not rewrite and time.time() - last < gap and same:
        if state.get("every") != every_min:
            state["every"] = every_min
            save_state(state)
        print(f"Skipped: last check was {int((time.time() - last) / 60)} min ago (minimum gap {every_min} min).")
        sync_slots()
        return False
    api = api or Blizzard(cfg)
    if missing:
        print(f"Watch list has {len(missing)} new item(s) not in the last snapshot; "
              f"rewriting Feed.lua from the current auction house data.")
    elif policy_stale:
        print("History export policy changed; rewriting Feed.lua from the current auction house data.")
    snap = fetch_snapshot(api, cfg, state, refresh=bool(rewrite))
    if snap is None:
        state["fetched"], state["every"] = int(time.time()), every_min
        save_state(state)
        when = discord.fmt_melbourne(state["updated"]) if state.get("updated") else "unknown"
        print(f"No new auction house snapshot yet (latest is from {when}). Feed.lua left as it was.")
        sync_slots()
        return False
    rows, updated = snap["rows"], snap["updated"]
    info = load_items(api, (watched | EXTRA_COMMODITY_IDS | ALCHEMY_OUTPUTS) & set(rows))
    for i, r in rows.items():
        r["name"] = info.get(i, {}).get("n") or f"item {i}"
    prev = state.get("items", {}) if state.get("market") == market else {}
    cutoff = updated - HISTORY_DAYS * 86400
    comm = commodities(rows, watched, info)
    craft_rows = craft_outputs(rows, set(comm))
    items, craft, new_state_items = {}, {}, {}

    def record(dest, item, r):
        p = prev.get(str(item), {})
        if p.get("min") and p["min"] != r["min"]:
            r["prevMin"] = p["min"]
        elif p.get("prevMin"):
            r["prevMin"] = p["prevMin"]
        hist = [h for h in p.get("hist", []) if h[0] >= cutoff]
        r["h"] = history_string(hist, updated)
        if not hist or hist[-1][0] != updated:  # one real point per Blizzard snapshot
            hist.append([updated, r["min"], r["qty"]])
        hist = hist[-HISTORY_POINTS:]
        dest[item] = r
        # History for commodities and craft is kept together; a reclassification
        # does not drop earlier points.
        new_state_items[str(item)] = {"min": r["min"], "prevMin": r.get("prevMin"), "hist": hist}

    for item, r in comm.items():
        record(items, item, r)
    for item, r in craft_rows.items():
        record(craft, item, r)
    # Items that sold out this hour keep their earlier points (history is never dropped early).
    for k, p in prev.items():
        if k not in new_state_items:
            hist = [h for h in p.get("hist", []) if h[0] >= cutoff]
            if hist:
                new_state_items[k] = dict(p, hist=hist)
    write_feed(market, cfg["faction"], market_label(cfg), auctions_url(cfg), updated, items, every_min, craft)
    state = {"source": "blizzard", "market": market, "fetched": int(time.time()), "updated": updated,
             "lm": snap["lm"] or formatdate(updated, usegmt=True), "items": new_state_items, "every": every_min,
             "watched": sorted(watched), "hist_policy": HIST_POLICY}
    save_state(state)
    on_lists = len(watched & set(items))
    extra = f" and {len(craft)} alchemy outputs (craft, not on the ticker)" if craft else ""
    print(f"Wrote {len(items)} commodities ({on_lists} from your watch lists){extra} to {FEED} "
          f"(prices as of {discord.fmt_melbourne(updated)}). In game, click Load feed (or /commodity loadfeed) "
          f"to pick them up without a /reload, once the feed slots are installed.")
    sync_slots()
    return True


def discord_after_update(a):
    """After a successful write: post to Discord only if a webhook is configured (or --dry-run)."""
    if a.no_discord:
        return None
    if not a.dry_run:
        try:
            if not discord.resolve_webhook(a.webhook):
                return None  # no webhook configured: no Discord output at all
        except ValueError as e:
            print(f"Discord: {e}. Nothing was posted.")
            return None
    return discord.run(FEED, DATA, a.lists, a.webhook, a.dry_run)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--region", default=None, help="us (Americas and Oceania, the default), eu, kr or tw")
    ap.add_argument("--ruleset", type=int, default=None, help="Blizzard ruleset id: 2 Normal (default), 1 PvP, 3 RP, 15 RP-PvP")
    ap.add_argument("--faction", default=None, help="Horde (default), Alliance or Blackwater")
    ap.add_argument("--auction-house", type=int, default=None, help="auction house id (overrides --faction), e.g. 114")
    ap.add_argument("--loop", action="store_true", help="repeat every --every minutes")
    ap.add_argument("--every", type=int, default=None, help="minutes between checks (default 30, minimum 5). Saved in feed_state.json for later --loop runs.")
    ap.add_argument("--force", action="store_true", help="ignore the minimum gap once")
    ap.add_argument("--discord", action="store_true", help="post/edit the Discord ticker from the current Feed.lua without fetching")
    ap.add_argument("--dry-run", action="store_true", help="print the Discord message instead of sending it")
    ap.add_argument("--lists", choices=["now", "later", "both"], default=None, help="watch list(s) to show in Discord (default: discord.json, else now)")
    ap.add_argument("--webhook", default=None, help="Discord webhook URL (else tools/discord.json or %s)" % discord.ENV_VAR)
    ap.add_argument("--no-discord", action="store_true", help="don't post to Discord on this run")
    a = ap.parse_args(argv)
    if a.discord:
        result = discord.run(FEED, DATA, a.lists, a.webhook, a.dry_run)
        return 0 if result in ("edited", "posted", "dry-run") else 1
    try:
        cfg = load_config({"region": a.region, "ruleset_id": a.ruleset, "faction": a.faction,
                           "auction_house_id": a.auction_house})
    except FeedError as e:
        print(f"Setup problem: {e}")
        return 1
    state = load_state()
    every_min = clamp_every(a.every if a.every is not None else state.get("every") or DEFAULT_EVERY)
    if state.get("every") != every_min:
        state["every"] = every_min
        save_state(state)
    every = every_min * 60
    api = None
    while True:
        try:
            api = api or Blizzard(cfg)
            if update(cfg, a.force, every_min, api):
                discord_after_update(a)
        except FeedError as e:
            print(f"Update failed: {e}. Feed.lua left as it was.")
        except Exception as e:  # keep looping through network hiccups
            print(f"Update failed: {e}")
        a.force = False
        if not a.loop:
            break
        time.sleep(every)
    return 0


if __name__ == "__main__":
    sys.exit(main())
