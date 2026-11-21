# Integración de SukiSU + SuSFS por script

`integrate_sukisu_susfs.sh` aplica, sobre el **código original de Samsung** (SM-A256E, Linux 5.10.223), lo mismo que ya está incluido en esta rama:

1. **SuSFS v2.4.0**: descarga `simonpunk/susfs4ksu` (rama `gki-android12-5.10`), copia `fs/susfs.c` e `include/linux/susfs*.h` y aplica `50_add_susfs_in_gki-android12-5.10.patch`. Corrige a mano los 4 bloques que no aplican sobre el árbol de Samsung (`fs/exec.c`, `fs/namespace.c` ×2, `fs/proc/base.c`). Si aparece cualquier otro rechazo, se detiene.
2. **SukiSU** (rama `builtin`, que trae SuSFS integrado): lo copia a `drivers/kernelsu` y lo enlaza en `drivers/Makefile` y `drivers/Kconfig`.
3. Corrige `kernel/sched/ems/sysbusy.c` (falta el tipo `int`; el kernel usa `-Werror=implicit-int`).
4. Activa `CONFIG_KSU`, `CONFIG_KPM` y todas las opciones `CONFIG_KSU_SUSFS_*` en `peta_defconfig` y `petardo_defconfig`.

Por defecto usa los commits probados (SuSFS `784ac9e`, SukiSU `4bec532`). Se puede ejecutar varias veces sin duplicar cambios.

## Uso

```bash
git clone https://github.com/TechExplorera/SM-A256E && cd SM-A256E
bash integration/integrate_sukisu_susfs.sh .
```

Opciones:

| Opción | Efecto |
|---|---|
| `--latest` | Usa lo último de ambas ramas en vez de los commits probados (puede fallar si cambian los parches) |
| `--susfs-ref REF` / `--sukisu-ref REF` | Fija otro commit o rama |
| `--defconfigs "a b"` | Defconfigs a modificar |
| `--no-kpm` | No activa `CONFIG_KPM` |
| `--symlink` | Copia SukiSU a `KernelSU/` y enlaza `drivers/kernelsu` con un symlink (como `setup.sh`) |

Requiere `git`, `patch`, `python3` y acceso a gitlab.com y github.com.

## Desde GitHub Actions

**Actions → Build kernel (A256E) → Run workflow**, con `metodo = script`. El workflow descarga el código original de `main` (`base_ref`), ejecuta el script y compila. En `script_args` se pueden pasar opciones, por ejemplo `--latest`.

## Comprobado

- Sobre el commit original `b20770f8b`, el resultado es idéntico byte a byte a esta rama (208 archivos).
- Ejecutarlo dos veces no cambia nada.
- `--no-kpm` y `--symlink` funcionan.
