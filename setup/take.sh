# Run inside lanspeed-server (docker exec -i … sh -s < take.sh): what's new for
# the history since it last looked, one JSON line each — the iperf3 server's
# reports waiting in /data/inbox, and LibreSpeed results after the last one
# taken (its number is kept in the history database).
cd /data/inbox 2>/dev/null && for f in $(ls | grep -E '^[0-9]+-[0-9]+\.json$' | head -n 50); do
  jq -c --arg f "$f" '{iperf: $f, r: (del(.intervals) | del(.end.streams))}' "$f" 2>/dev/null || printf '{"iperf":"%s","r":null}\n' "$f"
done
if [ -s /librespeed/db.sql ] && [ -f /data/history.db ]; then
  last=$(sqlite3 -cmd '.timeout 5000' /data/history.db "SELECT COALESCE((SELECT v FROM meta WHERE k = 'librespeed_last'), 0);" 2>/dev/null | tr -cd '0-9')
  sqlite3 -readonly -cmd '.timeout 5000' /librespeed/db.sql "SELECT json_object('browser', id, 'at', CAST(strftime('%s', timestamp) AS INTEGER), 'ip', ip, 'ua', substr(ua, 1, 300), 'dl', dl, 'ul', ul, 'ping', ping, 'jitter', jitter) FROM speedtest_users WHERE id > ${last:-0} ORDER BY id LIMIT 200;" 2>/dev/null
fi
true
