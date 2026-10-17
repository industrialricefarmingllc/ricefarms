GATEWAY=$(ip route show default | grep -v tun | head -1 | awk '{print $3}')
INTERFACE=$(ip route show default | grep -v tun | head -1 | awk '{print $5}')
sudo ip route replace default via $GATEWAY dev $INTERFACE metric 0 2>/dev/null
