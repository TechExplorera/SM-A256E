# Cambios del kernel SM-A256E (Galaxy A25 5G / Exynos 1280, s5e8825)

Kernel base: **Linux 5.10.223** (Android Common Kernel, android12-5.10), código oficial de Samsung para el SM-A256E.

Este documento resume **todo lo que se le ha hecho al kernel**, desde SuSFS hasta el último cambio (overclock + zram), con instrucciones para compilar, flashear y verificar.

---

## Resumen de cambios

| # | Cambio | Archivos principales |
|---|--------|----------------------|
| 1 | **SuSFS v2.4.0** integrado | `fs/susfs.c`, `include/linux/susfs*.h`, +27 archivos parcheados |
| 2 | **SukiSU (KernelSU)** integrado, rama `builtin` | `drivers/kernelsu/` |
| 3 | Enganche de SukiSU al kernel | `drivers/Makefile`, `drivers/Kconfig` |
| 4 | KSU + KPM + SuSFS activados | `arch/arm64/configs/peta_defconfig`, `petardo_defconfig` |
| 5 | Corrección de compilación | `kernel/sched/ems/sysbusy.c` |
| 6 | Workflow de compilación (GitHub Actions) | `.github/workflows/build-kernel.yml` |
| 7 | Script de integración desde el código original | `integration/integrate_sukisu_susfs.sh` |
| 8 | **zram por defecto a lz4** | `drivers/block/zram/zram_drv.c` |
| 9 | **Overclock: cluster grande 2400 → 2600 MHz** | `arch/arm64/boot/dts/exynos/s5e8825.dts` |

En total: **213 archivos** modificados o añadidos respecto al código original de Samsung.

---

## Detalle de cada cambio

### 1. SuSFS v2.4.0
De `simonpunk/susfs4ksu`, rama `gki-android12-5.10`. Añade `fs/susfs.c`, `include/linux/susfs.h`, `include/linux/susfs_def.h` y aplica el parche `50_add_susfs_in_gki-android12-5.10.patch` (hooks en `fs/`, `fs/proc/`, `selinux/`, `kernel/`, `mm/`). Cuatro bloques se colocaron a mano por el contexto distinto del árbol de Samsung (`fs/exec.c`, `fs/namespace.c` ×2, `fs/proc/base.c`); en `copy_mnt_ns()` el flag `CL_COPY_MNT_NS` va antes de la rama `CONFIG_KDP_NS` de Samsung.

### 2. SukiSU (KernelSU)
De `SukiSU-Ultra`, rama **`builtin`** (la que trae las opciones de SuSFS y usa los *inline hooks*). Copiado a `drivers/kernelsu/` (copia, no symlink, para que funcione en CI).

### 3. Enganche
- `drivers/Makefile`: `obj-$(CONFIG_KSU) += kernelsu/`
- `drivers/Kconfig`: `source "drivers/kernelsu/Kconfig"`

### 4. Opciones en los defconfig (`peta` y `petardo`)
`CONFIG_KSU=y`, `CONFIG_KPM=y`, `CONFIG_KSU_SUSFS=y` y todas las funciones `CONFIG_KSU_SUSFS_*` (SUS_PATH, SUS_MOUNT, SUS_KSTAT, SPOOF_UNAME, ENABLE_LOG, HIDE_KSU_SUSFS_SYMBOLS, SPOOF_CMDLINE_OR_BOOTCONFIG, OPEN_REDIRECT, SUS_MAP). Se quitó el inválido `CONFIG_KSU=n`.

### 5. Corrección `sysbusy.c`
`kernel/sched/ems/sysbusy.c`: a `cpn_next_cpu` le faltaba el tipo `int`. El kernel compila con `-Werror=implicit-int`, así que rompía el build.

### 6. Workflow de compilación
`.github/workflows/build-kernel.yml`: compila con el clang oficial de AOSP `clang-r416183b` (en caché), dentro del árbol. Push a `main`, PRs y manual (eligiendo defconfig). Si `CONFIG_KPM=y`, parchea la `Image` con `patch_linux` de SukiSU; paso no fatal (la `Image` sin parchear queda como `Image.nokpm`). Sube `Image`, módulos `.ko`, `.config` y logs.

### 7. Script de integración
`integration/integrate_sukisu_susfs.sh`: reproduce TODO lo anterior **sobre el código original de Samsung**. Idempotente. Ver `integration/README.md`.

### 8. zram → lz4
`drivers/block/zram/zram_drv.c`: compresor por defecto `lzo-rle` → `lz4` (`CONFIG_CRYPTO_LZ4=y` ya estaba). **Nota:** en Android el `swapon` del vendor puede fijar el compresor por su cuenta; si no toma, se ajusta por userspace (fstab/init).

### 9. Overclock cluster grande (2600 MHz)
`arch/arm64/boot/dts/exynos/s5e8825.dts`, nodo `exynos-acme domain@1` (cluster grande A78): `max-freq` 2400000 → 2600000 y se añade el paso 2600 al `freq-table`. El CAL/ECT de Samsung ya define el punto de 2600 MHz ("SOD"); solo estaba capado en el dts.

**Seguro por diseño:** el driver usa `domain->max_freq = min(ECT_max, dts_max)` y descarta del `freq-table` lo que esté por encima. Si el ECT del dispositivo **no** trae 2600, el paso se ignora y el cluster se queda en 2400 (sin riesgo de arranque).

- Cluster chico (A55) y GPU (Mali) quedan de fábrica: no tienen un punto de voltaje superior; subirlos exigiría inventar uno (riesgo alto).

---

## Cómo compilar

### Opción A — GitHub Actions (recomendado)
**Actions → Build kernel (A256E) → Run workflow**, eligiendo `peta_defconfig`. Al terminar, descarga el artefacto (`Image`, módulos, `.config`, logs).

### Opción B — Local
Requiere el toolchain clang de AOSP `clang-r416183b`. Resumido:

```bash
export PATH=<toolchain>/clang-r416183b/bin:$PATH
make ARCH=arm64 LLVM=1 LLVM_IAS=1 PLATFORM_VERSION=12 ANDROID_MAJOR_VERSION=s \
     TARGET_SOC=s5e8825 CROSS_COMPILE=aarch64-linux-gnu- peta_defconfig
make ARCH=arm64 LLVM=1 LLVM_IAS=1 PLATFORM_VERSION=12 ANDROID_MAJOR_VERSION=s \
     TARGET_SOC=s5e8825 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)"
```

Salida: `arch/arm64/boot/Image` y el dtb en `arch/arm64/boot/dts/exynos/`.

---

## Cómo flashear

1. **Haz respaldo de tu `boot.img` actual** antes de nada.
2. Mete el `Image` (y el dtb/dtbo si cambió) en tu `boot.img` original, con **magiskboot** o un zip de **AnyKernel3**.
3. Flashea el `boot.img` resultante (fastboot/Odin/recovery, según tu método).
4. Instala la app **SukiSU-Nova Manager** para gestionar root y módulos.

> Sin firmar módulos: `CONFIG_MODULE_SIG` está desactivado en el defconfig, así que los `.ko` cargan sin firma.

---

## Cómo verificar en el dispositivo (con root)

```bash
# SuSFS / SukiSU: desde la app Manager (versión de kernel y "SUSFS Inline Hook")

# Overclock cluster grande (debe aparecer 2600000 al final):
cat /sys/devices/system/cpu/cpufreq/policy6/scaling_available_frequencies

# Frecuencia actual del cluster grande:
cat /sys/devices/system/cpu/cpufreq/policy6/scaling_cur_freq

# Compresor de zram (el activo va entre corchetes, debería ser lz4):
cat /sys/block/zram0/comp_algorithm
```

Si `scaling_available_frequencies` sigue mostrando `2400000` como máximo, el ECT del dispositivo no trae el paso de 2600 y la única vía sería editar el blob ECT (más complejo).

---

## Avisos

- **Overclock**: sube calor y batería; en sesiones largas puede hacer *throttling*. En juegos el impacto es modesto porque el límite suele ser la GPU (que no se tocó). Todo es reversible reflasheando.
- **Root/SuSFS**: puede afectar a banca, pagos y apps con detección de root; usa el ocultamiento de SuSFS según necesites.
- **Garantía / Knox**: desbloquear bootloader y flashear dispara Knox de forma permanente.
