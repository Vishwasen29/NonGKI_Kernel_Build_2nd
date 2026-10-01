#!/usr/bin/env bash
# =============================================================================
# port_kernelsu_next_legacy.sh
#
# Ports / repairs a non-GKI kernel tree so that KernelSU-Next (branch: legacy)
# builds and works in MANUAL HOOK mode (CONFIG_KSU_MANUAL_HOOK=y, no SUSFS).
#
# Meant to run AFTER:
#   1. KernelSU-Next legacy has been set up (drivers/kernelsu -> KernelSU-Next/kernel)
#   2. JackA1ltman's Patches/syscall_hook_patches.sh (mainline) has been run
#      (that is what the "patch-no-kprobe" action does when SUSFS is off)
#
# What it does
#   A. Pre-applies the kernel backports that drivers/kernelsu/Kbuild would
#      otherwise apply with `$(shell sed -i ...)` while it is being parsed.
#      In a clean build that happens after init/ kernel/ mm/ fs/ ... were
#      already compiled, so a header change (struct seccomp) or a missing
#      path_umount() would only show up as a broken link or mismatched objects.
#         - fs/namespace.c   : can_umount() + path_umount()
#         - fs/internal.h    : path_umount() prototype
#         - include/linux/seccomp.h : atomic_t filter_count in struct seccomp
#   B. Repairs the hooks that the generic syscall_hook_patches.sh emits with
#      the older KernelSU API but that the legacy branch declares differently:
#         - fs/read_write.c  : ksu_handle_sys_read(fd)   (legacy: 1 argument)
#         - kernel/sys.c     : removes the setresuid hook (legacy does setuid
#                              through the LSM task_fix_setuid hook, 2 args)
#   C. Adds hooks the generic script does not provide:
#         - fs/exec.c        : do_execveat()/compat_do_execveat() for the
#                              execveat(AT_FDCWD, path, ..., 0) form that newer
#                              bionic uses for execve()
#         - security/selinux/avc.c : slow_avc_audit() -> ksu_handle_slow_avc_audit()
#                              and ksu_slow_avc_audit() (avc_spoof / selinux_hide)
#   D. Keeps selinux_hide.c from also registering a slow_avc_audit kprobe when
#      the manual hook is used (CONFIG_KPROBES=y in oplus.config).
#   E. Verifies every required hook is present and fails the build if not.
#
# Every step is idempotent: running the script twice changes nothing.
#
# Usage:   bash port_kernelsu_next_legacy.sh [KERNEL_DIR] [DEFCONFIG_FILE]
#   KERNEL_DIR      kernel source root              (default: current dir)
#   DEFCONFIG_FILE  defconfig to make sure has CONFIG_KSU=y and
#                   CONFIG_KSU_MANUAL_HOOK=y        (optional)
#
# Env:     KSU_PORT_STRICT=0   do not fail when a hook is missing (default 1)
#
# Tested on: LineageOS android_kernel_oneplus_sm8250 (4.19, lineage-24.0)
#            against KernelSU-Next legacy.
# =============================================================================
set -euo pipefail

KERNEL_DIR="${1:-$PWD}"
DEFCONFIG_FILE="${2:-}"

if [[ ! -f "$KERNEL_DIR/Makefile" ]]; then
    echo "[-] '$KERNEL_DIR' is not a kernel source tree." >&2
    exit 2
fi

command -v python3 >/dev/null 2>&1 || { echo "[-] python3 is required." >&2; exit 2; }

python3 - "$KERNEL_DIR" "$DEFCONFIG_FILE" <<'PYEOF'
import os
import re
import sys

ROOT = os.path.abspath(sys.argv[1])
DEFCONFIG = sys.argv[2]
STRICT = os.environ.get("KSU_PORT_STRICT", "1") != "0"
os.chdir(ROOT)

failures = []


def log(tag, msg):
    print(f"[{tag}] {msg}")


def die(msg):
    log("-", msg)
    sys.exit(1)


def rd(path):
    with open(path, "r", encoding="utf-8", errors="surrogateescape", newline="") as f:
        return f.read()


def wr(path, text):
    with open(path, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
        f.write(text)


def have(path):
    return os.path.isfile(path)


def need_file(path):
    if not have(path):
        die(f"{path} not found - is this the right kernel tree?")


# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------
def kernel_version():
    head = "".join(rd("Makefile").splitlines(True)[:5])
    major = int(re.search(r"^VERSION\s*=\s*(\d+)", head, re.M).group(1))
    minor = int(re.search(r"^PATCHLEVEL\s*=\s*(\d+)", head, re.M).group(1))
    return major, minor


KVER = kernel_version()
log("+", f"Kernel {KVER[0]}.{KVER[1]}")
if KVER < (4, 14) or KVER >= (5, 10):
    log("!", "Only 4.19 is tested; anchors for this version are best effort.")

KSU = "drivers/kernelsu"
if not os.path.isdir(KSU):
    die("drivers/kernelsu is missing - set up KernelSU-Next legacy first.")
if not (have(f"{KSU}/Kbuild") and "KernelSU-Next" in rd(f"{KSU}/Kbuild")
        and "KSU_MANUAL_HOOK" in rd(f"{KSU}/Kconfig")):
    die("drivers/kernelsu is not KernelSU-Next legacy (no KernelSU-Next marker "
        "in Kbuild / no KSU_MANUAL_HOOK in Kconfig).")
log("+", "KernelSU-Next legacy detected.")


# ----------------------------------------------------------------------------
# A. Kernel backports (same conditions as drivers/kernelsu/Kbuild)
# ----------------------------------------------------------------------------
CAN_UMOUNT = """static int can_umount(const struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);

	if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))
		return -EINVAL;
	if (!may_mount())
		return -EPERM;
	if (path->dentry != path->mnt->mnt_root)
		return -EINVAL;
	if (!check_mnt(mnt))
		return -EINVAL;
	if (mnt->mnt.mnt_flags & MNT_LOCKED)
		return -EINVAL;
	if (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN))
		return -EPERM;
	return 0;
}

"""

PATH_UMOUNT = """int path_umount(struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);
	int ret;

	ret = can_umount(path, flags);
	if (!ret)
		ret = do_umount(mnt, flags);

	/* we mustn't call path_put() as that would clear mnt_expiry_mark */
	dput(path->dentry);
	mntput_no_expire(mnt);
	return ret;
}

"""


def backport_namespace():
    p = "fs/namespace.c"
    need_file(p)
    s = rd(p)
    has_can = re.search(r"^static int can_umount", s, re.M) is not None
    has_path = re.search(r"^int path_umount", s, re.M) is not None
    if has_can and has_path:
        log("-", "fs/namespace.c already has can_umount()/path_umount(), skipped.")
        return
    anchor = re.search(r"^static bool is_mnt_ns_file", s, re.M)
    if not anchor:
        failures.append("fs/namespace.c: anchor 'static bool is_mnt_ns_file' not found")
        log("-", failures[-1])
        return
    if not re.search(r"^static int do_umount\(", s, re.M):
        failures.append("fs/namespace.c: do_umount() not found, cannot backport path_umount()")
        log("-", failures[-1])
        return
    add = ("" if has_can else CAN_UMOUNT) + ("" if has_path else PATH_UMOUNT)
    s = s[:anchor.start()] + add + s[anchor.start():]
    wr(p, s)
    log("+", "fs/namespace.c: backported can_umount()/path_umount().")


def backport_internal_h():
    p = "fs/internal.h"
    need_file(p)
    s = rd(p)
    if re.search(r"^int path_umount", s, re.M):
        log("-", "fs/internal.h already declares path_umount(), skipped.")
        return
    m = re.search(r"^extern void __init mnt_init\(void\);\n", s, re.M)
    if not m:
        failures.append("fs/internal.h: anchor 'extern void __init mnt_init' not found")
        log("-", failures[-1])
        return
    s = s[:m.end()] + "int path_umount(struct path *path, int flags);\n" + s[m.end():]
    wr(p, s)
    log("+", "fs/internal.h: declared path_umount().")


def backport_seccomp_h():
    p = "include/linux/seccomp.h"
    need_file(p)
    s = rd(p)
    if "atomic_t filter_count;" in s:
        log("-", "struct seccomp already has filter_count, skipped.")
        return
    m = re.search(r"(struct seccomp \{\s*\n\s*int mode;\n)", s)
    if not m:
        failures.append("include/linux/seccomp.h: 'struct seccomp { int mode;' not found")
        log("-", failures[-1])
        return
    s = s[:m.end()] + "\tatomic_t filter_count;\n" + s[m.end():]
    if "#include <linux/atomic.h>" not in s:
        s = re.sub(r"(#include <linux/thread_info\.h>\n)", r"\1#include <linux/atomic.h>\n", s, count=1)
    wr(p, s)
    log("+", "include/linux/seccomp.h: added filter_count to struct seccomp.")


# ----------------------------------------------------------------------------
# B. Repair hooks from the generic syscall_hook_patches.sh
# ----------------------------------------------------------------------------
def fix_read_write():
    p = "fs/read_write.c"
    need_file(p)
    s = rd(p)
    if re.search(r"ksu_handle_sys_read\(fd\);", s):
        log("-", "fs/read_write.c already uses ksu_handle_sys_read(fd), skipped.")
        return

    # Drop whatever the generic script (3-argument form) inserted.
    s = re.sub(r"#ifdef CONFIG_KSU\nextern bool ksu_(?:init_rc|vfs_read)_hook __read_mostly;\n"
               r"extern __attribute__\(\(cold\)\) int ksu_handle_sys_read\(unsigned int fd,[^;]*;\n#endif\n\n?",
               "", s)
    s = re.sub(r"(?<=\n)#ifdef CONFIG_KSU\n\tif \(unlikely\(ksu_(?:init_rc|vfs_read)_hook\)\)\n"
               r"\t\tksu_handle_sys_read\(fd, ?&buf, ?&count\);\n#endif\n",
               "", s)
    if "ksu_handle_sys_read" in s:
        failures.append("fs/read_write.c: unexpected leftover ksu_handle_sys_read hook")
        log("-", failures[-1])
        return

    decl = ("#ifdef CONFIG_KSU\n"
            "extern bool ksu_init_rc_hook __read_mostly;\n"
            "extern void ksu_handle_sys_read(unsigned int fd);\n"
            "#endif\n\n")
    call = ("#ifdef CONFIG_KSU\n"
            "\tif (unlikely(ksu_init_rc_hook))\n"
            "\t\tksu_handle_sys_read(fd);\n"
            "#endif\n")

    m = re.search(r"^SYSCALL_DEFINE3\(read, unsigned int, fd, char __user \*, buf, size_t, count\)",
                  s, re.M)
    if not m:
        failures.append("fs/read_write.c: SYSCALL_DEFINE3(read, ...) not found")
        log("-", failures[-1])
        return
    window_end = s.index("\n}\n", m.end()) + 3
    body = s[m.end():window_end]

    if "return ksys_read(fd, buf, count);" in body:
        new_body = body.replace("\treturn ksys_read(fd, buf, count);",
                                call + "\treturn ksys_read(fd, buf, count);", 1)
    elif "\tif (f.file) {" in body:
        new_body = body.replace("\tif (f.file) {", call + "\tif (f.file) {", 1)
    else:
        failures.append("fs/read_write.c: no insertion point in SYSCALL_DEFINE3(read)")
        log("-", failures[-1])
        return

    s = s[:m.start()] + decl + s[m.start():m.end()] + new_body + s[window_end:]
    wr(p, s)
    log("+", "fs/read_write.c: installed legacy ksu_handle_sys_read(fd) hook.")


def fix_sys_c():
    p = "kernel/sys.c"
    need_file(p)
    s = rd(p)
    if "ksu_handle_setresuid" not in s:
        log("-", "kernel/sys.c has no setresuid hook, skipped.")
        return
    hdr = f"{KSU}/hook/setuid_hook.h"
    if not (have(hdr) and re.search(r"ksu_handle_setresuid\(uid_t \w+, uid_t \w+\)", rd(hdr))):
        log("-", "KernelSU declares a 3-argument ksu_handle_setresuid, keeping kernel/sys.c hook.")
        return
    s = re.sub(r"#ifdef CONFIG_KSU\nextern int ksu_handle_setresuid\(uid_t ruid, uid_t euid, uid_t suid\);\n#endif\n\n?",
               "", s)
    s = re.sub(r"#ifdef CONFIG_KSU\n\t\(void\)ksu_handle_setresuid\(ruid, euid, suid\);\n#endif\n\n?",
               "", s)
    if "ksu_handle_setresuid" in s:
        failures.append("kernel/sys.c: could not remove the setresuid hook")
        log("-", failures[-1])
        return
    wr(p, s)
    log("+", "kernel/sys.c: removed setresuid hook (legacy uses LSM task_fix_setuid).")


# ----------------------------------------------------------------------------
# C. Extra hooks
# ----------------------------------------------------------------------------
EXECVEAT_CALL = ("#ifdef CONFIG_KSU\n"
                 "\tif (fd == AT_FDCWD && flags == 0)\n"
                 "\t\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n"
                 "#endif\n\n")
EXECVE_DECL = ("#ifdef CONFIG_KSU\n"
               "__attribute__((hot))\n"
               "extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,\n"
               "\t\t\t\tvoid *argv, void *envp, int *flags);\n"
               "#endif\n\n")


def hook_execveat():
    p = "fs/exec.c"
    need_file(p)
    s = rd(p)
    if "ksu_handle_execveat" not in s:
        failures.append("fs/exec.c: no ksu_handle_execveat hook - run syscall_hook_patches.sh first")
        log("-", failures[-1])
        return

    if "ksu_handle_execveat(&fd," in s:
        log("-", "fs/exec.c already hooks do_execveat(), skipped.")
        return

    pat = re.compile(r"^\treturn do_execveat_common\(fd, filename, argv, envp, flags\);\n", re.M)
    hits = list(pat.finditer(s))
    if not hits:
        failures.append("fs/exec.c: do_execveat()/compat_do_execveat() return statement not found")
        log("-", failures[-1])
        return
    for m in reversed(hits):
        s = s[:m.start()] + EXECVEAT_CALL + s[m.start():]
    wr(p, s)
    log("+", f"fs/exec.c: hooked execveat(AT_FDCWD, ..., 0) ({len(hits)} call site(s)).")


def hook_avc():
    p = "security/selinux/avc.c"
    need_file(p)
    s = rd(p)
    if "ksu_handle_slow_avc_audit" in s:
        log("-", "security/selinux/avc.c already hooked, skipped.")
        return
    m = re.search(r"^noinline int slow_avc_audit\(", s, re.M)
    if not m:
        failures.append("security/selinux/avc.c: slow_avc_audit() not found")
        log("-", failures[-1])
        return
    brace = s.index("{\n", m.start())
    sig = s[m.start():brace]
    if not re.search(r"\bu32\s+tsid\b", sig):
        failures.append("security/selinux/avc.c: slow_avc_audit() has no 'u32 tsid' parameter")
        log("-", failures[-1])
        return
    body_start = brace + 2
    blank = s.index("\n\n", body_start)
    decls = s[body_start:blank + 1]
    if re.search(r"^\t(?:if|for|while|return|switch)\b", decls, re.M):
        failures.append("security/selinux/avc.c: statements before first blank line in slow_avc_audit(), "
                        "cannot place the hook safely")
        log("-", failures[-1])
        return

    hook = ("#ifdef CONFIG_KSU\n"
            "\tksu_handle_slow_avc_audit(&tsid);\n"
            "\tksu_slow_avc_audit(&tsid);\n"
            "#endif\n\n")
    decl = ("#ifdef CONFIG_KSU\n"
            "extern int ksu_handle_slow_avc_audit(u32 *tsid);\n"
            "extern void ksu_slow_avc_audit(u32 *tsid);\n"
            "#endif\n\n")
    # Keep the original one-line comment attached to the function.
    ins = m.start()
    prev = re.search(r"^/\*[^\n]*\*/\n\Z", s[:ins], re.M)
    if prev:
        ins = prev.start()
    s = s[:ins] + decl + s[ins:blank + 2] + hook + s[blank + 2:]
    wr(p, s)
    log("+", "security/selinux/avc.c: hooked slow_avc_audit().")


# ----------------------------------------------------------------------------
# D. selinux_hide: no slow_avc_audit kprobe when the manual hook is used
# ----------------------------------------------------------------------------
def gate_selinux_hide_kprobe():
    p = f"{KSU}/feature/selinux_hide.c"
    if not have(p):
        log("-", "feature/selinux_hide.c not present, skipped.")
        return
    s = rd(p)
    old = "#if defined(CONFIG_KPROBES)\n"
    new = "#if defined(CONFIG_KPROBES) && !defined(CONFIG_KSU_MANUAL_HOOK)\n"
    if old not in s:
        log("-", "selinux_hide.c: kprobe already gated (or absent), skipped.")
        return
    n = s.count(old)
    wr(p, s.replace(old, new))
    log("+", f"selinux_hide.c: gated {n} kprobe block(s) behind !CONFIG_KSU_MANUAL_HOOK.")


# ----------------------------------------------------------------------------
# Defconfig sanity
# ----------------------------------------------------------------------------
def ensure_defconfig():
    if not DEFCONFIG:
        return
    if not have(DEFCONFIG):
        failures.append(f"defconfig {DEFCONFIG} not found")
        log("-", failures[-1])
        return
    s = rd(DEFCONFIG)
    add = []
    for opt in ("CONFIG_KSU=y", "CONFIG_KSU_MANUAL_HOOK=y"):
        if not re.search(r"^" + re.escape(opt) + r"\s*$", s, re.M):
            add.append(opt)
    if re.search(r"^CONFIG_KSU_(?:KPROBES|SYSCALL_TABLE)_HOOK=y", s, re.M):
        failures.append(f"{DEFCONFIG}: a dynamic KSU hook mode is enabled, it conflicts with manual hooks")
        log("-", failures[-1])
    if add:
        if not s.endswith("\n"):
            s += "\n"
        wr(DEFCONFIG, s + "\n".join(add) + "\n")
        log("+", f"{DEFCONFIG}: appended {', '.join(add)}")
    else:
        log("-", f"{DEFCONFIG}: KSU options already present.")


# ----------------------------------------------------------------------------
# E. Verification
# ----------------------------------------------------------------------------
def verify():
    checks = [
        ("exec: execve",          "fs/exec.c",                  r"ksu_handle_execveat\(\(int \*\)AT_FDCWD"),
        ("exec: execveat",        "fs/exec.c",                  r"ksu_handle_execveat\(&fd,"),
        ("open: faccessat",       "fs/open.c",                  r"ksu_handle_faccessat\(&dfd"),
        ("stat: newfstatat",      "fs/stat.c",                  r"ksu_handle_stat\(&dfd"),
        ("read: init.rc",         "fs/read_write.c",            r"ksu_handle_sys_read\(fd\);"),
        ("input: volume keys",    "drivers/input/input.c",      r"ksu_handle_input_handle_event\(&type"),
        ("reboot: supercall",     "kernel/reboot.c",            r"ksu_handle_sys_reboot\(magic1"),
        ("avc: selinux_hide",     "security/selinux/avc.c",     r"ksu_handle_slow_avc_audit\(&tsid\)"),
        ("backport: path_umount", "fs/namespace.c",             r"^int path_umount"),
        ("backport: can_umount",  "fs/namespace.c",             r"^static int can_umount"),
        ("backport: prototype",   "fs/internal.h",              r"^int path_umount"),
        ("backport: seccomp",     "include/linux/seccomp.h",    r"atomic_t filter_count;"),
    ]
    print("\n[+] Hook / backport status")
    missing = []
    for name, path, pattern in checks:
        ok = have(path) and re.search(pattern, rd(path), re.M) is not None
        print(f"    {'OK     ' if ok else 'MISSING'}  {name:<24} {path}")
        if not ok:
            missing.append(f"{name} ({path})")

    if have("kernel/sys.c") and re.search(r"ksu_handle_setresuid\(ruid, euid, suid\)", rd("kernel/sys.c")):
        hdr = f"{KSU}/hook/setuid_hook.h"
        if have(hdr) and re.search(r"ksu_handle_setresuid\(uid_t \w+, uid_t \w+\)", rd(hdr)):
            missing.append("kernel/sys.c still calls ksu_handle_setresuid with 3 arguments")
            print("    MISSING  sys.c setresuid cleanup  kernel/sys.c")

    if have("kernel/reboot.c") and "ksu_handle_sys_reboot" not in rd("kernel/reboot.c"):
        pass  # already reported above; Kbuild would stop with "No hooks were defined"
    return missing


backport_namespace()
backport_internal_h()
backport_seccomp_h()
fix_read_write()
fix_sys_c()
hook_execveat()
hook_avc()
gate_selinux_hide_kprobe()
ensure_defconfig()
missing = verify()

problems = failures + missing
if problems:
    print("\n[-] Problems found:")
    for item in problems:
        print(f"    - {item}")
    if STRICT:
        print("[-] Stopping (set KSU_PORT_STRICT=0 to continue anyway).")
        sys.exit(1)
    print("[!] Continuing because KSU_PORT_STRICT=0.")
else:
    print("\n[+] KernelSU-Next legacy port complete.")
PYEOF
