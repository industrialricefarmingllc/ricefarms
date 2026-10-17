#!/usr/bin/env python3
import pathlib, re, colorsys, json, sys
p = pathlib.Path.home() / ".config/opencode/themes/matugen.json"
try:
    text = p.read_text()
except: sys.exit(0)

def boost(hexcol, factor=1.7, min_s=0.6):
    hexcol=hexcol.strip()
    if not hexcol.startswith('#'): return hexcol
    h=hexcol.lstrip('#')
    if len(h)!=6: return hexcol
    r=int(h[0:2],16)/255; g=int(h[2:4],16)/255; b=int(h[4:6],16)/255
    h_,l,s = colorsys.rgb_to_hls(r,g,b)
    if s < 0.08 or l < 0.08 or l > 0.95:
        return hexcol
    ns = min(1.0, s * factor)
    if s>0.1 and ns < min_s:
        ns = min_s
    r2,g2,b2 = colorsys.hls_to_rgb(h_, l, ns)
    return f"#{int(r2*255):02x}{int(g2*255):02x}{int(b2*255):02x}"

# Boost every hex in the JSON, but keep background-like colors' l check will skip near-grays
new_text = re.sub(r'#[0-9a-fA-F]{6}', lambda m: boost(m.group(0)), text)
if new_text != text:
    p.write_text(new_text)
    print("boosted opencode saturation")
