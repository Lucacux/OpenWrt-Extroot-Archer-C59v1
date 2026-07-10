#!/bin/sh
# ============================================================================
# Extroot en TP-Link Archer C59 v1 (OpenWrt 25.12.x)
# ----------------------------------------------------------------------------
# Mueve /overlay a un pendrive USB ext4. NO toca zram ni la estrofa
# `config swap` del fstab. Idempotente en lo razonable.
#
# Prerrequisitos (ya en la imagen): block-mount, kmod-fs-ext4,
# kmod-usb-storage, kmod-usb2, e2fsprogs.
#
# USO: revisar cada bloque y ejecutar a mano. Requiere reboot al final.
#      Ejecutar por SSH como root. AJUSTAR la variable USB si no es /dev/sda1.
# ============================================================================
set -e

USB=/dev/sda1

echo "== 0) Chequeos previos =="
[ -b "$USB" ] || { echo "No existe $USB (¿pendrive conectado?)"; exit 1; }
block info "$USB" | grep -q 'TYPE="ext4"' || { echo "$USB no es ext4"; exit 1; }
UUID=$(block info "$USB" | grep -o 'UUID="[^"]*"' | head -1 | cut -d'"' -f2)
echo "UUID del USB: $UUID"

echo "== 1) Backups (config + contenido previo del USB) =="
umask 077
sysupgrade -b /tmp/owrt-config-backup-$(date +%Y%m%d-%H%M).tar.gz
mkdir -p /tmp/usbcheck
mount -o ro "$USB" /tmp/usbcheck
tar -C /tmp/usbcheck -czf /tmp/usb-old-overlay-$(date +%Y%m%d-%H%M).tar.gz . 2>/dev/null || true
umount /tmp/usbcheck
echo "Backups en /tmp (copialos fuera del router: son tmpfs y se pierden al reboot)."

echo "== 2) Corregir SOLO la estrofa extroot del fstab =="
# Snapshot del swap ANTES, como invariante a preservar:
cat /proc/swaps
uci set fstab.@mount[0].target='/overlay'
uci set fstab.@mount[0].uuid="$UUID"
uci set fstab.@mount[0].enabled='1'
uci commit fstab
echo "--- fstab resultante ---"
cat /etc/config/fstab

echo "== 3) Poblar el USB con el overlay ACTUAL (no el viejo) =="
mount "$USB" /mnt
rm -rf /mnt/upper /mnt/work
cp -a /overlay/upper /overlay/work /mnt/
sync
umount /mnt

echo "== 4) Reboot para aplicar =="
echo "Ejecutá:  reboot"
echo "Tras el reboot verificá:  df -h /overlay   (debe ser $USB, varios GB)"
echo "Y que zram siga igual:    cat /proc/swaps  (/dev/zram0 sin cambios)"
