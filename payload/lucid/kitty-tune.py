#!/usr/bin/env python3
"""Post-process matugen's kitty palette in one pass.

Two adjustments used to be two separate Python startups, two file writes and
two SIGUSR1 broadcasts per wallpaper:

  * light mode: soften foreground/cursor/color7 from on_surface to
    on_surface_variant, because matugen's light ink is harsh on a near-white
    terminal;
  * both modes: push the primary/secondary/tertiary families to full chroma so
    terminal accents stay legible against the surface.

Doing both here is one read, one write, and lets theme-fanout.sh send one kitty
signal for the whole change.
"""
import colorsys
import json
import re
import sys


def main() -> int:
    if len(sys.argv) < 4:
        return 2
    kitty_path, palette_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
    try:
        text = open(kitty_path).read()
        palette = json.load(open(palette_path))
    except (OSError, ValueError):
        return 0

    new = text
    if mode == "light":
        soft = palette.get("on_surface_variant") or palette.get("on_surface") or "#44474e"
        hard = palette.get("on_surface") or "#191c20"
        if soft and soft != hard:
            for key in ("foreground", "cursor", "color7"):
                new = re.sub(rf"^{key}\s+.*", f"{key}                {soft}", new, flags=re.M)

    keys = [
        "primary", "on_primary", "primary_container", "on_primary_container",
        "secondary", "on_secondary", "secondary_container", "on_secondary_container",
        "tertiary", "on_tertiary", "tertiary_container", "on_tertiary_container",
        "primary_fixed", "on_primary_fixed", "primary_fixed_dim", "on_primary_fixed_variant",
        "secondary_fixed", "on_secondary_fixed", "secondary_fixed_dim", "on_secondary_fixed_variant",
        "tertiary_fixed", "on_tertiary_fixed", "tertiary_fixed_dim", "on_tertiary_fixed_variant",
    ]
    strong = {
        str(palette[k]).lower()
        for k in keys
        if isinstance(palette.get(k), str) and str(palette[k]).startswith("#")
    }

    def boost(hexcol: str, factor: float = 4.0, min_s: float = 1.0) -> str:
        if hexcol.lower() not in strong:
            return hexcol
        h = hexcol.lstrip("#")
        if len(h) != 6:
            return hexcol
        try:
            r, g, b = (int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4))
        except ValueError:
            return hexcol
        hue, light, sat = colorsys.rgb_to_hls(r, g, b)
        if sat < 0.05 or light < 0.05 or light > 0.97:
            return hexcol
        sat = max(min_s, min(1.0, sat * factor))
        r2, g2, b2 = colorsys.hls_to_rgb(hue, light, sat)
        return f"#{int(r2 * 255):02x}{int(g2 * 255):02x}{int(b2 * 255):02x}"

    new = re.sub(r"#[0-9a-fA-F]{6}", lambda m: boost(m.group(0)), new)
    if new != text:
        try:
            with open(kitty_path + ".tmp", "w") as f:
                f.write(new)
            import os
            os.replace(kitty_path + ".tmp", kitty_path)
        except OSError:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
