#!/usr/bin/env bash
# fix_lineage_sm8250.sh
#
# Makes ALL SUSFS hunks land on LineageOS/android_kernel_oneplus_sm8250 (lineage-24.0,
# 4.19 + fs_context backport). Run from the kernel root AFTER the SUSFS patch steps and
# BEFORE the build:
#     bash "$GITHUB_WORKSPACE/fix_lineage_sm8250.sh" "$PWD"
#
# Hunks that reject on this tree, and what this script does about them:
#   fs/proc/task_mmu.c  #7   pagemap_read() SUS_MAP hook   -> re-applied with mmap_read_lock API
#   fs/namespace.c      #1   includes / externs / CL_COPY_MNT_NS / IDAs  -> added
#   fs/namespace.c      #6   vfs_kern_mount() KSU-domain hook -> ported into vfs_create_mount()
#                            (Lineage builds vfs_kern_mount() on fs_context/fc_mount())
#   fs/super.c          #1   include + externs                -> added
#   susfs_fixed.patch rejects (task_mmu.c include, kernel/sys.c uname hook) are duplicates of
#   what the base patch already applied; they are verified present, then the .rej is dropped.
#
# Idempotent. Exits non-zero (and the CI step fails) if an anchor is missing or if a SUSFS
# hook is still absent at the end, so a silently half-patched kernel can't get built.
set -euo pipefail

KDIR="${1:-.}"
cd "$KDIR"
[ -f fs/namespace.c ] && [ -f fs/proc/task_mmu.c ] || { echo "[-] Run from kernel root"; exit 1; }

python3 - <<'PY'
import re, sys

def rd(p):
    with open(p, encoding="utf-8", errors="surrogateescape") as f:
        return f.read()

def wr(p, s):
    with open(p, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(s)

def die(msg):
    print("[-] " + msg)
    sys.exit(1)

def note(p, changed):
    print(("[+] fixed " if changed else "[=] already fine: ") + p)

# ============================================================== fs/proc/task_mmu.c
p = "fs/proc/task_mmu.c"
s = rd(p); orig = s

if "linux/susfs_def.h" not in s:
    a = "#include <linux/ctype.h>\n"
    if a not in s: die("task_mmu.c: ctype.h include anchor not found")
    s = s.replace(a, a +
        "#if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n"
        "#include <linux/susfs_def.h>\n"
        "#endif // #if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n", 1)

m = re.search(r"static ssize_t pagemap_read\(.*?\n}\n", s, re.S)
if not m: die("task_mmu.c: pagemap_read() not found")
func = m.group(0); new = func

if "struct vm_area_struct *vma;" not in new:
    a = "\tint ret = 0, copied = 0;\n"
    if a not in new: die("task_mmu.c: 'int ret = 0, copied = 0;' anchor not found")
    new = new.replace(a, a + "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\tstruct vm_area_struct *vma;\n#endif\n", 1)

if "vma = find_vma(mm, start_vaddr);" not in new:
    pat = re.compile(
        r"(\t\tret = (?:mmap_read_lock_killable\(mm\)|down_read_killable\(&mm->mmap_sem\));\n"
        r"\t\tif \(ret\)\n\t\t\tgoto out_free;\n)"
        r"(\t\tret = walk_page_range\(start_vaddr, end, &pagemap_walk\);\n)")
    if not pat.search(new): die("task_mmu.c: walk_page_range anchor not found in pagemap_read")
    new = pat.sub(lambda mo: (
        mo.group(1) +
        "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
        "\t\tvma = find_vma(mm, start_vaddr);\n"
        "\t\tif (vma && vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n"
        "\t\t\tgoto bypass_orig_flow;\n"
        "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n" +
        mo.group(2) +
        "#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
        "bypass_orig_flow:\n"
        "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"), new, count=1)
s = s.replace(func, new, 1)
if s != orig: wr(p, s)
note(p, s != orig)

# ============================================================== fs/super.c
p = "fs/super.c"
s = rd(p); orig = s
if "linux/susfs_def.h" not in s:
    a = "#include <linux/user_namespace.h>\n"
    if a not in s: die("super.c: user_namespace.h include anchor not found")
    s = s.replace(a, a + "#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif // #ifdef CONFIG_KSU_SUSFS\n", 1)
if "extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted" not in s:
    a = '#include "internal.h"\n'
    if a not in s: die('super.c: #include "internal.h" anchor not found')
    s = s.replace(a, a +
        "\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
        "extern bool susfs_is_current_ksu_domain(void);\n"
        "extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n"
        "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n", 1)
if s != orig: wr(p, s)
note(p, s != orig)

# ============================================================== fs/namespace.c
p = "fs/namespace.c"
s = rd(p); orig = s

# --- hunk #1: include + externs + CL_COPY_MNT_NS + IDAs
if "linux/susfs_def.h" not in s:
    a = "#include <linux/sched/task.h>\n"
    if a not in s: die("namespace.c: sched/task.h include anchor not found")
    s = s.replace(a, a + "#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif // #ifdef CONFIG_KSU_SUSFS\n", 1)

if "extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted" not in s:
    a = '#include "internal.h"\n'
    if a not in s: die('namespace.c: #include "internal.h" anchor not found')
    s = s.replace(a, a +
        "\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
        "extern bool susfs_is_current_ksu_domain(void);\n"
        "extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n"
        "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n", 1)

tail = "extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n"
if "#define CL_COPY_MNT_NS " not in s:
    s = s.replace(tail, tail + "\n#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\n", 1)

# IDAs come from susfs_fixed.patch. Nothing references them in this SUSFS version, and clang
# -Werror=unused-variable would kill the build, hence __maybe_unused (same object, same init).
if "susfs_mnt_id_ida" not in s:
    a = "#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\n"
    s = s.replace(a, a +
        "\nstatic struct ida susfs_mnt_id_ida __maybe_unused = IDA_INIT(susfs_mnt_id_ida);\n"
        "static struct ida susfs_mnt_group_ida __maybe_unused = IDA_INIT(susfs_mnt_group_ida);\n", 1)

# --- hunk #6: KSU-domain mount allocation hook
if "susfs_alloc_non_unshare_ksu_vfsmnt(fc->source" not in s and 'susfs_alloc_non_unshare_ksu_vfsmnt(name ?:"none")' not in s:
    hook = lambda src: (
        "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
        "\t// - We will just stop checking for ksu process if /sdcard/Android is accessible,\n"
        "\t//   for the sake of performance\n"
        "\tif (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted)) {\n"
        "\t\tif (susfs_is_current_ksu_domain()) {\n"
        "\t\t\tmnt = susfs_alloc_non_unshare_ksu_vfsmnt(%s);\n"
        "\t\t\tgoto bypass_orig_flow;\n"
        "\t\t}\n"
        "\t}\n"
        "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\n" % src)
    tailhook = ("\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
                "bypass_orig_flow:\n"
                "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n")

    # (a) fs_context based trees (this one): alloc happens in vfs_create_mount()
    m = re.search(r"struct vfsmount \*vfs_create_mount\(struct fs_context \*fc\)\n\{.*?\n}\n", s, re.S)
    if m:
        func = m.group(0)
        old = '\tmnt = alloc_vfsmnt(fc->source ?: "none");\n'
        if func.count(old) != 1: die("namespace.c: alloc_vfsmnt() call in vfs_create_mount not found")
        newf = func.replace(old, hook('fc->source ?: "none"') + old + tailhook, 1)
        s = s.replace(func, newf, 1)
    else:
        # (b) classic trees: alloc happens in vfs_kern_mount()
        m = re.search(r"\nvfs_kern_mount\(struct file_system_type \*type.*?\n}\n", s, re.S)
        if not m: die("namespace.c: neither vfs_create_mount() nor vfs_kern_mount() found")
        func = m.group(0)
        old = "\tmnt = alloc_vfsmnt(name);\n"
        if func.count(old) != 1: die("namespace.c: alloc_vfsmnt(name) call in vfs_kern_mount not found")
        newf = func.replace(old, hook('name ?:"none"') + old + tailhook, 1)
        s = s.replace(func, newf, 1)

if s != orig: wr(p, s)
note(p, s != orig)

# ============================================================== verification
# Every SUSFS hook that the patches are supposed to add must be present now.
need = {
    "fs/namespace.c": ["extern bool susfs_is_current_ksu_domain(void);",
                       "#define CL_COPY_MNT_NS ",
                       "linux/susfs_def.h",
                       "susfs_alloc_non_unshare_ksu_vfsmnt(",
                       "bypass_orig_flow:"],
    "fs/super.c": ["extern bool susfs_is_current_ksu_domain(void);", "linux/susfs_def.h"],
    "fs/proc/task_mmu.c": ["vma = find_vma(mm, start_vaddr);", "linux/susfs_def.h"],
    "kernel/sys.c": ["susfs_spoof_uname(&tmp);", "susfs_is_uname_spoof_buffer_set"],
}
ok = True
for f, marks in need.items():
    try: t = rd(f)
    except FileNotFoundError:
        print("[-] missing file " + f); ok = False; continue
    for mk in marks:
        if mk not in t:
            print("[-] %s: SUSFS hook missing -> %s" % (f, mk)); ok = False
# the call sites we hook must exist exactly where the helper is used
t = rd("fs/namespace.c")
if t.count("susfs_alloc_non_unshare_ksu_vfsmnt(") < 3:
    print("[-] namespace.c: expected >=3 uses of susfs_alloc_non_unshare_ksu_vfsmnt (def + clone_mnt + mount hook)"); ok = False
if not ok:
    sys.exit(1)
print("[+] verified: all SUSFS hooks present")
PY

# The rejects are now fully accounted for (applied above, or duplicates of already-applied
# hunks). Remove them so later "rej" checks / artifact uploads don't trip on stale files.
for f in fs/namespace.c fs/super.c fs/proc/task_mmu.c kernel/sys.c; do
    rm -f "$f.rej" "$f.orig"
done
echo "[+] Lineage sm8250 SUSFS fixups done."
