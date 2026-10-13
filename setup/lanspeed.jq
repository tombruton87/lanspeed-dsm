# LAN Speed's reading of iperf3 and LibreSpeed results, for app.sh (jq -L /pkg/setup 'include "lanspeed"; …').
# Everything here comes from other devices or programs, so every text is cut short
# and stripped of control characters, and every value goes into SQL quoted.

def clean: tostring | gsub("[\u0000-\u001f\u007f]"; "") | .[0:300];
def q: if . == null then "NULL"
       elif type == "number" then (if isinfinite or isnan then "NULL" else tostring end)
       elif type == "boolean" then (if . then "1" else "0" end)
       else "'" + (clean | gsub("'"; "''")) + "'" end;
def mbps: if type == "number" then (. / 1000000 * 10 | round / 10) else null end;
def addr: if type == "string" then sub("^::ffff:"; "") | clean else "" end;
def numish: if type == "number" then . elif type == "string" then (tonumber? // null) else null end;
def sane($max): if type == "number" and . >= 0 and . <= $max then . else null end;

def pos(a; b): if (a | type) == "number" and a > 0 then a elif (b | type) == "number" and b > 0 then b else null end;

# iperf3's JSON report (-J) → one summary from this Synology's point of view.
# $role: "client" when the Synology ran the test (iperf3 -c), "server" when another device tested against it.
# to = Synology → device, from = device → Synology, in Mbit/s as the receiving side measured it.
def summary($role):
  (.start // {}) as $s | ($s.test_start // {}) as $t | (.end // {}) as $e
  | (($t.protocol // "") | ascii_downcase) as $proto
  | (($t.reverse // 0) == 1) as $rev | (($t.bidir // 0) == 1) as $bidir
  # The receiver's figure when this side has it; the sending side's report has 0 there (iperf3 3.20), so then the sender's.
  | (if $proto == "udp" then pos($e.sum_received.bits_per_second; $e.sum.bits_per_second // $e.sum_sent.bits_per_second)
     else pos($e.sum_received.bits_per_second; $e.sum_sent.bits_per_second) end) as $fwd
  | pos($e.sum_received_bidir_reverse.bits_per_second; $e.sum_sent_bidir_reverse.bits_per_second) as $back
  | (if $bidir then (if $role == "client" then {to: $fwd, from: $back} else {to: $back, from: $fwd} end)
     elif (($role == "client") != $rev) then {to: $fwd, from: null}
     else {to: null, from: $fwd} end) as $d
  | (if $proto == "udp" then ($e.sum_received // $e.sum // {}) else {} end) as $u
  | {
      at: ($s.timestamp.timesecs // null),
      addr: (($s.connected[0].remote_host // $s.accepted_connection.host // "") | addr),
      proto: $proto,
      dir: (if $bidir then "both" elif $d.to != null then "to" else "from" end),
      secs: ($t.duration // null), streams: ($t.num_streams // null),
      to: ($d.to | mbps), from: ($d.from | mbps),
      retrans: (if $proto == "tcp" then ($e.sum_sent.retransmits // null) else null end),
      jitter: (if $proto == "udp" then ($u.jitter_ms // null | if type == "number" then (. * 1000 | round / 1000) else null end) else null end),
      loss: (if $proto == "udp" then ($u.lost_percent // null | if type == "number" then (. * 100 | round / 100) else null end) else null end),
      cookie: ($s.cookie // ""),
      version: ($s.version // ""),
      error: (.error // null)
    }
  | .ok = (.error == null and ((.to // 0) > 0 or (.from // 0) > 0));

def test_sql($source; $host):
  "INSERT OR IGNORE INTO tests (at, source, addr, host, proto, dir, secs, streams, to_mbps, from_mbps, jitter_ms, loss_pct, retrans, ok, error, client, ext) VALUES ("
  + ([(.at // now | floor), $source, .addr, $host, .proto, .dir, .secs, .streams, .to, .from, .jitter, .loss, .retrans, .ok, (.error // ""),
      (if $source == "server" then "iperf3" else "" end),
      (if .cookie != "" then $source + ":" + .cookie else null end)] | map(q) | join(", ")) + ");";

# A browser's user agent → "iPhone · Safari".
def device_of:
  clean as $ua
  | (if ($ua | test("iPhone")) then "iPhone" elif ($ua | test("iPad")) then "iPad" elif ($ua | test("Android")) then "Android"
     elif ($ua | test("CrOS")) then "Chromebook" elif ($ua | test("Windows")) then "Windows" elif ($ua | test("Macintosh|Mac OS X")) then "Mac"
     elif ($ua | test("Linux")) then "Linux" else null end) as $os
  | (if ($ua | test("Edg/|EdgA/|EdgiOS/")) then "Edge" elif ($ua | test("OPR/|Opera")) then "Opera" elif ($ua | test("SamsungBrowser")) then "Samsung Internet"
     elif ($ua | test("Firefox/|FxiOS/")) then "Firefox" elif ($ua | test("Chrome/|CriOS/")) then "Chrome" elif ($ua | test("Safari/")) then "Safari"
     elif ($ua | test("^curl/")) then "curl" else null end) as $br
  | [$os, $br] | map(select(. != null)) | join(" · ") | if . == "" then "a browser" else . end;

# A LibreSpeed result (its telemetry row) → an INSERT. dl = Synology → device, ul = device → Synology.
def browser_sql:
  (.dl | numish | sane(1000000)) as $dl | (.ul | numish | sane(1000000)) as $ul
  | select(($dl // 0) > 0 or ($ul // 0) > 0)
  | "INSERT OR IGNORE INTO tests (at, source, addr, host, proto, dir, to_mbps, from_mbps, ping_ms, jitter_ms, ok, error, client, ext) VALUES ("
    + ([(.at | numish // now | floor), "browser", (.ip | addr), "", "http", "both",
        ($dl | if . == null then null else (. * 10 | round / 10) end), ($ul | if . == null then null else (. * 10 | round / 10) end),
        (.ping | numish | sane(100000)), (.jitter | numish | sane(100000)), true, "", (.ua | device_of), ("librespeed:" + (.browser | tostring))] | map(q) | join(", ")) + ");";
