#!/usr/bin/env bash
# Add Kali NetHunter support to an Android 4.19 (arm64) kernel tree.
# Usage: bash patch-nethunter.sh <kernel_dir>
# Env:   NH_STRICT=1        -> abort the build if any NetHunter patch fails to apply
#        NH_WLAN_BUILTIN=1  -> force CONFIG_QCA_CLD_WLAN=y (internal Wi-Fi built in)
#        NH_RTL88XXAU=y|m|n -> how to build the external rtl88xxau driver (default y)
set -uo pipefail

KDIR="${1:-$PWD}"
cd "$KDIR" || { echo "::error::bad kernel dir"; exit 1; }

STRICT="${NH_STRICT:-0}"
WLAN_BUILTIN="${NH_WLAN_BUILTIN:-0}"
RTL_MODE="${NH_RTL88XXAU:-y}"
NH_REPO="https://gitlab.com/kalilinux/nethunter/build-scripts/kali-nethunter-kernel.git"
CFG_REL="vendor/nethunter.config"
CFG="arch/arm64/configs/${CFG_REL}"
TMP="$(mktemp -d)"

fail() { echo "::warning::$*"; [ "$STRICT" = "1" ] && exit 1; return 0; }

echo "== [1/5] Fetching NetHunter kernel patches"
git clone --depth=1 "$NH_REPO" "$TMP/nh" || { echo "::error::clone failed"; exit 1; }
PDIR="$TMP/nh/patches/4.19"
if [ ! -d "$PDIR" ]; then
  echo "::error::patches/4.19 not found, available:"; ls "$TMP/nh/patches"; exit 1
fi
echo "Available 4.19 patches:"; ls -1 "$PDIR"

apply() {
  local name="$1" p="$PDIR/$1"
  if [ ! -f "$p" ]; then fail "patch missing upstream: $name"; return 0; fi
  if patch -p1 --dry-run -s < "$p" >"$TMP/dry.log" 2>&1; then
    patch -p1 -s --no-backup-if-mismatch < "$p" && echo "applied: $name"
  else
    echo "---- dry-run output for $name ----"; tail -n 30 "$TMP/dry.log"
    fail "patch does not apply cleanly (skipped): $name"
  fi
}

# Try a list of candidate patches in order, stop at the first that applies cleanly.
apply_best() {
  local label="$1"; shift
  local name p
  for name in "$@"; do
    p="$PDIR/$name"
    [ -f "$p" ] || continue
    if patch -p1 --dry-run -s < "$p" >"$TMP/dry.log" 2>&1; then
      patch -p1 -s --no-backup-if-mismatch < "$p" && { echo "applied: $name"; return 0; }
    fi
    echo "---- dry-run output for $name (did not apply) ----"; tail -n 20 "$TMP/dry.log"
  done
  fail "no $label patch applied cleanly (tried: $*)"
}

echo "== [2/5] Applying patches (Wi-Fi drivers, injection, naming fix)"
apply add-rtl88xxau-5.6.4.2-drivers.patch

# The repo's "4.19" patch folder actually holds injection patches for several
# kernel versions (4.14 and 4.19 seen so far). Pick the one matching this
# kernel's real version first, then fall back to whatever else exists here,
# instead of hardcoding 4.14 (which fails a hunk on a true 4.19 tree).
KVER="$(awk -F'=' '/^VERSION[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2}' Makefile 2>/dev/null | head -n1)"
KPLVL="$(awk -F'=' '/^PATCHLEVEL[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2}' Makefile 2>/dev/null | head -n1)"
KV="${KVER:+${KVER}.${KPLVL}}"
echo "Detected kernel version: ${KV:-unknown} (from Makefile VERSION/PATCHLEVEL)"

INJ_CANDS=()
[ -n "$KV" ] && [ -f "$PDIR/add-wifi-injection-${KV}.patch" ] && INJ_CANDS+=("add-wifi-injection-${KV}.patch")
while IFS= read -r f; do
  case " ${INJ_CANDS[*]:-} " in *" $f "*) ;; *) INJ_CANDS+=("$f") ;; esac
done < <(cd "$PDIR" && ls add-wifi-injection-*.patch 2>/dev/null)
apply_best "wifi-injection" "${INJ_CANDS[@]}"

apply fix-ath9k-naming-conflict.patch

echo "== [3/5] Writing config fragment: $CFG"
mkdir -p "$(dirname "$CFG")"
cat > "$CFG" <<'EOF'
# ---- Kali NetHunter fragment (4.19 arm64) ----

# Chroot / userspace needs (postgres for Metasploit needs SYSVIPC)
CONFIG_SYSVIPC=y
CONFIG_SYSVIPC_SYSCTL=y
CONFIG_POSIX_MQUEUE=y
CONFIG_BLK_DEV_LOOP=y
CONFIG_FUSE_FS=y
CONFIG_TUN=y
CONFIG_PACKET=y
CONFIG_UNIX=y
CONFIG_NAMESPACES=y
CONFIG_UTS_NS=y
CONFIG_IPC_NS=y
CONFIG_USER_NS=y
CONFIG_PID_NS=y
CONFIG_NET_NS=y
CONFIG_CGROUPS=y
CONFIG_INPUT_UINPUT=y
CONFIG_UHID=y
CONFIG_HIDRAW=y
CONFIG_SECURITY_SELINUX_DEVELOP=y
# CONFIG_ANDROID_PARANOID_NETWORK is not set

# Netfilter / NAT / MITM (bettercap, ettercap, Responder, mitmproxy, sslstrip)
CONFIG_NETFILTER=y
CONFIG_NETFILTER_ADVANCED=y
CONFIG_NF_CONNTRACK=y
CONFIG_NF_NAT=y
CONFIG_NF_NAT_IPV4=y
CONFIG_NF_NAT_IPV6=y
CONFIG_NETFILTER_NETLINK_QUEUE=y
CONFIG_NETFILTER_XT_TARGET_NFQUEUE=y
CONFIG_NETFILTER_XT_TARGET_REDIRECT=y
CONFIG_NETFILTER_XT_TARGET_TPROXY=y
CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_NETFILTER_XT_TARGET_MARK=y
CONFIG_NETFILTER_XT_MATCH_CONNTRACK=y
CONFIG_NETFILTER_XT_MATCH_STATE=y
CONFIG_NETFILTER_XT_MATCH_MARK=y
CONFIG_NETFILTER_XT_MATCH_MULTIPORT=y
CONFIG_NETFILTER_XT_MATCH_OWNER=y
CONFIG_NETFILTER_XT_MATCH_STRING=y
CONFIG_IP_NF_IPTABLES=y
CONFIG_IP_NF_FILTER=y
CONFIG_IP_NF_NAT=y
CONFIG_IP_NF_MANGLE=y
CONFIG_IP_NF_RAW=y
CONFIG_IP_NF_TARGET_MASQUERADE=y
CONFIG_IP_NF_TARGET_REJECT=y
CONFIG_IP6_NF_IPTABLES=y
CONFIG_IP6_NF_FILTER=y
CONFIG_IP6_NF_MANGLE=y
CONFIG_IP6_NF_RAW=y
CONFIG_IP6_NF_NAT=y
CONFIG_IP6_NF_TARGET_MASQUERADE=y
CONFIG_NF_TABLES=y
CONFIG_NF_TABLES_INET=y
CONFIG_NFT_CT=y
CONFIG_NFT_NAT=y
CONFIG_NFT_MASQ=y
CONFIG_NFT_REDIR=y
CONFIG_NFT_LOG=y
CONFIG_NFT_LIMIT=y
CONFIG_NFT_COUNTER=y
CONFIG_NFT_REJECT=y
CONFIG_BRIDGE=y
CONFIG_BRIDGE_NETFILTER=y
CONFIG_VLAN_8021Q=y
CONFIG_NET_IPIP=y
CONFIG_NET_IPGRE=y
CONFIG_PPP=y
CONFIG_PPP_ASYNC=y
CONFIG_PPP_DEFLATE=y
CONFIG_PPP_MPPE=y
CONFIG_PPPOE=y
CONFIG_PPTP=y

# Wi-Fi stack + external USB adapters (built-in, no .ko packing needed)
CONFIG_WIRELESS=y
CONFIG_CFG80211=y
CONFIG_CFG80211_WEXT=y
CONFIG_MAC80211=y
CONFIG_MAC80211_MESH=y
CONFIG_WLAN_VENDOR_ATH=y
CONFIG_ATH9K_HTC=y
CONFIG_CARL9170=y
CONFIG_WLAN_VENDOR_REALTEK=y
CONFIG_RTL8187=y
CONFIG_RTL8XXXU=y
CONFIG_RTL8XXXU_UNTESTED=y
CONFIG_RTL_CARDS=y
CONFIG_RTL8192CU=y
CONFIG_WLAN_VENDOR_RALINK=y
CONFIG_RT2X00=y
CONFIG_RT2500USB=y
CONFIG_RT73USB=y
CONFIG_RT2800USB=y
CONFIG_WLAN_VENDOR_MEDIATEK=y
CONFIG_MT7601U=y
CONFIG_MT76x0U=y
CONFIG_MT76x2U=y
CONFIG_WLAN_VENDOR_ZYDAS=y
CONFIG_ZD1211RW=y

# USB gadget (HID/BadUSB, RNDIS/ECM/NCM, mass storage, serial)
CONFIG_USB_GADGET=y
CONFIG_USB_CONFIGFS=y
CONFIG_USB_CONFIGFS_UEVENT=y
CONFIG_USB_CONFIGFS_SERIAL=y
CONFIG_USB_CONFIGFS_ACM=y
CONFIG_USB_CONFIGFS_NCM=y
CONFIG_USB_CONFIGFS_ECM=y
CONFIG_USB_CONFIGFS_ECM_SUBSET=y
CONFIG_USB_CONFIGFS_RNDIS=y
CONFIG_USB_CONFIGFS_EEM=y
CONFIG_USB_CONFIGFS_MASS_STORAGE=y
CONFIG_USB_CONFIGFS_F_FS=y
CONFIG_USB_CONFIGFS_F_HID=y

# USB host (OTG): serial, storage, ethernet dongles
CONFIG_USB_ACM=y
CONFIG_USB_STORAGE=y
CONFIG_USB_SERIAL=y
CONFIG_USB_SERIAL_GENERIC=y
CONFIG_USB_SERIAL_FTDI_SIO=y
CONFIG_USB_SERIAL_CH341=y
CONFIG_USB_SERIAL_CP210X=y
CONFIG_USB_SERIAL_PL2303=y
CONFIG_USB_NET_DRIVERS=y
CONFIG_USB_USBNET=y
CONFIG_USB_NET_CDCETHER=y
CONFIG_USB_NET_CDC_NCM=y
CONFIG_USB_NET_CDC_EEM=y
CONFIG_USB_NET_RNDIS_HOST=y
CONFIG_USB_NET_AX8817X=y
CONFIG_USB_NET_AX88179_178A=y
CONFIG_USB_RTL8152=y
CONFIG_USB_NET_SMSC75XX=y
CONFIG_USB_NET_SMSC95XX=y

# Bluetooth arsenal
CONFIG_BT=y
CONFIG_BT_BREDR=y
CONFIG_BT_RFCOMM=y
CONFIG_BT_RFCOMM_TTY=y
CONFIG_BT_BNEP=y
CONFIG_BT_BNEP_MC_FILTER=y
CONFIG_BT_BNEP_PROTO_FILTER=y
CONFIG_BT_HIDP=y
CONFIG_BT_LE=y
CONFIG_BT_HCIBTUSB=y
CONFIG_BT_HCIBTUSB_BCM=y
CONFIG_BT_HCIBTUSB_RTL=y
CONFIG_BT_HCIUART=y
CONFIG_BT_HCIUART_H4=y
CONFIG_BT_HCIVHCI=y
CONFIG_BT_HCIBCM203X=y
CONFIG_BT_HCIBPA10X=y

# CAN bus (CAN Arsenal)
CONFIG_CAN=y
CONFIG_CAN_DEV=y
CONFIG_CAN_RAW=y
CONFIG_CAN_BCM=y
CONFIG_CAN_GW=y
CONFIG_CAN_VCAN=y
CONFIG_CAN_SLCAN=y
CONFIG_CAN_CALC_BITTIMING=y
CONFIG_CAN_GS_USB=y
CONFIG_CAN_PEAK_USB=y
CONFIG_CAN_8DEV_USB=y
CONFIG_CAN_EMS_USB=y
CONFIG_CAN_KVASER_USB=y
EOF

# Realtek 88xxau Kconfig symbol name/location differs by patch version: discover it.
# Search the whole tree by content (not just drivers/net/wireless by filename) -
# the driver patch may land under a different path (e.g. drivers/net/wireless/realtek/...).
RTL_DIR="$(find . -maxdepth 7 -type d -iname '*88xxau*' 2>/dev/null | grep -v "^\./${TMP##*/}" | head -n1)"
RTL_KCONF="$(grep -rilE --include='Kconfig*' '88xxau' . 2>/dev/null | head -n1)"
if [ -z "$RTL_KCONF" ] && [ -n "$RTL_DIR" ]; then
  RTL_KCONF="$(find "$RTL_DIR" -iname 'Kconfig*' 2>/dev/null | head -n1)"
fi

if [ -n "$RTL_KCONF" ]; then
  echo "rtl88xxau Kconfig: $RTL_KCONF (driver dir: ${RTL_DIR:-<not located separately>})"
  SYM="$(grep -ioE '^[[:space:]]*config[[:space:]]+[A-Za-z0-9_]*88XXAU[A-Za-z0-9_]*' "$RTL_KCONF" | head -n1 | awk '{print toupper($2)}')"
  [ -z "$SYM" ] && SYM="$(grep -oE '^[[:space:]]*config[[:space:]]+[A-Za-z0-9_]+' "$RTL_KCONF" | head -n1 | awk '{print $2}')"
  if [ -n "$SYM" ]; then
    if [ "$RTL_MODE" = "n" ]; then echo "# CONFIG_${SYM} is not set" >> "$CFG"; else echo "CONFIG_${SYM}=${RTL_MODE}" >> "$CFG"; fi
    echo "RTL88XXAU symbol: CONFIG_${SYM}=${RTL_MODE}"
  else
    fail "found $RTL_KCONF but could not parse a config symbol out of it"
  fi
else
  echo "Searched whole tree for 'Kconfig*' files mentioning 88xxau and for a *88xxau* directory; neither found."
  echo "drivers/net/wireless now contains:"; ls -1 drivers/net/wireless 2>/dev/null
  fail "rtl88xxau driver not found in tree (patch skipped or unpacked elsewhere) - RTL8812AU/8814AU/8821AU adapters won't work"
fi

echo "== [4/5] Internal Wi-Fi (qcacld-3.0) monitor mode"
# Folder may be named qcacld-3.0 (usual) or something similar; find it by Kbuild.
QDIR=""
while read -r c; do
  [ -f "$c/Kbuild" ] && { QDIR="$c"; break; }
done < <(find drivers/staging -maxdepth 1 -type d \( -iname 'qcacld*' -o -iname 'q*3.0' \) 2>/dev/null | sort)

if [ -z "$QDIR" ]; then
  echo "drivers/staging has:"; ls -1 drivers/staging | grep -i -E 'q|wlan|cld' || true
  fail "qcacld-3.0 folder with a Kbuild not found under drivers/staging - internal Wi-Fi monitor mode skipped"
else
  echo "qcacld dir: $QDIR"

  MON_SRC="$(grep -rl --include='*.c' 'QDF_GLOBAL_MONITOR_MODE' "$QDIR" 2>/dev/null | head -n3)"
  CONMODE_SRC="$(grep -rl --include='*.c' 'con_mode' "$QDIR" 2>/dev/null | head -n1)"
  echo "con_mode defined in : ${CONMODE_SRC:-<none>}"
  echo "monitor-mode code in: ${MON_SRC:-<none>}"
  echo "Monitor-related Kbuild switches:"; grep -nE 'MONITOR|PKT_CAPTURE' "$QDIR/Kbuild" | head -n 20 || true

  if [ -n "$MON_SRC" ] && [ -n "$CONMODE_SRC" ]; then
    echo "Driver already has monitor mode (con_mode=4); no patch needed."
  else
    echo "Monitor-mode code missing, trying kimocoder enable_monitor_mode.patch"
    MURL="https://github.com/kimocoder/qualcomm_android_monitor_mode/raw/master/files/enable_monitor_mode.patch"
    if curl -fsSL "$MURL" -o "$TMP/enable_monitor_mode.patch"; then
      done_=0
      for d in "$QDIR" "."; do
        if patch -d "$d" -p1 --dry-run -s < "$TMP/enable_monitor_mode.patch" >"$TMP/mon.log" 2>&1; then
          patch -d "$d" -p1 -s --no-backup-if-mismatch < "$TMP/enable_monitor_mode.patch" \
            && { echo "applied monitor patch in $d"; done_=1; break; }
        fi
      done
      [ "$done_" = "1" ] || { tail -n 30 "$TMP/mon.log"; fail "enable_monitor_mode.patch does not apply to this qcacld (skipped)"; }
    else
      fail "could not download enable_monitor_mode.patch"
    fi
  fi

  # Wi-Fi symbol (normally QCA_CLD_WLAN) and its current state in the base defconfig
  WSYM="$(grep -oE '^config[[:space:]]+[A-Za-z0-9_]+' "$QDIR/Kconfig" 2>/dev/null | head -n1 | awk '{print $2}')"
  WSYM="${WSYM:-QCA_CLD_WLAN}"
  BASE="arch/arm64/configs/${DEFCONFIG_NAME:-vendor/kona-perf_defconfig}"
  echo "Base defconfig has: $(grep -h "^CONFIG_${WSYM}[= ]" "$BASE" 2>/dev/null || echo '<not set>')"
  if [ "$WLAN_BUILTIN" = "1" ]; then
    echo "CONFIG_${WSYM}=y" >> "$CFG"; echo "Forcing CONFIG_${WSYM}=y"
  fi
  echo "After boot: ip link set wlan0 down; echo 4 > /sys/module/wlan/parameters/con_mode; ip link set wlan0 up"
fi

echo "== [5/5] Checking every symbol exists in this tree"
grep -rhoE --include='Kconfig*' '^[[:space:]]*(menu)?config[[:space:]]+[A-Za-z0-9_]+' \
  arch/arm64 arch/Kconfig drivers net fs kernel init crypto security block lib mm 2>/dev/null \
  | awk '{print $NF}' | sort -u > "$TMP/syms"

MISSING=0
while read -r s; do
  if ! grep -qx "$s" "$TMP/syms"; then
    echo "::warning::CONFIG_$s not in this kernel (will be ignored)"; MISSING=$((MISSING+1))
  fi
done < <(grep -oE '^(# )?CONFIG_[A-Za-z0-9_]+' "$CFG" | sed 's/^# //; s/^CONFIG_//' | sort -u)

echo "Done. Missing symbols: $MISSING. Fragment: $CFG"
echo "Now append ',${CFG_REL}' (LAST) to MERGE_CONFIG_FILES."
rm -rf "$TMP"
exit 0
