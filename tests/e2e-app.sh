# LAN Speed's steps for the chassis harness (chassis/tests/e2e.sh <appdir> act).
# Real iperf3 tests from the package to a throwaway iperf3 container (TCP, UDP,
# reverse, both), tests from a client container against the package's own
# server, a browser test driven with curl through LibreSpeed's own endpoints,
# the schedule with a threshold nothing meets, refused hosts and options, the
# iperf3 port moved and back, backup and restore of the history, and an update.
IPORT=${E2E_IPERF_PORT:-5201}; IPORT2=${E2E_IPERF_PORT2:-5202}
PEER=lanspeed-e2e-peer; IMG=lanspeed-iperf3:local
app_e2e_answers() { printf "IPERF_PORT='%s'\n" "$IPORT"; }
wait_for() { local i; for i in $(seq 1 "$2"); do touch "$VAR/watching"; jq -e "$1" "$VAR/status.json" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
b64u() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
hist() { jq -c "[.app.history.rows[] | {src: .[2], addr: .[3], proto: .[5], dir: .[6], to: .[7], from: .[8], ping: .[9], jitter: .[10], loss: .[11], retrans: .[12], ok: .[13], error: .[14], client: .[15]}] | $1" "$VAR/status.json"; }
ignored() { grep -c "ignoring a request that wasn't in order" "$VAR/package.log"; }
hostile() {   # request lines… → 0 when the setup container refused the file
  local n0; n0=$(ignored); printf '%s\n' "$@" "BY='e2e'" > "$VAR/request"
  for i in $(seq 1 30); do touch "$VAR/watching"; [[ ! -f "$VAR/request" ]] && break; sleep 2; done
  (( $(ignored) > n0 ))
}
client() { docker run --rm --network bridge "$IMG" iperf3 -c "$GW" -p "${CPORT:-$IPORT}" -t 2 "$@" >/dev/null 2>&1; }
telemetry() {   # a browser test, done the way LibreSpeed's page does it: download, upload, ping, then its result to telemetry.php
  local url=$1 ua=$2 d u p dl ul pings ping jitter
  read -r d dt < <(curl -s -o /dev/null -w '%{size_download} %{time_total}\n' "$url/backend/garbage.php?ckSize=25")
  read -r u ut < <(head -c 20000000 /dev/zero | curl -s -o /dev/null -w '%{size_upload} %{time_total}\n' -H 'Content-Type: application/octet-stream' --data-binary @- "$url/backend/empty.php")
  pings=$(for i in 1 2 3 4 5 6; do curl -s -o /dev/null -w '%{time_total}\n' "$url/backend/empty.php?r=$i"; done)
  dl=$(awk -v b="$d" -v t="$dt" 'BEGIN { printf "%.2f", b * 8 / t / 1000000 }'); ul=$(awk -v b="$u" -v t="$ut" 'BEGIN { printf "%.2f", b * 8 / t / 1000000 }')
  ping=$(awk '{ v = $1 * 1000; s += v; if (NR > 1) { d = v - p; j += (d < 0 ? -d : d) } p = v } END { printf "%.2f", s / NR }' <<< "$pings")
  jitter=$(awk '{ v = $1 * 1000; if (NR > 1) { d = v - p; j += (d < 0 ? -d : d) } p = v } END { printf "%.2f", j / (NR - 1) }' <<< "$pings")
  curl -s -A "$ua" "$url/backend/getIP.php" >/dev/null
  curl -s -A "$ua" --data-urlencode "ispinfo={\"processedString\":\"private IPv4 access\"}" --data-urlencode "extra=" --data-urlencode "dl=$dl" --data-urlencode "ul=$ul" \
       --data-urlencode "ping=$ping" --data-urlencode "jitter=$jitter" --data-urlencode "log=" "$url/results/telemetry.php"
  echo " (dl $dl, ul $ul, ping $ping, jitter $jitter)"
}
app_e2e_act() {
  local fail=0 url="http://127.0.0.1:$PORT" pip got n b2 total i
  log "lanspeed"
  wait_for '.app.server.up and .app.web.up and (.app.history.rows | type == "array")' 90 && echo "  ok   iperf3 $(jq -r .app.server.version "$VAR/status.json") and LibreSpeed $(jq -r .app.web.version "$VAR/status.json") are up; the history is ready" \
    || { echo "  FAIL status: $(jq -c '.app | del(.qr)' "$VAR/status.json" | head -c 400)"; fail=1; }
  [[ "$(curl -s "$url/index-classic.html" | grep -c '<title>LAN Speed</title>')" -ge 1 ]] && echo "  ok   the browser test answers on $PORT, titled LAN Speed" || { echo "  FAIL web page"; fail=1; }
  jq -e '.app.qr | length > 100' "$VAR/status.json" >/dev/null && echo "  ok   a QR code of $(jq -r .app.url "$VAR/status.json") for phones" || { echo "  FAIL qr"; fail=1; }
  [[ "$(curl -s "$url/settings.json" | jq -r .telemetry_level)" == basic ]] && echo "  ok   LibreSpeed keeps results (telemetry basic, SQLite)" || { echo "  FAIL telemetry setting"; fail=1; }
  curl -s "$url/results/stats.php" | grep -qi 'password' && ! curl -s -d 'op=login&password=password' "$url/results/stats.php" | grep -qi 'logout' \
    && echo "  ok   LibreSpeed's own results page is locked, and not with its default password" || { echo "  FAIL stats page"; fail=1; }
  ss -Hlnt | awk '{print $4}' | grep -qE ":$IPORT\$" \
    && echo "  ok   iperf3 listens on $IPORT on the host's network (UDP opens per test; the UDP tests below go through it)" || { echo "  FAIL not listening on $IPORT: $(ss -Hlnt | grep ":$IPORT" | head -2)"; fail=1; }
  [[ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' lanspeed-server)" == host ]] && echo "  ok   lanspeed-server runs on the host network" || { echo "  FAIL network mode"; fail=1; }

  # A device to test: a throwaway iperf3 server on Docker's bridge.
  docker rm -f "$PEER" >/dev/null 2>&1; docker run -d --name "$PEER" --network bridge "$IMG" iperf3 -s -p 5201 >/dev/null
  sleep 2; pip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$PEER"); GW=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')
  echo "  (peer $pip, this host on the bridge $GW)"
  request "ACTION='device'" "DEV_HOST='$pip'" "DEV_NAME_B64='$(b64u 'Test "peer" & co')'" "DEV_PORT='5201'" || fail=1
  wait_for ".app.history.devices | any(.host == \"$pip\" and .name == \"Test \\\"peer\\\" & co\")" 30 && echo "  ok   the device is saved with its name intact" || { echo "  FAIL devices: $(jq -c .app.history.devices "$VAR/status.json")"; fail=1; }
  # TCP, Synology → device, 2 streams.
  request "ACTION='runtest'" "TEST_HOST='$pip'" "TEST_PORT='5201'" "TEST_PROTO='tcp'" "TEST_DIR='up'" "TEST_SECS='3'" "TEST_STREAMS='2'" "TEST_RATE='100'" || fail=1
  jq -e '.app.lastrun | .source == "run" and (.legs | length == 1) and (.legs[0] | .ok and .to > 0 and .from == null and (.retrans | type == "number") and .addr != "")' "$VAR/status.json" >/dev/null \
    && echo "  ok   TCP upload: $(jq -r '.app.lastrun.legs[0] | "\(.to) Mbit/s Synology → device, \(.retrans) retransmits, \(.streams) streams"' "$VAR/status.json")" || { echo "  FAIL tcp up: $(jq -c .app.lastrun "$VAR/status.json")"; fail=1; }
  # TCP, device → Synology (-R).
  request "ACTION='runtest'" "TEST_HOST='$pip'" "TEST_PORT='5201'" "TEST_PROTO='tcp'" "TEST_DIR='down'" "TEST_SECS='3'" "TEST_STREAMS='1'" "TEST_RATE='100'" || fail=1
  jq -e '.app.lastrun.legs[0] | .ok and .from > 0 and .to == null' "$VAR/status.json" >/dev/null \
    && echo "  ok   TCP download (-R): $(jq -r '.app.lastrun.legs[0] | "\(.from) Mbit/s device → Synology, \(.retrans) retransmits"' "$VAR/status.json")" || { echo "  FAIL tcp down: $(jq -c .app.lastrun "$VAR/status.json")"; fail=1; }
  # UDP, both directions, at 50 Mbit/s.
  request "ACTION='runtest'" "TEST_HOST='$pip'" "TEST_PORT='5201'" "TEST_PROTO='udp'" "TEST_DIR='both'" "TEST_SECS='3'" "TEST_STREAMS='1'" "TEST_RATE='50'" || fail=1
  jq -e '.app.lastrun.legs | length == 2 and (.[0] | .ok and .to > 30 and (.jitter | type == "number") and (.loss | type == "number")) and (.[1] | .ok and .from > 30 and (.jitter | type == "number"))' "$VAR/status.json" >/dev/null \
    && echo "  ok   UDP both ways at 50 Mbit/s: $(jq -r '.app.lastrun.legs | map("\(.to // .from) Mbit/s, jitter \(.jitter) ms, \(.loss)% lost") | join(" / ")' "$VAR/status.json")" || { echo "  FAIL udp: $(jq -c .app.lastrun.legs "$VAR/status.json")"; fail=1; }
  wait_for '[.app.history.rows[] | select(.[2] == "run")] | length == 4' 30 && hist "map(select(.src == \"run\")) | all(.addr != \"\")" | grep -q true \
    && echo "  ok   all four in History as Run here: $(hist 'map(select(.src == "run")) | map("\(.proto) \(.dir) \(.to // .from)") | join(", ")')" || { echo "  FAIL run rows: $(hist 'map(select(.src == "run"))')"; fail=1; }
  # Tests that can't work: refused, with a sentence.
  request "ACTION='runtest'" "TEST_HOST='$pip'" "TEST_PORT='5999'" "TEST_PROTO='tcp'" "TEST_DIR='both'" "TEST_SECS='2'" "TEST_STREAMS='1'" "TEST_RATE='100'" >/dev/null && { echo "  FAIL a closed port passed"; fail=1; } \
    || { jq -r .last.message "$VAR/status.json" | grep -q "Nothing answered on $pip port 5999" && echo "  ok   a closed port: $(jq -r .last.message "$VAR/status.json")" || { echo "  FAIL closed port message: $(jq -r .last.message "$VAR/status.json")"; fail=1; }; }
  request "ACTION='runtest'" "TEST_HOST='no-such-host.invalid'" "TEST_PORT='5201'" "TEST_PROTO='tcp'" "TEST_DIR='up'" "TEST_SECS='2'" "TEST_STREAMS='1'" "TEST_RATE='100'" >/dev/null && { echo "  FAIL an unknown name passed"; fail=1; } \
    || { jq -r .last.message "$VAR/status.json" | grep -q "isn't a name" && echo "  ok   an unknown name: $(jq -r .last.message "$VAR/status.json")" || { echo "  FAIL unknown name message: $(jq -r .last.message "$VAR/status.json")"; fail=1; }; }
  # Hostile request files: refused whole by the setup container.
  for bad in "TEST_HOST='-R'" "TEST_HOST='--help'" "TEST_HOST='a;id'" "TEST_HOST='\$(id)'" "TEST_HOST='1.2.3.999'" "TEST_SECS='99'" "TEST_STREAMS='0'" "TEST_PROTO='sctp'" "TEST_RATE='99999'" "TEST_PORT='70000'"; do
    hostile "ACTION='runtest'" "TEST_HOST='10.0.0.1'" "$bad" && echo "  ok   refused: $bad" || { echo "  FAIL accepted: $bad"; fail=1; }; done
  hostile "ACTION='device'" "DEV_HOST='10.0.0.9'" "DEV_NAME_B64='a b'" && echo "  ok   refused: a name that isn't base64url" || { echo "  FAIL device name"; fail=1; }

  # Other devices testing against this Synology's iperf3 server.
  client && client -R && client -u -b 20M && client --bidir || { echo "  FAIL a client couldn't test against $GW:$IPORT"; fail=1; }
  wait_for '[.app.history.rows[] | select(.[2] == "server")] | length == 4' 120 \
    && echo "  ok   four tests from a client container, logged from the server's side: $(hist 'map(select(.src == "server")) | map("\(.proto) \(.dir) to \(.to) from \(.from)") | join("; ")')" \
    || { echo "  FAIL server rows: $(hist 'map(select(.src == "server"))')"; fail=1; }
  hist 'map(select(.src == "server")) | (.[0].addr | test("^[0-9.]+$")) and (map(select(.dir == "both")) | length == 1 and .[0].to > 0 and .[0].from > 0) and (map(select(.proto == "udp")) | .[0].jitter != null)' | grep -q true \
    && echo "  ok   …with the client's address, both directions of --bidir, and UDP's jitter" || { echo "  FAIL server row detail"; fail=1; }
  [[ "$(docker exec lanspeed-server sh -c 'ls /data/inbox | wc -l')" == 0 ]] && echo "  ok   the server's reports were taken from its inbox" || { echo "  FAIL inbox not empty"; fail=1; }

  # A browser test, as LibreSpeed's page does it.
  echo -n "  (browser test with curl"; telemetry "$url" "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1" | tr -d '\n'; echo ")"
  wait_for '[.app.history.rows[] | select(.[2] == "browser")] | length == 1' 90 && hist 'map(select(.src == "browser"))[0] | .to > 0 and .from > 0 and .ping != null and .jitter != null and .client == "iPhone · Safari" and .addr != ""' | grep -q true \
    && echo "  ok   the browser test is in History: $(hist 'map(select(.src == "browser"))[0] | "\(.to) down, \(.from) up, ping \(.ping) ms, jitter \(.jitter) ms, \(.client) at \(.addr)"')" \
    || { echo "  FAIL browser row: $(hist 'map(select(.src == "browser"))')"; fail=1; }

  # The schedule: every 15 minutes to the peer, slow below a speed nothing reaches, DSM told.
  request "ACTION='schedule'" "SCHED_EVERY='15m'" "TEST_HOST='$pip'" "TEST_PORT='5201'" "TEST_PROTO='tcp'" "TEST_DIR='both'" "TEST_SECS='2'" "TEST_STREAMS='1'" "TEST_RATE='100'" "THRESHOLD='100000'" "ON='1'" "KEEP_DAYS='365'" || fail=1
  wait_for '.app.schedule | .every == "15m" and .threshold == 100000 and .alert and .next != null' 20 && echo "  ok   saved: $(jq -r .last.message "$VAR/status.json")" || { echo "  FAIL schedule saved: $(jq -c .app.schedule "$VAR/status.json")"; fail=1; }
  wait_for '[.app.history.rows[] | select(.[2] == "schedule")] | length == 2' 180 && wait_for '.app.schedule.state == "slow"' 30 \
    && echo "  ok   the scheduled test ran on its own: $(hist 'map(select(.src == "schedule")) | map("\(.to // .from)") | join(" / ")') Mbit/s, below 100000: slow" || { echo "  FAIL scheduled: $(hist 'map(select(.src == "schedule"))') $(jq -c .app.schedule "$VAR/status.json")"; fail=1; }
  for i in $(seq 1 30); do grep -qE "told DSM: slow|notification \(slow\)" "$VAR/package.log" && break; sleep 1; done
  grep -qE "told DSM: slow|a DSM notification \(slow\)" "$VAR/package.log" && echo "  ok   it went to DSM's notifications (no DSM here, so only attempted)" || { echo "  FAIL no DSM notification attempt"; fail=1; }
  request "ACTION='schedule'" "SCHED_EVERY='off'" "THRESHOLD='0'" "ON='0'" "KEEP_DAYS='365'" >/dev/null || fail=1
  wait_for '.app.schedule.every == "off"' 20 && echo "  ok   schedule off" || { echo "  FAIL schedule off"; fail=1; }

  # Everything as a CSV.
  wait_for '.app.history.total >= 11' 30
  [[ "$(head -n 1 "$VAR/history.csv" 2>/dev/null)" == time_utc,source,device,* ]] && (( $(wc -l < "$VAR/history.csv") >= 12 )) && grep -q 'Test ""peer"" & co' "$VAR/history.csv" \
    && echo "  ok   history.csv: $(( $(wc -l < "$VAR/history.csv") - 1 )) tests, with device names" || { echo "  FAIL csv: $(head -n 3 "$VAR/history.csv" 2>&1)"; fail=1; }

  # Rename, forget.
  request "ACTION='device'" "DEV_HOST='$pip'" "DEV_NAME_B64='$(b64u 'Peer')'" "DEV_PORT='5201'" || fail=1
  wait_for ".app.history.devices | length == 1 and .[0].name == \"Peer\" and .[0].addr == \"$pip\"" 20 && echo "  ok   renamed" || { echo "  FAIL rename: $(jq -c .app.history.devices "$VAR/status.json")"; fail=1; }

  # Backup with the history, history cleared, restored.
  request "ACTION='backup'" || fail=1; b2=$(jq -r '.backups[0].name' "$VAR/status.json"); total=$(jq '.app.history.total' "$VAR/status.json")
  tar -tf "$APP/backups/$b2" | grep -q 'history.sqlite.gz$' && tar -tf "$APP/backups/$b2" | grep -q 'librespeed.sqlite.gz$' \
    && echo "  ok   $b2: both databases" || { echo "  FAIL backup contents: $(tar -tf "$APP/backups/$b2" | paste -sd' ')"; fail=1; }
  request "ACTION='clearhist'" || fail=1
  wait_for '.app.history.total == 0 and (.app.history.devices | length == 1)' 20 && echo "  ok   history cleared, the device name kept" || { echo "  FAIL clear: $(jq -c '.app.history | {total, devices}' "$VAR/status.json")"; fail=1; }
  request "ACTION='undevice'" "DEV_HOST='$pip'" || fail=1
  wait_for '.app.history.devices | length == 0' 20 && echo "  ok   the device forgotten" || { echo "  FAIL undevice"; fail=1; }
  request "ACTION='restore'" "BACKUP='$b2'" || fail=1
  wait_for ".app.history.total == $total and (.app.history.devices | length == 1)" 60 && echo "  ok   restored: $total tests and the device are back" || { echo "  FAIL restore: $(jq -c '.app.history | {total, devices}' "$VAR/status.json")"; fail=1; }
  sleep 15; touch "$VAR/watching"; wait_for '[.app.history.rows[] | select(.[2] == "browser")] | length == 1' 20 && echo "  ok   …and the browser test wasn't taken twice" || { echo "  FAIL browser rows after restore: $(hist 'map(select(.src == "browser")) | length')"; fail=1; }

  # The iperf3 port, moved and back.
  request "ACTION='settings'" "APP_URL='http://127.0.0.1:$PORT'" "HTTP_PORT='$PORT'" "SSL_PROXY='0'" "APP_TZ='Europe/London'" "IPERF_PORT='$IPORT2'" || fail=1
  n=$(jq '[.app.history.rows[] | select(.[2] == "server")] | length' "$VAR/status.json")
  sleep 3; CPORT=$IPORT2 client && wait_for "[.app.history.rows[] | select(.[2] == \"server\")] | length == $((n + 1))" 60 && docker exec "$NAME" grep -q "^IPERF_PORT=$IPORT2$" "$APP/.env" && jq -e ".app.iperf_port == $IPORT2" "$VAR/status.json" >/dev/null && echo "  ok   iperf3 moved to $IPORT2, and a test there is logged" || { echo "  FAIL port move: $(jq .app.iperf_port "$VAR/status.json")"; fail=1; }
  request "ACTION='settings'" "APP_URL='http://127.0.0.1:$PORT'" "HTTP_PORT='$PORT'" "SSL_PROXY='0'" "APP_TZ='Europe/London'" "IPERF_PORT='$IPORT'" >/dev/null || fail=1
  wait_for ".app.iperf_port == $IPORT" 20 && sleep 3 && client && echo "  ok   …and back to $IPORT" || { echo "  FAIL port back"; fail=1; }

  # Updates: LibreSpeed pinned; pretend this install is on 6.2.1.
  docker exec "$NAME" sed -i 's|^LS_IMAGE=.*|LS_IMAGE=ghcr.io/librespeed/speedtest:6.2.1-alpine|' "$APP/.env"
  request "ACTION='check'" || fail=1
  jq -e '.image_update | .librespeed.available == true and .librespeed.current == "6.2.1" and (.iperf3.latest | length > 0) and .iperf3.current == .iperf3.latest and .iperf3.available == false' "$VAR/status.json" >/dev/null \
    && echo "  ok   updates found: LibreSpeed $(jq -r '.image_update.librespeed | "\(.current) → \(.latest)"' "$VAR/status.json"); iperf3 in Alpine $(jq -r .image_update.iperf3.latest "$VAR/status.json"), here $(jq -r .image_update.iperf3.current "$VAR/status.json")" \
    || { echo "  FAIL check: $(jq -c .image_update "$VAR/status.json")"; fail=1; }
  request "ACTION='updateapp'" || fail=1
  docker exec "$NAME" grep -q "^LS_IMAGE=ghcr.io/librespeed/speedtest:$(jq -r '.image_update.librespeed.latest' "$VAR/status.json")-alpine$" "$APP/.env" && jq -e '.image_update.librespeed.available == false' "$VAR/status.json" >/dev/null \
    && ! grep -q 'image prune' "$VAR/package.log" \
    && echo "  ok   updated with a backup first ($(jq -r '.backup.last.name' "$VAR/status.json")), no host-wide prune" || { echo "  FAIL update: $(jq -c '.image_update' "$VAR/status.json")"; fail=1; }
  request "ACTION='updateapp'" >/dev/null && { echo "  FAIL an update with nothing newer"; fail=1; } || echo "  ok   nothing newer: $(jq -r .last.message "$VAR/status.json")"

  # Storage, logs.
  wait_for '.storage.app | has("history") and has("librespeed")' 30 && echo "  ok   storage: $(jq -c .storage.app "$VAR/status.json")" || { echo "  FAIL storage: $(jq -c .storage "$VAR/status.json")"; fail=1; }
  for i in $(seq 1 20); do [[ -s "$VAR/logs/server.log" ]] && break; touch "$VAR/watching"; sleep 1; done
  grep -q "iperf3 server: a test from" "$VAR/logs/server.log" && echo "  ok   the server's log for the window" || { echo "  FAIL server.log"; fail=1; }
  docker rm -f "$PEER" >/dev/null 2>&1
  (( fail )) && { echo "  lanspeed: something FAILED"; return 1; }; echo "  lanspeed: all passed"
}
