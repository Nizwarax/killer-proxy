# 🤖 KILLER PROXY - AI AGENT OPERATIONAL & DEPLOYMENT INSTRUCTIONS
> **Target Audience:** AI Coding Assistants (Antigravity, Claude Code, Cursor, Aider, Codex, ChatGPT, etc.)
> **Task Objective:** Automatically deploy, scale, maintain, or troubleshoot the `proxy` Multi-IP Proxy Server on any Linux VPS (Ubuntu / Debian).
> **Repo:** https://github.com/Nizwarax/killer-proxy

---

## 1. Executive System Context & Architecture
`proxy` is an automated multi-IP proxy server (SOCKS5 & HTTP/HTTPS) plus VLESS Reality, designed to run on a single VPS without breaking the main networking or SSH connectivity:

* **Inbound Access:** Clients connect via `IPv4_VPS:Port:Username:Password` over the public IPv4 of the VPS.
* **Tier 1 (Direct Native IPv4):**
  - SOCKS5 Port: `10001` | HTTP Port: `11001`
  - Egress: Native Public IPv4 of the host VPS (detected at runtime, never hardcoded).
* **Tier 2 (Cloudflare WARP User-Space Outbounds):**
  - SOCKS5 Ports: `10002` s.d. `10099+` | HTTP Ports: `11002` s.d. `11099+`
  - Egress: Distinct, clean Cloudflare WARP IPv4 & IPv6 addresses.
  - Implementation: Runs via `wireproxy` (user-space WireGuard proxy) bound locally to `127.0.0.1:40001..4000X`.
  - **CRITICAL GUARDRAIL:** Never use `wg-quick` or full-tunnel routing table modifications. `wireproxy` runs strictly in user-space, ensuring ZERO risk of SSH lockout.
* **Tier 3 (Native IPv6 Subnet Multi-Port) — SELF-PROBED:**
  - SOCKS5 Ports: `20001+` | HTTP Ports: `21001+`
  - Egress: Individual IPv6 addresses bound via `3proxy` with `sysctl net.ipv6.ip_nonlocal_bind=1`.
  - **Enabled ONLY if the install-time probe (`detect-ipv6.sh`) proves the VPS can actually source traffic from a sub-allocated /64.** Many VPS have a shared SLAAC /64 you CANNOT source from — the probe detects this and disables Tier 3 instead of shipping dead ports.
* **VLESS Reality (Port 443):**
  - Xray-core, fresh REALITY keypair per install (never hardcoded), per-user WARP or Direct outbound.
  - Traffic stats available via Xray API on `127.0.0.1:10085`.
* **Management & Control:**
  - Interactive TUI: `/usr/local/bin/menu` (aliased as `proxy` and `menu`).
  - Telegram Bot Daemon: `/usr/local/bin/telegram-bot.py` (systemd `proxy-bot.service`).

---

## 2. Guardrails & Safety Protocols for AI Agents
1. **Zero SSH Lockout (CRITICAL):**
   - Always detect the active SSH listening port first (`ss -tulpn | grep -E 'sshd|ssh'`).
   - Never overwrite UFW / iptables rules without explicitly allowing the active SSH port.
2. **Lightweight Resource Footprint:**
   - Designed for low-spec VPS (down to 1 vCPU / 1 GB RAM).
   - If total RAM is <= 1.5 GB and swap is missing, always ensure a 1 GB swapfile is active (`/swapfile`).
3. **Idempotence & Anti-Churn:**
   - Generators are content-guarded: if the new config equals the running one, they do **not** rewrite or restart (the cron worker will never drop live connections every 10 minutes).
   - Config is validated with `xray run -test` before it replaces the live one.
   - Running installer or generator scripts multiple times must never duplicate port configurations or destroy working credentials unless explicitly instructed by the user.

---

## 3. Deployment Instructions on a Fresh VPS
When a user asks you to set up `proxy` on a new VPS, execute the following steps:

```bash
# 1. Verify OS and RAM
cat /etc/os-release
free -m

# 2. Check active SSH port
ss -tulpn | grep ssh

# 3. One-command install (auto-downloads the repo — no manual copy needed)
curl -fsSL https://raw.githubusercontent.com/Nizwarax/killer-proxy/main/install.sh | bash

# 4. Verify all systemd services are active
systemctl is-active 3proxy xray proxy-bot wireproxy@warp1 wireproxy@warp2 wireproxy@warp3 wireproxy@warp4 ufw

# 5. Run live connectivity verification
source /etc/3proxy/credentials.txt
curl -s -m 5 --socks5-hostname "$USER:$PASS@127.0.0.1:10001" https://icanhazip.com
curl -s -m 5 --socks5-hostname "$USER:$PASS@127.0.0.1:10002" https://api64.ipify.org
```

---

## 4. Scaling Instructions (How to Add More WARP Ports)
If the user requests more ports (e.g., "Add 10 more WARP proxy ports" or "Scale to 20 ports"):

1. Open `/usr/local/bin/menu` and use Option `[4] Tambah Jumlah Port WARP`, OR
2. Run this automated bash loop:
```bash
START_IDX=5
TARGET_TOTAL=20

for (( i=START_IDX; i<=TARGET_TOTAL; i++ )); do
    inst_dir="/etc/wireproxy/warp$i"
    mkdir -p "$inst_dir"
    cd "$inst_dir"
    wgcf register --accept-tos >/dev/null 2>&1
    wgcf generate >/dev/null 2>&1
    socks_port=$((40000 + i))
    http_port=$((45000 + i))
    python3 -c "
import configparser
cfg = configparser.ConfigParser()
cfg.read('$inst_dir/wgcf-profile.conf')
priv = cfg['Interface']['PrivateKey']
addr = cfg['Interface']['Address']
pub = cfg['Peer']['PublicKey']
conf = f'''[Interface]
PrivateKey = {priv}
Address = {addr}
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = {pub}
Endpoint = 162.159.192.1:2408
KeepAlive = 25

[Socks5]
BindAddress = 127.0.0.1:$socks_port

[Http]
BindAddress = 127.0.0.1:$http_port
'''
with open('$inst_dir/wireproxy.conf', 'w') as f:
    f.write(conf)
"
    systemctl enable wireproxy@warp$i >/dev/null 2>&1
    systemctl restart wireproxy@warp$i
done

# Regenerate multi-user configs (both are content-guarded: no restart if unchanged)
/usr/local/bin/generate-proxies.py
/usr/local/bin/generate-xray.py
```

---

## 5. Telegram Bot Setup
If the user provides a Telegram Bot Token (from `@BotFather`) and Chat ID:

```bash
cat << 'EOF' > /etc/3proxy/telegram_bot.conf
BOT_TOKEN="<USER_BOT_TOKEN>"
ADMIN_ID="<USER_CHAT_ID>"
EOF
chmod 600 /etc/3proxy/telegram_bot.conf

systemctl enable proxy-bot
systemctl restart proxy-bot
systemctl status proxy-bot --no-pager
```

---

## 6. Common Troubleshooting Scenarios

| Issue / Symptom | Root Cause | Solution |
| :--- | :--- | :--- |
| **WARP Port Timeout** | Cloudflare handshake stalled | Run `/usr/local/bin/rotate-warp.sh <INSTANCE_NUM>` to refresh keys and reconnect. |
| **Port refused from outside** | UFW firewall blocking | Check `ufw status` and ensure `10001:10099/tcp`, `11001:11099/tcp` and `443/tcp` are allowed. |
| **3proxy fails to start** | Port collision or syntax error | Run `3proxy /etc/3proxy/3proxy.cfg` directly to view debug error output. |
| **Xray fails to start** | Invalid config rejected by `xray run -test` | Read `/usr/local/etc/xray/.config.validate.json` error output; the old good config stays live. |
| **IPv6 Tier 3 RTO** | Provider hasn't routed the subnet | Check `cat /etc/proxy/ipv6.json` — if `enabled:false`, the VPS has a shared SLAAC /64; contact hosting support to route a dedicated prefix, then re-run `detect-ipv6.sh`. |
| **Connections drop every 10 min** | Old non-guarded cron worker | Ensure `/etc/cron.d/proxy-expiry` runs `auto-expire.sh`, which calls the guarded generators (no restart when config is unchanged). |

---

## 7. Multi-User & Expiry Management Suite

### SOCKS5 & HTTP Users:
* Database: `/etc/3proxy/users.json`
* Generator: `/usr/local/bin/generate-proxies.py`
* CLI Command:
  ```bash
  proxy-user add <username> <password> <days>  # Add/extend user
  proxy-user del <username>                    # Delete user
  proxy-user list                              # View active & expired users
  proxy-user check                             # Trigger expiration check
  ```

### VLESS Reality Users (Port 443):
* Engine: **Xray-core** (config at `/usr/local/etc/xray/config.json`)
* Database: `/etc/xray/vless_users.json`
* Generator: `/usr/local/bin/generate-xray.py`
* Outbounds: Dedicated WARP instances (`warp-1` to `warp-N`) or Direct VPS (`direct`)
* CLI Command:
  ```bash
  proxy-vless add <username> <days> [warp|direct] [warp_instance_num]
  proxy-vless del <username>
  proxy-vless list
  proxy-vless check
  ```
* Accounts List & Links: Saved at `/root/vless_accounts.txt`

### Automated Expiry Cron Job:
* Cron file: `/etc/cron.d/proxy-expiry`
* Worker: `/usr/local/bin/auto-expire.sh`
* Schedule: Runs every 10 minutes (`*/10 * * * *`). Instantly disconnects expired accounts and reloads configurations without admin intervention — and does nothing (no restart) when nothing expired.
