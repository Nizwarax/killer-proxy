#!/bin/bash
# KILLER PROXY uninstaller (bersih)
set -u
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
[ "$(id -u)" -ne 0 ] && { echo -e "${RED}Harus root${NC}"; exit 1; }
read -p "$(echo -e ${BOLD}Uninstall TOTAL? ketik YES: ${NC})" yy
[ "$yy" = "YES" ] || { echo -e "${GREEN}Dibatalkan${NC}"; exit 0; }
echo -e "${CYAN}[1/5] Stop service...${NC}"
systemctl stop xray 3proxy proxy-bot >/dev/null 2>&1
for i in $(seq 1 12); do systemctl stop "wireproxy@warp$i" >/dev/null 2>&1; done
systemctl disable xray 3proxy proxy-bot >/dev/null 2>&1
echo -e "${CYAN}[2/5] Hapus binaries...${NC}"
rm -f /usr/local/bin/3proxy /usr/local/bin/wgcf /usr/local/bin/wireproxy
rm -f /usr/local/bin/menu /usr/local/bin/proxy /usr/local/bin/proxy-user /usr/local/bin/proxy-vless
rm -f /usr/local/bin/generate-proxies.py /usr/local/bin/generate-xray.py /usr/local/bin/rotate-warp.sh /usr/local/bin/auto-expire.sh /usr/local/bin/telegram-bot.py /usr/local/bin/detect-ipv6.sh
echo -e "${CYAN}[2b/5] Hapus IPv6 Tier-3 addrs & config...${NC}"
if [ -f /etc/proxy/ipv6.json ]; then
  V6IF=$(grep -o '"iface": "[^"]*"' /etc/proxy/ipv6.json 2>/dev/null | cut -d'"' -f4)
  VPREF=$(grep -o '"prefix": "[^"]*"' /etc/proxy/ipv6.json 2>/dev/null | cut -d'"' -f4)
  if [ -n "$V6IF" ] && [ -n "$VPREF" ]; then
    for i in $(seq 1 99); do
      ip -6 addr del "${VPREF}$(printf '%x' "$i")/128" dev "$V6IF" >/dev/null 2>&1
    done
  fi
fi
rm -rf /etc/proxy
echo -e "${CYAN}[3/5] Hapus config...${NC}"
rm -rf /etc/3proxy /etc/xray /etc/wireproxy /root/daftar_proxy.txt /root/vless_accounts.txt
rm -f /etc/systemd/system/3proxy.service /etc/systemd/system/wireproxy@.service /etc/systemd/system/proxy-bot.service /etc/cron.d/proxy-expiry /etc/sysctl.d/99-killerproxy.conf
systemctl daemon-reload
echo -e "${CYAN}[4/5] Hapus xray (opsional)...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge >/dev/null 2>&1 || true
echo -e "${CYAN}[5/5] Bersihkan alias...${NC}"
sed -i '/alias proxy=/d;/alias menu=/d' /root/.bashrc 2>/dev/null
echo -e "${GREEN}Uninstall selesai${NC}"
