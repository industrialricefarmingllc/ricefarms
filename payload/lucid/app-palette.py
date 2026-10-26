#!/usr/bin/env python3
"""The palette apps get: a light one with the shell's own surfaces.

Theme.qml walks a light palette's surface ladder off white and tints it toward
the accent before drawing anything, so the bars never look like paper. Apps
read the palette raw and did. This hands them the same surfaces
(lucid_palette.app_surfaces). A dark palette passes through unchanged.

app-palette.py <palette.json>        a Lucid palette, {role: hex}
app-palette.py --scheme <colours>    the json matugen dumps for a scheme; the
                                     default and light entries of each surface
                                     role are rewritten

Prints the result. apply-theme.sh uses the first form for the files it writes
itself, render-templates.sh the second for every template but the shell's.
"""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lucid_palette import SURFACE_ROLES, app_surfaces


def scheme(data):
    colors = data.get("colors") or {}
    flat = {}
    for role, v in colors.items():
        c = (v.get("default") or {}).get("color") if isinstance(v, dict) else None
        if isinstance(c, str):
            flat[role] = c
    soft = app_surfaces(flat)
    for role in SURFACE_ROLES:
        if role in flat and soft[role] != flat[role]:
            for variant in ("default", "light"):
                if isinstance(colors[role].get(variant), dict):
                    colors[role][variant]["color"] = soft[role]
    return data


def main():
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "--scheme":
        with open(args[1]) as f:
            out = scheme(json.load(f))
    elif len(args) == 1:
        with open(args[0]) as f:
            out = app_surfaces(json.load(f))
    else:
        print("usage: app-palette.py <palette.json> | --scheme <colours.json>", file=sys.stderr)
        return 2
    json.dump(out, sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
