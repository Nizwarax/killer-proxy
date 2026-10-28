#!/bin/bash
# proxy-rotate-warp: rotate WARP IPs (re-register + restart wireproxy).
# Usage: proxy-rotate-warp [all|N]   (default all)
set -u
DIR_BASE="/etc/wireproxy"

rotate_one(){
  local i=$1 retry=0
  local dir="$DIR_BASE/warp$1"
  local socks_port=$((40000 + i)) http_port=$((45000 + i))
  mkdir -p "$dir"; cd "$dir" || return 1
  rm -f wgcf-account.toml wgcf-profile.conf
  while [ $retry -lt 3 ]; do
    if wgcf register --accept-tos >/dev/null 2>&1 && wgcf generate >/dev/null 2>&1 && [ -s "$dir/wgcf-profile.conf" ]; then
      break
    fi
    retry=$((retry + 1)); sleep 2
  done
  [ -s "$dir/wgcf-profile.conf" ] || { echo "[ERR] WARP #$i registration failed"; return 1; }
  python3 - "$dir" "$socks_port" "$http_port" <<'PY'
import configparser, sys
d, sp, hp = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
cfg = configparser.ConfigParser(); cfg.read(f"{d}/wgcf-profile.conf")
priv = cfg['Interface']['PrivateKey']; addr = cfg['Interface']['Address']; pub = cfg['Peer']['PublicKey']
conf = f"""[Interface]
PrivateKey = {priv}
Address = {addr}
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = {pub}
Endpoint = 162.159.192.1:2408
KeepAlive = 25

[Socks5]
BindAddress = 127.0.0.1:{sp}

[Http]
BindAddress = 127.0.0.1:{hp}
"""
open(f"{d}/wireproxy.conf", "w").write(conf)
PY
  systemctl restart "wireproxy@warp$i"
  sleep 1
  echo "[OK] WARP #$i rotated (egress via wireproxy@warp$i)"
}

TARGET="${1:-all}"
if [ "$TARGET" = "all" ]; then
  INSTANCES=$(find "$DIR_BASE" -maxdepth 1 -type d -name 'warp*' 2>/dev/null | sort -V | sed 's|.*/warp||')
  [ -z "$INSTANCES" ] && INSTANCES="1 2 3 4"
  for idx in $INSTANCES; do rotate_one "$idx" & done
  wait
  echo "[DONE] all WARP rotated"
else
  rotate_one "$TARGET"
fi
