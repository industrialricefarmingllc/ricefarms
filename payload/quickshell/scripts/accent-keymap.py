#!/usr/bin/env python3
# Builds the keyboard map and the alternate-spelling table for the Lucid
# long-press letter picker (AccentPicker.qml).
#
# The layout half asks Hyprland for the real keyboard configuration (layout,
# variant, model, options) and turns it into xkbcommon, so every keycode is
# resolved exactly the way the compositor resolves it.  The result is one table
# per layout group, plus the plain/shifted pair for each keycode.
#
# The variants half is generated from Unicode itself: every precomposed
# character that decomposes to one base letter plus one combining mark is a
# spelling of that letter.  A few ligatures/letters that have no canonical
# decomposition (ae, oe, slashed o, ...) are appended by hand.
#
# Output is a single JSON document on stdout.  This runs once at shell start
# (and again if the keyboard configuration changes), never on a keystroke.

import ctypes
import json
import subprocess
import sys
import unicodedata


def hypr_keyboard():
    try:
        raw = subprocess.check_output(["hyprctl", "devices", "-j"], stderr=subprocess.DEVNULL, timeout=3)
        data = json.loads(raw)
    except Exception:
        return None

    boards = data.get("keyboards") or []
    if not boards:
        return None

    return next((k for k in boards if k.get("main")), boards[0])


def rule_names(kb):
    layout = kb.get("layout") or "us"
    variant = kb.get("variant") or ""
    # Hyprland lists one entry per layout group.  Without a variant for a
    # group the field is empty, but the comma still has to be there.
    codes = [x.strip() for x in layout.split(",")]
    n = max(1, len(codes))
    variants = [x.strip() for x in variant.split(",")] if variant else []
    while len(variants) < n:
        variants.append("")
    return {
        "rules": "evdev",
        "model": kb.get("model") or "",
        "layout": ",".join(codes),
        "variant": ",".join(variants[:n]),
        "options": kb.get("options") or "",
    }


class Rules(ctypes.Structure):
    _fields_ = [
        ("rules", ctypes.c_char_p),
        ("model", ctypes.c_char_p),
        ("layout", ctypes.c_char_p),
        ("variant", ctypes.c_char_p),
        ("options", ctypes.c_char_p),
    ]


class XKB:
    def __init__(self, rules):
        self.lib = ctypes.CDLL("libxkbcommon.so.0")
        l = self.lib
        l.xkb_context_new.argtypes = [ctypes.c_int]
        l.xkb_context_new.restype = ctypes.c_void_p
        l.xkb_keymap_new_from_names.argtypes = [ctypes.c_void_p, ctypes.POINTER(Rules), ctypes.c_int]
        l.xkb_keymap_new_from_names.restype = ctypes.c_void_p
        l.xkb_state_new.argtypes = [ctypes.c_void_p]
        l.xkb_state_new.restype = ctypes.c_void_p
        l.xkb_state_key_get_utf32.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        l.xkb_state_key_get_utf32.restype = ctypes.c_uint32
        l.xkb_state_update_mask.argtypes = [ctypes.c_void_p] + [ctypes.c_uint32] * 6
        l.xkb_keymap_mod_get_index.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        l.xkb_keymap_mod_get_index.restype = ctypes.c_uint32
        l.xkb_keymap_num_layouts.argtypes = [ctypes.c_void_p]
        l.xkb_keymap_num_layouts.restype = ctypes.c_uint32

        self.ctx = l.xkb_context_new(0)
        names = Rules(
            rules["rules"].encode(),
            rules["model"].encode(),
            rules["layout"].encode(),
            rules["variant"].encode(),
            rules["options"].encode(),
        )
        self.keymap = l.xkb_keymap_new_from_names(self.ctx, ctypes.byref(names), 0)
        if not self.keymap:
            raise RuntimeError("xkbcommon rejected the keyboard configuration")
        self.state = l.xkb_state_new(self.keymap)
        self.shift = 1 << l.xkb_keymap_mod_get_index(self.keymap, b"Shift")
        self.layouts = l.xkb_keymap_num_layouts(self.keymap)

    def char(self, keycode, shift, group):
        l = self.lib
        l.xkb_state_update_mask(self.state, self.shift if shift else 0, 0, 0, 0, 0, group)
        cp = l.xkb_state_key_get_utf32(self.state, keycode)
        if cp == 0 or cp > 0x10FFFF:
            return ""
        try:
            ch = chr(cp)
        except ValueError:
            return ""
        return ch if ch.isalpha() else ""


# Ordering inside a popup: the accents people reach for first, then the rest.
MARK_ORDER = {
    "acute": 0,
    "grave": 1,
    "circumflex": 2,
    "tilde": 3,
    "diaeresis": 4,
    "ring": 5,
    "macron": 6,
    "breve": 7,
    "caron": 8,
    "ogonek": 9,
    "dot above": 10,
    "cedilla": 11,
    "double acute": 12,
    "comma below": 13,
    "hook above": 14,
    "dot below": 15,
    "horn": 16,
    "line below": 17,
    "inverted breve": 18,
    "stroke": 19,
}

# Letters that are alternates of a base but do not decompose into base + mark.
SPECIALS = {
    "a": ["æ", "ɑ"],
    "A": ["Æ", "Ɑ"],
    "d": ["đ", "ð"],
    "D": ["Đ", "Ð"],
    "e": ["ə"],
    "E": ["Ə"],
    "i": ["ı"],
    "I": ["İ"],
    "l": ["ł"],
    "L": ["Ł"],
    "o": ["ø", "œ", "ɔ"],
    "O": ["Ø", "Œ", "Ɔ"],
    "s": ["ß", "ſ"],
    "S": ["ẞ"],
    "t": ["þ"],
    "T": ["Þ"],
}


def build_variants():
    """base letter -> every precomposed spelling, in a useful order."""
    found = {}
    # Latin Extended, IPA, Cyrillic, Greek and the rest of the BMP.  Nothing
    # above plane 0 has canonical base+mark letters we care about.
    for cp in range(0x20, 0x30000):
        ch = chr(cp)
        if not ch.isalpha():
            continue
        decomp = unicodedata.decomposition(ch)
        # <compat> and <font> forms are not real spellings of the letter.
        if not decomp or decomp.startswith("<"):
            continue
        parts = unicodedata.normalize("NFD", ch)
        if len(parts) != 2:
            continue
        base, markpart = parts[0], parts[1]
        if not base.isalpha() or not unicodedata.combining(markpart):
            continue
        mark = unicodedata.name(markpart, "").replace("COMBINING ", "").replace(" ACCENT", "").lower()
        found.setdefault(base, []).append((MARK_ORDER.get(mark, 50), mark, ch))

    out = {}
    for base, entries in found.items():
        entries.sort(key=lambda e: (e[0], e[1], e[2]))
        out[base] = [e[2] for e in entries]

    for base, extras in SPECIALS.items():
        seen = set(out.get(base, []))
        out.setdefault(base, [])
        for ch in extras:
            if ch not in seen:
                out[base].append(ch)
                seen.add(ch)

    return out


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

    kb = hypr_keyboard() or {"layout": "us", "variant": "", "model": "", "options": "", "active_layout_index": 0}
    rules = rule_names(kb)
    xkb = XKB(rules)

    layouts = []
    for group in range(xkb.layouts):
        keys = {}
        for keycode in range(9, 256):
            plain = xkb.char(keycode, False, group)
            shifted = xkb.char(keycode, True, group)
            if plain or shifted:
                keys[str(keycode)] = [plain, shifted]
        layouts.append({
            "name": (rules["layout"].split(",")[group] if group < len(rules["layout"].split(",")) else ""),
            "variant": (rules["variant"].split(",")[group] if group < len(rules["variant"].split(",")) else ""),
            "keys": keys,
        })

    doc = {
        "signature": "|".join([rules["rules"], rules["model"], rules["layout"], rules["variant"], rules["options"]]),
        "active": int(kb.get("active_layout_index") or 0) if str(kb.get("active_layout_index", 0)).isdigit() else 0,
        "layouts": layouts,
        "variants": build_variants(),
    }
    json.dump(doc, sys.stdout, ensure_ascii=False, separators=(",", ":"))


if __name__ == "__main__":
    main()
