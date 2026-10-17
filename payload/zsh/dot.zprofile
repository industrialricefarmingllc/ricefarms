# --- Desktop on-demand: Hyprland (preferred) > KDE Plasma > sway on tty7 ---
# Launched via `desktop-toggle` which starts getty@tty7.service (autologin).
# This block runs inside the login shell on tty7 (pam_systemd, logind session).
# kmscon stays default; this only runs when you toggle.
if [ "$(tty)" = "/dev/tty7" ]; then
  # Clear stale WAYLAND_DISPLAY/SWAYSOCK left from unclean exit
  if [ -n "$WAYLAND_DISPLAY" ] && [ ! -e "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
    unset WAYLAND_DISPLAY
    unset SWAYSOCK
    unset HYPRLAND_INSTANCE_SIGNATURE
    systemctl --user unset-environment WAYLAND_DISPLAY SWAYSOCK HYPRLAND_INSTANCE_SIGNATURE 2>/dev/null || true
  fi
  if [ -z "$WAYLAND_DISPLAY" ]; then
    if [ -z "$XDG_RUNTIME_DIR" ]; then
      export XDG_RUNTIME_DIR=/run/user/$(id -u)
    fi
    # Gate: don't exec the compositor until logind marks OUR session active.
    # Starting Hyprland while the session is inactive makes aquamarine log
    # "Session is not active, waiting for 5s" and enumerate every input as
    # "not using input device" (dead mouse/kb until the next VT switch), and
    # risks DRM master/permission failures. desktop-toggle chvt's to tty7
    # right after starting getty, so this wait is normally <1s; the 12s cap
    # is only for a wedged VT switch (then start anyway, old behavior).
    if [ -z "$XDG_SESSION_ID" ]; then
      XDG_SESSION_ID=$(loginctl 2>/dev/null | awk -v vt="tty$(basename "$(tty)" | tr -dc '0-9')" '$4==vt{print $1}' | head -n1)
    fi
    if [ -n "$XDG_SESSION_ID" ]; then
      # No sudo needed: activating your own session is allowed.
      loginctl activate "$XDG_SESSION_ID" 2>/dev/null || true
      for _dt_wait in $(seq 1 24); do
        if [ "$(loginctl show-session "$XDG_SESSION_ID" -p Active --value 2>/dev/null)" = "yes" ]; then
          break
        fi
        sleep 0.5
      done
      unset _dt_wait
    fi
    # Prefer Hyprland lightweight if installed, else KDE, else sway
    # Legacy DRM modeset (mirrors hyprland.conf env = AQ_NO_ATOMIC,1; belt
    # and suspenders: backend may init before config env applies).
    export AQ_NO_ATOMIC=1
    # Use start-hyprland wrapper to avoid "launched without start-hyprland" warning
    if [ -x /usr/bin/Hyprland ]; then
      exec start-hyprland
    elif [ -x /usr/bin/startplasma-wayland ]; then
      # KDE handles its own Wayland socket; no sway config needed
      exec dbus-run-session startplasma-wayland
    else
      exec sway --unsupported-gpu -c "$HOME/.config/sway/config"
    fi
  fi
fi

# Disabled 2026-08-27: don't auto-start gpu-tty-foot on tty3 by default (run manually with `gpu-tty-foot` if needed)
# if [ "$(tty)" = "/dev/tty3" ] && [ -z "$WAYLAND_DISPLAY" ]; then
#   exec /usr/local/bin/gpu-tty-foot
# fi
