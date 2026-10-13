#!/bin/sh
# iperf3's server for LAN Speed. One test at a time (iperf3 -s -1), each test's
# report (JSON) left in /data/inbox for the package to add to the history, then
# listening again. If the port can't be opened, why goes to /tmp/listen-error,
# which makes the container unhealthy (and the window says so).
port=${IPERF_PORT:-5201}
case "$port" in ''|*[!0-9]*) port=5201 ;; esac
inbox=/data/inbox
mkdir -p "$inbox"; rm -f "$inbox"/.current
pid=""
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; exit 0' TERM INT
n=0
echo "iperf3 server: $(iperf3 --version | head -n 1), listening on port $port (TCP and UDP)"
while :; do
  # Never more than 500 reports waiting (the package takes them every minute or so).
  waiting=$(ls "$inbox" | wc -l)
  [ "$waiting" -gt 500 ] && ls "$inbox"/*.json | head -n $((waiting - 500)) | xargs rm -f
  iperf3 -s -1 -J -p "$port" > "$inbox/.current" 2>/tmp/iperf3.err &
  pid=$!; wait "$pid"; rc=$?; pid=""
  err=$(jq -r '.error // empty' "$inbox/.current" 2>/dev/null)
  case "$err" in
    *"unable to start listener"*|*"Address in use"*|*"Address already in use"*)
      echo "$err" > /tmp/listen-error; echo "iperf3 server: $err"; rm -f "$inbox/.current"; sleep 10; continue ;;
  esac
  rm -f /tmp/listen-error
  if [ -s "$inbox/.current" ]; then
    n=$((n + 1)); f="$inbox/$(date +%s)-$n.json"; mv "$inbox/.current" "$f"
    if [ -n "$err" ]; then echo "iperf3 server: a connection ended with: $err"
    else echo "iperf3 server: a test from $(jq -r '.start.connected[0].remote_host // "?"' "$f" 2>/dev/null) finished"; fi
  fi
  [ "$rc" -ne 0 ] && sleep 1
done
