"""Create and refresh the load-on-demand feed-slot addons.

Each CTFeedNN addon can be loaded once per game session. Loading it
re-executes a copy of Feed.lua, so CommodityTicker can pick up a new
snapshot without a /reload. A toc cannot safely reference a file outside
its own folder, so this copies Feed.lua into every slot.
"""
import os
import shutil

SLOT_COUNT = 24
PREFIX = "CTFeed"
INTERFACE = "16001"
VERSION = "2.7.0"

def addons_root(addon_dir):
    return os.path.dirname(os.path.abspath(addon_dir))

def slot_name(i):
    return f"{PREFIX}{i:02d}"

def slot_dir(root, i):
    return os.path.join(root, slot_name(i))

def toc_text(i):
    name = slot_name(i)
    return (
        f"## Interface: {INTERFACE}\n"
        f"## Title: CommodityTicker Feed {i:02d}\n"
        f"## Notes: Load-on-demand slot so CommodityTicker can re-read the price feed mid-session without a full UI reload. Safe to leave enabled.\n"
        f"## Author: Brett Malpas\n"
        f"## Version: {VERSION}\n"
        f"## LoadOnDemand: 1\n"
        f"## Dependencies: CommodityTicker\n"
        f"## DefaultState: enabled\n"
        f"## Category: Auction\n"
        f"## Group: CommodityTicker\n"
        f"Feed.lua\n"
    )

def placeholder(i):
    # Must not assign CommodityTickerFeed — loading an unsynced slot would wipe the in-memory feed.
    return f"-- CommodityTicker feed slot {i:02d}. update_feed.py overwrites this with the latest Feed.lua.\n"

def write_stubs(addons_dir, feed_src=None):
    """Create CTFeed01..N under addons_dir and copy feed_src into each slot when it exists."""
    os.makedirs(addons_dir, exist_ok=True)
    written = []
    for i in range(1, SLOT_COUNT + 1):
        d = slot_dir(addons_dir, i)
        os.makedirs(d, exist_ok=True)
        toc = os.path.join(d, slot_name(i) + ".toc")
        with open(toc, "w", encoding="utf-8", newline="\n") as f:
            f.write(toc_text(i))
        dest = os.path.join(d, "Feed.lua")
        if feed_src and os.path.isfile(feed_src):
            shutil.copyfile(feed_src, dest)
        elif not os.path.isfile(dest):
            with open(dest, "w", encoding="utf-8", newline="\n") as f:
                f.write(placeholder(i))
        written.append(d)
    return written

def sync_from_feed(feed_path, addons_dir=None):
    """Copy the current Feed.lua into every slot, creating the stub addons if needed."""
    feed_path = os.path.abspath(feed_path)
    if addons_dir is None:
        # Feed.lua lives in Interface/AddOns/CommodityTicker/Feed.lua
        addons_dir = os.path.dirname(os.path.dirname(feed_path))
    return write_stubs(addons_dir, feed_src=feed_path if os.path.isfile(feed_path) else None)
