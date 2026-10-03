#!/usr/bin/env bash
# =============================================================================
# fix_ksun_legacy_hooks.sh
#
# Fixes the build failure seen in "OnePlus 9r Series (ColorOS 15 A15)":
#
#   ld.lld: error: undefined symbol: ksu_is_init_rc_hook_enabled
#   >>> referenced by xarray.c  vmlinux.o:(__jump_table+0x1faf8)
#
# ROOT CAUSE
#   SUSFS_ENABLE=true makes the `patch-no-kprobe` action run
#   Patches/susfs_inline_hook_patches.sh. That script injects hooks written for
#   ReSukiSU-style KernelSU: static keys (ksu_is_init_rc_hook_enabled,
#   ksu_su_compat_enabled, ksu_is_input_hook_enabled), struct filename*
#   prototypes, ksu_handle_vfs_fstat(), ...
#   KernelSU-Next `legacy` (v3.4.0) uses a different ABI: plain `bool` flags
#   (ksu_init_rc_hook, ksu_su_compat_enabled, ksu_input_hook), `const char __user **`
#   prototypes and ksu_handle_newfstat_ret(). It also has no SUSFS glue at all.
#   Linking fails on the first missing symbol; the other mismatches
#   (a bool used as a static key => memory corruption at boot) would have
#   linked fine and caused a bootloop, so do NOT "fix" this by just defining
#   the missing symbol.
#
# USAGE (two calls in the workflow, see the patched yml)
#   fix_ksun_legacy_hooks.sh prepare   # BEFORE "Patch for no-kprobe"
#   fix_ksun_legacy_hooks.sh verify    # AFTER all patch steps, BEFORE "Build Process"
#
# Optional 2nd argument: kernel dir (default: $GITHUB_WORKSPACE/device_kernel)
# Exit code is non-zero if verify finds a real ABI problem.
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
        local content; content="$(cat "$ACTION")"
        if [[ "$content" == *"$old"* ]]; then
            printf '%s\n' "${content/"$old"/"$new"}" > "$ACTION"
            info "patch-no-kprobe: SUSFS-inline hooks are now skipped for KernelSU-Next legacy;"
            info "                 syscall_hook_patches.sh (bool ABI) will be used instead."
            return 0
        fi
    fi

    # Fallback: action text differs from upstream -> flip SUSFS_ENABLE for the remaining steps.
    # (patch-susfs / build-ready already ran; later actions do not read SUSFS_ENABLE.)
    note "Could not edit patch-no-kprobe; falling back to SUSFS_ENABLE=false for the remaining steps."
    if [ -n "${GITHUB_ENV:-}" ]; then echo "SUSFS_ENABLE=false" >> "$GITHUB_ENV"; fi
    return 0
}

# ---------------------------------------------------------------------------
# verify: every KernelSU symbol the patched kernel tree references via `extern`
# or static_branch_*() must exist in drivers/kernelsu with the SAME kind
# (function / plain variable / static key). Catches in seconds what otherwise
# surfaces after a ~20 min LTO link (or worse: as a bootloop).
# ---------------------------------------------------------------------------
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
        note "No KernelSU extern/static-key references found in the kernel tree (hooks not applied?)."
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

    if [ "$errors" -gt 0 ]; then
        fail "KernelSU hook verification FAILED: ${errors} problem(s) in ${checked} checked symbol(s). Aborting before the long build."
        return 1
    fi
    info "KernelSU hook verification passed (${checked} symbol(s) checked)."
}

case "$MODE" in
    prepare) do_prepare ;;
    verify)  do_verify ;;
    *) echo "usage: $0 {prepare|verify} [kernel_dir]" >&2; exit 2 ;;
esac
