# OpenWrt Extroot — TP-Link Archer C59 v1

Reproducible procedure to enable **extroot** (moving `/overlay` to a USB flash
drive) on a **TP-Link Archer C59 v1** running **OpenWrt 25.12.x**, plus the
**post-mortem** of why it broke after a reflash and how to avoid it in the future.

> Extroot and **zram** coexist with no conflict: they are orthogonal. zram is
> compressed RAM swap (`/dev/zram0`); extroot moves the overlay *storage* to the
> USB. This procedure **does not touch** the zram configuration.

---

## Hardware / environment

| Item | Value |
|---|---|
| Device | TP-Link Archer C59 v1 (`tplink,archer-c59-v1`) |
| SoC / target | Qualcomm QCA9563 — `ath79/generic` |
| RAM | 128 MB (~118 MB usable) |
| Flash | 16 MB NOR → internal overlay **~4 MB** (jffs2) |
| OpenWrt | 25.12.5 (`r33051`), package manager **apk** |
| USB | 16 GB flash drive, single **ext4** partition |

With only ~4 MB of internal overlay, any real workload (adblock, DoH, logs, extra
packages) fills the flash and **wears it out**. Extroot fixes this by moving the
overlay to a 16 GB USB drive.

---

## Post-mortem: why extroot stopped working

Extroot had been working until ~late May. It broke and the router ended up booting
on the ~4 MB of internal flash. Timeline reconstructed from file dates:

| Evidence | Date | Interpretation |
|---|---|---|
| `/rom/etc/openwrt_release`, `/etc/apk/world`, `/sbin/block` | **Jun 29** | Router was **reflashed/sysupgraded** to 25.12.5. |
| `/etc/config/fstab` | **Feb 12** | The fstab was **stale**, carried over from the previous system. |
| USB overlay (`upper/etc`) | May 25 | Last write of the old extroot before it stopped. |

**Root cause — two combined faults in `/etc/config/fstab`:**

1. The `/overlay` `config mount` had **`option enabled '0'`** → `block-mount` skips it at boot.
2. **`option uuid` pointed to a USB that no longer exists** (`f839c3e4-…`), while the
   current drive has a different UUID (`ccb76309-…`, reformatted at some point).

Result: even though the packages (`block-mount`, `kmod-fs-ext4`, `kmod-usb-storage`,
`e2fsprogs`) were installed and the USB was healthy, the system **never mounted** the
external overlay and fell back to internal flash.

> This was **not** a case of one config "overwriting" the extroot. It was a **reflash
> that left a desynchronized fstab** (disabled + a UUID from a previous USB), and the
> customizations were never reapplied after the flash.

---

## Diagnosis (how to tell extroot is NOT active)

```sh
df -h /overlay
# BROKEN:  /overlay on /dev/mtdblockX (jffs2), a few MB
# OK:      /overlay on /dev/sda1, several GB

block info | grep sda1
# the USB must show  MOUNT="/overlay"

cat /etc/config/fstab      # check the 'config mount': enabled and uuid
block info                 # real UUID of the USB (must match the fstab)
```

---

## Fix (applied procedure)

> Prerequisites (already present in this image): `block-mount`, `kmod-fs-ext4`,
> `kmod-usb-storage`, `kmod-usb2`, `e2fsprogs`.

See `setup-extroot.sh` for the full, commented script. Summary:

1. **Back up** the config (`sysupgrade -b`) and the USB's previous contents.
2. **Fix ONLY the `config mount` stanza** in fstab with the real USB UUID and
   `enabled '1'` (without touching `config swap` or zram):
   ```sh
   UUID=$(block info /dev/sda1 | grep -o 'UUID="[^"]*"' | cut -d'"' -f2)
   uci set fstab.@mount[0].target='/overlay'
   uci set fstab.@mount[0].uuid="$UUID"
   uci set fstab.@mount[0].enabled='1'
   uci commit fstab
   ```
3. **Populate the USB with the CURRENT overlay** (not the old one, which belongs to
   a different version):
   ```sh
   mount /dev/sda1 /mnt
   rm -rf /mnt/upper /mnt/work        # remove old overlay (backed up beforehand)
   cp -a /overlay/upper /overlay/work /mnt/
   sync && umount /mnt
   ```
4. **Reboot** and verify.

---

## Coexistence with zram (important)

This device relies on **zram** to avoid OOM (128 MB of RAM). Extroot does **not**
interfere:

- zram = `/dev/zram0`, compressed RAM swap (`zram-swap` package).
- extroot = `/overlay` on USB, storage.

The procedure **does not modify** `rc.local`, the `zram-swap` package, or the
`config swap` stanza in fstab. Before and after the change, `cat /proc/swaps` must
show `/dev/zram0` unchanged.

> Note: the fstab carried an orphan `config swap → /overlay/swap` entry (the file
> does not exist; the `swapon` fails silently). It was left **untouched** to avoid
> risking swap; it can be cleaned up separately if desired.

---

## How to avoid breaking it on the next sysupgrade

The external overlay is **not** preserved across a `sysupgrade`. To avoid a repeat:

1. **Before** the sysupgrade: disable extroot (`uci set fstab.@mount[0].enabled='0'; uci commit fstab`) so it boots cleanly on internal flash.
2. Run the sysupgrade **keeping settings**.
3. **After**: reinstall `block-mount` + kmods if missing, **regenerate the fstab UUID with the current USB's** (this was the bug!), repopulate the overlay, and set `enabled '1'`.
4. If the drive is reformatted/replaced, **always** re-read the UUID with `block info` — never assume the old one.

---

## Final verification (healthy state)

```
/dev/sda1        14.6G   2.3M   13.8G   0%   /overlay
overlayfs:/overlay ...                        /
/dev/sda1: UUID="ccb76309-…" MOUNT="/overlay" TYPE="ext4"
/dev/zram0  partition  81916  0  100         # zram untouched
```
