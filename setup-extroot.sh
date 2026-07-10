#!/bin/sh
# ============================================================================
# Extroot on TP-Link Archer C59 v1 (OpenWrt 25.12.x)
# ----------------------------------------------------------------------------
# Moves /overlay to a USB ext4 drive. Does NOT touch zram or the `config swap`
# fstab stanza. Reasonably idempotent.
#
# Prerequisites (already in the image): block-mount, kmod-fs-ext4,
# kmod-usb-storage, kmod-usb2, e2fsprogs.
#
# USAGE: review each block and run by hand. Requires a reboot at the end.
#        Run over SSH as root. ADJUST the USB variable if it is not /dev/sda1.
# ============================================================================
set -e

USB=/dev/sda1

echo "== 0) Pre-flight checks =="
[ -b "$USB" ] || { echo "$USB does not exist (is the USB plugged in?)"; exit 1; }
block info "$USB" | grep -q 'TYPE="ext4"' || { echo "$USB is not ext4"; exit 1; }
UUID=$(block info "$USB" | grep -o 'UUID="[^"]*"' | head -1 | cut -d'"' -f2)
echo "USB UUID: $UUID"

echo "== 1) Backups (config + previous USB contents) =="
umask 077
sysupgrade -b /tmp/owrt-config-backup-$(date +%Y%m%d-%H%M).tar.gz
mkdir -p /tmp/usbcheck
mount -o ro "$USB" /tmp/usbcheck
tar -C /tmp/usbcheck -czf /tmp/usb-old-overlay-$(date +%Y%m%d-%H%M).tar.gz . 2>/dev/null || true
umount /tmp/usbcheck
echo "Backups in /tmp (copy them off the router: /tmp is tmpfs and is lost on reboot)."

echo "== 2) Fix ONLY the extroot fstab stanza =="
# Snapshot of swap BEFORE, as the invariant to preserve:
cat /proc/swaps
uci set fstab.@mount[0].target='/overlay'
uci set fstab.@mount[0].uuid="$UUID"
uci set fstab.@mount[0].enabled='1'
uci commit fstab
echo "--- resulting fstab ---"
cat /etc/config/fstab

echo "== 3) Populate the USB with the CURRENT overlay (not the old one) =="
mount "$USB" /mnt
rm -rf /mnt/upper /mnt/work
cp -a /overlay/upper /overlay/work /mnt/
sync
umount /mnt

echo "== 4) Reboot to apply =="
echo "Run:  reboot"
echo "After reboot verify:  df -h /overlay   (must be $USB, several GB)"
echo "And that zram is unchanged:  cat /proc/swaps  (/dev/zram0 unchanged)"
