#!/usr/bin/env python3
"""Search Wallhaven and the most popular Wallpaper Engine Workshop items for the
lucid wallpaper picker.

The picker stays local-first: this only returns descriptors. Nothing is
downloaded until a card is picked, so a search costs two requests (wallhaven)
and two requests (workshop browse + details) and no disk.

Output is always JSON on stdout:
    {"wallhaven": [...], "steam": [...], "hasMore": bool, "errors": [...]}

Each item has the shape the picker's ListModels already use:
    path, name, thumb, preview, key, kind, source, file, resolution, ...
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

UA = "lucid-shell/1.0 (+wallpaper search)"
WALLHAVEN = "https://wallhaven.cc/api/v1/search"
WORKSHOP = "https://steamcommunity.com/workshop/browse/"
WORKSHOP_APP = "431960"  # Wallpaper Engine
DETAILS = "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"
PAGE_SIZE = 24  # wallhaven; the API hard limit
WORKSHOP_PAGE = 30


def curl(url: str, data: str | None = None, headers: dict[str, str] | None = None) -> str:
    # Keep secrets out of argv: curl reads the URL/header config from stdin, so
    # an API key is never visible in `ps` while a search is running.
    config = ['url = "' + url.replace('"', "%22") + '"']
    for k, v in (headers or {}).items():
        config.append('header = "' + k + ": " + v.replace('"', '\\"') + '"')
    cmd = ["curl", "-4", "-fsSL", "--max-time", "25", "-A", UA, "--config", "-"]
    if data is not None:
        cmd += ["--data", data]
    p = subprocess.run(cmd, input="\n".join(config) + "\n", capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or "curl failed").strip()[:300])
    return p.stdout


def steam_thumb(url: str) -> str:
    """Ask the CDN for the largest preview it will give us.

    The UGC file is sometimes a 160px GIF and sometimes a 768px JPEG; the
    resize parameters are harmless on the former and help the latter.
    """
    if not url:
        return ""
    sep = "&" if "?" in url else "?"
    return url + sep + "imw=1024&imh=576&ima=fit&impolicy=Letterbox&imcolor=%23000000&letterbox=false"


def wallhaven(query: str, page: int, key: str, purity: str, top_range: str = ""):
    if page <= 0:
        return [], False

    params = {
        # general + anime only: the user asked to drop the people category
        "categories": "110",
        "purity": purity or "110",
        "sorting": "toplist" if top_range else "date_added",
        # phone wallpapers are portrait; everything the picker shows is a
        # desktop crop. Wallhaven accepts the named "landscape" preset.
        "ratios": "landscape",
        "page": str(page),
    }
    if top_range:
        params["topRange"] = top_range
    if query:
        params["q"] = query
    if key:
        params.pop("apikey", None)
    data = json.loads(curl(
        WALLHAVEN + "?" + urllib.parse.urlencode(params),
        headers={"X-API-Key": key} if key else None,
    ))
    items = []
    for w in data.get("data") or []:
        width = int(w.get("dimension_x") or 0)
        height = int(w.get("dimension_y") or 0)
        # The named ratio filter already drops portrait uploads, but never let
        # a mobile wallpaper through if the API falls back to an older page.
        if width > 0 and height > width:
            continue
        thumbs = w.get("thumbs") or {}
        thumb = thumbs.get("large") or thumbs.get("original") or thumbs.get("small") or ""
        if not thumb:
            continue
        items.append({
            "path": "wh:" + str(w.get("id", "")),
            "name": str(w.get("id", "")),
            "thumb": thumb,
            # the card loads this only for the selected result: a full-size
            # preview without downloading 24 full images up front
            "preview": w.get("path") or "",
            "key": str(w.get("id", "")),
            "kind": "wallhaven",
            "source": "wallhaven",
            "file": w.get("path") or "",
            "width": width,
            "height": height,
            "resolution": w.get("resolution") or "",
            "fileSize": w.get("file_size") or 0,
            "fileType": w.get("file_type") or "",
            "purity": w.get("purity") or "",
            "category": w.get("category") or "",
            "url": w.get("url") or "",
        })
    meta = data.get("meta") or {}
    current = int(meta.get("current_page") or page)
    last = int(meta.get("last_page") or current)
    return items, current < last


def workshop(query: str, page: int, allow_mature: bool, days: int = 1):
    if page <= 0:
        return [], False
    # Most popular in the last day, not only the items carrying Wallpaper
    # Engine's Approved tag: that filter hid most of the Workshop.
    params = {
        "appid": WORKSHOP_APP,
        "browsesort": "trend",
        "days": str(days),
        "section": "readytouseitems",
        "p": str(page),
    }
    if query:
        params["searchtext"] = query
    html = curl(WORKSHOP + "?" + urllib.parse.urlencode(params))

    ids: list[str] = []
    for m in re.finditer(r"sharedfiles/filedetails/\?id=(\d+)", html):
        pid = m.group(1)
        if pid not in ids:
            ids.append(pid)
    if not ids:
        return [], False

    body = urllib.parse.urlencode({
        "itemcount": len(ids),
        **{f"publishedfileids[{n}]": pid for n, pid in enumerate(ids)},
    })
    data = json.loads(curl(DETAILS, body))
    items = []
    for d in (data.get("response") or {}).get("publishedfiledetails") or []:
        tags = [t.get("tag", "") for t in d.get("tags") or []]
        if d.get("result") != 1 or d.get("banned") or d.get("visibility", 0) != 0:
            continue
        # Steam has Everyone and Mature only; the Wallhaven NSFW chip decides
        # whether Mature scenes are allowed through.
        if "Mature" in tags and not allow_mature:
            continue
        thumb = steam_thumb(d.get("preview_url") or "")
        if not thumb:
            continue
        pid = str(d.get("publishedfileid") or "")
        if pid == "":
            continue
        items.append({
            "path": "skwd:we:" + pid,
            "name": d.get("title") or pid,
            "thumb": thumb,
            "preview": "",
            "key": "we:" + pid,
            "kind": "steam",
            "source": "steam",
            "workshopId": pid,
            "fileSize": int(d.get("file_size") or 0),
            "created": int(d.get("time_created") or 0),
            "tags": tags,
        })
    # The page holds 30; the scrape occasionally sees a duplicate, so a
    # near-full page still means there is another one.
    return items, len(ids) >= WORKSHOP_PAGE - 6


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--query", default="")
    # pages are per source now: Wallhaven can restart at page 1 on the next
    # topRange while Steam keeps advancing
    ap.add_argument("--wh-page", type=int, default=-1)
    ap.add_argument("--steam-page", type=int, default=-1)
    ap.add_argument("--page", type=int, default=1)
    ap.add_argument("--wh-top-range", default="")
    # Prefer the prefs file: a key in argv is visible in `ps`. --key stays for
    # one-off tests.
    ap.add_argument("--key", default="")
    ap.add_argument("--prefs", default=os.path.expanduser("~/.config/quickshell/lucidprefs/prefs.json"))
    ap.add_argument("--steam-days", type=int, default=1)
    ap.add_argument("--purity", default="110")
    args = ap.parse_args()

    if not args.key:
        try:
            with open(args.prefs) as f:
                args.key = json.load(f).get("wallhavenApiKey") or ""
        except Exception:  # noqa: BLE001 - no key is a valid guest search
            args.key = ""

    wh_page = args.wh_page if args.wh_page >= 0 else max(1, args.page)
    steam_page = args.steam_page if args.steam_page >= 0 else max(1, args.page)
    out = {
        "wallhaven": [], "steam": [],
        "wallhavenHasMore": False, "steamHasMore": False,
        "hasMore": False, "errors": [],
    }

    # active sources in parallel; a page 0 means that source is exhausted for
    # this request (Wallhaven may still resume on a wider topRange later)
    with ThreadPoolExecutor(max_workers=2) as pool:
        fw = pool.submit(wallhaven, args.query, wh_page, args.key, args.purity, args.wh_top_range) if wh_page > 0 else None
        # The last Wallhaven purity digit is the NSFW switch; the Workshop has
        # no sketchy tier, so only that digit maps onto it.
        allow_mature = (args.purity or "100").strip().endswith("1")
        fs = pool.submit(workshop, args.query, steam_page, allow_mature, args.steam_days) if steam_page > 0 else None

        if fw is not None:
            try:
                out["wallhaven"], out["wallhavenHasMore"] = fw.result()
            except Exception as e:  # noqa: BLE001 - a failed source is not a failed search
                out["errors"].append("wallhaven: " + str(e))

        if fs is not None:
            try:
                out["steam"], out["steamHasMore"] = fs.result()
            except Exception as e:  # noqa: BLE001
                out["errors"].append("steam: " + str(e))

    out["hasMore"] = bool(out["wallhavenHasMore"] or out["steamHasMore"])
    json.dump(out, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
