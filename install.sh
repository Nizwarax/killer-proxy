#!/bin/bash
# ==============================================================================
# KILLER PROXY - 1-Click Automated Multi-IP Proxy + VLESS Installer
# Repo: https://github.com/Nizwarax/killer-proxy
# One command:  curl -fsSL https://raw.githubusercontent.com/Nizwarax/killer-proxy/main/install.sh | bash
# Debian/Ubuntu. Must be root.
# ==============================================================================
set -u
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
die(){ echo -e "${RED}[ERROR] $1${NC}"; exit 1; }
ok(){ echo -e "${GREEN}[OK] $1${NC}"; }
warn(){ echo -e "${YELLOW}[WARN] $1${NC}"; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
N_WARP=4

# --- bootstrap: bila dijalankan via curl|bash (tanpa file repo), download & re-exec ---
if [ ! -f "$SCRIPT_DIR/bin/menu" ]; then
  echo -e "${CYAN}[bootstrap] Mengunduh Nizwarax/killer-proxy...${NC}"
  rm -rf /root/proxy; mkdir -p /root/proxy
  curl -fsSL https://github.com/Nizwarax/killer-proxy/archive/refs/heads/main.tar.gz \
    | tar -xz --strip-components=1 -C /root/proxy || die "Gagal unduh repo"
  exec bash /root/proxy/install.sh
fi

[ "$(id -u)" -ne 0 ] && die "Harus root! sudo -i"

# ---------- 1. deps ----------
echo -e "${CYAN}[1/9] Dependensi sistem...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1 || warn "apt update bermasalah"
apt-get install -y curl wget unzip jq git build-essential ufw openssl python3 python3-requests ca-certificates qrencode >/dev/null 2>&1 \
  || die "Gagal install paket dasar"
ok "dependensi"

# ---------- 2. swap jika RAM kecil ----------
MEM=$(free -m | awk '/^Mem:/{print $2}'); SWAP=$(free -m | awk '/^Swap:/{print $2}')
if [ "$MEM" -lt 1500 ] && [ "$SWAP" -lt 500 ] && [ ! -f /swapfile ]; then
  echo -e "${CYAN}[2/9] Membuat swap 1GB (RAM ${MEM}MB)...${NC}"
  (fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none)
  chmod 600 /swapfile; mkswap /swapfile >/dev/null 2>&1; swapon /swapfile >/dev/null 2>&1
  grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
  ok "swap"
else
  echo -e "${CYAN}[2/9] Swap...${NC}"; ok "swap siap/skip"
fi

# ---------- 3. 3proxy ----------
echo -e "${CYAN}[3/9] Build 3proxy...${NC}"
if ! command -v 3proxy >/dev/null 2>&1; then
  cd /tmp || die "cd /tmp gagal"; rm -rf 3proxy
  git clone -q --depth 1 https://github.com/3proxy/3proxy.git || die "gagal clone 3proxy"
  (cd 3proxy && make -f Makefile.Linux >/dev/null 2>&1) || die "gagal build 3proxy"
  cp 3proxy/bin/3proxy /usr/local/bin/3proxy || die "gagal copy 3proxy"
  cd / || exit; rm -rf /tmp/3proxy
fi
ok "3proxy"

# ---------- 4. wgcf + wireproxy ----------
echo -e "${CYAN}[4/9] Install wgcf & wireproxy...${NC}"
[ -x /usr/local/bin/wgcf ] || { curl -fsSL https://github.com/ViRb3/wgcf/releases/download/v2.3.1/wgcf_2.3.1_linux_amd64 -o /usr/local/bin/wgcf && chmod +x /usr/local/bin/wgcf; }
[ -x /usr/local/bin/wireproxy ] || {
  curl -fsSL https://github.com/windtf/wireproxy/releases/download/v1.1.3/wireproxy_linux_amd64.tar.gz -o /tmp/wp.tgz
  tar -xzf /tmp/wp.tgz -C /usr/local/bin wireproxy && chmod +x /usr/local/bin/wireproxy; rm -f /tmp/wp.tgz
}
command -v wgcf >/dev/null 2>&1 && command -v wireproxy >/dev/null 2>&1 || die "wgcf/wireproxy gagal"
ok "wgcf + wireproxy"

# ---------- 5. xray ----------
echo -e "${CYAN}[5/9] Install Xray-core...${NC}"
[ -x /usr/local/bin/xray ] || bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 || true
[ -x /usr/local/bin/xray ] || die "xray gagal install"
/usr/local/bin/xray x25519 >/dev/null 2>&1 || die "xray x25519 tidak berfungsi"
ok "xray"

# ---------- 6. REALITY keys FRESH (per install, never hardcoded) ----------
echo -e "${CYAN}[6/9] Generate REALITY keys fresh...${NC}"
mkdir -p /etc/xray
KEYS=$(/usr/local/bin/xray x25519 2>/dev/null)
RPRIV=$(awk '/Private/{print $NF}' <<<"$KEYS"); RPUB=$(awk '/Public/{print $NF}' <<<"$KEYS")
[ -n "$RPRIV" ] && [ -n "$RPUB" ] || die "gagal parse xray x25519"
python3 -c "import base64,sys; [base64.b64decode(k.replace('-','+').replace('_','/')+'='*(-len(k)%4),validate=True) for k in sys.argv[1:]]" "$RPRIV" "$RPUB" \
  || die "key xray invalid (bukan 32-byte)"
RSID=$(openssl rand -hex 8)
echo "{\"privateKey\":\"$RPRIV\",\"publicKey\":\"$RPUB\",\"shortId\":\"$RSID\"}" > /etc/xray/reality.json
chmod 600 /etc/xray/reality.json
ok "REALITY keys valid (fresh)"

# ---------- 7. pasang script + systemd + cron + alias ----------
echo -e "${CYAN}[7/9] Pasang script & service...${NC}"
mkdir -p /etc/3proxy /etc/xray /etc/wireproxy
for f in menu proxy-user proxy-vless generate-proxies.py generate-xray.py rotate-warp.sh auto-expire.sh telegram-bot.py detect-ipv6.sh; do
  [ -f "$SCRIPT_DIR/bin/$f" ] && { cp -f "$SCRIPT_DIR/bin/$f" "/usr/local/bin/$f"; chmod +x "/usr/local/bin/$f"; }
done
ln -sf /usr/local/bin/menu /usr/local/bin/proxy
ln -sf /usr/local/bin/menu /usr/local/bin/menu
# aliases
grep -q 'alias proxy=' /root/.bashrc 2>/dev/null || echo 'alias proxy="/usr/local/bin/menu"' >> /root/.bashrc
grep -q 'alias menu=' /root/.bashrc 2>/dev/null || echo 'alias menu="/usr/local/bin/menu"' >> /root/.bashrc

# systemd
cp -f "$SCRIPT_DIR/systemd/3proxy.service" /etc/systemd/system/3proxy.service
cp -f "$SCRIPT_DIR/systemd/wireproxy@.service" /etc/systemd/system/wireproxy@.service
cp -f "$SCRIPT_DIR/systemd/proxy-bot.service" /etc/systemd/system/proxy-bot.service

# sysctl performa (BBR + high-performance tuning + IPv6 nonlocal bind)
cat > /etc/sysctl.d/99-killerproxy.conf <<'SYS'
# IPv6/IPv4 non-local bind: izinkan bind ke IPv6 yang belum di-assign (Tier-3)
net.ipv6.ip_nonlocal_bind = 1
net.ipv4.ip_nonlocal_bind = 1
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# BBR Congestion Control & queueing
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP MTU probing (penting untuk MTU tunnel WARP 1280)
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3

# High performance connection limits & reuse
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# TCP window & buffer besar
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
SYS
sysctl -p /etc/sysctl.d/99-killerproxy.conf >/dev/null 2>&1

# Tier-3 IPv6: probe apakah VPS benar-benar bisa sub-alokasi prefix IPv6
/usr/local/bin/detect-ipv6.sh || true
if [ -f /etc/proxy/ipv6.json ] && grep -q '"enabled": *true' /etc/proxy/ipv6.json; then
  ok "Tier-3 IPv6 ENABLED (prefix ter-routing terdeteksi)"
else
  warn "Tier-3 IPv6 disabled (VPS tidak punya prefix ter-routing / SLAAC bersama)"
fi

# cron (guarded worker - hanya restart bila config berubah)
cat > /etc/cron.d/proxy-expiry <<'CRON'
*/10 * * * * root /usr/local/bin/auto-expire.sh >/dev/null 2>&1
CRON
chmod 644 /etc/cron.d/proxy-expiry

# user DB templates (jangan timpa yang sudah ada)
[ -f /etc/3proxy/users.json ] || echo '{"version":"1.0","mode":"multi-user","users":{}}' > /etc/3proxy/users.json
[ -f /etc/xray/vless_users.json ] || echo '{"version":"1.0","users":{}}' > /etc/xray/vless_users.json
# credentials admin (dibuat sekali, acak)
if [ ! -f /etc/3proxy/credentials.txt ]; then
  AUSER="admin$(openssl rand -hex 2)"; APASS=$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-14)
  echo "USER=$AUSER" > /etc/3proxy/credentials.txt; echo "PASS=$APASS" >> /etc/3proxy/credentials.txt
fi
chmod 600 /etc/3proxy/users.json /etc/3proxy/credentials.txt 2>/dev/null

systemctl daemon-reload
systemctl enable 3proxy xray >/dev/null 2>&1
systemctl enable proxy-bot >/dev/null 2>&1
ok "script + service terpasang"

# ---------- 8. init WARP (wireproxy, user-space) ----------
echo -e "${CYAN}[8/9] Inisialisasi ${N_WARP} WARP instance (user-space)...${NC}"
for i in $(seq 1 "$N_WARP"); do
  mkdir -p "/etc/wireproxy/warp$i"
  systemctl enable "wireproxy@warp$i" >/dev/null 2>&1
done
if command -v wgcf >/dev/null 2>&1; then
  /usr/local/bin/rotate-warp.sh all || warn "sebagian WARP gagal (Tier 1 & VLESS direct tetap jalan)"
else
  warn "wgcf tidak ada, skip WARP"
fi

# ---------- 9. generate config + firewall ----------
echo -e "${CYAN}[9/9] Generate config & firewall...${NC}"
/usr/local/bin/generate-proxies.py || warn "generate 3proxy gagal"
/usr/local/bin/generate-xray.py || warn "generate xray gagal"

# UFW aman (deteksi port SSH, anti-lockout)
SSH_PORT=$(ss -tulpn 2>/dev/null | grep -E 'sshd|ssh' | awk '{print $5}' | awk -F: '{print $NF}' | sort -u | head -n1)
SSH_PORT=${SSH_PORT:-22}
ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1
ufw allow 443/tcp >/dev/null 2>&1
ufw allow 10001:10099/tcp >/dev/null 2>&1
ufw allow 11001:11099/tcp >/dev/null 2>&1
# Tier-3 IPv6 ports hanya jika probe bilang prefix benar-benar ter-routing
if [ -f /etc/proxy/ipv6.json ] && grep -q '"enabled": *true' /etc/proxy/ipv6.json; then
  ufw allow 20001:20099/tcp >/dev/null 2>&1
  ufw allow 21001:21099/tcp >/dev/null 2>&1
fi
ufw default allow outgoing >/dev/null 2>&1
ufw default deny incoming >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1 || warn "ufw enable gagal"
ok "firewall (SSH ${SSH_PORT}, 443, proxy ports)"

# ---------- ringkasan ----------
IP=$(curl -s4 --max-time 4 icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
echo ""
echo -e "${BOLD}${GREEN}==============================================================================${NC}"
echo -e "${BOLD}${GREEN}          KILLER PROXY - INSTALASI SELESAI & SUKSES!${NC}"
echo -e "${BOLD}${GREEN}==============================================================================${NC}"
echo -e " VPS IPv4     : ${BOLD}${GREEN}$IP${NC}"
echo -e " SOCKS5       : 10001+ (Tier1 direct) + per-user WARP port"
echo -e " HTTP         : 11001+"
echo -e " VLESS REALITY: 443 (SNI www.speedtest.net)"
echo -e " File SOCKS   : ${BOLD}/root/daftar_proxy.txt${NC}"
echo -e " File VLESS   : ${BOLD}/root/vless_accounts.txt${NC}"
echo -e " Admin proxy  : $(cat /etc/3proxy/credentials.txt 2>/dev/null | tr '\n' ' ')"
echo -e "==============================================================================${NC}"
echo -e " Perintah:"
echo -e "  menu / proxy            -> dashboard"
echo -e "  proxy-user add <u> <p> <hari>  -> tambah user SOCKS/HTTP"
echo -e "  proxy-vless add <u> <hari> [warp|direct] -> tambah user VLESS"
echo -e "  rotate-warp.sh all      -> rotasi IP WARP"
echo -e "  proxy-bot: isi /etc/3proxy/telegram_bot.conf lalu: systemctl restart proxy-bot"
echo -e "==============================================================================${NC}"
