# LAN Speed's actions, validated by the CGI before they become a request file.
# A device's address is only ever an IPv4 or IPv6 address or a host name; every
# number has a range; a device's name (free text) travels base64url-encoded.
b64u() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
ok_host() {   # the same rule as the setup container's valid_host
  local h=$1 o c rest l parts
  (( ${#h} >= 1 && ${#h} <= 253 )) || return 1
  if [[ "$h" =~ ^[0-9.]+$ ]]; then
    [[ "$h" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done; return 0
  fi
  if [[ "$h" == *:* ]]; then
    [[ "$h" =~ ^[0-9A-Fa-f:]{2,39}$ && ! "$h" =~ [0-9A-Fa-f]{5} && "$h" != *:::* ]] || return 1
    c=${h//[^:]/}; (( ${#c} >= 2 && ${#c} <= 7 )) || return 1
    rest=${h/::/}; [[ "$rest" != *::* ]] || return 1
    [[ "$h" =~ ^:[^:] || "$h" =~ [^:]:$ ]] && return 1
    [[ "$h" == *::* ]] || (( ${#c} == 7 )) || return 1
    return 0
  fi
  [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*\.?$ ]] || return 1
  IFS=. read -ra parts <<< "${h%.}"; for l in "${parts[@]}"; do (( ${#l} <= 63 )) || return 1; done
}
ok_num() { [[ "$1" =~ ^(0|[1-9][0-9]{0,5})$ ]] && (( $1 >= $2 && $1 <= $3 )); }   # value min max
port_in_use() {   # port — something on this Synology listens on it (as the wizard sees it)
  local used
  if command -v netstat >/dev/null 2>&1; then used=$(netstat -lntu 2>/dev/null | awk 'NR > 2 {print $4}'); else used=$(ss -Hlntu 2>/dev/null | awk '{print $5}'); fi
  printf '%s\n' "$used" | sed 's/.*://' | grep -qx "$1"
}
test_lines() {   # body → the TEST_* lines of a test (run now, or on the schedule) in $TL, or error (not in a subshell: error replies and exits)
  local b=$1 host port proto dir secs streams rate
  host=$(decode "$(param host "$b")"); port=$(param port "$b"); proto=$(param proto "$b"); dir=$(param dir "$b")
  secs=$(param secs "$b"); streams=$(param streams "$b"); rate=$(param rate "$b")
  ok_host "$host" || error "400 Bad Request" "The address is an IP address (192.168.1.31, fe80::1) or a name (office-pc.lan) — nothing else."
  ok_num "$port" 1 65535 || error "400 Bad Request" "The port is a number from 1 to 65535 (iperf3's own is 5201)."
  [[ "$proto" =~ ^(tcp|udp)$ ]] || error "400 Bad Request" "Pick TCP or UDP."
  [[ "$dir" =~ ^(up|down|both)$ ]] || error "400 Bad Request" "Pick a direction."
  ok_num "$secs" 1 60 || error "400 Bad Request" "A test runs for 1 to 60 seconds."
  ok_num "$streams" 1 16 || error "400 Bad Request" "Parallel streams: 1 to 16."
  if [[ "$proto" == udp ]]; then ok_num "$rate" 1 10000 || error "400 Bad Request" "UDP sends at 1 to 10000 Mbit/s."; else rate=100; fi
  TL=$(printf "TEST_HOST='%s'\nTEST_PORT='%s'\nTEST_PROTO='%s'\nTEST_DIR='%s'\nTEST_SECS='%s'\nTEST_STREAMS='%s'\nTEST_RATE='%s'" "$host" "$port" "$proto" "$dir" "$secs" "$streams" "$rate")
}
app_cgi_post() {   # action body → sets $lines, or error
  local a=$1 body=$2 t host name port every thr alert keep
  case "$a" in
    runtest) test_lines "$body"; lines="ACTION='runtest'
$TL" ;;
    device)
      host=$(decode "$(param host "$body")"); name=$(decode "$(param name "$body")"); port=$(param port "$body")
      ok_host "$host" || error "400 Bad Request" "The address is an IP address or a name — nothing else."
      name=$(printf '%s' "$name" | tr -d '\000-\037\177'); [[ -n "${name// /}" && ${#name} -le 60 ]] || error "400 Bad Request" "Give the device a name, up to 60 characters."
      ok_num "${port:-5201}" 1 65535 || error "400 Bad Request" "The port is a number from 1 to 65535."
      lines="ACTION='device'
DEV_HOST='$host'
DEV_NAME_B64='$(b64u "$name")'
DEV_PORT='${port:-5201}'" ;;
    undevice)
      host=$(decode "$(param host "$body")")
      ok_host "$host" && jq -e --arg h "$host" 'any(.app.history.devices[]?; .host == $h)' "$VAR/status.json" >/dev/null 2>&1 || error "400 Bad Request" "Pick a device from the list."
      lines="ACTION='undevice'
DEV_HOST='$host'" ;;
    schedule)
      every=$(param every "$body"); thr=$(param threshold "$body"); alert=$(param alert "$body"); keep=$(param keep "$body")
      [[ "$every" =~ ^(off|15m|30m|1h|3h|6h|12h|24h)$ ]] || error "400 Bad Request" "Pick how often."
      ok_num "${thr:-0}" 0 100000 || error "400 Bad Request" "Slow is a whole number of Mbit/s, 0 to 100000 (0: never)."
      [[ "$alert" =~ ^[01]$ ]] || error "400 Bad Request" "DSM notifications are on or off."
      [[ "$keep" =~ ^(0|30|90|180|365|730)$ ]] || error "400 Bad Request" "Pick how long results are kept."
      if [[ "$every" == off && -z "$(param host "$body")" ]]; then t=""
      else test_lines "$body"; t=$TL; fi
      lines="ACTION='schedule'
SCHED_EVERY='$every'
THRESHOLD='${thr:-0}'
ON='$alert'
KEEP_DAYS='$keep'${t:+
$t}" ;;
    clearhist) lines="ACTION='clearhist'" ;;
  esac
}
app_cgi_settings() {   # body → appends IPERF_PORT to $lines, or errors
  local p cur; p=$(param iperf_port "$1"); [[ -z "$p" ]] && return 0
  ok_num "$p" 1024 65535 || error "400 Bad Request" "The iperf3 port is a number from 1024 to 65535."
  [[ "$p" != "$(param port "$1")" ]] || error "400 Bad Request" "The iperf3 port and the web port must differ."
  cur=$(jq -r '.app.iperf_port // empty' "$VAR/status.json" 2>/dev/null)
  [[ "$p" == "$cur" ]] || ! port_in_use "$p" || error "400 Bad Request" "Port $p is in use on this Synology — pick another (5202, for instance)."
  lines="$lines
IPERF_PORT='$p'"
}
app_cgi_get() {   # action query → replies, or returns for "unknown"
  case "$1" in
    historycsv)
      [[ -f "$VAR/history.csv" ]] || error "404 Not Found" "The history hasn't been written yet — it comes in a moment while the window is open."
      printf 'Status: 200 OK\r\nContent-Type: text/csv; charset=utf-8\r\nContent-Disposition: attachment; filename="lanspeed-history-%s.csv"\r\nCache-Control: no-store\r\n\r\n' "$(date +%Y%m%d)"
      cat "$VAR/history.csv"; exit 0 ;;
  esac
}
