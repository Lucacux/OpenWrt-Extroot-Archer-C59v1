# OpenWrt Extroot — TP-Link Archer C59 v1

Documentación y procedimiento reproducible para habilitar **extroot** (mover el
`/overlay` a un pendrive USB) en un **TP-Link Archer C59 v1** corriendo
**OpenWrt 25.12.x**, más el **post-mortem** de por qué se rompió tras un reflash
y cómo evitarlo en el futuro.

> Extroot y **zram** conviven sin problema: son cosas ortogonales. zram es swap
> comprimido en RAM (`/dev/zram0`); extroot mueve el almacenamiento del overlay
> al USB. Este procedimiento **no toca** la configuración de zram.

---

## Hardware / entorno

| Ítem | Valor |
|---|---|
| Equipo | TP-Link Archer C59 v1 (`tplink,archer-c59-v1`) |
| SoC / target | Qualcomm QCA9563 — `ath79/generic` |
| RAM | 128 MB (~118 MB útiles) |
| Flash | 16 MB NOR → overlay interno **~4 MB** (jffs2) |
| OpenWrt | 25.12.5 (`r33051`), gestor de paquetes **apk** |
| USB | Pendrive 16 GB, partición única **ext4** |

Con solo ~4 MB de overlay interno, cualquier uso serio (adblock, DoH, logs,
paquetes extra) llena la flash y la **desgasta**. Extroot resuelve esto llevando
el overlay a un USB de 16 GB.

---

## Post-mortem: por qué extroot dejó de funcionar

Extroot venía funcionando hasta ~fin de mayo. Se rompió y el router quedó
booteando en los ~4 MB de flash interna. Reconstrucción por fechas de archivos:

| Evidencia | Fecha | Interpretación |
|---|---|---|
| `/rom/etc/openwrt_release`, `/etc/apk/world`, `/sbin/block` | **29-jun** | Se **reflasheó/sysupgradeó** a 25.12.5. |
| `/etc/config/fstab` | **12-feb** | El fstab quedó **viejo**, preservado del sistema anterior. |
| overlay del USB (`upper/etc`) | 25-may | Última escritura del extroot viejo antes del corte. |

**Causa raíz — dos fallas combinadas en `/etc/config/fstab`:**

1. `config mount` de `/overlay` con **`option enabled '0'`** → `block-mount` lo ignora en el boot.
2. **`option uuid` apuntaba a un USB que ya no existe** (`f839c3e4-…`), mientras que
   el pendrive actual tiene otro UUID (`ccb76309-…`, reformateado en algún momento).

Resultado: aunque los paquetes (`block-mount`, `kmod-fs-ext4`, `kmod-usb-storage`,
`e2fsprogs`) estaban instalados y el USB estaba sano, el sistema **nunca montaba**
el overlay externo y caía a la flash interna.

> **No fue** que otra configuración "pisara" el extroot. Fue un **reflash que dejó
> un fstab desincronizado** (deshabilitado + UUID de un USB anterior), y las
> customizaciones no se reaplicaron después del flash.

---

## Diagnóstico (cómo detectar que extroot NO está activo)

```sh
df -h /overlay
# ROTO:   /overlay en /dev/mtdblockX (jffs2), pocos MB
# OK:     /overlay en /dev/sda1, varios GB

block info | grep sda1
# el USB debe figurar con  MOUNT="/overlay"

cat /etc/config/fstab      # revisar 'config mount': enabled y uuid
block info                 # UUID real del USB (debe coincidir con el fstab)
```

---

## Solución (procedimiento aplicado)

> Prerrequisitos (ya presentes en esta imagen): `block-mount`, `kmod-fs-ext4`,
> `kmod-usb-storage`, `kmod-usb2`, `e2fsprogs`.

Ver `setup-extroot.sh` para el script completo y comentado. Resumen:

1. **Backup** de la config (`sysupgrade -b`) y del contenido previo del USB.
2. **Corregir SOLO la estrofa `config mount`** del fstab con el UUID real del USB
   y `enabled '1'` (sin tocar `config swap` ni zram):
   ```sh
   UUID=$(block info /dev/sda1 | grep -o 'UUID="[^"]*"' | cut -d'"' -f2)
   uci set fstab.@mount[0].target='/overlay'
   uci set fstab.@mount[0].uuid="$UUID"
   uci set fstab.@mount[0].enabled='1'
   uci commit fstab
   ```
3. **Poblar el USB con el overlay ACTUAL** (no el viejo, que es de otra versión):
   ```sh
   mount /dev/sda1 /mnt
   rm -rf /mnt/upper /mnt/work        # limpia overlay viejo (respaldado antes)
   cp -a /overlay/upper /overlay/work /mnt/
   sync && umount /mnt
   ```
4. **Reboot** y verificar.

---

## Convivencia con zram (importante)

Este equipo depende de **zram** para no morir por OOM (128 MB de RAM). Extroot
**no** interfiere:

- zram = `/dev/zram0`, swap comprimido en RAM (paquete `zram-swap`).
- extroot = `/overlay` en USB, almacenamiento.

El procedimiento **no modifica** `rc.local`, el paquete `zram-swap`, ni la estrofa
`config swap` del fstab. Antes y después del cambio, `cat /proc/swaps` debe mostrar
`/dev/zram0` idéntico.

> Nota: el fstab traía una entrada huérfana `config swap → /overlay/swap` (el
> archivo no existe; el `swapon` falla en silencio). Se dejó **sin tocar** para no
> arriesgar el swap; se puede limpiar aparte si se desea.

---

## Cómo evitar que se rompa en el próximo sysupgrade

El overlay externo **no** se conserva en un `sysupgrade`. Para no repetir el corte:

1. **Antes** del sysupgrade: deshabilitar extroot (`uci set fstab.@mount[0].enabled='0'; uci commit fstab`) para bootear limpio en flash interna.
2. Hacer el sysupgrade **conservando settings**.
3. **Después**: reinstalar `block-mount` + kmods si faltan, **regenerar el UUID en el fstab con el del USB actual** (¡acá estuvo el bug!), re-poblar el overlay y `enabled '1'`.
4. Si se reformatea/cambia el pendrive, **siempre** re-leer el UUID con `block info` — nunca asumir el viejo.

---

## Verificación final (estado OK)

```
/dev/sda1        14.6G   2.3M   13.8G   0%   /overlay
overlayfs:/overlay ...                        /
/dev/sda1: UUID="ccb76309-…" MOUNT="/overlay" TYPE="ext4"
/dev/zram0  partition  81916  0  100         # zram intacto
```
