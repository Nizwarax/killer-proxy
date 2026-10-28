#!/usr/bin/env python3
"""
proxy-generate-xray: build /usr/local/etc/xray/config.json from vless_users.json.

FIXED vs wibuproxy:
  - VPS IP detected at RUNTIME (never hardcoded).
  - REALITY keypair read from /etc/xray/reality.json (fresh per install).
  - Dynamic WARP outbound count (not hardcoded 4).
  - xray run -test validation BEFORE applying.
  - Guard: if the generated config == existing file, do NOT rewrite/restart
    (this stops the cron from dropping every live connection every 10 min).
  - Traffic stats enabled (Xray API on 127.0.0.1:10085).
"""
import json, os, subprocess, sys
from datetime import datetime, timezone

XRAY_CFG  = "/usr/local/etc/xray/config.json"
VLESS_JSON = "/etc/xray/vless_users.json"
REALITY_JSON = "/etc/xray/reality.json"
OUT_FILE  = "/root/vless_accounts.txt"
XRAY_BIN  = "/usr/local/bin/xray"
SNI       = "www.speedtest.net"

def log(m): print(m)

def get_ip():
    for url in ("https://icanhazip.com", "https://api.ipify.org", "https://ifconfig.me/ip"):
        try:
            ip = subprocess.run(["curl", "-4", "-s", "--max-time", "4", url],
                                capture_output=True, text=True).stdout.strip()
            if ip and "." in ip:
                return ip
        except Exception:
            pass
    try:
        out = subprocess.run(["ip", "-4", "route", "get", "1.1.1.1"],
                             capture_output=True, text=True).stdout
        import re
        m = re.search(r"src\s+([\d.]+)", out)
        if m:
            return m.group(1)
    except Exception:
        pass
    return "0.0.0.0"

def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default

def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)
    try: os.chmod(path, 0o600)
    except Exception: pass

def warp_outbounds():
    """Return [(tag, local_port)] for each wireproxy instance: warp-N -> 40000+N."""
    ob = []
    base = "/etc/wireproxy"
    if os.path.isdir(base):
        for d in sorted(os.listdir(base)):
            if d.startswith("warp"):
                try:
                    n = int(d[4:])
                    ob.append((f"warp-{n}", 40000 + n))
                except ValueError:
                    pass
    return ob

def main():
    # --- fresh REALITY keys (per-install), never hardcoded ---
    if not os.path.exists(REALITY_JSON):
        log("[ERROR] /etc/xray/reality.json not found. Run install.sh first.")
        sys.exit(1)
    reality = load_json(REALITY_JSON, {})
    rpriv = reality.get("privateKey"); rpub = reality.get("publicKey")
    rsid  = reality.get("shortId")
    if not (rpriv and rpub and rsid):
        log("[ERROR] reality.json incomplete (privateKey/publicKey/shortId).")
        sys.exit(1)

    ip = get_ip()
    vless = load_json(VLESS_JSON, {"version": "1.0", "users": {}})
    users = vless.setdefault("users", {})

    # --- expiry: mark expired (persist only if changed) ---
    now = datetime.now(timezone.utc)
    changed = False
    for u, info in users.items():
        exp = info.get("expires_at")
        if exp and info.get("status") != "expired":
            try:
                if datetime.fromisoformat(exp.replace("Z", "+00:00")) <= now:
                    info["status"] = "expired"; changed = True
                    log(f"[EXPIRE] {u} expired")
            except Exception:
                pass
    if changed:
        save_json(VLESS_JSON, vless)

    active = {u: i for u, i in users.items() if i.get("status") == "active"}
    warps = warp_outbounds()
    warp_tags = [t for t, _ in warps]

    # --- build clients + routing rules ---
    clients, rules = [], []
    for u, info in sorted(active.items()):
        uuid = info.get("uuid")
        if not uuid:
            continue
        email = info.get("email", f"{u}@proxy")
        ob = info.get("outbound", "direct")
        if ob.startswith("warp") and ob not in warp_tags:
            ob = "direct"                      # missing warp -> safe fallback
        if ob not in warp_tags and ob != "direct":
            ob = "direct"
        clients.append({"id": uuid, "flow": "xtls-rprx-vision", "email": email})
        rules.append({"type": "field", "user": [email], "outboundTag": ob})

    outbounds = []
    for tag, port in warps:
        outbounds.append({"tag": tag, "protocol": "socks",
                          "settings": {"servers": [{"address": "127.0.0.1", "port": port}]}})
    outbounds.append({"tag": "direct", "protocol": "freedom"})
    outbounds.append({"tag": "block", "protocol": "blackhole"})

    xcfg = {
        "log": {"loglevel": "warning"},
        "api": {"tag": "api", "listen": "127.0.0.1", "port": 10085},
        "policy": {"system": {"statsInboundUplink": True, "statsInboundDownlink": True,
                              "statsOutboundUplink": True, "statsOutboundDownlink": True}},
        "inbounds": [{
            "port": 443, "protocol": "vless",
            "settings": {"clients": clients, "decryption": "none"},
            "streamSettings": {"network": "tcp", "security": "reality",
                "realitySettings": {"show": False, "dest": f"{SNI}:443", "xver": 0,
                    "serverNames": [SNI, "speedtest.net"],
                    "privateKey": rpriv, "shortIds": [rsid]}},
            "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}
        }],
        "outbounds": outbounds,
        "routing": {"domainStrategy": "IPIfNonMatch", "rules": rules}
    }
    new_cfg = json.dumps(xcfg, indent=2)

    # --- GUARD: identical config -> skip write & restart (no churn) ---
    if os.path.exists(XRAY_CFG):
        try:
            if open(XRAY_CFG).read().strip() == new_cfg.strip():
                log("[OK] xray config unchanged, skip restart")
                return 0
        except Exception:
            pass

    tmp = "/usr/local/etc/xray/.config.validate.json"
    with open(tmp, "w") as f:
        f.write(new_cfg)

    # --- validate before applying (ext .json: xray detects format by extension) ---
    if os.path.exists(XRAY_BIN):
        r = subprocess.run([XRAY_BIN, "run", "-test", "-config", tmp],
                           capture_output=True, text=True)
        if r.returncode != 0:
            log("[ERROR] xray config INVALID:")
            log(r.stderr.strip()[-600:])
            try: os.remove(tmp)
            except Exception: pass
            sys.exit(1)
    os.replace(tmp, XRAY_CFG)

    subprocess.run(["systemctl", "restart", "xray"], capture_output=True)

    # --- regenerate vless_accounts.txt ---
    lines = ["=" * 80, "             KILLER PROXY - VLESS REALITY ACCOUNTS", "=" * 80,
             f"Server IPv4 : {ip}", "Port        : 443", "Security    : REALITY (Vision)",
             f"SNI         : {SNI}", f"Public Key  : {rpub}", f"Short ID    : {rsid}",
             "=" * 80, ""]
    for u, info in sorted(users.items()):
        uuid, ob = info.get("uuid"), info.get("outbound", "?")
        st = info.get("status", "?")
        exp = info.get("expires_at", "Never")[:10]
        link = f"vless://{uuid}@{ip}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni={SNI}&fp=chrome&pbk={rpub}&sid={rsid}&type=tcp#PROXY-{u.upper()}"
        lines.append(f"User: {u} ({st.upper()} | exp {exp} | outbound {ob})")
        lines.append(f"Link: {link}\n")
    lines.append("=" * 80)
    with open(OUT_FILE, "w") as f:
        f.write("\n".join(lines) + "\n")
    log(f"[OK] xray config applied (validated), {len(active)} active VLESS user(s)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
