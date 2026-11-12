#!/bin/sh
# helium-url-handler.sh - hand a URL to Helium, then focus the window that got it.
#
# Why this exists: on Wayland, Chromium only raises an already-running window
# when it can complete an xdg-activation handshake, and a URL delivered by
# xdg-open or the OpenURI portal arrives without an activation token (and
# without any input serial of its own). Helium therefore opens the tab in the
# background and stays on whatever workspace it was on. Nothing reaches the
# compositor - no xdg-activation request, no urgent hint - so the urgency
# guard in custom.lua cannot see it either. The handler does the focus itself.
#
# Used as the Exec of helium.desktop, i.e. the x-scheme-handler/{http,https}
# URL handler. Wrapper (not a desktop-file one-liner) so the %U list and
# quoting stay sane and the poll is testable.

set -u

# No URL (plain menu launch): let Hyprland focus the new window itself.
if [ "$#" -eq 0 ]; then
  exec helium-browser --remote-debugging-port=9222 --profile-directory=Default
fi

helium-browser --remote-debugging-port=9222 --profile-directory=Default "$@" >/dev/null 2>&1 &

# Warm handoff: the URL is already in the running instance by the time the
# client exits, so the first poll usually hits. Cold start: wait up to 4s for
# a mapped window, and never steal focus for a launch that failed.
i=0
while [ "$i" -lt 40 ]; do
  if hyprctl clients -j 2>/dev/null |
       jq -e 'any(.[]; .class == "helium" and .mapped)' >/dev/null 2>&1; then
    # 0.57 Lua config: dispatch is a wrapper for hl.dispatch(...), the old
    # `dispatch focuswindow class:...` form is gone.
    hyprctl eval 'hl.dispatch(hl.dsp.focus({ window = "class:helium" }))' >/dev/null 2>&1 || true
    exit 0
  fi
  i=$((i + 1))
  sleep 0.1
done
exit 0
