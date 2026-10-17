#!/usr/bin/env bash
# Helper: show current vocal-chain ports + suggested manual links
# ??? #1 = capture conditioner (RODE locked 48k, no suspend)
# ??? #2 = router/monitor split (VST_OUT.monitor -> wired out, VST_Mic -> apps)
set -euo pipefail
echo "=== RODE (??? #1 in) ==="
pw-link -o | grep -i rode || echo "(rode not found)"
echo
echo "=== VST_OUT (VAC) ==="
pw-link -o | grep -i VST || echo "(VAC not up — run ./vac-up.sh)"
pw-link -i | grep -i VST || true
echo
echo "=== Suggested Carla wiring (run in qpwgraph or pw-link): ==="
echo "  RODE:capture_FL -> carla:capture_1"
echo "  RODE:capture_FR -> carla:capture_2   (or FL only for mono mic)"
echo "  carla:playback_1 -> VST_OUT:playback_FL"
echo "  carla:playback_2 -> VST_OUT:playback_FR"
echo "  VST_OUT:monitor_FL -> Starship analog playback (wired monitor, NOT bluetooth)"
echo "  Apps mic select: VST_Mic (NOT RODE NT-USB)"
echo
echo "=== Live links touching RODE/VST ==="
pw-link -l 2>/dev/null | grep -i -e rode -e VST -e carla || echo "(no links yet)"
