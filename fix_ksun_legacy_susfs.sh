#!/usr/bin/env bash
# fix_ksun_legacy_susfs.sh
#
# CI step: make KernelSU-Next (legacy branch) SUSFS-compatible for
# LineageOS android_kernel_oneplus_sm8250 (lineage-24.0, 4.19).
#
# Runs AFTER your "Patch Kernel of SUSFS" step (kernel side: fs/susfs.c,
# include/linux/susfs*.h) and after KernelSU-Next is set up, with manual hooks.
#
# What it does
#   1. Finds the KernelSU-Next driver dir (drivers/kernelsu or KernelSU-Next/kernel).
#   2. If the KernelSU-side SUSFS glue is missing (upstream purged it from `legacy`,
#      KernelSU-Next#1384), restores it by reverse-applying the purge commit(s).
#   3. Scans the glue against the SUSFS API your kernel really has; generates
#      no-op compat stubs (susfs_compat.h, force-included) for removed v2 functions.
#   4. Enables CONFIG_KSU_SUSFS* (+ KSU_MANUAL_HOOK) in your defconfig.
#
# Usage:  bash fix_ksun_legacy_susfs.sh [KERNEL_DIR]        (default: $PWD)
# Env overrides:
#   KSU_SRC=<path>        KernelSU-Next "kernel" dir (auto-detected otherwise)
#   PURGE_SHAS=a,b        purge commit(s), newest first (auto-detected otherwise)
#   KSUN_REPO / KSUN_BRANCH   upstream used when local history lacks the commit
#   DEFCONFIG_NAME        e.g. vendor/kona-perf_defconfig (same var as your workflow)
#   ALLOW_MISSING=1       don't fail on missing non-function SUSFS symbols
set -Eeuo pipefail

KERNEL_DIR=$(readlink -f "${1:-$PWD}")
KSU_SRC=${KSU_SRC:-}
PURGE_SHAS=${PURGE_SHAS:-}
KSUN_REPO=${KSUN_REPO:-https://github.com/KernelSU-Next/KernelSU-Next.git}
KSUN_BRANCH=${KSUN_BRANCH:-legacy}
DEFCONFIG_NAME=${DEFCONFIG_NAME:-vendor/kona-perf_defconfig}
ALLOW_MISSING=${ALLOW_MISSING:-0}

gha() { [[ -n ${GITHUB_ACTIONS:-} ]]; }
say()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
warn() { gha && echo "::warning::$*" || true; printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { gha && echo "::error::$*" || true; printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
SUMMARY=()
cd "$KERNEL_DIR"
[[ -f Makefile && -d fs && -d arch/arm64 ]] || die "$KERNEL_DIR is not a kernel root"

# ------------------------------------------------------------ 1. locate KernelSU
if [[ -z $KSU_SRC ]]; then
  for c in drivers/kernelsu KernelSU-Next/kernel KernelSU/kernel; do
    if [[ -f $c/Kconfig ]] && grep -q '^config KSU$' "$c/Kconfig"; then
      KSU_SRC=$(readlink -f "$c"); break
    fi
  done
fi
[[ -n $KSU_SRC && -f $KSU_SRC/Kconfig ]] || die "KernelSU source not found. Run this after KernelSU-Next setup, or set KSU_SRC"
say "kernel : $KERNEL_DIR"
say "KSU src: $KSU_SRC"

# kernel-side SUSFS must already be there (your patch-susfs step)
for f in fs/susfs.c include/linux/susfs.h; do
  [[ -f $f ]] || die "$f missing: the kernel-side SUSFS patch did not apply"
done
grep -rqE 'ksu_handle_(execveat|faccessat|stat|vfs_read|sys_reboot|setuid|input_event)' fs kernel drivers/input 2>/dev/null \
  || warn "no ksu_handle_* manual hook call sites found; manual hooks missing?"

# ------------------------------------------------- 2. restore KernelSU-side glue
# full = Kconfig menu + SUSFS_MAGIC supercall routing + susfs_init() all present
# none = nothing present; partial = an earlier step half-applied the glue
glue_state() {
  local a=0 b=0 c=0
  grep -q '^config KSU_SUSFS' "$KSU_SRC/Kconfig" && a=1
  grep -rqw 'SUSFS_MAGIC' "$KSU_SRC" --include='*.c' --include='*.h' && b=1
  grep -rqE 'susfs_init[[:space:]]*\(' "$KSU_SRC" --include='*.c' && c=1
  case $((a + b + c)) in 3) echo full ;; 0) echo none ;; *) echo "partial(kconfig=$a,supercall=$b,init=$c)" ;; esac
}

state=$(glue_state)
if [[ $state == partial* ]]; then
  find "$KSU_SRC" -name '*.rej' -o -name '*.orig' | sed 's/^/    leftover: /' >&2
  die "KernelSU-side SUSFS glue is only partly present: $state. An earlier SUSFS patch step half-applied it; fix that step instead of restoring on top"
fi

if [[ $state == full ]]; then
  say "KernelSU-side SUSFS glue already present - skipping restore"
  SUMMARY+=("glue: already present")
else
  top=$(git -C "$KSU_SRC" rev-parse --show-toplevel 2>/dev/null || true)
  find_shas() { git -C "$1" log --all -i -E --grep='(purge|remove|drop).*susfs' --format=%H -- kernel 2>/dev/null || true; }
  repo=""; shas=""
  if [[ -n $top ]]; then
    if [[ -n $PURGE_SHAS ]]; then
      shas=${PURGE_SHAS//,/ }
      git -C "$top" cat-file -e "${shas%% *}^{commit}" 2>/dev/null && repo=$top || shas=""
    else
      shas=$(find_shas "$top"); [[ -n $shas ]] && repo=$top
    fi
  fi
  if [[ -z $repo ]]; then
    say "local history lacks the purge commit; cloning $KSUN_REPO ($KSUN_BRANCH)"
    repo=$WORK/ksun
    git clone -q --no-checkout --filter=blob:none "$KSUN_REPO" "$repo"
    git -C "$repo" fetch -q origin '+refs/heads/*:refs/remotes/origin/*' || true
    if [[ -n $PURGE_SHAS ]]; then shas=${PURGE_SHAS//,/ }; else shas=$(find_shas "$repo"); fi
  fi
  [[ -n $shas ]] || die "purge commit not found. Open KernelSU-Next PR #1384, copy its commit SHA(s) and set PURGE_SHAS"
  n=$(wc -w <<<"$shas")
  (( n <= 5 )) || die "$n commits matched the purge pattern (too broad). Set PURGE_SHAS explicitly"

  mkdir -p "$KERNEL_DIR/.ksun-susfs-restore"
  rej=0
  for sha in $shas; do                       # newest first -> correct order to reverse
    say "reversing: $(git -C "$repo" log -1 --format='%h %s' "$sha")"
    p="$KERNEL_DIR/.ksun-susfs-restore/${sha:0:10}.patch"
    git -C "$repo" diff "$sha" "$sha^" -- kernel > "$p"
    [[ -s $p ]] || { warn "empty patch for $sha"; continue; }
    if ! patch -p2 -F3 -N --no-backup-if-mismatch -d "$KSU_SRC" < "$p"; then rej=1; fi
  done
  if (( rej )) || find "$KSU_SRC" -name '*.rej' | grep -q .; then
    find "$KSU_SRC" -name '*.rej' | sed 's/^/    reject: /' >&2
    die "restore had rejected hunks (KernelSU-Next legacy drifted since the purge). Port the .rej files by hand, commit the result as a patch and apply it in the workflow"
  fi
  [[ $(glue_state) == full ]] || die "restore applied but the SUSFS glue isn't complete: $(glue_state) (layout changed?)"
  SUMMARY+=("glue: restored from $n purge commit(s)")
fi

# ----------------------------------- 3. API compatibility vs this kernel's SUSFS
say "checking SUSFS symbols used by KernelSU-Next against this kernel"
defs=$WORK/defs.txt
cat include/linux/susfs*.h fs/susfs.c arch/arm64/include/asm/thread_info.h include/linux/thread_info.h 2>/dev/null > "$defs"

mapfile -t used < <(grep -rhoE '\b(susfs_[a-z0-9_]+|SUSFS_[A-Z0-9_]+|CMD_SUSFS_[A-Z0-9_]+|TIF_PROC_[A-Z_]+|st_susfs_[a-z0-9_]+)\b' \
                     "$KSU_SRC" --include='*.c' --include='*.h' | sort -u || true)
miss_fn=(); miss_other=()
for s in "${used[@]}"; do
  [[ $s == susfs_compat* ]] && continue
  grep -qw -- "$s" "$defs" && continue
  grep -rqE "^[A-Za-z_][A-Za-z0-9_ \*]*[ \*]${s}[[:space:]]*\(|^#[[:space:]]*define[[:space:]]+${s}\b" \
       "$KSU_SRC" --include='*.c' --include='*.h' --exclude='susfs_compat.h' && continue
  if [[ $s == susfs_* ]] && grep -rqE "\b${s}[[:space:]]*\(" "$KSU_SRC" --include='*.c'; then
    miss_fn+=("$s")
  else
    miss_other+=("$s")
  fi
done

if (( ${#miss_fn[@]} )); then
  compat="$KSU_SRC/susfs_compat.h"
  {
    echo "/* auto-generated by fix_ksun_legacy_susfs.sh: no-op stubs for SUSFS functions"
    echo " * that this kernel's SUSFS no longer provides. Features behind them are disabled. */"
    echo "#ifndef _KSU_SUSFS_COMPAT_H"; echo "#define _KSU_SUSFS_COMPAT_H"
    echo "#ifdef CONFIG_KSU_SUSFS"
    for s in "${miss_fn[@]}"; do
      if grep -rqE "(=|return|\(|!|&&|\|\|)[[:space:]]*${s}[[:space:]]*\(" "$KSU_SRC" --include='*.c'; then
        echo "#define $s(...) (0)"          # return value is consumed
      else
        echo "#define $s(...) ((void)0)"
      fi
    done
    echo "#endif"; echo "#endif"
  } > "$compat"
  mk="$KSU_SRC/Kbuild"; [[ -f $mk ]] || mk="$KSU_SRC/Makefile"
  if ! grep -q 'susfs_compat.h' "$mk"; then
    printf '\n# SUSFS compat stubs (fix_ksun_legacy_susfs.sh)\nccflags-$(CONFIG_KSU_SUSFS) += -include $(srctree)/$(src)/susfs_compat.h\n' >> "$mk"
  fi
  warn "stubbed ${#miss_fn[@]} SUSFS function(s) missing in this kernel: ${miss_fn[*]}"
  SUMMARY+=("stubbed: ${miss_fn[*]}")
fi
if (( ${#miss_other[@]} )); then
  warn "symbols used by KernelSU-Next but absent from kernel SUSFS (need manual port): ${miss_other[*]}"
  grep -rnwE "$(IFS='|'; echo "${miss_other[*]}")" "$KSU_SRC" --include='*.c' --include='*.h' | head -40 | sed 's/^/    /' >&2
  (( ALLOW_MISSING )) || die "unresolved SUSFS symbols (set ALLOW_MISSING=1 to continue anyway)"
fi
(( ${#miss_fn[@]} + ${#miss_other[@]} )) || SUMMARY+=("api: all SUSFS symbols resolve")

# --------------------------------------------------------------- 4. defconfig
defcfg="$KERNEL_DIR/arch/arm64/configs/$DEFCONFIG_NAME"
if [[ -f $defcfg ]]; then
  opts=(KSU_SUSFS)
  grep -q '^config KSU_MANUAL_HOOK' "$KSU_SRC/Kconfig" && opts+=(KSU_MANUAL_HOOK)
  while read -r o; do
    [[ $o == *SUS_SU ]] && continue                    # not for manual hooks
    # only enable options the kernel side actually implements
    if grep -rqw "CONFIG_$o" fs include kernel arch/arm64 --include='*.c' --include='*.h' 2>/dev/null; then
      opts+=("$o")
    fi
  done < <(grep -hE '^config KSU_SUSFS_' "$KSU_SRC/Kconfig" | awk '{print $2}')
  for o in "${opts[@]}"; do
    sed -i "/^\(# \)\?CONFIG_${o}[= ]/d" "$defcfg"
    echo "CONFIG_${o}=y" >> "$defcfg"
  done
  say "enabled in $DEFCONFIG_NAME: ${opts[*]}"
  SUMMARY+=("config: ${opts[*]}")
else
  warn "$defcfg not found; enable CONFIG_KSU_SUSFS* yourself"
fi

say "done"
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  { echo "### KernelSU-Next legacy SUSFS fix"; printf -- '- %s\n' "${SUMMARY[@]}"; } >> "$GITHUB_STEP_SUMMARY"
fi
printf '    %s\n' "${SUMMARY[@]}"
