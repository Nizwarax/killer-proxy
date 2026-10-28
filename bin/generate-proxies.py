#!/usr/bin/env python3
"""
proxy-generate-proxies: build /etc/3proxy/3proxy.cfg from users.json.

FIXED vs wibuproxy:
  - Per-user port + WARP instance allocation is idempotent & persisted.
  - Guard: if the generated config == existing file, do NOT rewrite/restart
    (stops the cron from dropping every live connection every 10 min).
  - VPS IP detected at runtime (fallback never hardcodes a stale IP).
  - Per-port egress via 3proxy `parent ... socks5 127.0.0.1 <wireproxy_port>`.
"""
import json, os, subprocess, sys
from datetime import datetime, timezone

CFG_FILE  = "/etc/3proxy/3proxy.cfg"
USERS_JSON = "/etc/3proxy/users.json"
CRED_FILE = "/etc/3proxy/credentials.txt"
OUT_LIST  = "/root/daftar_proxy.txt"

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
    # fallback: source address kernel akan pakai untuk keluar
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

def ipv6_tier():
    """Return (enabled, prefix, iface) from the install-time probe, or (False,"","")."""
    try:
        with open("/etc/proxy/ipv6.json") as f:
            d = json.load(f)
        if d.get("enabled") and d.get("prefix"):
            return True, d["prefix"], d.get("iface", "")
    except Exception:
        pass
    return False, "", ""

def ensure_v6_addr(addr, iface):
    """Assign the /128 on the interface if not already there (idempotent)."""
    if not iface:
        return
    try:
        r = subprocess.run(["ip", "-6", "addr", "show", "dev", iface],
                           capture_output=True, text=True).stdout
        if addr in r:
            return
        subprocess.run(["ip", "-6", "addr", "add", f"{addr}/128", "dev", iface],
                       capture_output=True)
    except Exception:
        pass

def warp_count():
    if os.path.isdir("/etc/wireproxy"):
        try:
            return len([d for d in os.listdir("/etc/wireproxy") if d.startswith("warp")])
        except Exception:
            pass
    return 4

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

def allocate(data, wcount):
    """Assign socks_port/http_port/warp_instance to any active user missing them."""
    users = data.setdefault("users", {})
    used_socks = {v.get("socks_port") for v in users.values() if v.get("socks_port")}
    # next warp for new users: cycle by count of existing warp users
    warp_users = sum(1 for v in users.values() if v.get("warp_instance"))
    changed = False
    for u, info in users.items():
        if info.get("status") != "active":
            continue
        if not info.get("socks_port"):
            p = 10002
            while p in used_socks:
                p += 1
            info["socks_port"] = p
            info["http_port"] = p + 1000
            used_socks.add(p)
            changed = True
        if not info.get("warp_instance"):
            info["warp_instance"] = ((warp_users) % wcount) + 1
            warp_users += 1
            changed = True
    if changed:
        save_json(USERS_JSON, data)
    return data

def main():
    if not os.path.exists(USERS_JSON):
        log("[ERROR] users.json not found. Run install.sh first.")
        sys.exit(1)
    data = load_json(USERS_JSON, {"version": "1.0", "mode": "multi-user", "users": {}})
    users = data.setdefault("users", {})
    wcount = warp_count()
    data = allocate(data, wcount)
    users = data["users"]
    active = {k: v for k, v in users.items() if v.get("status") == "active"}

    # admin/fallback creds
    admin_user, admin_pass = "admin", "adminpass"
    if os.path.exists(CRED_FILE):
        for line in open(CRED_FILE):
            line = line.strip()
            if line.startswith("USER="): admin_user = line.split("=", 1)[1]
            elif line.startswith("PASS="): admin_pass = line.split("=", 1)[1]

    ip = get_ip()
    L = ["# KILLER PROXY - auto-generated (do not edit)",
         "nserver 8.8.8.8", "nserver 1.1.1.1", "nscache 65536",
         "timeouts 1 5 30 60 180 1800 15 60", "maxconn 3000", ""]
    for u, info in active.items():
        L.append(f"users {u}:CL:{info.get('password','')}")
    if admin_user not in active:
        L.append(f"users {admin_user}:CL:{admin_pass}")
    L += ["", "auth strong", ""]

    # Tier 1: direct VPS IP (shared by admin + all active)
    L += ["# TIER 1: Direct VPS IPv4", "flush"]
    for u in active: L.append(f"allow {u}")
    L.append(f"allow {admin_user}")
    L += [f"socks -p10001 -e{ip}", f"proxy -p11001 -e{ip}", ""]

    # Tier 2: per-user WARP egress
    L.append("# TIER 2: Dedicated WARP outbounds (1 user = 1 IP)")
    for u, info in sorted(active.items(), key=lambda x: x[1].get("socks_port", 10000)):
        wn = info.get("warp_instance", 1)
        local_p = 40000 + wn
        sp = info.get("socks_port", 10002); hp = info.get("http_port", sp + 1000)
        L += [f"# {u} -> WARP #{wn}", "flush", f"allow {u}", "maxconn 500",
              f"parent 1000 socks5 127.0.0.1 {local_p}",
              f"socks -p{sp}", f"proxy -p{hp}", ""]

    if not active:
        for i in range(1, wcount + 1):
            L += [f"# default WARP #{i}", "flush", f"allow {admin_user}",
                  f"parent 1000 socks5 127.0.0.1 {40000 + i}",
                  f"socks -p{10001 + i}", f"proxy -p{11001 + i}", ""]

    # Tier 3: unique IPv6 per user (HANYA jika probe membuktikan prefix ter-routing)
    v6_on, v6_prefix, v6_iface = ipv6_tier()
    v6_lines = []   # also collected for the list file
    if v6_on:
        L += ["# TIER 3: Unique IPv6 egress (1 user = 1 source IPv6)", ""]
        v6_idx = 1
        # admin first (::1), then each active user
        for name in [admin_user] + list(active.keys()):
            addr = v6_prefix + format(v6_idx, "x")       # ::1, ::2, ::3 ...
            ensure_v6_addr(addr, v6_iface)
            sp6 = 20000 + v6_idx; hp6 = 21000 + v6_idx
            L += [f"# {name} -> {addr}", "flush", f"allow {name}", "maxconn 500",
                  f"socks -p{sp6} -i{addr} -De{v6_iface}",
                  f"proxy -p{hp6} -i{addr} -De{v6_iface}", ""]
            v6_lines.append((name, addr, sp6, hp6))
            v6_idx += 1

    new_cfg = "\n".join(L) + "\n"

    # --- GUARD: identical config -> skip write & restart ---
    if os.path.exists(CFG_FILE):
        try:
            if open(CFG_FILE).read().strip() == new_cfg.strip():
                log("[OK] 3proxy config unchanged, skip restart")
                sys.exit(0)
        except Exception:
            pass
    with open(CFG_FILE, "w") as f:
        f.write(new_cfg)
    os.chmod(CFG_FILE, 0o600)
    subprocess.run(["systemctl", "restart", "3proxy"], capture_output=True)

    # --- regenerate daftar_proxy.txt ---
    out = ["=" * 78, "              KILLER PROXY - MULTI-USER PROXY LIST", "=" * 78,
           f"Server IPv4 : {ip}", f"Active Users: {len(active)}/{len(users)}",
           "Format      : IP:PORT:USERNAME:PASSWORD", "=" * 78, "",
           f"[TIER 1] DIRECT - {ip}:10001 (SOCKS5) / {ip}:11001 (HTTP) - user:{admin_user} pass:{admin_pass}", ""]
    if v6_on and v6_lines:
        out.append("[TIER 3] IPv6 direct (1 user = 1 source IPv6):")
        for name, addr, sp6, hp6 in v6_lines:
            pw = admin_pass if name == admin_user else (active.get(name, {}).get("password", ""))
            out.append(f"  SOCKS5: [{addr}]:{sp6}:{name}:{pw}")
            out.append(f"  HTTP:   [{addr}]:{hp6}:{name}:{pw}")
        out.append("")
    for u, info in sorted(active.items(), key=lambda x: x[1].get("socks_port", 10000)):
        exp = info.get("expires_at", "")[:10]
        out += [f"User: {u} (exp {exp} | {info.get('duration_days',0)}d | WARP #{info.get('warp_instance',1)})",
                f"  SOCKS5: {ip}:{info.get('socks_port')}:{u}:{info.get('password')}",
                f"  HTTP:   {ip}:{info.get('http_port')}:{u}:{info.get('password')}", ""]
    out.append("=" * 78)
    with open(OUT_LIST, "w") as f:
        f.write("\n".join(out) + "\n")
    os.chmod(OUT_LIST, 0o600)
    log(f"[OK] 3proxy config applied, {len(active)} active user(s), {wcount} WARP instance(s)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
