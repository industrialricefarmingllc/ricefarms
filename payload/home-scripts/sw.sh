#!/bin/bash
# sw.sh - toggles ethernet connection (enp4s0)
# Requires sudo (NOPASSWD) for ip/networkctl
set -e
IFACE="enp4s0"

# Fallback: auto-detect primary ethernet if enp4s0 not found
if [ ! -d "/sys/class/net/$IFACE" ]; then
  # find first ether-type interface excluding lo/docker/wlan
  IFACE=$(ip -o link show | awk -F': ' '{print $2}' | cut -d' ' -f1 | grep -vE '^(lo|docker|wlan|wlp|wwan)' | head -n1)
  # alternative detection via Type=ether if needed
  if [ -z "$IFACE" ] || [ ! -d "/sys/class/net/$IFACE" ]; then
    IFACE=$(networkctl list --no-legend 2>/dev/null | awk '$2=="ether" {print $2; exit}' || true)
  fi
  if [ -z "$IFACE" ]; then
    echo "No ethernet interface found" >&2
    exit 1
  fi
fi

# Determine admin state (flags contain UP). "state UP" is operstate and is DOWN during no-carrier, so use flags.
if ip link show "$IFACE" | grep -qE "<.*UP"; then
  echo "Toggling $IFACE: currently UP (admin UP $(ip link show "$IFACE" | grep -o "<.*>" | tr -d '\n')) -> bringing DOWN..."
  sudo ip link set dev "$IFACE" down
  sleep 1
  echo "$IFACE is now DOWN (admin)"
else
  echo "Toggling $IFACE: currently DOWN (admin DOWN $(ip link show "$IFACE" | grep -o "<.*>" | tr -d '\n')) -> bringing UP..."
  sudo ip link set dev "$IFACE" up
  # Ensure systemd-networkd reconfigures DHCP
  sudo networkctl reconfigure "$IFACE" 2>&1 || true
  echo "Waiting for carrier/DHCP (up to 8s)..."
  for _ in 1 2 3 4 5 6 7 8; do
    sleep 1
    # Break if routable
    if networkctl status "$IFACE" 2>&1 | grep -q "State: routable"; then
      break
    fi
    # Or if LOWER_UP appears (carrier acquired), wait a bit more for DHCP then break
    if ip link show "$IFACE" | grep -q "LOWER_UP"; then
      sleep 2
      break
    fi
  done
  echo "$IFACE is now UP (admin)"
fi

# Show brief status - show both admin flags and operstate + full details
echo "--- status ---"
echo "flags/operstate: $(ip link show "$IFACE" | grep -Eo "<[^>]+>.*state [A-Z]+")"
ip -br link show "$IFACE" 2>&1 || ip link show "$IFACE" 2>&1 | head -n 5
networkctl status "$IFACE" 2>&1 | head -n 40 || true
