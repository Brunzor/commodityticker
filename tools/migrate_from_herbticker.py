#!/usr/bin/env python3
"""One-time move from HerbTicker to CommodityTicker (runs OUTSIDE the game).

Run it with the game CLOSED, after extracting CommodityTicker into AddOns and
before deleting the old HerbTicker folder. It copies (never moves or deletes):

  WTF\\Account\\<account>\\SavedVariables\\HerbTicker.lua -> CommodityTicker.lua
      (settings, bar position, lists and saved prices; the addon converts them
      on first login and prints one chat line)
  Interface\\AddOns\\HerbTicker\\tools\\feed_state.json, discord.json, discord_state.json
      -> Interface\\AddOns\\CommodityTicker\\tools\\  (feed history, your Discord webhook
      config and the Discord message ID, so the same message keeps being edited)

Existing CommodityTicker files are never overwritten.
"""
import argparse, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.dirname(HERE)                       # ...\Interface\AddOns\CommodityTicker
ADDONS = os.path.dirname(ADDON)                     # ...\Interface\AddOns
DEFAULT_ROOT = os.path.dirname(os.path.dirname(ADDONS))  # ...\_forever_
TOOL_FILES = ("feed_state.json", "discord.json", "discord_state.json")


def game_running():
    if os.name != "nt":
        return False
    try:
        out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq Wow.exe"], capture_output=True, text=True).stdout
        return "wow.exe" in out.lower()
    except OSError:
        return False


def migrate(root, addons, ignore_running=False, log=print):
    if not ignore_running and game_running():
        log("WoW is running. Exit the game first (it rewrites saved variables when it closes), then run this again.")
        return 2
    wtf = os.path.join(root, "WTF", "Account")
    copied = skipped = 0
    if os.path.isdir(wtf):
        for account in sorted(os.listdir(wtf)):
            sv = os.path.join(wtf, account, "SavedVariables")
            src, dst = os.path.join(sv, "HerbTicker.lua"), os.path.join(sv, "CommodityTicker.lua")
            if not os.path.isfile(src):
                continue
            if os.path.exists(dst):
                log(f"{account}: CommodityTicker.lua already exists - left it alone.")
                skipped += 1
                continue
            shutil.copy2(src, dst)
            log(f"{account}: copied HerbTicker saved data to CommodityTicker.lua.")
            copied += 1
    else:
        log(f"No WTF\\Account folder under {root} - nothing to copy (use --wow-root if your game folder is elsewhere).")
    old_tools = os.path.join(addons, "HerbTicker", "tools")
    new_tools = os.path.join(addons, "CommodityTicker", "tools")
    for name in TOOL_FILES:
        src, dst = os.path.join(old_tools, name), os.path.join(new_tools, name)
        if os.path.isfile(src) and not os.path.exists(dst) and os.path.isdir(new_tools):
            shutil.copy2(src, dst)
            log(f"copied tools\\{name} from HerbTicker.")
    if copied == 0 and skipped == 0:
        log("No HerbTicker saved data found. That's fine for a fresh install.")
    log("Done. Now delete the old Interface\\AddOns\\HerbTicker folder and start the game.")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--wow-root", default=DEFAULT_ROOT, help="the _forever_ folder (contains WTF and Interface)")
    ap.add_argument("--ignore-running", action="store_true", help="skip the 'is WoW running' check")
    a = ap.parse_args(argv)
    addons = os.path.join(a.wow_root, "Interface", "AddOns") if a.wow_root != DEFAULT_ROOT else ADDONS
    return migrate(a.wow_root, addons, a.ignore_running)


if __name__ == "__main__":
    sys.exit(main())
