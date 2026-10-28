#!/bin/bash
# =============================================================================
# detect-ipv6.sh - PROBE whether this VPS can actually use a sub-allocated
# IPv6 prefix (Tier-3 "unique IPv6 per user").
#
# It does NOT trust the mere presence of a global /64 (that is often a shared
# SLAAC prefix you cannot source from). It assigns a candidate /128 from the
# prefix, sends real traffic with it as the source, and only enables Tier-3 if
# the reply comes back WITH that exact address.
#
# Writes /etc/proxy/ipv6.json  ->  {"enabled":bool,"prefix":"...","iface":"..."}
# Exit code is always 0; the decision lives in the JSON.
# =============================================================================
set -u
OUT=/etc/proxy/ipv6.json
mkdir -p /etc/proxy

write(){ # enabled prefix iface
  printf '{\n  "enabled": %s,\n  "prefix": "%s",\n  "iface": "%s",\n  "probed_at": "%s"\n}\n' \
    "$1" "$2" "$3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OUT"
}

# 1) find an interface with a global IPv6 whose prefix length is <= 64
#    track the current interface from the "^N: iface:" header lines
IFACE=""; ADDR=""
while read -r line; do
  case "$line" in
    [0-9]*:*:*|*": "*:*)  # e.g. "2: eth0: <...>"  -> capture iface
      cur=$(echo "$line" | sed -n 's/^[0-9]*: \([^:]*\):.*/\1/p')
      [ -n "$cur" ] && IFACE="$cur"
      ;;
    inet6*global*)
      case "$line" in *fe80:*) continue;; esac
      A=$(echo "$line" | awk '{print $2}')
      P=$(echo "$A" | awk -F/ '{print $2}')
      if [ -n "${A:-}" ] && [ -n "${P:-}" ] && [ "${P:-99}" -le 64 ] 2>/dev/null; then
        ADDR=$(echo "$A" | cut -d/ -f1)
        break
      fi
      ;;
  esac
done < <(ip -6 addr show 2>/dev/null)

if [ -z "${IFACE:-}" ] || [ -z "${ADDR:-}" ]; then
  echo "[ipv6] tidak ada global IPv6 /64 -> Tier-3 DISABLED"
  write false "" ""
  exit 0
fi

# 2) derive the /64 prefix (first 4 hextets) from the interface address
PREFIX=$(awk -F: 'BEGIN{OFS=":"} {printf "%s:%s:%s:%s::\n", $1, $2, $3, $4}' <<<"$ADDR")

# 3) pick a probe address unlikely to collide (host bits near the top)
PROBE="${PREFIX}ff00"

# 4) real egress probe with the candidate address as source
enabled=false
ip -6 addr add "$PROBE/128" dev "$IFACE" 2>/dev/null && {
  sleep 1
  GOT=$(timeout 8 curl -6 -s --interface "$PROBE" \
          "https://api64.ipify.org?format=text" 2>/dev/null \
        | tr -d '[:space:]')
  ip -6 addr del "$PROBE/128" dev "$IFACE" 2>/dev/null
  if [ "$GOT" = "$PROBE" ]; then
    enabled=true
  fi
}

if $enabled; then
  echo "[ipv6] PROBE OK: prefix $PREFIX bisa di-subalokasi -> Tier-3 ENABLED"
  write true "$PREFIX" "$IFACE"
else
  echo "[ipv6] PROBE GAGAL: $PREFIX bukan prefix ter-routing (kemungkinan SLAAC bersama) -> Tier-3 DISABLED"
  write false "$PREFIX" "$IFACE"
fi
