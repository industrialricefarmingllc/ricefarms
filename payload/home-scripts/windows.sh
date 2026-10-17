#!/bin/bash
set -e
# windows.sh - reboot/shutdown once into VeraCrypt BootLoader without changing BootOrder
# Uses UEFI BootNext (efibootmgr -n) - cleared after one boot, permanent BootOrder untouched
# Target: VeraCrypt BootLoader (DcsBoot) - BootDC5B - \EFI\VERACRYPT\DCSBOOT.EFI
# Verified via: efibootmgr -v | grep -i veracrypt
TARGET="DC5B"
DESC="VeraCrypt BootLoader (DcsBoot)"

# allow --shutdown / -s to poweroff instead of reboot (next power-on will still hit BootNext)
MODE="reboot"
if [[ "$1" == "--shutdown" || "$1" == "-s" ]]; then
  MODE="shutdown"
fi

echo "Setting BootNext to $TARGET ($DESC) for one-time boot..."
if ! efibootmgr -n "$TARGET" 2>&1; then
  echo "Failed to set BootNext with efibootmgr. Trying with sudo..."
  sudo efibootmgr -n "$TARGET"
fi

echo "Verifying BootNext:"
efibootmgr | grep -E "BootNext|BootCurrent|BootOrder" || efibootmgr

if [[ "$MODE" == "shutdown" ]]; then
  echo "Shutting down - next power-on will boot into $DESC..."
  sudo shutdown -h now
else
  echo "Rebooting to $DESC..."
  sudo shutdown -r now
fi
