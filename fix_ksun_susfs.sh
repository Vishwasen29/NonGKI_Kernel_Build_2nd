#!/usr/bin/env bash
# =============================================================================
# fix_ksun_susfs.sh  -  KernelSU-Next (legacy) + SUSFS for the OnePlus 9R build
#
# Fixes two separate problems seen in "OnePlus 9r Series (ColorOS 15 A15)":
#
#  1) LINK ERROR   ld.lld: undefined symbol: ksu_is_init_rc_hook_enabled
#     patch-no-kprobe ran susfs_inline_hook_patches.sh, which injects hooks for
#     ReSukiSU-style KernelSU (static keys, struct filename* prototypes).
#     KernelSU-Next legacy uses plain bool flags + const char __user ** protos.
#     Just defining the missing symbol would link and then bootloop.
#
#  2) NO SUSFS GLUE  KernelSU-Next legacy v3.4.0 removed all SUSFS code from
#     drivers/kernelsu ("kernel: purge SuSFS remnants", KernelSU-Next#1384).
#     The kernel-side SUSFS patch (fs/susfs.c ...) then has nothing calling it
#     and CONFIG_KSU_SUSFS=y in the defconfig is silently dropped (no Kconfig
#     symbol). `glue` pins KernelSU-Next to the commit just BEFORE that purge.
#
# USAGE (three calls, see the patched workflow):
#   fix_ksun_susfs.sh glue      # right after "Get necessary tools"
#   fix_ksun_susfs.sh prepare   # right before "Patch for no-kprobe"
#   fix_ksun_susfs.sh verify    # after all patch steps, before "Build Process"
#
# Optional 2nd arg: kernel dir (default: $GITHUB_WORKSPACE/device_kernel)
# Env overrides:
#   KSUN_SUSFS_COMMIT=<sha>   pin KernelSU-Next to this commit instead of auto
#   KSUN_GLUE=skip            do not touch the KernelSU-Next checkout
# Exit code is non-zero if anything would fail at link time or misbehave at boot.
# =============================================================================
set -euo pipefail

MODE="${1:-}"
WS="${GITHUB_WORKSPACE:-$PWD}"
KDIR="${2:-$WS/device_kernel}"
ACTION="$WS/.github/workflows/patch-no-kprobe/action.yml"

info() { echo "[+] $*"; }
note() { echo "[-] $*"; }
fail() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::$*" >&2; else echo "[x] $*" >&2; fi
}

# ---------------------------------------------------------------------------
# Which hook ABI does the KernelSU copy in the kernel tree speak?
#   bool        -> KernelSU-Next legacy (and similar): plain bool flags
#   static-key  -> ReSukiSU / SukiSU style: DEFINE_STATIC_KEY_* flags
# ---------------------------------------------------------------------------
detect_abi() {
    local d="$KDIR/drivers/kernelsu"
    if [ ! -d "$d" ]; then echo none; return; fi
    if grep -RqsE 'DEFINE_STATIC_KEY_(TRUE|FALSE)[[:space:]]*\([[:space:]]*ksu_is_init_rc_hook_enabled' "$d"; then
        echo static-key
    elif grep -RqsE '^[[:space:]]*bool[[:space:]]+(__maybe_unused[[:space:]]+)?ksu_init_rc_hook\b' "$d"; then
        echo bool
    else
        echo unknown
    fi
}

# ---------------------------------------------------------------------------
# glue: KernelSU-Next legacy >= v3.4.0 has no SUSFS code. If drivers/kernelsu
# lacks it, pin the KernelSU-Next checkout to the commit before the purge.
# ---------------------------------------------------------------------------
has_susfs_glue() {
    grep -RqsE 'susfs_init|SUSFS_MAGIC|config[[:space:]]+KSU_SUSFS\b' "$KDIR/drivers/kernelsu" 2>/dev/null
}

do_glue() {
    if [ ! -e "$KDIR/drivers/kernelsu" ]; then
        fail "drivers/kernelsu not found in $KDIR - run 'glue' after 'Get necessary tools'."; return 1
    fi
    if [ "${KSUN_GLUE:-}" = "skip" ]; then note "KSUN_GLUE=skip - leaving KernelSU-Next as is."; return 0; fi
    if has_susfs_glue && [ -z "${KSUN_SUSFS_COMMIT:-}" ]; then
        info "KernelSU already contains SUSFS glue. Nothing to do."; return 0
    fi

    local repo
    repo="$(git -C "$(readlink -f "$KDIR/drivers/kernelsu")" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "$repo" ] || { [ ! -d "$repo/.git" ] && [ ! -f "$repo/.git" ]; }; then
        fail "drivers/kernelsu is not inside a git checkout; cannot pin KernelSU-Next (use KERNELSU_METHOD: shell or manual)."; return 1
    fi
    info "KernelSU-Next checkout: $repo (HEAD $(git -C "$repo" rev-parse --short HEAD))"

    # need full history to find the purge commit
    if [ "$(git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
        git -C "$repo" fetch --unshallow --quiet origin legacy 2>/dev/null || git -C "$repo" fetch --unshallow --quiet || true
    fi
    git -C "$repo" fetch --quiet origin legacy 2>/dev/null || true

    local target="${KSUN_SUSFS_COMMIT:-}"
    if [ -z "$target" ]; then
        local purge
        purge="$(git -C "$repo" log origin/legacy -i --grep='purge susfs remnants' -n 1 --format=%H 2>/dev/null || true)"
        if [ -z "$purge" ]; then
            purge="$(git -C "$repo" log HEAD -i --grep='purge susfs remnants' -n 1 --format=%H 2>/dev/null || true)"
        fi
        if [ -z "$purge" ]; then
            fail "Could not find KernelSU-Next's 'purge SuSFS remnants' commit and drivers/kernelsu has no SUSFS glue. Set KSUN_SUSFS_COMMIT=<sha> to a legacy commit that still has SUSFS."
            return 1
        fi
        target="$(git -C "$repo" rev-parse "${purge}^1")"
        info "SUSFS was removed by ${purge:0:10}; pinning to its parent ${target:0:10}."
    else
        info "Pinning KernelSU-Next to KSUN_SUSFS_COMMIT=${target:0:10}."
    fi

    git -C "$repo" checkout -q --detach -f "$target"
    info "KernelSU-Next now at $(git -C "$repo" log -1 --format='%h %s' )"

    if ! has_susfs_glue; then
        fail "Pinned commit ${target:0:10} still has no SUSFS glue in drivers/kernelsu."; return 1
    fi
    info "SUSFS glue present in drivers/kernelsu."
}

# ---------------------------------------------------------------------------
# prepare: make the no-kprobe step choose hooks matching the KernelSU ABI
# ---------------------------------------------------------------------------
do_prepare() {
    local abi; abi="$(detect_abi)"
    info "Detected KernelSU hook ABI: $abi"

    case "$abi" in
        static-key)
            info "Static-key ABI: SUSFS inline hooks are the correct choice. Nothing to change."
            return 0 ;;
        bool) ;;
        none)    fail "drivers/kernelsu not found in $KDIR - run this after 'Get necessary tools'."; return 1 ;;
        unknown) note "Could not classify KernelSU ABI; leaving hook selection alone (verify step will still check)."; return 0 ;;
    esac

    if [ "${HOOK_METHOD:-syscall}" != "syscall" ]; then
        fail "HOOK_METHOD='${HOOK_METHOD}' but KernelSU-Next legacy needs the syscall (manual) hook patcher. Set HOOK_METHOD: \"syscall\"."
        return 1
    fi

    # 1) tell later steps which ABI we have
    if [ -n "${GITHUB_ENV:-}" ]; then echo "KSU_HOOK_ABI=bool" >> "$GITHUB_ENV"; fi
    export KSU_HOOK_ABI=bool

    # 2) make patch-no-kprobe skip the SUSFS-inline branch for bool ABI
    local old='if [[ ${{ env.SUSFS_ENABLE }} == "true" ]]; then'
    local new='if [[ "${KSU_HOOK_ABI:-}" != "bool" && ${{ env.SUSFS_ENABLE }} == "true" ]]; then'

    if [ ! -f "$ACTION" ]; then
        note "$ACTION not found."
    elif grep -qF 'KSU_HOOK_ABI' "$ACTION"; then
        info "patch-no-kprobe already adjusted."
        return 0
    else
        if OLD="$old" NEW="$new" ACTION="$ACTION" python3 - <<'PY'
import os, sys
p = os.environ["ACTION"]; old = os.environ["OLD"]; new = os.environ["NEW"]
t = open(p, encoding="utf-8").read()
if old not in t:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(t.replace(old, new, 1))
PY
        then
            info "patch-no-kprobe: SUSFS-inline hooks are now skipped for KernelSU-Next legacy;"
            info "                 syscall_hook_patches.sh (bool ABI) will be used instead."
            return 0
        fi
    fi

    # Fallback: action text differs from upstream -> flip SUSFS_ENABLE for the remaining steps.
    # (patch-susfs / build-ready already ran; later actions do not read SUSFS_ENABLE.)
    note "Could not edit patch-no-kprobe (action text differs). Falling back to SUSFS_ENABLE=false for the remaining steps: the syscall hooks get used, kernel-side SUSFS patches stay applied."
    if [ -n "${GITHUB_ENV:-}" ]; then echo "SUSFS_ENABLE=false" >> "$GITHUB_ENV"; fi
    return 0
}

# ---------------------------------------------------------------------------
# verify: every KernelSU symbol the patched kernel tree references via `extern`
# or static_branch_*() must exist in drivers/kernelsu with the SAME kind
# (function / plain variable / static key). Catches in seconds what otherwise
# surfaces after a ~20 min LTO link (or worse: as a bootloop).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# verify_susfs: SUSFS wiring between drivers/kernelsu and the patched kernel
#  - every susfs_* function KernelSU calls must be declared by the kernel's SUSFS
#  - CONFIG_KSU_SUSFS in the defconfig must exist as a Kconfig symbol, otherwise
#    Kconfig drops it silently and the build "succeeds" with SUSFS off
# ---------------------------------------------------------------------------
verify_susfs() {
    SUSFS_ERRORS=0
    local defcfg
    defcfg="$(ls arch/arm64/configs/vendor/kona-perf_defconfig arch/arm64/configs/*kona*perf* 2>/dev/null | head -1 || true)"
    local wants_susfs=0
    if [ -n "$defcfg" ] && grep -q '^CONFIG_KSU_SUSFS=y' "$defcfg"; then wants_susfs=1; fi
    if [ "$wants_susfs" -eq 0 ] && ! has_susfs_glue; then
        note "SUSFS not requested and no glue present - SUSFS checks skipped."; return 0
    fi

    if ! grep -RqsE '^[[:space:]]*config[[:space:]]+KSU_SUSFS[[:space:]]*$' drivers/kernelsu/Kconfig drivers/kernelsu/*/Kconfig 2>/dev/null; then
        fail "CONFIG_KSU_SUSFS is set in the defconfig but drivers/kernelsu/Kconfig does not define it - SUSFS would be silently disabled. Run '$0 glue'."
        SUSFS_ERRORS=$((SUSFS_ERRORS+1))
    fi

    if [ ! -f fs/susfs.c ] || [ ! -f include/linux/susfs.h ]; then
        fail "Kernel-side SUSFS (fs/susfs.c, include/linux/susfs.h) missing - the SUSFS kernel patch did not apply."
        SUSFS_ERRORS=$((SUSFS_ERRORS+1)); return 0
    fi

    local used decl missing=""
    used="$(grep -RhoE --include='*.c' --include='*.h' '\bsusfs_[a-z0-9_]+[[:space:]]*\(' drivers/kernelsu/ 2>/dev/null \
            | sed -E 's/[[:space:]]*\($//' | sort -u)"
    decl="$(cat include/linux/susfs.h include/linux/susfs_def.h fs/susfs.c 2>/dev/null)"
    local f own
    own="$(grep -RhoE --include='*.c' --include='*.h' '^[A-Za-z_][A-Za-z0-9_ \*]*[ \*]susfs_[a-z0-9_]+[[:space:]]*\(' drivers/kernelsu/ 2>/dev/null \
           | grep -oE 'susfs_[a-z0-9_]+' | sort -u || true)"
    for f in $used; do
        grep -qx "$f" <<<"$own" && continue
        if ! grep -qE "\b${f}\b" <<<"$decl"; then missing+=" $f"; fi
    done
    if [ -n "$missing" ]; then
        fail "drivers/kernelsu calls SUSFS functions the kernel's SUSFS does not provide:${missing}. KernelSU glue and kernel SUSFS are different versions."
        SUSFS_ERRORS=$((SUSFS_ERRORS+1))
    else
        info "SUSFS glue <-> kernel SUSFS symbols match ($(wc -w <<<"$used") function(s) checked)."
    fi

    # other CONFIG_KSU_SUSFS_* options: unknown ones are dropped by Kconfig -> warn only
    if [ -n "$defcfg" ]; then
        local c
        for c in $(grep -oE '^CONFIG_KSU_SUSFS[A-Z_]*' "$defcfg" | sort -u); do
            grep -RqsE "config[[:space:]]+${c#CONFIG_}\b" drivers/kernelsu fs/Kconfig 2>/dev/null \
                || note "defconfig sets ${c} but no Kconfig defines it (ignored by Kconfig)."
        done
    fi
}

do_verify() {
    cd "$KDIR"
    [ -d drivers/kernelsu ] || { fail "drivers/kernelsu missing"; return 1; }

    local scan_dirs=()
    local d
    for d in fs kernel security drivers include arch/arm64 init mm lib net; do
        [ -d "$d" ] && scan_dirs+=("$d")
    done

    local EXCL=(--exclude-dir=kernelsu --exclude-dir=KernelSU --exclude-dir=KernelSU-Next --exclude-dir=.git)
    local KSU_C=()
    mapfile -t KSU_C < <(find -L drivers/kernelsu -name '*.c' 2>/dev/null)

    # Lines in the kernel tree that reference KernelSU symbols through extern / static keys
    local REFS
    REFS="$(grep -RInE --include='*.c' --include='*.h' "${EXCL[@]}" \
            -e '^[[:space:]]*extern[^;]*\b(__)?ksu_[a-z0-9_]+' \
            -e 'static_branch_(un)?likely[[:space:]]*\([[:space:]]*&?[[:space:]]*(__)?ksu_[a-z0-9_]+' \
            "${scan_dirs[@]}" 2>/dev/null || true)"

    if [ -z "$REFS" ]; then
        note "No KernelSU extern/static-key references found in the kernel tree (hooks not applied, or declared via header)."
        verify_susfs
        if [ "$SUSFS_ERRORS" -gt 0 ]; then fail "SUSFS verification FAILED: ${SUSFS_ERRORS} problem(s)."; return 1; fi
        return 0
    fi

    local errors=0 checked=0
    declare -A seen=()

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        local file="${line%%:*}"; local rest="${line#*:}"; local lno="${rest%%:*}"; local text="${rest#*:}"

        # all ksu identifiers on this line
        local ident
        for ident in $(grep -oE '\b(__)?ksu_[a-z0-9_]+' <<<"$text" | sort -u); do
            # kernel-side kind
            local kkind="var"
            if grep -qE "static_branch_(un)?likely[[:space:]]*\([[:space:]]*&?[[:space:]]*${ident}\b" <<<"$text"; then
                kkind="key"
            elif grep -qE 'struct[[:space:]]+static_key_(true|false)' <<<"$text"; then
                kkind="key"
            elif grep -qE "\b${ident}[[:space:]]*\(" <<<"$text"; then
                kkind="func"
            fi
            # a bare 'extern ... (' line may list a function while the ident we matched is its argument
            [ "$kkind" = "func" ] || [ "$kkind" = "key" ] || [ "$kkind" = "var" ] || continue

            local k="${ident}|${kkind}"
            [ -z "${seen[$k]:-}" ] || continue
            seen[$k]=1
            checked=$((checked+1))

            # KernelSU-side kinds (a symbol may legitimately have several, e.g. ifdef'd variants)
            local kinds=""
            if [ ${#KSU_C[@]} -gt 0 ]; then
                if grep -hEqs "DEFINE_STATIC_KEY_(TRUE|FALSE)[[:space:]]*\([[:space:]]*${ident}[[:space:]]*[,)]" "${KSU_C[@]}"; then
                    kinds+=" key"
                fi
                # non-static definitions at column 0 (function: name( ; var: name = / ; / __read_mostly)
                local defs
                defs="$(grep -hE "^([A-Za-z_][A-Za-z0-9_ \*\(\)]*[ \*])?${ident}[[:space:]]*(\(|=|;|\[|__)" "${KSU_C[@]}" 2>/dev/null \
                        | grep -vE '^[[:space:]]*(static|extern|return|typedef|#)' || true)"
                if [ -n "$defs" ]; then
                    if grep -qE "\b${ident}[[:space:]]*\(" <<<"$defs"; then kinds+=" func"; fi
                    if grep -qE "\b${ident}[[:space:]]*(=|;|\[|__)" <<<"$defs"; then kinds+=" var"; fi
                fi
            fi

            if [ -z "$kinds" ]; then
                fail "UNDEFINED  ${ident}  (used in ${file}:${lno}) - not provided by this KernelSU. The hook patch targets a different KernelSU variant."
                errors=$((errors+1))
                continue
            fi
            if [[ " $kinds " != *" $kkind "* ]]; then
                fail "ABI MISMATCH  ${ident}  kernel(${file}:${lno}) treats it as '${kkind}', KernelSU defines it as:${kinds}"
                errors=$((errors+1))
                continue
            fi

            # prototype sanity for the two su-compat hooks that changed type between variants
            case "$ident" in
                ksu_handle_faccessat|ksu_handle_stat)
                    if [ "$kkind" = "func" ] && grep -qE 'struct[[:space:]]+filename' <<<"$text"; then
                        # a KernelSU may ship both variants under #ifdef (e.g. ReSukiSU + CONFIG_KSU_SUSFS);
                        # only complain when NO variant takes 'struct filename'
                        local protos
                        protos="$(grep -hA1 -E "^(int[[:space:]]+)?${ident}[[:space:]]*\(" "${KSU_C[@]}" 2>/dev/null || true)"
                        if ! grep -q 'struct filename' <<<"$protos" && grep -q 'const char __user' <<<"$protos"; then
                            fail "PROTOTYPE MISMATCH  ${ident}  kernel(${file}:${lno}) passes 'struct filename **', KernelSU expects 'const char __user **'"
                            errors=$((errors+1))
                        fi
                    fi ;;
            esac
        done
    done <<<"$REFS"

    verify_susfs
    errors=$((errors+SUSFS_ERRORS))

    if [ "$errors" -gt 0 ]; then
        fail "KernelSU hook verification FAILED: ${errors} problem(s) in ${checked} checked symbol(s). Aborting before the long build."
        return 1
    fi
    info "KernelSU hook verification passed (${checked} symbol(s) checked)."
}

case "$MODE" in
    glue)    do_glue ;;
    prepare) do_prepare ;;
    verify)  do_verify ;;
    *) echo "usage: $0 {glue|prepare|verify} [kernel_dir]" >&2; exit 2 ;;
esac
