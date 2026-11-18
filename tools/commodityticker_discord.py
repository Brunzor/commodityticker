"""CommodityTicker Discord webhook ticker (optional, personal use, runs OUTSIDE the game).

Posts the watch-list prices from Feed.lua into one Discord channel through a
channel webhook, then edits that same message on later runs instead of
posting new ones. No bot token, no gateway connection, no Developer Portal app.

The webhook URL is a secret: anyone who has it can post in your channel. Keep it
in tools/discord.json or the COMMODITYTICKER_DISCORD_WEBHOOK environment variable
(the old HERBTICKER_DISCORD_WEBHOOK still works).
Never share it, commit it, or paste it into chat.
"""
import hashlib, json, os, re, time, urllib.error, urllib.request
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(HERE, "discord.json")
DSTATE = os.path.join(HERE, "discord_state.json")
ENV_VAR = "COMMODITYTICKER_DISCORD_WEBHOOK"
OLD_ENV_VAR = "HERBTICKER_DISCORD_WEBHOOK"  # still honoured
UA = "DiscordBot (CommodityTicker, 2.0) personal webhook"
WEBHOOK_RE = re.compile(r"^https://(?:(?:ptb|canary)\.)?discord(?:app)?\.com/api/(?:v\d+/)?webhooks/(\d+)/([\w-]+)$")
LIST_TITLES = {"now": "Level-38 list", "later": "Level-50+ watch list"}
EMBED_COLOR = 0x33FF99
NUM_RE = re.compile(r"^\d+$")


# ---------------------------------------------------------------- time (Melbourne)
def _first_sunday(year, month):
    d = datetime(year, month, 1)
    return d + timedelta(days=(6 - d.weekday()) % 7)


def _melbourne_fallback(ts):
    """Australia/Melbourne without a tz database (Windows Python often lacks one).
    DST (AEDT, UTC+11) runs from 2:00 AEST on the first Sunday of October to
    3:00 AEDT on the first Sunday of April; otherwise AEST, UTC+10."""
    utc = datetime.fromtimestamp(ts, timezone.utc).replace(tzinfo=None)
    y = utc.year
    dst_end = _first_sunday(y, 4) + timedelta(hours=3) - timedelta(hours=11)
    dst_start = _first_sunday(y, 10) + timedelta(hours=2) - timedelta(hours=10)
    dst = utc < dst_end or utc >= dst_start
    offset = 11 if dst else 10
    return utc + timedelta(hours=offset), ("AEDT" if dst else "AEST")


def melbourne(ts):
    """Return (naive local datetime, 'AEDT'/'AEST') for a Unix timestamp."""
    try:
        from zoneinfo import ZoneInfo
        local = datetime.fromtimestamp(ts, ZoneInfo("Australia/Melbourne"))
        return local.replace(tzinfo=None), local.tzname()
    except Exception:
        return _melbourne_fallback(ts)


def fmt_melbourne(ts):
    d, zone = melbourne(ts)
    hour = d.hour % 12 or 12
    ampm = "am" if d.hour < 12 else "pm"
    return f"{hour}:{d.minute:02d} {ampm} {zone}, {d.strftime('%a')} {d.day} {d.strftime('%b')}"


# ---------------------------------------------------------------- money / rows
def money(copper):
    if copper is None:
        return "unknown"
    copper = int(round(copper))
    g, s, c = copper // 10000, (copper % 10000) // 100, copper % 100
    parts = []
    if g:
        parts.append(f"{g}g")
    if s and g < 100:
        parts.append(f"{s}s")
    if c and not g:
        parts.append(f"{c}c")
    return " ".join(parts) or "0c"


def change_text(cur, prev):
    if not cur or not prev or prev <= 0 or cur == prev:
        return ""
    pct = (cur - prev) / prev * 100
    arrow = "▲" if pct > 0 else "▼"
    return f"{arrow}{abs(pct):.0f}%" if abs(pct) >= 1 else f"{arrow}<1%"


# ---------------------------------------------------------------- reading the addon files
def read_lists(data_path):
    """Watch lists from Data.lua: {'now': [(id, name)], 'later': [...]}."""
    with open(data_path, encoding="utf-8") as f:
        text = f.read()
    out, current = {"now": [], "later": []}, None
    for line in text.splitlines():
        m = re.match(r"\s*(now|later)\s*=\s*\{", line)
        if m:
            current = m.group(1)
            continue
        m = re.search(r'\{\s*id\s*=\s*(\d+),\s*name\s*=\s*"((?:[^"\\]|\\.)*)"', line)
        if m and current:
            out[current].append((int(m.group(1)), m.group(2).replace('\\"', '"')))
    return out


def read_feed(feed_path):
    """Parse the Feed.lua that update_feed.py writes. Returns None if it holds no data."""
    if not os.path.exists(feed_path):
        return None
    with open(feed_path, encoding="utf-8") as f:
        text = f.read()
    if not re.search(r"^(?:CommodityTickerFeed|HerbTickerFeed)\s*=\s*\{", text, re.M):
        return None
    head = text.split("items = {", 1)[0]
    def field(name, num=True):
        m = re.search(r"\b%s\s*=\s*(\d+)" % name if num else r'\b%s\s*=\s*"((?:[^"\\]|\\.)*)"' % name, head)
        return (int(m.group(1)) if num else m.group(1)) if m else None
    items = {}
    for m in re.finditer(r"\[(\d+)\]\s*=\s*\{([^}]*)\}", text):
        body = re.sub(r'"(?:[^"\\]|\\.)*"', '""', m.group(2))  # ignore string fields (name, history)
        vals = {k: int(v) for k, v in re.findall(r"(\w+)\s*=\s*(\d+)", body)}
        nm = re.search(r'\bn\s*=\s*"((?:[^"\\]|\\.)*)"', m.group(2))
        if nm:
            vals["name"] = nm.group(1).replace('\\"', '"')
        items[int(m.group(1))] = vals
    if not items:
        return None
    return {
        "source": field("source", False), "market": field("market", False), "faction": field("faction", False),
        "label": field("label", False), "updated": field("updated"), "fetched": field("fetched"),
        "every": field("every"), "items": items,
    }


# ---------------------------------------------------------------- embed
def market_title(feed):
    m = (feed.get("market") or "").split("-")
    region = {"us": "Americas", "eu": "Europe", "kr": "Korea", "tw": "Taiwan"}.get(m[0], m[0].upper()) if m else ""
    rules = m[1].capitalize() if len(m) > 1 else ""
    faction = feed.get("faction") or (m[2].capitalize() if len(m) > 2 else "")
    return " ".join(x for x in (region, rules, faction) if x) or "Unknown market"


def _rows(entries, feed):
    lines = [f"{'Item':<19} {'Price':>9} {'Chg':>6} {'Listed':>7}"]
    for item_id, name in entries:
        short = name if len(name) <= 19 else name[:18] + "…"
        it = feed["items"].get(item_id)
        if not it or "min" not in it:
            lines.append(f"{short:<19} not in feed")
            continue
        qty = it.get("qty")
        if qty == 0:
            lines.append(f"{short:<19} none listed (last {money(it['min'])})")
            continue
        ch = change_text(it["min"], it.get("prevMin"))
        q = f"x{qty:,}" if qty is not None else ""
        lines.append(f"{short:<19} {money(it['min']):>9} {ch:>6} {q:>7}".rstrip())
    return lines


def build_payload(feed, lists, which="now", now=None):
    now = now or time.time()
    keys = ["now", "later"] if which == "both" else [which]
    fields = []
    for key in keys:
        body = "\n".join(_rows(lists.get(key, []), feed)) or "(empty list)"
        fields.append({"name": LIST_TITLES[key], "value": "```\n" + body[:1000] + "\n```", "inline": False})
    desc = ["Lowest buyout per unit on the auction house, with change vs the previous different price and units listed."]
    if feed.get("updated"):
        desc.append(f"**Prices as of** {fmt_melbourne(feed['updated'])} (<t:{feed['updated']}:R>)")
    if feed.get("fetched"):
        every = feed.get("every")
        tail = f" · updater runs every {every} min" if every else ""
        desc.append(f"**Fetched** {fmt_melbourne(feed['fetched'])}{tail}")
    desc.append(f"**Message updated** {fmt_melbourne(now)}")
    embed = {
        "title": f"📈 CommodityTicker · {market_title(feed)}",
        "description": "\n".join(desc),
        "color": EMBED_COLOR,
        "fields": fields,
        "footer": {"text": f"Data: {feed.get('source') or 'unknown source'} (Blizzard API + player scans). "
                           "Personal use only - do not republish."},
    }
    return {"username": "CommodityTicker", "embeds": [embed], "allowed_mentions": {"parse": []}}


# ---------------------------------------------------------------- config / state
def mask(url):
    m = WEBHOOK_RE.match(url or "")
    return f"webhook …/{m.group(1)[-4:]}/****" if m else "webhook (invalid URL)"


def load_config(path=CONFIG):
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
    return cfg if isinstance(cfg, dict) else {}


def resolve_webhook(cli_url=None, cfg=None):
    cfg = cfg if cfg is not None else load_config()
    url = cli_url or os.environ.get(ENV_VAR) or os.environ.get(OLD_ENV_VAR) or cfg.get("webhook_url") or ""
    url = url.strip()
    if not url or "PASTE" in url.upper():
        return None
    if not WEBHOOK_RE.match(url):
        raise ValueError("the Discord webhook URL doesn't look like https://discord.com/api/webhooks/<id>/<token>")
    return url


def _key(url):
    return hashlib.sha256(url.encode()).hexdigest()[:16]


def load_message_id(url, path=DSTATE):
    try:
        with open(path, encoding="utf-8") as f:
            st = json.load(f)
        if st.get("webhook") == _key(url) and NUM_RE.match(str(st.get("message_id", ""))):
            return str(st["message_id"])
    except (OSError, ValueError):
        pass
    return None


def save_message_id(url, message_id, path=DSTATE):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"webhook": _key(url), "message_id": str(message_id), "saved": int(time.time())}, f)
    os.replace(tmp, path)


# ---------------------------------------------------------------- HTTP
def http_request(method, url, payload):
    """Returns (status, parsed JSON or None). Never raises for HTTP status codes."""
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json", "User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        try:
            body = json.loads(e.read() or b"null")
        except ValueError:
            body = None
        return e.code, body


def _call(http, method, url, payload):
    status, body = http(method, url, payload)
    if status == 429 and isinstance(body, dict):  # rate limited: wait once, retry once
        time.sleep(min(float(body.get("retry_after", 2)), 10))
        status, body = http(method, url, payload)
    return status, body


def _code(body):
    return body.get("code") if isinstance(body, dict) else None


def publish(url, payload, http=None, state_path=DSTATE, log=print):
    """Edit the saved message, or post a new one. Returns 'edited', 'posted' or None on failure."""
    http = http or http_request
    msg_id = load_message_id(url, state_path)
    if msg_id:
        status, body = _call(http, "PATCH", f"{url}/messages/{msg_id}", payload)
        if 200 <= status < 300:
            log(f"Discord: updated the ticker message ({mask(url)}).")
            return "edited"
        if _code(body) == 10015 or (status == 401):
            log(f"Discord: the webhook was deleted or is invalid (HTTP {status}). Make a new one and update discord.json.")
            return None
        if status in (403, 404) or _code(body) in (10008, 50005):
            log("Discord: the saved ticker message is gone or can't be edited; posting a new one.")
        else:
            log(f"Discord: editing failed (HTTP {status}); not posting a duplicate. Will try again next run.")
            return None
    status, body = _call(http, "POST", f"{url}?wait=true", payload)
    if 200 <= status < 300 and isinstance(body, dict) and NUM_RE.match(str(body.get("id", ""))):
        save_message_id(url, body["id"], state_path)
        log(f"Discord: posted a new ticker message ({mask(url)}); later runs will edit it in place.")
        return "posted"
    if _code(body) == 10015 or status in (401, 404):
        log(f"Discord: the webhook was deleted or is invalid (HTTP {status}). Make a new one and update discord.json.")
    else:
        log(f"Discord: posting failed (HTTP {status}).")
    return None


def run(feed_path, data_path, which=None, cli_url=None, dry_run=False, http=None,
        config_path=CONFIG, state_path=DSTATE, log=print):
    """Post Feed.lua to Discord. Returns 'edited', 'posted', 'dry-run', 'skipped' or None (failed)."""
    cfg = load_config(config_path)
    which = which or cfg.get("lists") or "now"
    if which not in ("now", "later", "both"):
        log("Discord: lists must be now, later or both.")
        return None
    feed = read_feed(feed_path)
    if not feed:
        log("Discord: Feed.lua has no prices yet, so nothing was posted. Run the updater first.")
        return None
    payload = build_payload(feed, read_lists(data_path), which)
    if dry_run:
        log("Discord dry run - this is what would be sent (nothing was posted):")
        log(json.dumps(payload, indent=2, ensure_ascii=False))
        return "dry-run"
    try:
        url = resolve_webhook(cli_url, cfg)
    except ValueError as e:
        log(f"Discord: {e}. Nothing was posted.")
        return None
    if not url:
        log("Discord: no webhook configured (tools/discord.json, --webhook or %s). Nothing was posted." % ENV_VAR)
        return "skipped"
    return publish(url, payload, http=http, state_path=state_path, log=log)
