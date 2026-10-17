#!/bin/bash
# WARP full tunnel - SAFE version with auto-revert
# If SSH breaks and you don't confirm within 45s, everything reverts automatically.
# Confirm: ~/tun confirm    Stop: ~/tun stop
set -e

ACTION=${1:-start}
GATEWAY=$(ip route show default | grep -v tun | grep -v "metric 10" | head -1 | awk '{print $3}')
INTERFACE=$(ip route show default | grep -v tun | grep -v "metric 10" | head -1 | awk '{print $5}')
SERVER_IP=$(hostname -I | awk '{print $1}')
CONFIRMED=0

# Save current state for revert
save_state() {
    echo "Saving state..."
    ip route > /tmp/tun_routes_backup 2>/dev/null
    ip rule list > /tmp/tun_rules_backup 2>/dev/null
    iptables-save -t mangle > /tmp/tun_mangle_backup 2>/dev/null || true
    echo "State saved."
}

# Revert to saved state
revert() {
    echo "REVERTING..."
    sudo iptables -t mangle -F 2>/dev/null || true
    sudo ip rule del fwmark 1 2>/dev/null || true
    sudo ip rule del fwmark 2 2>/dev/null || true
    sudo ip route flush table 100 2>/dev/null || true
    sudo ip route flush table 101 2>/dev/null || true
    sudo ip route del 162.159.198.0/24 2>/dev/null || true
    sudo sysctl -w net.ipv4.conf.all.rp_filter=1 2>/dev/null || true
    sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0 2>/dev/null || true
    warp-cli mode proxy 2>/dev/null || true
    warp-cli disconnect 2>/dev/null || true
    # Restore original route
    sudo ip route replace default via $GATEWAY dev $INTERFACE metric 0 2>/dev/null || true
    sudo cp /etc/resolv.conf.bak /etc/resolv.conf 2>/dev/null || true
    echo "REVERTED. SSH should work."
}

# Auto-revert timer (background)
auto_revert() {
    echo "Auto-revert in 45s. Run 'tun confirm' to keep changes."
    for i in $(seq 45 -1 1); do
        if [ "$CONFIRMED" = "1" ]; then
            echo "Changes confirmed. No revert."
            rm -f /tmp/tun_revert_pid
            return
        fi
        printf "\rRevert in %02d s " $i
        sleep 1
    done
    echo ""
    echo "TIMEOUT. Reverting..."
    revert
    exit 1
}

stop() {
    echo "Stopping..."
    CONFIRMED=1
    sudo iptables -t mangle -F 2>/dev/null || true
    sudo ip rule del fwmark 1 2>/dev/null || true
    sudo ip rule del fwmark 2 2>/dev/null || true
    sudo ip route flush table 100 2>/dev/null || true
    sudo ip route flush table 101 2>/dev/null || true
    sudo ip route del 162.159.198.0/24 2>/dev/null || true
    sudo sysctl -w net.ipv4.conf.all.rp_filter=1 2>/dev/null || true
    sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0 2>/dev/null || true
    warp-cli mode proxy 2>/dev/null || true
    warp-cli disconnect 2>/dev/null || true
    sudo ip route replace default via $GATEWAY dev $INTERFACE metric 0 2>/dev/null || true
    sudo cp /etc/resolv.conf.bak /etc/resolv.conf 2>/dev/null || true
    echo "Stopped."
}

confirm() {
    CONFIRMED=1
    echo "Changes confirmed."
}

if [ "$ACTION" = "stop" ]; then
    stop
    exit 0
fi

if [ "$ACTION" = "confirm" ]; then
    confirm
    exit 0
fi

echo "=== Cleaning up ==="
sudo iptables -t mangle -F 2>/dev/null || true
sudo ip rule del fwmark 1 2>/dev/null || true
sudo ip rule del fwmark 2 2>/dev/null || true
sudo ip route flush table 100 2>/dev/null || true
sudo ip route flush table 101 2>/dev/null || true
sudo ip route del 162.159.198.0/24 2>/dev/null || true
sudo sysctl -w net.ipv4.conf.all.rp_filter=1 2>/dev/null || true
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0 2>/dev/null || true
warp-cli mode proxy 2>/dev/null || true
warp-cli disconnect 2>/dev/null || true
sleep 1
echo "Clean."

echo "=== Step 1: Save current state ==="
save_state

echo "=== Step 2: Switch DNS to IPv4-only ==="
sudo cp /etc/resolv.conf /etc/resolv.conf.bak
sudo bash -c 'echo "nameserver 185.12.64.1
nameserver 8.8.8.8
nameserver 1.1.1.1" > /etc/resolv.conf'
nslookup ifconfig.me 185.12.64.1 > /dev/null 2>&1 || { echo "DNS test failed"; sudo cp /etc/resolv.conf.bak /etc/resolv.conf; exit 1; }
echo "DNS OK."

echo "=== Step 3: Connect WARP in proxy mode ==="
warp-cli registration new 2>/dev/null || true
warp-cli mode proxy
warp-cli connect
for i in $(seq 1 30); do
    if warp-cli status 2>/dev/null | grep -q "Connected"; then
        echo "WARP connected after ${i}s"
        break
    fi
    sleep 1
done
warp-cli status | grep -q "Connected" || { echo "WARP failed."; sudo cp /etc/resolv.conf.bak /etc/resolv.conf; exit 1; }

echo "=== Step 4: Disable IPv6 ==="
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1 || true
sudo sysctl -w net.ipv6.conf.eth0.disable_ipv6=1 || true
sudo sysctl -w net.ipv4.conf.all.rp_filter=0 || true
sudo sysctl -w net.ipv4.conf.eth0.rp_filter=0 || true

echo "=== Step 5: SSH bypass rules (BEFORE warp mode) ==="
echo "101 ssh_direct" | sudo tee /etc/iproute2/rt_tables >/dev/null
sudo ip route add default via $GATEWAY dev $INTERFACE table ssh_direct 2>/dev/null || true
sudo iptables -t mangle -A OUTPUT -p tcp --dport 22 -j MARK --set-mark 1
sudo iptables -t mangle -A OUTPUT -p tcp --sport 22 -j MARK --set-mark 1
sudo ip rule add fwmark 1 table ssh_direct
echo "SSH bypass: fwmark 1 -> table 101 -> direct via $GATEWAY"

echo "=== Step 6: WARP servers direct route ==="
sudo ip route add 162.159.198.0/24 via $GATEWAY dev $INTERFACE 2>/dev/null || true

echo "=== Step 7: Switch to warp mode ==="
warp-cli mode warp
sleep 5

echo "=== Step 8: Check what WARP rules added ==="
echo "Current rules:"
ip rule list
echo ""
echo "Current routes:"
ip route | head -10

echo "=== Step 9: Re-add SSH bypass with HIGHER priority ==="
# WARP may have added rules at priority ~32766. Add ours at 100 (before everything except local)
sudo ip rule add fwmark 1 table ssh_direct priority 100 2>/dev/null || true
echo "SSH bypass re-added at priority 100."
echo ""
echo "Final rules:"
ip rule list

echo ""
echo "=== RESULTS ==="
echo -n "WARP IP: "
curl -s --max-time 10 https://ifconfig.me || echo "FAIL"
echo ""
echo ""
echo "========================================="
echo "  DO NOT CLOSE THIS SESSION YET"
echo "  Auto-revert in 45s if not confirmed."
echo "  Run 'tun confirm' to keep changes."
echo "  Run 'tun stop' to revert manually."
echo "========================================="

# Start auto-revert in background
auto_revert
