# 🚀 KILLER PROXY v4.0 — Automated Multi-IP Proxy + VLESS Panel

**Repo:** `Nizwarax/killer-proxy` · One-command install · Debian/Ubuntu · root

Satu VPS → banyak port proxy **SOCKS5 & HTTP** dengan **IP keluar berbeda-beda** (Cloudflare WARP via **wireproxy** user-space), plus **VLESS+REALITY** di port 443 — semuanya dikelola lewat CLI, dashboard, dan Telegram bot.

> v4.0 = v3 + **Tier-3 IPv6 self-probe** + **tuning kernel performa** (BBR, MTU probing, buffer besar) + **AI_INSTRUCTIONS.md** untuk deployment otomatis oleh AI agent.

## ⚡ One-Command Install (langsung jalan)

```bash
curl -fsSL https://raw.githubusercontent.com/Nizwarax/killer-proxy/main/install.sh | bash
```

Installer otomatis: deteksi RAM + swap → install 3proxy/wgcf/wireproxy/xray → **generate key REALITY fresh** → init 4 WARP → generate config (tervalidasi) → firewall aman → cron expiry (guarded). Selesai, langsung pakai.

```bash
proxy            # atau `menu` — dashboard interaktif
```

## 🧱 Arsitektur (mengapa ini kuat)

| Lapisan | Teknologi | Catatan |
|---|---|---|
| Egress multi-IP | **wireproxy** (user-space WARP) | Zero SSH lockout, tidak sentuh routing kernel |
| Port proxy | **3proxy** `parent ... socks5` chain | 1 user = 1 IP keluar unik |
| VLESS | **Xray-core** REALITY Vision 443 | SNI `www.speedtest.net` |
| Manajemen | CLI + dashboard + **Telegram bot** | multi-user + expiry + traffic stats |
| Keamanan | key REALITY **fresh per install**, IP dinamis | tanpa hardcode |

## 📦 Fitur

- **Tier 1:** SOCKS5 `10001` / HTTP `11001` — egress IP VPS asli (shared, admin).
- **Tier 2:** per-user WARP — tiap user dapat port SOCKS5 + HTTP dengan **IP keluar unik** dari instance WARP.
- **Tier 3 (opsional, self-probe):** 1 user = **1 source IPv6 unik** (`20001+`/`21001+`) — aktif HANYA jika `detect-ipv6.sh` membuktikan VPS bisa sub-alokasi prefix-nya (tidak pernah buka port mati).
- **Tuning kernel:** BBR + `tcp_mtu_probing` + `tcp_fastopen` + buffer/window besar + `ip_nonlocal_bind` (otomatis via sysctl).
- **VLESS REALITY:** `proxy-vless add <user> <hari> [warp|direct]` — tiap user bisa outbound lewat WARP tertentu atau direct.
- **Multi-user + expiry:** `proxy-user add/del/extend/list` · cron cek tiap 10 menit, **hanya restart kalau ada yang berubah** (koneksi live tidak diputus tiap 10 menit).
- **Traffic stats** per-user via Xray API (`proxy` → menu 7).
- **Rotasi IP:** `rotate-warp.sh all` — re-register semua WARP paralel.
- **Bot Telegram:** `/start` → keyboard (list/stats/rotate/status/traffic), offset-aware.
- **Diagnostik:** uji tiap port dengan skema HTTP/SOCKS5 yang benar.

## 🎛️ Perintah Cepat

```bash
proxy-user add alice pass123 30        # tambah user SOCKS/HTTP (30 hari)
proxy-user list
proxy-user extend alice 7              # perpanjang
proxy-user del alice

proxy-vless add bob 30 warp            # user VLESS via WARP
proxy-vless add carol 30 direct        # user VLESS via IP VPS langsung
proxy-vless list

rotate-warp.sh all                     # rotasi semua IP WARP
rotate-warp.sh 2                       # rotasi instance 2 saja

cat /root/daftar_proxy.txt             # daftar proxy (IP:PORT:USER:PASS)
cat /root/vless_accounts.txt           # link VLESS + public key
```

## 🤖 Bot Telegram

```bash
menu   # → pilih [8] Setup Bot, atau manual:
cat > /etc/3proxy/telegram_bot.conf <<'EOF'
BOT_TOKEN="123456:ABC..."
ADMIN_ID="123456789"
EOF
chmod 600 /etc/3proxy/telegram_bot.conf
systemctl restart proxy-bot
```

## 🔧 Troubleshooting

- **Port WARP timeout** → `rotate-warp.sh all`
- **Port refused dari luar** → `ufw status` (pastikan 10001-10099/11001-11099/443 open)
- **Tier-3 IPv6 tidak aktif** → `cat /etc/proxy/ipv6.json`; kalau `enabled:false`, prefix VPS bukan ter-routing (SLAAC bersama). Minta provider route prefix dedicated, lalu jalankan ulang `detect-ipv6.sh`.
- **3proxy gagal start** → `3proxy /etc/3proxy/3proxy.cfg` (lihat error)
- **VLESS tidak connect** → cek `xray run -test -config /usr/local/etc/xray/config.json`, lalu `systemctl status xray`

## 🗑️ Uninstall

```bash
bash /root/proxy/uninstall.sh
```

---
*Key REALITY dihasilkan otomatis per instalasi; jangan pernah menyalin konfigurasi antar VPS.*
