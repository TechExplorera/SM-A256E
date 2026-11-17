#!/usr/bin/env bash
# Integra SukiSU (rama builtin, requiere SuSFS) + SuSFS en el kernel original de Samsung SM-A256E
# (Linux 5.10, android12-5.10). Es idempotente: se puede ejecutar varias veces.
#
# Uso:
#   integration/integrate_sukisu_susfs.sh [opciones] [DIR_KERNEL]
#
# Opciones:
#   --susfs-ref REF     Commit/rama de susfs4ksu (por defecto: commit probado)
#   --sukisu-ref REF    Commit/rama de SukiSU-Ultra (por defecto: commit probado)
#   --latest            Usar lo último de ambas ramas (puede romper los parches)
#   --defconfigs "a b"  Defconfigs a activar (por defecto: "peta_defconfig petardo_defconfig")
#   --no-kpm            No activar CONFIG_KPM
#   --symlink           Enlazar drivers/kernelsu con symlink en vez de copiar
#   -h, --help          Mostrar esta ayuda
set -euo pipefail

SUSFS_REPO=https://gitlab.com/simonpunk/susfs4ksu.git
SUSFS_BRANCH=gki-android12-5.10
SUSFS_REF=784ac9e6fd49bb02499b5b60c57ccc9d0c680204
SUKISU_REPO=https://github.com/SukiSU-Ultra/SukiSU-Ultra.git
SUKISU_BRANCH=builtin
SUKISU_REF=4bec532dd447e2852aa8932afa768255350c103a
DEFCONFIGS="peta_defconfig petardo_defconfig"
KPM=y
SYMLINK=0
KDIR=.

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --susfs-ref)  SUSFS_REF=$2; shift ;;
    --sukisu-ref) SUKISU_REF=$2; shift ;;
    --latest)     SUSFS_REF=$SUSFS_BRANCH; SUKISU_REF=$SUKISU_BRANCH ;;
    --defconfigs) DEFCONFIGS=$2; shift ;;
    --no-kpm)     KPM=n ;;
    --symlink)    SYMLINK=1 ;;
    -h|--help)    usage; exit 0 ;;
    -*)           die "Opción desconocida: $1" ;;
    *)            KDIR=$1 ;;
  esac
  shift
done

KDIR=$(cd "$KDIR" && pwd)
cd "$KDIR"
[ -f Makefile ] && [ -d drivers ] && [ -d fs ] || die "$KDIR no parece un árbol del kernel"
KVER=$(awk '/^VERSION =/{v=$3}/^PATCHLEVEL =/{p=$3}END{print v"."p}' Makefile)
[ "$KVER" = "5.10" ] || warn "Kernel $KVER: los parches están pensados para 5.10"
for t in git patch python3; do command -v $t >/dev/null || die "Falta la herramienta: $t"; done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fetch() { # repo branch ref dest
  git init -q "$4"
  git -C "$4" remote add origin "$1"
  if ! git -C "$4" fetch -q --depth 1 origin "$3" 2>/dev/null; then
    git -C "$4" fetch -q origin "$2"
  fi
  git -C "$4" checkout -q FETCH_HEAD 2>/dev/null || true
  git -C "$4" checkout -q "$3" 2>/dev/null || die "No se encontró $3 en $1"
  log "$(basename "$1" .git): $(git -C "$4" log -1 --format='%h %ad %s' --date=short)"
}

# ---------------------------------------------------------------- 1. SuSFS
log "Descargando SuSFS ($SUSFS_BRANCH)"
  fetch "$SUSFS_REPO" "$SUSFS_BRANCH" "$SUSFS_REF" "$WORK/susfs"
  KP=$WORK/susfs/kernel_patches
  cp "$KP"/fs/* fs/
  cp "$KP"/include/linux/* include/linux/

  if grep -q 'CONFIG_KSU_SUSFS' fs/open.c; then
    log "Parche SuSFS ya aplicado, se omite"
  else
    log "Aplicando 50_add_susfs_in_gki-android12-5.10.patch"
    patch -p1 --forward --no-backup-if-mismatch -r "$WORK/rejects" \
      < "$KP/50_add_susfs_in_gki-android12-5.10.patch" > "$WORK/patch.log" || true
    grep -E 'FAILED' "$WORK/patch.log" | sed 's/^/    /' || true
  fi

  # Bloques que no aplican sobre el árbol de Samsung (contexto distinto por
  # cpufreq_times, task_integrity/proca y CONFIG_KDP_NS). Se insertan a mano.
  python3 - <<'PY'
import sys
def ins(path, anchor, text, after=True, marker=None):
    s = open(path).read()
    if (marker or text.strip()) in s:
        return
    if s.count(anchor) != 1:
        sys.exit(f"[x] {path}: no se encontró un único ancla para el bloque manual")
    s = s.replace(anchor, anchor + text if after else text + anchor)
    open(path, "w").write(s)
    print(f"    corregido a mano: {path}")

ins("fs/exec.c", "#include <linux/io_uring.h>\n",
    "#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif\n")
ins("fs/namespace.c", "#include <linux/shmem_fs.h>\n",
    "#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif // #ifdef CONFIG_KSU_SUSFS\n")
ins("fs/namespace.c", '#include "internal.h"\n',
    "\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
    "extern bool susfs_is_current_ksu_domain(void);\n"
    "extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n\n"
    "#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\n\n"
    "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n",
    marker="#define CL_COPY_MNT_NS BIT(25)")
# En copy_mnt_ns(): entre CL_SHARED_TO_SLAVE y la rama CONFIG_KDP_NS de Samsung
ins("fs/namespace.c", "#ifdef CONFIG_KDP_NS\n\tnew = copy_tree(",
    "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\tcopy_flags |= CL_COPY_MNT_NS;\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n",
    after=False, marker="\tcopy_flags |= CL_COPY_MNT_NS;")
ins("fs/proc/base.c", "#include <linux/cpufreq_times.h>\n",
    "#if defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n"
    "#include <linux/susfs_def.h>\n"
    "#endif // #if defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n")
PY

  # Cualquier rechazo que no sea de los 4 conocidos es un error real
  if [ -d "$WORK/rejects" ] || [ -f "$WORK/rejects" ]; then
    other=$(grep -E '^(\+\+\+|---) ' "$WORK/rejects" 2>/dev/null | awk '{print $2}' | sort -u |
            grep -vE '^(fs/exec\.c|fs/namespace\.c|fs/proc/base\.c)$' || true)
    [ -z "$other" ] || die "Bloques rechazados no previstos en: $other"
  fi
  grep -q 'CL_COPY_MNT_NS;' fs/namespace.c || die "SuSFS no quedó aplicado en fs/namespace.c"
  log "SuSFS $(grep -m1 SUSFS_VERSION include/linux/susfs.h | cut -d'"' -f2) integrado"

# --------------------------------------------------------------- 2. SukiSU
log "Descargando SukiSU ($SUKISU_BRANCH)"
fetch "$SUKISU_REPO" "$SUKISU_BRANCH" "$SUKISU_REF" "$WORK/sukisu"
rm -rf drivers/kernelsu
if [ $SYMLINK = 1 ]; then
  rm -rf KernelSU && cp -r "$WORK/sukisu" KernelSU && rm -rf KernelSU/.git
  ln -s ../KernelSU/kernel drivers/kernelsu
else
  cp -r "$WORK/sukisu/kernel" drivers/kernelsu
fi
rm -f drivers/kernelsu/setup.sh
grep -q 'kernelsu/' drivers/Makefile || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig ||
  sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"\n' drivers/Kconfig
log "SukiSU integrado en drivers/kernelsu"

# ------------------------------------------------- 3. Corrección de compilación
# kernel/sched/ems/sysbusy.c: falta el tipo (-Werror=implicit-int)
if [ -f kernel/sched/ems/sysbusy.c ] && grep -q '^static cpn_next_cpu\[' kernel/sched/ems/sysbusy.c; then
  sed -i 's/^static cpn_next_cpu\[/static int cpn_next_cpu[/' kernel/sched/ems/sysbusy.c
  log "Corregido kernel/sched/ems/sysbusy.c"
fi

# ------------------------------------------------------------- 4. Defconfigs
for d in $DEFCONFIGS; do
  f=arch/arm64/configs/$d
  [ -f "$f" ] || { warn "No existe $f, se omite"; continue; }
  sed -i -E '/^CONFIG_(KSU|KSU_[A-Z_]+|KPM)=/d; /^# CONFIG_(KSU|KSU_[A-Z_]+|KPM) is not set/d' "$f"
  {
    echo "CONFIG_KSU=y"
    [ $KPM = y ] && echo "CONFIG_KPM=y"
    for o in SUSFS SUSFS_SUS_PATH SUSFS_SUS_MOUNT SUSFS_SUS_KSTAT SUSFS_SPOOF_UNAME \
             SUSFS_ENABLE_LOG SUSFS_HIDE_KSU_SUSFS_SYMBOLS SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
             SUSFS_OPEN_REDIRECT SUSFS_SUS_MAP; do echo "CONFIG_KSU_$o=y"; done
  } >> "$f"
  log "Activado KernelSU en $d (KPM=$KPM, SuSFS=y)"
done

log "Listo. Compila con: make <defconfig> && make (ver build_kernel.sh)"
