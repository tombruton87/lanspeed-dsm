# LAN Speed's hooks for the chassis core (sourced by run-core.sh). The core
# gives: say, phase, env_get/env_set, rand, compose, in_volume, cname, svc_up,
# notify, fresh, now, for_window, wait_ready, make_backup, record_backup,
# qr_png_b64, sync_dsm, MSG, BUSY, APPJ, VAR, APP, LOG, BUILD, PKG_NAME, PKG_TITLE.
#
# Two containers: iperf3's server on the host network (lanspeed-server, built
# here from Alpine's iperf3, setup/iperf3) and LibreSpeed, the browser test
# (lanspeed-web, a pinned ghcr.io release). The history is a SQLite database in
# the lanspeed_data volume, written only from here, through sqlite3 inside
# lanspeed-server: every iperf3 test the window or the schedule runs (iperf3 -c
# inside that container, so it's this Synology's own network card), every test
# another device runs against the server (its JSON report, left in an inbox),
# and every browser test (LibreSpeed's telemetry, read from its own database).
#
# Chassis gaps handled here: the core's image check only knows Docker Hub, and
# its update runs `docker image prune -f` for the whole host — this file
# defines its own check_image_update and update_app, which replace the core's
# (app.sh is sourced after them), and remove only the images they replaced.

SV=""; WB=""
LS_REPO=ghcr.io/librespeed/speedtest
LS_PINNED=$LS_REPO:6.3.0-alpine      # the LibreSpeed release this package was tested with
IP_IMAGE_NAME=lanspeed-iperf3:local
IP_SRC=/pkg/setup/iperf3
ALPINE_BRANCH=v3.24                  # setup/iperf3/Dockerfile's base, for the iperf3 update check
JQ=(jq -L /pkg/setup)

# ------------------------------------------------------------ what a value may be
valid_host() {   # an IPv4 or IPv6 address, or a host name — never anything iperf3 could read as an option
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
in_range() { [[ "$1" =~ ^(0|[1-9][0-9]{0,5})$ ]] && (( $1 >= $2 && $1 <= $3 )); }   # value min max
app_validate() {   # key value → 0 if the value has the key's shape
  case "$1" in
    IPERF_PORT)          in_range "$2" 1024 65535 ;;
    TEST_PORT|DEV_PORT)  in_range "$2" 1 65535 ;;
    TEST_HOST|DEV_HOST)  valid_host "$2" ;;
    TEST_PROTO)          [[ "$2" =~ ^(tcp|udp)$ ]] ;;
    TEST_DIR)            [[ "$2" =~ ^(up|down|both)$ ]] ;;
    TEST_SECS)           in_range "$2" 1 60 ;;
    TEST_STREAMS)        in_range "$2" 1 16 ;;
    TEST_RATE)           in_range "$2" 1 10000 ;;
    DEV_NAME_B64)        [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && (( ${#2} <= 200 )) ;;
    SCHED_EVERY)         [[ "$2" =~ ^(off|15m|30m|1h|3h|6h|12h|24h)$ ]] ;;
    THRESHOLD)           in_range "$2" 0 100000 ;;
    KEEP_DAYS)           [[ "$2" =~ ^(0|30|90|180|365|730)$ ]] ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------ small helpers
b64d() { local s=${1//-/+}; s=${s//_//}; while (( ${#s} % 4 )); do s="$s="; done; printf '%s' "$s" | base64 -d 2>/dev/null; }   # base64url → text
sqlq() { local v; v=$(printf '%s' "$1" | tr -d '\000-\037\177'); printf "'%s'" "${v//\'/\'\'}"; }   # text → a SQL string
newer() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]; }   # is version $1 newer than $2?
every_secs() { case "$1" in 15m) echo 900 ;; 30m) echo 1800 ;; 1h) echo 3600 ;; 3h) echo 10800 ;; 6h) echo 21600 ;; 12h) echo 43200 ;; 24h) echo 86400 ;; *) echo 0 ;; esac; }
every_words() { case "$1" in 15m) echo "every 15 minutes" ;; 30m) echo "every 30 minutes" ;; 1h) echo "every hour" ;; 3h) echo "every 3 hours" ;; 6h) echo "every 6 hours" ;; 12h) echo "twice a day" ;; 24h) echo "once a day" ;; *) echo "off" ;; esac; }
ls_tag() { local i=${1:-$(env_get LS_IMAGE)}; [[ "$i" =~ ^ghcr\.io/librespeed/speedtest:([0-9]+\.[0-9]+\.[0-9]+)-alpine$ ]] && echo "${BASH_REMATCH[1]}"; true; }
port_taken() {   # port — is something on this Synology listening on it (TCP or UDP)?
  ss -Hlntu 2>/dev/null | awk '{print $5}' | sed 's/.*://' | grep -qx "$1"
}

# ------------------------------------------------------------ the history database (in lanspeed_data, through lanspeed-server)
SCHEMA="PRAGMA journal_mode=DELETE;
CREATE TABLE IF NOT EXISTS tests (
  id INTEGER PRIMARY KEY, at INTEGER NOT NULL,
  source TEXT NOT NULL,               -- run (from the window) | schedule | server (another device against this one) | browser
  addr TEXT NOT NULL DEFAULT '',      -- the other device's address
  host TEXT NOT NULL DEFAULT '',      -- as it was asked for (run, schedule)
  proto TEXT NOT NULL DEFAULT '',     -- tcp | udp | http (browser)
  dir TEXT NOT NULL DEFAULT '',       -- to (Synology → device) | from (device → Synology) | both
  secs REAL, streams INTEGER,
  to_mbps REAL, from_mbps REAL, ping_ms REAL, jitter_ms REAL, loss_pct REAL, retrans INTEGER,
  ok INTEGER NOT NULL DEFAULT 1, error TEXT NOT NULL DEFAULT '', client TEXT NOT NULL DEFAULT '',
  ext TEXT UNIQUE);
CREATE INDEX IF NOT EXISTS tests_at ON tests (at);
CREATE TABLE IF NOT EXISTS devices (host TEXT PRIMARY KEY, name TEXT NOT NULL, port INTEGER NOT NULL DEFAULT 5201, addr TEXT NOT NULL DEFAULT '', added INTEGER);
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);"
sql() {   # SQL on stdin → sqlite3's output (inside lanspeed-server while it runs, else in a helper on the volume)
  if svc_up server; then docker exec -i "$SV" sqlite3 -bail -cmd '.timeout 5000' /data/history.db
  else in_volume data rw -- 'sqlite3 -bail -cmd ".timeout 5000" /vol/history.db'; fi
}
db_init() {
  [[ -f "$VAR/.db-ready" ]] && return 0
  svc_up server || return 1
  printf '%s\n' "$SCHEMA" | sql >/dev/null 2>>"$LOG" || { say "✗ the history database couldn't be set up — trying again shortly"; return 1; }
  touch "$VAR/.db-ready" "$VAR/.hist-dirty"
}
dirty() { touch "$VAR/.hist-dirty"; }

# What's new: the iperf3 server's reports and LibreSpeed's results → the history.
take_new() {
  local lines sqlf files n
  svc_up server && db_init || return 0
  lines=$(docker exec -i "$SV" sh -s < /pkg/setup/take.sh 2>/dev/null) || return 0
  [[ -n "$lines" ]] || return 0
  sqlf=$(mktemp)
  { echo "BEGIN;"
    "${JQ[@]}" -r 'include "lanspeed"; select(.iperf and .r != null) | .r | summary("server") | select(.ok) | test_sql("server"; "")' <<< "$lines" 2>>"$LOG"
    "${JQ[@]}" -r 'include "lanspeed"; select(.browser) | browser_sql' <<< "$lines" 2>>"$LOG"
    "${JQ[@]}" -r -s '[.[] | select(.browser) | .browser | numbers] | max // empty | "INSERT OR REPLACE INTO meta (k, v) VALUES (\u0027librespeed_last\u0027, \(.));"' <<< "$lines" 2>>"$LOG"
    echo "COMMIT;"; } > "$sqlf"
  if sql < "$sqlf" >/dev/null 2>>"$LOG"; then
    files=$(jq -r 'select(.iperf) | .iperf' <<< "$lines" 2>/dev/null | grep -E '^[0-9]+-[0-9]+\.json$')
    [[ -n "$files" ]] && docker exec "$SV" sh -c 'cd /data/inbox && rm -f "$@"' sh $files 2>>"$LOG"
    n=$(grep -c '^INSERT OR IGNORE' "$sqlf"); (( n )) && { dirty; say "history: $n new result(s) from other devices"; }
  else say "✗ new results couldn't be added to the history — trying again shortly"; fi
  rm -f "$sqlf"; true
}

# The window's view of the history: the latest 400 tests and the named devices (cached until something changes).
hist_json() {
  if [[ ! -f "$VAR/.hist-dirty" ]] && fresh "$VAR/.hist.json" 300; then cat "$VAR/.hist.json"; return 0; fi
  local out
  out=$(sql <<'SQL' 2>>"$LOG"
SELECT json_object(
  'rows', json(COALESCE((SELECT json_group_array(json_array(id, at, source, addr, host, proto, dir, to_mbps, from_mbps, ping_ms, jitter_ms, loss_pct, retrans, ok, error, client, secs, streams))
                         FROM (SELECT * FROM tests ORDER BY at DESC, id DESC LIMIT 400)), '[]')),
  'devices', json(COALESCE((SELECT json_group_array(json_object('host', host, 'name', name, 'port', port, 'addr', addr))
                            FROM (SELECT * FROM devices ORDER BY name COLLATE NOCASE)), '[]')),
  'total', (SELECT count(*) FROM tests), 'first', (SELECT min(at) FROM tests),
  'by', json_object('run', (SELECT count(*) FROM tests WHERE source = 'run'), 'schedule', (SELECT count(*) FROM tests WHERE source = 'schedule'),
                    'server', (SELECT count(*) FROM tests WHERE source = 'server'), 'browser', (SELECT count(*) FROM tests WHERE source = 'browser')));
SQL
  ) || true
  if jq -e '.rows' <<< "$out" >/dev/null 2>&1; then
    printf '%s' "$out" > "$VAR/.hist.json.tmp" && mv "$VAR/.hist.json.tmp" "$VAR/.hist.json"; rm -f "$VAR/.hist-dirty"; write_csv
    printf '%s' "$out"
  else cat "$VAR/.hist.json" 2>/dev/null || echo null; fi
}
write_csv() {   # every test, for the window's "Save as CSV"
  { sql <<'SQL'
.headers on
.mode csv
SELECT datetime(t.at, 'unixepoch') AS time_utc, t.source, COALESCE(d.name, '') AS device, t.addr AS address, t.host, t.proto AS protocol,
  t.to_mbps AS synology_to_device_mbps, t.from_mbps AS device_to_synology_mbps, t.ping_ms, t.jitter_ms, t.loss_pct, t.retrans AS retransmits,
  t.secs AS seconds, t.streams, CASE t.ok WHEN 1 THEN 'yes' ELSE 'no' END AS ok, t.error, t.client
FROM tests t LEFT JOIN devices d ON d.host = t.host OR (t.host = '' AND (d.host = t.addr OR d.addr = t.addr))
GROUP BY t.id ORDER BY t.at;
SQL
  } > "$VAR/history.csv.tmp" 2>>"$LOG" && for_window "$VAR/history.csv"
  true
}

# ------------------------------------------------------------ running a test from this Synology
friendly_error() {   # host port error → one sentence
  local h=$1 p=$2 e=$3
  case "$e" in
    *"Connection refused"*)                         echo "Nothing answered on $h port $p — start iperf3 there in server mode (iperf3 -s), or check the port." ;;
    *"resolve"*|*"not known"*|*"No address associated"*|*"Try again"*) echo "$h isn't a name this Synology can look up — try its IP address." ;;
    *"No route to host"*|*"Network is unreachable"*|*"Host is unreachable"*) echo "$h can't be reached from this Synology (no route) — is it on and on this network?" ;;
    *"timed out"*|*"Connection timed out"*|*"timeout"*) echo "$h didn't answer on port $p in time — is it on, and does its firewall let iperf3 in?" ;;
    *"busy"*)                                       echo "iperf3 on $h is busy with another test — try again in a moment." ;;
    *"killed"*|*"Killed"*)                          echo "The test to $h didn't finish and was stopped." ;;
    *)                                              echo "iperf3 said: ${e:0:200}" ;;
  esac
}
iperf_leg() {   # host port proto dir(up|down) secs streams rate → one summary (JSON line)
  local host=$1 port=$2 proto=$3 dir=$4 secs=$5 streams=$6 rate=$7 out args
  args=(-c "$host" -p "$port" -t "$secs" -P "$streams" -J --connect-timeout 5000)
  [[ "$proto" == udp ]] && args+=(-u -b "${rate}M")
  [[ "$dir" == down ]] && args+=(-R)
  out=$(docker exec "$SV" timeout -s KILL $(( secs + 30 )) iperf3 "${args[@]}" 2>&1)
  if jq -e 'type == "object" and has("start")' <<< "$out" >/dev/null 2>&1; then
    "${JQ[@]}" -c 'include "lanspeed"; summary("client")' <<< "$out"
  else   # iperf3 died before it could write its report (or the container went away)
    jq -cn --arg e "$(printf '%s' "${out:-killed}" | tr -d '\000-\037' | tail -c 300)" --arg p "$proto" --arg d "$([[ "$dir" == down ]] && echo from || echo to)" \
      '{at: now | floor, addr: "", proto: $p, dir: $d, to: null, from: null, error: $e, ok: false, cookie: ""}'
  fi
}
LEGS="[]"
run_test() {   # source host port proto dir secs streams rate → LEGS (summaries), the history, $VAR/lastrun.json; MSG; 0 if any leg worked
  local src=$1 host=$2 port=$3 proto=$4 dir=$5 secs=$6 streams=$7 rate=$8 d leg sqlf ok=1 name parts=() e
  LEGS="[]"
  svc_up server || { MSG="The iperf3 container (lanspeed-server) isn't running — see the log."; return 1; }
  db_init || true
  name=$(device_name "$host")
  for d in $([[ "$dir" == both ]] && echo "up down" || echo "$dir"); do
    say "iperf3 test to $host:$port, $proto, $([[ "$d" == up ]] && echo "Synology → device" || echo "device → Synology"), $secs s, $streams stream(s)$([[ "$proto" == udp ]] && echo " at $rate Mbit/s")"
    leg=$(iperf_leg "$host" "$port" "$proto" "$d" "$secs" "$streams" "$rate")
    jq -e '.' <<< "$leg" >/dev/null 2>&1 || leg='{"ok": false, "error": "no result"}'
    LEGS=$(jq -c --argjson l "$leg" '. + [$l]' <<< "$LEGS")
    if jq -e '.ok' <<< "$leg" >/dev/null; then ok=0; say "  $(jq -r '(if .to != null then "\(.to) Mbit/s Synology → device" else "\(.from) Mbit/s device → Synology" end) + (if .retrans != null then ", \(.retrans) retransmits" else "" end) + (if .jitter != null then ", jitter \(.jitter) ms, \(.loss)% lost" else "" end)' <<< "$leg")"
    else e=$(jq -r '.error // "no result"' <<< "$leg"); say "  ✗ $e"
      # A name that doesn't resolve shows up as an odd connect error under musl: ask DNS before blaming the device.
      if [[ "$host" =~ [A-Za-z] && "$host" != *:* && "$e" != *refused* ]] && ! docker exec "$SV" nslookup "$host" >/dev/null 2>&1; then e="cannot resolve $host"; fi
      parts+=("$(friendly_error "$host" "$port" "$e")"); fi
    [[ "$(jq -r '.error // ""' <<< "$leg")" =~ resolve|refused|unreachable|No\ route|timed\ out ]] && break   # the other direction won't do better
  done
  sqlf=$(mktemp)
  { echo "BEGIN;"; jq -c '.[]' <<< "$LEGS" | while read -r leg; do
      "${JQ[@]}" -r --arg src "$src" --arg host "$host" 'include "lanspeed"; .addr = (if .addr == "" then $host else .addr end) | test_sql($src; $host)' <<< "$leg"; done
    e=$(jq -r '[.[] | select(.ok and .addr != "") | .addr][0] // empty' <<< "$LEGS")
    [[ -n "$e" ]] && printf 'UPDATE devices SET addr = %s WHERE host = %s;\n' "$(sqlq "$e")" "$(sqlq "$host")"
    echo "COMMIT;"; } > "$sqlf"
  sql < "$sqlf" >/dev/null 2>>"$LOG" || say "✗ the result couldn't be added to the history"
  rm -f "$sqlf"; dirty
  jq -n -c --argjson at "$(now)" --arg src "$src" --arg host "$host" --arg name "$name" --argjson port "$port" --arg proto "$proto" --arg dir "$dir" \
     --argjson secs "$secs" --argjson streams "$streams" --argjson rate "$rate" --argjson legs "$LEGS" --arg msg "${parts[*]:-}" \
     '{at: $at, source: $src, host: $host, name: $name, port: $port, proto: $proto, dir: $dir, secs: $secs, streams: $streams, rate: $rate, legs: $legs, error: $msg}' \
     > "$VAR/lastrun.json.tmp" && mv "$VAR/lastrun.json.tmp" "$VAR/lastrun.json"
  if (( ok == 0 )); then
    MSG="${name:-$host}: $(jq -r '[.[] | select(.ok) | if .to != null then "\(.to) Mbit/s Synology → device" else "\(.from) Mbit/s device → Synology" end] | join(", ")' <<< "$LEGS").${parts[*]:+ ${parts[*]}}"
    return 0
  fi
  MSG=${parts[0]:-"The test to $host didn't work — see the log."}; return 1
}
device_name() { [[ -n "$1" ]] || return 0; printf 'SELECT name FROM devices WHERE host = %s LIMIT 1;\n' "$(sqlq "$1")" | sql 2>/dev/null | head -n 1 | tr -d '\000-\037' | cut -c1-60; true; }

# ------------------------------------------------------------ the schedule, and DSM notifications when it's slow
sched_tick() {
  local every gap last host
  every=$(env_get SCHED_EVERY); gap=$(every_secs "$every"); host=$(env_get SCHED_HOST)
  (( gap > 0 )) && [[ -n "$host" ]] && valid_host "$host" || return 0
  [[ -z "$BUSY" ]] || return 0
  last=$(tr -cd '0-9' 2>/dev/null < "$VAR/.sched-last"); last=${last:-0}
  (( $(now) - last >= gap )) || return 0
  now > "$VAR/.sched-last"
  BUSY="scheduled test"; write_status
  run_test schedule "$host" "$(env_get SCHED_PORT)" "$(env_get SCHED_PROTO)" "$(env_get SCHED_DIR)" "$(env_get SCHED_SECS)" "$(env_get SCHED_STREAMS)" "$(env_get SCHED_RATE)"
  local rc=$?
  say "scheduled test: $MSG"; MSG=""
  judge_scheduled "$rc" "$host"
  BUSY=""; write_status
}
judge_scheduled() {   # rc host — slow or failed → a DSM notification (on a change, then at most every 6 hours while it lasts)
  local rc=$1 host=$2 thr low state prev name
  thr=$(env_get THRESHOLD); thr=${thr:-0}; name=$(device_name "$host"); name=${name:-$host}
  low=$(jq -r '[.[] | select(.ok) | (.to // .from)] | min // empty' <<< "$LEGS")
  if (( rc != 0 )); then state=failed
  elif (( thr > 0 )) && [[ -n "$low" ]] && awk -v l="$low" -v t="$thr" 'BEGIN { exit !(l < t) }'; then state=slow
  else state=ok; fi
  prev=$(cat "$VAR/.sched-state" 2>/dev/null); echo "$state" > "$VAR/.sched-state"
  [[ "$state" == ok ]] && return 0
  say "scheduled test to $name: $([[ "$state" == slow ]] && echo "$low Mbit/s, below $thr Mbit/s" || echo "failed")"
  [[ "$(env_get ALERT)" == 1 ]] || return 0
  [[ "$state" != "$prev" ]] || ! fresh "$VAR/.sched-alerted" 21600 || return 0
  touch "$VAR/.sched-alerted"
  if [[ "$state" == slow ]]; then notify slow 0 "$name" "$low" "$thr"
  else notify testfailed 0 "$name" "$(jq -r '[.[] | .error // empty][0] // "no reason given"' <<< "$LEGS" | cut -c1-80)"; fi
}

# ------------------------------------------------------------ the iperf3 image, built here
ip_src_id() { cat "$IP_SRC/Dockerfile" "$IP_SRC/server.sh" | md5sum | cut -c1-12; }
ip_build() {   # [--fresh] — builds lanspeed-iperf3:local when it's missing or this package's recipe changed; --fresh: newest Alpine and iperf3
  local want have old new
  want=$(ip_src_id); have=$(docker image inspect -f '{{index .Config.Labels "lanspeed.src"}}' "$IP_IMAGE_NAME" 2>/dev/null)
  [[ "${1:-}" != --fresh && "$have" == "$want" ]] && return 0
  old=$(docker image inspect -f '{{.Id}}' "$IP_IMAGE_NAME" 2>/dev/null)
  phase "building the iperf3 image from Alpine's iperf3 (follow it in the log)"
  docker build $([[ "${1:-}" == --fresh ]] && echo "--pull --no-cache") --label "lanspeed.src=$want" -t "$IP_IMAGE_NAME" "$IP_SRC" 2>&1 | grep -vE '^\s*$' | tail -n 15 | tee -a "$LOG" >/dev/null
  new=$(docker image inspect -f '{{.Id}}' "$IP_IMAGE_NAME" 2>/dev/null)
  [[ -n "$new" ]] || { say "✗ the iperf3 image couldn't be built — the lines above say why"; return 1; }
  [[ -n "$old" && "$old" != "$new" ]] && echo "$old" > "$VAR/.ip-old"   # removed once nothing uses it (after the next start)
  rm -f "$VAR/.iperf-version"; return 0
}
ip_drop_old() {   # the image the last build replaced — by its id, nothing else
  local old; old=$(tr -cd 'a-z0-9:' 2>/dev/null < "$VAR/.ip-old") || true; [[ -n "$old" ]] || return 0
  docker image rm "$old" >> "$LOG" 2>&1 && say "removed the old iperf3 image" || true
  rm -f "$VAR/.ip-old"
}
iperf_version() {   # iperf3's version in the image (cached)
  [[ -s "$VAR/.iperf-version" ]] || docker exec "$SV" sh -c 'iperf3 --version | head -n 1; apk list -I iperf3 2>/dev/null | head -n 1' 2>/dev/null \
    | sed -n -e 's/^iperf \([0-9][0-9.]*\).*/v \1/p' -e 's/^iperf3-\([0-9][0-9a-z.-]*\) .*/apk \1/p' > "$VAR/.iperf-version"
  sed -n "s/^${1:-v} //p" "$VAR/.iperf-version" 2>/dev/null | head -n 1
}

# ------------------------------------------------------------ lifecycle hooks
app_first_env() {
  env_set IPERF_PORT "${IPERF_PORT:-5201}"
  env_set LS_IMAGE "$LS_PINNED"; env_set IP_IMAGE "$IP_IMAGE_NAME"
  env_set LS_STATS_PASSWORD "$(rand 32)"
  env_set SCHED_EVERY off; env_set SCHED_HOST ""; env_set SCHED_PORT 5201; env_set SCHED_PROTO tcp; env_set SCHED_DIR both
  env_set SCHED_SECS 10; env_set SCHED_STREAMS 1; env_set SCHED_RATE 100; env_set THRESHOLD 0; env_set ALERT 1; env_set KEEP_DAYS 365
}
app_load_env() {
  SV=$(cname server); WB=$(cname web)
  unset IPERF_PORT 2>/dev/null || true   # the wizard's answer is in .env now; a stale copy in the environment would win over it in compose
  [[ -n "$(env_get IP_IMAGE)" ]] || env_set IP_IMAGE "$IP_IMAGE_NAME"
  # A newer package brings a newer tested LibreSpeed: move the pin forward (never back), with a backup first.
  local cur pin; cur=$(ls_tag); pin=$(ls_tag "$LS_PINNED")
  if [[ -n "$cur" ]] && newer "$pin" "$cur"; then
    say "this package brings LibreSpeed $pin (installed: $cur) — a backup first"
    if make_backup pre-update; then record_backup true "$MADE"; echo "$(env_get LS_IMAGE)" > "$VAR/.ls-old"; env_set LS_IMAGE "$LS_PINNED"; say "LibreSpeed moves to $pin; the state from before is in $MADE"
    else say "✗ couldn't back up first, so LibreSpeed stays at $cur for now"; fi
  fi
  rm -f "$VAR/.db-ready"
  return 0
}
app_before_up() {
  local p; p=$(env_get IPERF_PORT)
  ip_build || return 1
  if port_taken "$p" && ! svc_up server; then say "✗ port $p is already in use on this Synology, so iperf3 can't listen there — pick another in the window: Site address → iperf3 port"; fi
  return 0
}
app_after_up() {
  local i; for i in $(seq 1 30); do svc_up server && break; sleep 1; done
  db_init || true
  ip_drop_old
  local old; old=$(tr -cd 'A-Za-z0-9._:/-' 2>/dev/null < "$VAR/.ls-old") || true; rm -f "$VAR/.ls-old"
  [[ -n "$old" && "$old" != "$(env_get LS_IMAGE)" ]] && { docker image rm "$old" >> "$LOG" 2>&1 && say "removed the old image $old" || true; }
  return 0
}
app_health() {
  svc_up server && [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$(env_get HTTP_PORT)/backend/empty.php" 2>/dev/null)" == 200 ]]
}
app_version() { printf '%s' "${BUILD%-*}" | tr -cd '0-9A-Za-z.-'; }

# ------------------------------------------------------------ what the window shows
app_status() {
  svc_up server || svc_up web || { echo '{"up": false}'; return 0; }
  local hist lerr url qr
  hist=$(hist_json); jq -e '.rows' <<< "$hist" >/dev/null 2>&1 || hist=null
  lerr=$(docker exec "$SV" cat /tmp/listen-error 2>/dev/null | tr -d '\000-\037' | head -c 300)
  url=$(env_get APP_URL)
  if [[ "$(head -n 1 "$VAR/qr.url" 2>/dev/null)" != "$url" || ! -s "$VAR/qr.b64" ]]; then qr_png_b64 "$url" > "$VAR/qr.b64.tmp" && mv "$VAR/qr.b64.tmp" "$VAR/qr.b64"; echo "$url" > "$VAR/qr.url"; fi
  qr=$(cat "$VAR/qr.b64" 2>/dev/null)
  jq -n -c --arg url "$url" --arg lan "$(env_get LAN_IP)" --arg iport "$(env_get IPERF_PORT)" --arg lerr "$lerr" --arg qr "$qr" \
     --arg iv "$(iperf_version v)" --arg lsv "$(ls_tag)" --arg lsimg "$(env_get LS_IMAGE)" \
     --argjson sv "$(svc_up server && echo true || echo false)" --argjson wb "$(svc_up web && echo true || echo false)" \
     --arg every "$(env_get SCHED_EVERY)" --arg shost "$(env_get SCHED_HOST)" --arg sport "$(env_get SCHED_PORT)" --arg sproto "$(env_get SCHED_PROTO)" \
     --arg sdir "$(env_get SCHED_DIR)" --arg ssecs "$(env_get SCHED_SECS)" --arg sstreams "$(env_get SCHED_STREAMS)" --arg srate "$(env_get SCHED_RATE)" \
     --arg thr "$(env_get THRESHOLD)" --arg alert "$(env_get ALERT)" --arg keep "$(env_get KEEP_DAYS)" \
     --arg slast "$(tr -cd '0-9' 2>/dev/null < "$VAR/.sched-last")" --arg sstate "$(cat "$VAR/.sched-state" 2>/dev/null)" \
     --argjson last "$(cat "$VAR/lastrun.json" 2>/dev/null || echo null)" --argjson hist "$hist" \
     '($every | if . == "off" or . == "" then 0 else ({"15m": 900, "30m": 1800, "1h": 3600, "3h": 10800, "6h": 21600, "12h": 43200, "24h": 86400}[.] // 0) end) as $gap
      | {up: true, url: $url, lan_ip: $lan, iperf_port: ($iport | tonumber? // 5201), qr: $qr,
         server: {up: $sv, version: $iv, error: $lerr}, web: {up: $wb, version: $lsv, image: $lsimg},
         schedule: {every: (if $every == "" then "off" else $every end), host: $shost, port: ($sport | tonumber? // 5201), proto: $sproto, dir: $sdir,
                    secs: ($ssecs | tonumber? // 10), streams: ($sstreams | tonumber? // 1), rate: ($srate | tonumber? // 100),
                    threshold: ($thr | tonumber? // 0), alert: ($alert == "1"), keep: ($keep | tonumber? // 365),
                    last: ($slast | tonumber? // null), next: (if $gap > 0 and ($slast | tonumber? // 0) > 0 then ($slast | tonumber) + $gap else null end), state: $sstate},
         lastrun: $last, history: $hist}'
}

# ------------------------------------------------------------ updates: LibreSpeed pinned to a release, iperf3 from Alpine
check_image_update() {   # replaces the core's (Docker Hub only): LibreSpeed's releases on GitHub + ghcr.io, and Alpine's iperf3 package
  local cur latest tok code ls_avail=false note="" arch idx apk_now apk_new ip_avail=false
  cur=$(ls_tag)
  latest=$(curl -sSI --max-time 15 https://github.com/librespeed/speedtest/releases/latest 2>/dev/null | tr -d '\r' | awk 'tolower($1) == "location:" {print $2}' | sed -n 's|.*/releases/tag/v\{0,1\}\([0-9][0-9.]*\)$|\1|p' | tail -n 1)
  [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || latest=$(curl -fsS --max-time 15 https://api.github.com/repos/librespeed/speedtest/releases/latest 2>/dev/null | jq -r '.tag_name // ""' 2>/dev/null | sed 's/^v//')
  if [[ -n "$cur" && "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && newer "$latest" "$cur"; then
    tok=$(curl -fsS --max-time 15 "https://ghcr.io/token?scope=repository:librespeed/speedtest:pull" 2>/dev/null | jq -r '.token // ""' 2>/dev/null)
    code=$(curl -s -o /dev/null -I -w '%{http_code}' --max-time 15 -H "Authorization: Bearer $tok" \
      -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json" \
      "https://ghcr.io/v2/librespeed/speedtest/manifests/$latest-alpine" 2>/dev/null)
    if [[ "$code" == 200 ]]; then ls_avail=true; else note="LibreSpeed $latest is out, but its image isn't on ghcr.io yet"; fi
  fi
  # iperf3: the package Alpine has now for this Synology's processor, against the one in the image.
  arch=$(uname -m); apk_now=$(iperf_version apk)
  idx=$(curl -fsS --max-time 30 "https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/main/$arch/APKINDEX.tar.gz" 2>/dev/null | tar -xzO APKINDEX 2>/dev/null)
  apk_new=$(awk '/^P:iperf3$/ {f = 1} f && /^V:/ {sub(/^V:/, ""); print; exit}' <<< "$idx" | tr -cd '0-9a-z.-')
  [[ -n "$apk_now" && -n "$apk_new" && "$apk_new" != "$apk_now" ]] && ip_avail=true
  if [[ -z "$latest" && -z "$apk_new" ]]; then
    IMAGE_UPDATE=$(jq -nc --argjson at "$(now)" '{checked: $at, error: "GitHub and Alpine could not be reached"}'); return 0; fi
  IMAGE_UPDATE=$(jq -nc --argjson at "$(now)" --arg img "$(env_get LS_IMAGE)" --arg cur "$cur" --arg latest "$latest" --argjson lsa "$ls_avail" --arg note "$note" \
      --arg ipv "$(iperf_version v)" --arg apk_now "$apk_now" --arg apk_new "$apk_new" --argjson ipa "$ip_avail" \
    '{checked: $at, image: $img, available: ($lsa or $ipa), remote: $latest, local: $cur,
      librespeed: {current: $cur, latest: $latest, available: $lsa, note: $note, page: (if $latest != "" then "https://github.com/librespeed/speedtest/releases/tag/v" + $latest else "" end)},
      iperf3: {version: $ipv, current: $apk_now, latest: $apk_new, available: $ipa}}')
  say "LibreSpeed: newest release ${latest:-?}, this is ${cur:-?}; iperf3: Alpine has ${apk_new:-?}, the image ${apk_now:-?}$([[ "$ls_avail" == true || "$ip_avail" == true ]] && echo " — an update is available")"
}
update_app() {   # replaces the core's (which prunes every unused image on the host): what check_image_update found, nothing from the request
  local latest img old_ls="" ls=false ip=false
  jq -e '.available == true' <<< "$IMAGE_UPDATE" >/dev/null 2>&1 || { MSG="There's nothing newer to install — look for updates first."; return 1; }
  jq -e '.librespeed.available == true' <<< "$IMAGE_UPDATE" >/dev/null 2>&1 && ls=true
  jq -e '.iperf3.available == true' <<< "$IMAGE_UPDATE" >/dev/null 2>&1 && ip=true
  latest=$(jq -r '.librespeed.latest // ""' <<< "$IMAGE_UPDATE"); img="$LS_REPO:$latest-alpine"
  if [[ "$ls" == true ]] && ! [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ls=false; fi
  say "updating $([[ "$ls" == true ]] && echo "LibreSpeed to $latest")$([[ "$ls" == true && "$ip" == true ]] && echo " and ")$([[ "$ip" == true ]] && echo "iperf3") — first, a backup"
  make_backup pre-update || { MSG="Couldn't back up first, so nothing was updated."; return 1; }
  record_backup true "$MADE"
  if [[ "$ls" == true ]]; then
    say "pulling $img"; docker pull "$img" 2>&1 | grep -vE '^\s*$' | tail -n 5 | tee -a "$LOG" >/dev/null
    docker image inspect "$img" >/dev/null 2>&1 || { MSG="LibreSpeed $latest couldn't be downloaded; nothing was changed."; return 1; }
    old_ls=$(env_get LS_IMAGE); env_set LS_IMAGE "$img"
  fi
  if [[ "$ip" == true ]]; then ip_build --fresh || { MSG="The iperf3 image couldn't be rebuilt — see the log. The state from before is in $MADE."; return 1; }; fi
  compose up -d --remove-orphans 2>&1 | tee -a "$LOG" >/dev/null || { MSG="The updated containers didn't start — see the log. The state from before is in $MADE."; return 1; }
  wait_ready 600 || { MSG="Updated, but LAN Speed hasn't answered yet — see the log. The state from before is in $MADE."; return 1; }
  [[ -n "$old_ls" && "$old_ls" != "$img" ]] && { docker image rm "$old_ls" >> "$LOG" 2>&1 && say "removed the old image $old_ls" || true; }
  ip_drop_old; rm -f "$VAR/.iperf-version"; check_image_update
  MSG="Updated: LibreSpeed $(ls_tag), iperf3 $(iperf_version v). The state from before is in $MADE."
}

# ------------------------------------------------------------ every tick
app_tick() {
  svc_up server || return 0
  db_init || return 0
  take_new
  sched_tick
  if ! fresh "$VAR/.pruned" 86400; then touch "$VAR/.pruned"; prune_history; fi
  return 0
}
prune_history() {
  local keep; keep=$(env_get KEEP_DAYS); [[ "$keep" =~ ^[0-9]+$ ]] && (( keep > 0 )) || return 0
  local n; n=$(printf "DELETE FROM tests WHERE at < CAST(strftime('%%s', 'now') AS INTEGER) - %d; SELECT changes();\n" $(( keep * 86400 )) | sql 2>>"$LOG" | tail -n 1)
  [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) && { dirty; say "history: $n result(s) older than $keep days removed"; }
  true
}

# ------------------------------------------------------------ settings, ports, logs, storage, backups, report
app_settings() {   # the iperf3 port, from Site address
  local p=${IPERF_PORT:-}
  unset IPERF_PORT   # .env is what counts: a refused port left in the environment would win over it in compose
  [[ -n "$p" && "$p" != "$(env_get IPERF_PORT)" ]] || return 1
  if [[ "$p" == "$(env_get HTTP_PORT)" ]]; then say "✗ the iperf3 port can't be the web port ($p) — left at $(env_get IPERF_PORT)"; return 1; fi
  if port_taken "$p"; then say "✗ port $p is in use on this Synology — the iperf3 port stays $(env_get IPERF_PORT)"; return 1; fi
  env_set IPERF_PORT "$p"; say "iperf3 moves to port $p"; return 0
}
app_after_settings() { sync_dsm; }
app_extra_ports() {   # iperf3, beside the web port, in DSM's firewall list
  printf '[%s_iperf3]\ntitle="%s: iperf3 server"\ndesc="%s"\nport_forward="no"\ndst.ports="%s/tcp,udp"\n' "$PKG_NAME" "$PKG_TITLE" "$PKG_TITLE" "$(env_get IPERF_PORT)"
}
app_storage() {
  local a b
  a=$(in_volume data ro -- 'printf "history\t%s\n" "$(du -cm /vol/history.db* 2>/dev/null | tail -n 1 | cut -f1)"; printf "waiting\t%s\n" "$(ls /vol/inbox 2>/dev/null | wc -l)"; true' </dev/null 2>/dev/null)
  b=$(in_volume librespeed ro -- 'printf "librespeed\t%s\n" "$(du -cm /vol/db.sql* 2>/dev/null | tail -n 1 | cut -f1)"; true' </dev/null 2>/dev/null)
  printf '%s\n%s\n' "$a" "$b" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber? // 0)}) | from_entries' 2>/dev/null || echo "{}"
}
app_backup() {   # dir — consistent copies of both databases (checked)
  in_volume data rw -- 'set -e; test -f /vol/history.db; sqlite3 -readonly /vol/history.db ".backup /tmp/h.db"; test "$(sqlite3 /tmp/h.db "pragma quick_check;")" = ok; gzip -c /tmp/h.db' \
    > "$1/history.sqlite.gz" 2>>"$LOG" </dev/null && gzip -t "$1/history.sqlite.gz" 2>/dev/null || { say "✗ the history database couldn't be copied"; return 1; }
  in_volume librespeed rw -- 'set -e; if test -s /vol/db.sql; then sqlite3 -readonly /vol/db.sql ".backup /tmp/l.db"; test "$(sqlite3 /tmp/l.db "pragma quick_check;")" = ok; gzip -c /tmp/l.db; fi' \
    > "$1/librespeed.sqlite.gz" 2>>"$LOG" </dev/null || { say "✗ LibreSpeed's database couldn't be copied"; return 1; }
  [[ -s "$1/librespeed.sqlite.gz" ]] || rm -f "$1/librespeed.sqlite.gz"   # no browser test yet
  return 0
}
app_restore() {   # dir — the core has stopped the containers
  [[ -s "$1/history.sqlite.gz" ]] && gzip -t "$1/history.sqlite.gz" 2>/dev/null || { MSG="That backup has no history database."; return 1; }
  in_volume data rw -- 'set -e; mkdir -p /vol/inbox; rm -f /vol/inbox/*.json /vol/history.db-journal; gzip -dc > /vol/history.db.new; mv /vol/history.db.new /vol/history.db' < "$1/history.sqlite.gz" 2>>"$LOG" \
    || { MSG="The history database didn't unpack."; return 1; }
  if [[ -s "$1/librespeed.sqlite.gz" ]]; then
    in_volume librespeed rw -- 'set -e; rm -f /vol/db.sql-journal; gzip -dc > /vol/db.sql.new; mv /vol/db.sql.new /vol/db.sql' < "$1/librespeed.sqlite.gz" 2>>"$LOG" || { MSG="LibreSpeed's database didn't unpack."; return 1; }
  else in_volume librespeed rw -- 'rm -f /vol/db.sql /vol/db.sql-journal' </dev/null 2>>"$LOG"; fi
  rm -f "$VAR/.hist.json" "$VAR/.db-ready" "$VAR/lastrun.json"; dirty
}
app_report() {
  local h; h=$(hist_json); jq -e '.rows' <<< "$h" >/dev/null 2>&1 || h='{}'
  echo "== history: $(jq -r '.total // "?"' <<< "$h") tests ($(jq -r '.by // {} | to_entries | map("\(.key) \(.value)") | join(", ")' <<< "$h")); $(jq -r '.devices | length' <<< "$h" 2>/dev/null) named devices; kept $(env_get KEEP_DAYS) days (0: for good)"
  echo "== iperf3: $(iperf_version v) (apk $(iperf_version apk)) on port $(env_get IPERF_PORT); listen error: $(docker exec "$SV" cat /tmp/listen-error 2>/dev/null || echo none); waiting reports: $(docker exec "$SV" sh -c 'ls /data/inbox | wc -l' 2>/dev/null)"
  echo "== LibreSpeed: $(env_get LS_IMAGE)"
  echo "== schedule: $(every_words "$(env_get SCHED_EVERY)") to $(env_get SCHED_HOST):$(env_get SCHED_PORT) $(env_get SCHED_PROTO) $(env_get SCHED_DIR) $(env_get SCHED_SECS) s x $(env_get SCHED_STREAMS); threshold $(env_get THRESHOLD) Mbit/s; DSM alerts $(env_get ALERT); last state $(cat "$VAR/.sched-state" 2>/dev/null)"
  echo; echo "== latest results"
  jq -r '.rows[:25][]? | "\(.[1] | todate)  \(.[2])  \(.[3])  \(.[5])  to \(.[7] // "-")  from \(.[8] // "-")  ping \(.[9] // "-")  \(if .[13] == 1 then "ok" else "failed: " + .[14] end)"' <<< "$h" 2>/dev/null
  :
}
app_wipe() {   # the image built here (and its Alpine base, unless something else uses it)
  docker image rm "$IP_IMAGE_NAME" >> "$LOG" 2>&1 || true
  docker image rm alpine:3.24 >> "$LOG" 2>&1 || true
}

# ------------------------------------------------------------ the window's actions
app_act() {   # action (request vars are set)
  local name n
  case "$1" in
    runtest)
      [[ -n "${TEST_HOST:-}" ]] || { MSG="Give the device's address."; return 1; }
      local secs=${TEST_SECS:-10} total
      [[ "${TEST_DIR:-up}" == both ]] && total=$(( (secs + 3) * 2 )) || total=$(( secs + 3 ))
      BUSY="testing ${TEST_HOST}"
      APPJ=$(jq -c --arg h "$TEST_HOST" --argjson until "$(( $(now) + total ))" --argjson from "$(now)" 'if type == "object" then . else {} end | .running = {host: $h, from: $from, until: $until}' <<< "$APPJ" 2>/dev/null || echo null)
      write_status
      run_test run "$TEST_HOST" "${TEST_PORT:-5201}" "${TEST_PROTO:-tcp}" "${TEST_DIR:-up}" "$secs" "${TEST_STREAMS:-1}" "${TEST_RATE:-100}" ;;
    device)
      [[ -n "${DEV_HOST:-}" ]] || { MSG="Give the device's address."; return 1; }
      name=$(b64d "${DEV_NAME_B64:-}" | tr -d '\000-\037\177' | cut -c1-60); [[ -n "$name" ]] || { MSG="Give the device a name."; return 1; }
      n=$(printf 'SELECT count(*) FROM devices WHERE host <> %s;\n' "$(sqlq "$DEV_HOST")" | sql 2>/dev/null | tr -cd '0-9')
      (( ${n:-0} < 100 )) || { MSG="That's 100 devices already — remove one first."; return 1; }
      printf "INSERT INTO devices (host, name, port, added) VALUES (%s, %s, %d, %d) ON CONFLICT (host) DO UPDATE SET name = excluded.name, port = excluded.port;\n" \
        "$(sqlq "$DEV_HOST")" "$(sqlq "$name")" "${DEV_PORT:-5201}" "$(now)" | sql >/dev/null 2>>"$LOG" || { MSG="The device couldn't be saved — see the log."; return 1; }
      dirty; MSG="Saved: $name ($DEV_HOST)." ;;
    undevice)
      [[ -n "${DEV_HOST:-}" ]] || { MSG="Pick a device."; return 1; }
      name=$(device_name "$DEV_HOST")
      printf 'DELETE FROM devices WHERE host = %s;\n' "$(sqlq "$DEV_HOST")" | sql >/dev/null 2>>"$LOG" || { MSG="The device couldn't be removed — see the log."; return 1; }
      dirty; MSG="${name:-$DEV_HOST} is no longer named; its results stay in the history under its address." ;;
    schedule)
      local every=${SCHED_EVERY:-off}
      if [[ "$every" != off && -z "${TEST_HOST:-}" ]]; then MSG="Pick the device to test."; return 1; fi
      env_set SCHED_EVERY "$every"; env_set SCHED_HOST "${TEST_HOST:-}"; env_set SCHED_PORT "${TEST_PORT:-5201}"; env_set SCHED_PROTO "${TEST_PROTO:-tcp}"
      env_set SCHED_DIR "${TEST_DIR:-both}"; env_set SCHED_SECS "${TEST_SECS:-10}"; env_set SCHED_STREAMS "${TEST_STREAMS:-1}"; env_set SCHED_RATE "${TEST_RATE:-100}"
      env_set THRESHOLD "${THRESHOLD:-0}"; env_set ALERT "${ON:-0}"; env_set KEEP_DAYS "${KEEP_DAYS:-365}"
      rm -f "$VAR/.sched-state" "$VAR/.sched-alerted" "$VAR/.pruned"
      local gap; gap=$(every_secs "$every")
      (( gap > 0 )) && echo $(( $(now) - gap + 60 )) > "$VAR/.sched-last"   # the first one in about a minute
      if [[ "$every" == off ]]; then MSG="No scheduled tests. Results are kept $([[ "${KEEP_DAYS:-365}" == 0 ]] && echo "for good" || echo "for ${KEEP_DAYS:-365} days")."
      else name=$(device_name "$TEST_HOST")
        MSG="A test to ${name:-$TEST_HOST} $(every_words "$every"), the first in about a minute$([[ "${THRESHOLD:-0}" != 0 ]] && echo "; below ${THRESHOLD} Mbit/s counts as slow$([[ "${ON:-0}" == 1 ]] && echo " and DSM is told")")."; fi ;;
    clearhist)
      printf 'DELETE FROM tests;\n' | sql >/dev/null 2>>"$LOG" || { MSG="The history couldn't be cleared — see the log."; return 1; }
      rm -f "$VAR/lastrun.json"; dirty; say "the history was cleared by ${BY:-?}"; MSG="The history is empty. Device names and the schedule stay." ;;
    *) MSG="Unknown request."; return 1 ;;
  esac
}
