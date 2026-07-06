#!/usr/bin/env bash
# OPTIONAL: create GUI-visible static DHCP reservations for the Talos nodes on an
# OPNsense box (dnsmasq) via its API. Each node becomes a host entry under
# Services → Dnsmasq DNS & DHCP → Hosts, then a reconfigure applies it live.
# Idempotent: matches an existing entry by MAC (or hostname+domain) and updates
# it instead of adding a duplicate.
#
# The domain is optional. Leave opnsense.domain blank for a DHCP reservation
# with no DNS host override; dnsmasq still registers the name under the DHCP
# range's domain when the node gets its lease.
#
# Verify mode (no changes): DHCP_VERIFY=1 ./bootstrap.sh dhcp
#   Compares each node's reservation and current lease so you can see why a node
#   isn't getting its reserved IP (MAC mismatch, stale lease, DNS-only entry…).
#
# Requirements on OPNsense: 25.1+ with dnsmasq as the DHCP server (a DHCP range
# on the nodes' subnet, and no other DHCP server active on that interface), plus
# an API key/secret whose user may access "Services: Dnsmasq DNS/DHCP".
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[[ "$(cfg '.opnsense.enabled')" == "true" ]] || { log "opnsense.enabled is not true - skipping DHCP reservations."; exit 0; }
require_cmd curl
require_cmd jq

base="$(cfg '.opnsense.baseURL')"; base="${base%/}"
key="$(cfg '.opnsense.apiKey')"
secret="$(cfg '.opnsense.apiSecret')"
verify="$(cfg '.opnsense.verifyTLS')"
domain="$(cfg '.opnsense.domain')"        # optional - blank means no host override
prefix="$(cfg '.opnsense.hostnamePrefix')"; prefix="${prefix:-talos}"
[[ -n "$base"   ]] || die "opnsense.baseURL not set"
[[ -n "$key"    ]] || die "opnsense.apiKey not set (System → Access → Users → API keys)"
[[ -n "$secret" ]] || die "opnsense.apiSecret not set"

API_BODY=""; API_CODE=""
api() {  # METHOD PATH [JSON]  -> echoes body; dies with the real status+body on non-2xx
  local method="$1" path="$2" data="${3:-}"
  local a=(-sS --connect-timeout 15 -u "${key}:${secret}" -X "$method" -w $'\n%{http_code}')
  [[ "$verify" == "true" ]] || a+=(-k)
  # Only send a JSON content-type when there's a body - OPNsense rejects a
  # Content-Type: application/json request with an empty body ("invalid json syntax").
  [[ -n "$data" ]] && a+=(-H 'Content-Type: application/json' --data-binary "$data")
  local out
  out="$(curl "${a[@]}" "${base}/api/${path}")" \
    || die "could not reach ${base} - check the URL/port and TLS (set opnsense.verifyTLS: false for a self-signed cert)"
  API_CODE="${out##*$'\n'}"; API_BODY="${out%$'\n'*}"
  if [[ "$API_CODE" != 2* ]]; then
    die "OPNsense API ${method} /api/${path} → HTTP ${API_CODE}
Response: ${API_BODY:-<empty>}
Likely: 401 bad key/secret · 403 the key's user can't access Services: Dnsmasq DNS/DHCP ·
400/404 endpoint missing (needs OPNsense 25.1+ with dnsmasq as the DHCP server)."
  fi
  printf '%s' "$API_BODY"
}

# hosts as a [{key,value}] list, tolerant of both serialisations (hosts as the
# array itself, or nested under .host).
hosts_map='(.dnsmasq.hosts.host? // .dnsmasq.hosts // {}) | (if type=="object" then to_entries else [] end)'
# match an item by MAC (primary, survives domain/name edits) or hostname+domain.
match='map(select((.value|type=="object") and ((((.value.hwaddr // "") | if type=="array" then join(",") else tostring end) | ascii_downcase) == ($mac|ascii_downcase) or (.value.host==$h and (.value.domain // "")==$d))))'

find_uuid() {  # name domain mac
  printf '%s' "$model" | jq -r --arg h "$1" --arg d "$2" --arg mac "$3" \
    "$hosts_map | $match | (.[0].key // empty)" | head -n1
}

label() { if [[ -n "$domain" ]]; then printf '%s.%s' "$1" "$domain"; else printf '%s' "$1"; fi; }

upsert() {  # name ip mac
  local name="$1" ip="$2" mac="$3" payload uuid resp
  payload="$(jq -nc --arg h "$name" --arg d "$domain" --arg ip "$ip" --arg mac "$mac" \
    '{host:{host:$h,domain:$d,ip:$ip,hwaddr:$mac,descr:"talos node (managed by bootstrap)"}}')"
  uuid="$(find_uuid "$name" "$domain" "$mac")"
  if [[ -n "$uuid" && "$uuid" != "null" ]]; then
    log "  update  $(label "$name") → ${ip} (${mac})"
    resp="$(api POST "dnsmasq/settings/set_host/${uuid}" "$payload")"
  else
    log "  add     $(label "$name") → ${ip} (${mac})"
    resp="$(api POST 'dnsmasq/settings/add_host' "$payload")"
  fi
  [[ "$(printf '%s' "$resp" | jq -r '.result // "failed"')" == "saved" ]] \
    || die "OPNsense rejected the host for ${name}: ${resp}"
}

check_one() {  # name ip mac  (verify mode)
  local name="$1" ip="$2" mac="$3" resv resv_ip resv_hw lrows lip
  resv="$(printf '%s' "$model" | jq -r --arg h "$name" --arg d "$domain" --arg mac "$mac" \
    "$hosts_map | $match | (.[0].value // {}) | (((.ip // \"\") | if type==\"array\" then join(\",\") else tostring end) + \"|\" + ((.hwaddr // \"\") | if type==\"array\" then join(\",\") else tostring end))")"
  resv_ip="${resv%%|*}"; resv_hw="${resv##*|}"
  if [[ -z "$resv" || "$resv" == "|" ]]; then
    warn "$(label "$name"): NO reservation found - create it by running the dhcp phase without DHCP_VERIFY"
  else
    log "$(label "$name"): reserved ip=${resv_ip:-?} mac=${resv_hw:-<none>}"
    [[ -z "$resv_hw" ]] && warn "  → reservation has NO MAC, so it is only a DNS host override, not a DHCP reservation"
    [[ -n "$resv_hw" && "${resv_hw,,}" != "${mac,,}" ]] && warn "  → reservation MAC (${resv_hw}) != config MAC (${mac})"
    [[ -n "$resv_ip" && "$resv_ip" != "$ip" ]] && warn "  → reserved IP (${resv_ip}) != config IP (${ip})"
  fi
  lrows="$(printf '%s' "$leases" | jq -c --arg m "$mac" '.rows[]? | select([..|strings] | any(ascii_downcase == ($m|ascii_downcase)))' 2>/dev/null || true)"
  if [[ -n "$lrows" ]]; then
    lip="$(printf '%s' "$lrows" | jq -r '([..|strings|select(test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$"))]|.[0]) // ""' 2>/dev/null | head -n1)"
    if [[ -n "$lip" && "$lip" != "$ip" ]]; then
      warn "  → ACTIVE LEASE is ${lip}, not the reserved ${ip} - stale dynamic lease; delete it on OPNsense and let the node renew"
    else
      log "  active lease: ${lip:-present} (matches)"
    fi
  else
    log "  no active lease for ${mac} yet - node not seen, or its real NIC MAC differs from ${mac}"
  fi
}

for_each_node() {  # callback name ip mac
  local cb="$1" role labelword sel i name line
  local -a lines
  for role in cp worker; do
    if [[ "$role" == cp ]]; then labelword=cp;     sel='.nodes.controlPlanes[]?'; mapfile -t lines < <(control_planes)
    else                        labelword=worker; sel='.nodes.workers[]?';       mapfile -t lines < <(workers); fi
    i=0
    for line in "${lines[@]}"; do
      [[ -z "$line" ]] && continue
      local ip host vmid mac
      IFS=';' read -r ip host vmid mac <<<"$line"
      i=$((i+1))
      if [[ -z "$mac" ]]; then warn "node $ip has no mac - skipping (a MAC is required for a reservation)"; continue; fi
      name="$(yq -r "$sel | select(.ip == \"$ip\") | .name // \"\"" "$CONFIG")"
      [[ -z "$name" ]] && name="${prefix}-${labelword}-${i}"
      "$cb" "$name" "$ip" "$mac"
    done
  done
}

log "Reading dnsmasq settings from ${base}"
model="$(api GET 'dnsmasq/settings/get')"

if [[ "${DHCP_VERIFY:-}" == "1" ]]; then
  log "Verify mode (no changes) - reservations vs. current leases"
  leases="$(api GET 'dnsmasq/leases/search' 2>/dev/null || echo '{"rows":[]}')"
  for_each_node check_one
  log "Fixes: MAC mismatch → set the node's mac: to the VM's real NIC MAC (Proxmox: qm config <vmid> | grep net0). Stale lease → delete it on OPNsense and reboot the node. No DHCP at all → make dnsmasq the DHCP server on that interface."
  exit 0
fi

for_each_node upsert
log "Applying (dnsmasq reconfigure)…"
api POST 'dnsmasq/service/reconfigure' '{}' >/dev/null
log "Done. Reservations are under Services → Dnsmasq DNS & DHCP → Hosts (or run DHCP_VERIFY=1 ./bootstrap.sh dhcp)."
