#!/usr/bin/env bash
# Add Kali NetHunter support to an Android 4.19 (arm64) kernel tree.
# Usage: bash patch-nethunter.sh <kernel_dir>
# Env:   NH_STRICT=1  -> abort the build if any NetHunter patch fails to apply
set -uo pipefail

KDIR="${1:-$PWD}"
cd "$KDIR" || { echo "::error::bad kernel dir"; exit 1; }

STRICT="${NH_STRICT:-0}"
NH_REPO="https://gitlab.com/kalilinux/nethunter/build-scripts/kali-nethunter-kernel.git"
CFG_REL="vendor/nethunter.config"
CFG="arch/arm64/configs/${CFG_REL}"
TMP="$(mktemp -d)"

fail() { echo "::warning::$*"; [ "$STRICT" = "1" ] && exit 1; return 0; }

echo "== [1/4] Fetching NetHunter kernel patches"
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

echo "== [2/4] Applying patches (Wi-Fi drivers, injection, naming fix)"
apply add-rtl88xxau-5.6.4.2-drivers.patch
apply add-wifi-injection-4.14.patch
apply fix-ath9k-naming-conflict.patch

echo "== [3/4] Writing config fragment: $CFG"
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

# Realtek 88xxau Kconfig symbol name differs by patch version: discover it
RTL_KCONF="$(find drivers/net/wireless -ipath '*88xxau*' -name 'Kconfig*' 2>/dev/null | head -n1)"
if [ -n "$RTL_KCONF" ]; then
  SYM="$(grep -oE '^config[[:space:]]+[A-Za-z0-9_]+' "$RTL_KCONF" | head -n1 | awk '{print $2}')"
  [ -n "$SYM" ] && { echo "CONFIG_${SYM}=y" >> "$CFG"; echo "RTL88XXAU symbol: CONFIG_${SYM}"; }
else
  fail "rtl88xxau driver not found in tree (patch skipped?) - RTL8812AU/8814AU/8821AU adapters won't work"
fi

echo "== [4/4] Checking every symbol exists in this tree"
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
