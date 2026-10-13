# LAN Speed's CGI checks (sourced by chassis/tests/test-api.sh).
expect "runtest good" 202 "$(post "$me" runtest 'action=runtest&host=192.168.1.31&port=5201&proto=tcp&dir=both&secs=10&streams=4&rate=100')"; request_is "runtest request" "ACTION='runtest'
TEST_HOST='192.168.1.31'
TEST_PORT='5201'
TEST_PROTO='tcp'
TEST_DIR='both'
TEST_SECS='10'
TEST_STREAMS='4'
TEST_RATE='100'
BY='$me'"
expect "runtest IPv6" 202 "$(post "$me" runtest 'action=runtest&host=fe80%3A%3A1&port=5201&proto=udp&dir=down&secs=5&streams=1&rate=500')"
grep -q "^TEST_HOST='fe80::1'$" "$CHASSIS_VAR/request" && grep -q "^TEST_RATE='500'$" "$CHASSIS_VAR/request" && { (( pass++ )); echo "  ok   IPv6 and the UDP rate pass through"; } || { (( fail++ )); echo "  FAIL ipv6: $(tr '\n' ' ' < "$CHASSIS_VAR/request")"; }; rm -f "$CHASSIS_VAR/request"
expect "runtest host name" 202 "$(post "$me" runtest 'action=runtest&host=office-pc.lan&port=5201&proto=tcp&dir=up&secs=1&streams=16&rate=')"; rm -f "$CHASSIS_VAR/request"
for bad in '-R' '--help' 'a%3Bid' '%24(id)' 'a%20b' '192.168.1.256' '1.2.3' '999.1.1.1' '%60id%60' 'a..b' '-host.lan' 'host-.lan' ':%3A%3A1' '1%3A2%3A3' 'fe80%3A%3A1%25eth0' "x'y" ''; do
  expect "runtest refuses host [$bad]" 400 "$(post "$me" runtest "action=runtest&host=$bad&port=5201&proto=tcp&dir=up&secs=10&streams=1&rate=100")"; done
expect "runtest port 0" 400 "$(post "$me" runtest 'action=runtest&host=10.0.0.1&port=0&proto=tcp&dir=up&secs=10&streams=1&rate=100')"
expect "runtest port 65536" 400 "$(post "$me" runtest 'action=runtest&host=10.0.0.1&port=65536&proto=tcp&dir=up&secs=10&streams=1&rate=100')"
expect "runtest proto" 400 "$(post "$me" runtest 'action=runtest&host=10.0.0.1&port=5201&proto=sctp&dir=up&secs=10&streams=1&rate=100')"
expect "runtest dir" 400 "$(post "$me" runtest 'action=runtest&host=10.0.0.1&port=5201&proto=tcp&dir=sideways&secs=10&streams=1&rate=100')"
expect "runtest 61 s" 400 "$(post "$me" runtest 'action=runtest&host=10.0.0.1&port=5201&proto=tcp&dir=up&secs=61&streams=1&rate=100')"
expect "runtest 010 s" 400 "$(post "$me" runtest 'action=runtest&host=10.0.0.1&port=5201&proto=tcp&dir=up&secs=010&streams=1&rate=100')"
expect "runtest 17 streams" 400 "$(post "$me" runtest 'action=runtest&host=10.0.0.1&port=5201&proto=tcp&dir=up&secs=10&streams=17&rate=100')"
expect "runtest UDP rate 0" 400 "$(post "$me" runtest 'action=runtest&host=10.0.0.1&port=5201&proto=udp&dir=up&secs=10&streams=1&rate=0')"
expect "runtest UDP rate 10001" 400 "$(post "$me" runtest 'action=runtest&host=10.0.0.1&port=5201&proto=udp&dir=up&secs=10&streams=1&rate=10001')"
expect "viewer runtest → 403" 403 "$(CHASSIS_ADMINS=no-such-group post "$me" runtest 'action=runtest&host=10.0.0.1&port=5201&proto=tcp&dir=up&secs=10&streams=1&rate=100')"
expect "device" 202 "$(post "$me" device "action=device&host=192.168.1.31&name=Office%20PC%20%22Ada's%22%20%26%20co&port=5201")"
grep -q "^DEV_NAME_B64='T2ZmaWNlIFBDICJBZGEncyIgJiBjbw'$" "$CHASSIS_VAR/request" && { (( pass++ )); echo "  ok   the device name travels base64url"; } || { (( fail++ )); echo "  FAIL device request: $(tr '\n' ' ' < "$CHASSIS_VAR/request")"; }; rm -f "$CHASSIS_VAR/request"
expect "device no name" 400 "$(post "$me" device 'action=device&host=192.168.1.31&name=%20&port=5201')"
expect "device long name" 400 "$(post "$me" device "action=device&host=192.168.1.31&name=$(printf 'x%.0s' $(seq 1 61))&port=5201")"
expect "device bad host" 400 "$(post "$me" device 'action=device&host=a%3Bb&name=x&port=5201')"
jq -c '. + {app: {history: {devices: [{host: "192.168.1.31", name: "Office PC", port: 5201}]}, iperf_port: 5201}}' "$CHASSIS_VAR/status.json" > "$CHASSIS_VAR/status.json.tmp" && mv "$CHASSIS_VAR/status.json.tmp" "$CHASSIS_VAR/status.json"
expect "undevice listed" 202 "$(post "$me" undevice 'action=undevice&host=192.168.1.31')"; request_is "undevice request" "ACTION='undevice'
DEV_HOST='192.168.1.31'
BY='$me'"
expect "undevice not listed" 400 "$(post "$me" undevice 'action=undevice&host=192.168.1.32')"
expect "schedule good" 202 "$(post "$me" schedule 'action=schedule&every=1h&host=192.168.1.1&port=5201&proto=tcp&dir=both&secs=10&streams=2&rate=100&threshold=500&alert=1&keep=365')"; request_is "schedule request" "ACTION='schedule'
SCHED_EVERY='1h'
THRESHOLD='500'
ON='1'
KEEP_DAYS='365'
TEST_HOST='192.168.1.1'
TEST_PORT='5201'
TEST_PROTO='tcp'
TEST_DIR='both'
TEST_SECS='10'
TEST_STREAMS='2'
TEST_RATE='100'
BY='$me'"
expect "schedule off, no device" 202 "$(post "$me" schedule 'action=schedule&every=off&host=&threshold=0&alert=0&keep=90')"; rm -f "$CHASSIS_VAR/request"
expect "schedule on, no device" 400 "$(post "$me" schedule 'action=schedule&every=1h&host=&port=5201&proto=tcp&dir=up&secs=10&streams=1&rate=100&threshold=0&alert=0&keep=90')"
expect "schedule bad every" 400 "$(post "$me" schedule 'action=schedule&every=5m&host=10.0.0.1&port=5201&proto=tcp&dir=up&secs=10&streams=1&rate=100&threshold=0&alert=0&keep=90')"
expect "schedule bad threshold" 400 "$(post "$me" schedule 'action=schedule&every=1h&host=10.0.0.1&port=5201&proto=tcp&dir=up&secs=10&streams=1&rate=100&threshold=1e9&alert=0&keep=90')"
expect "schedule bad keep" 400 "$(post "$me" schedule 'action=schedule&every=1h&host=10.0.0.1&port=5201&proto=tcp&dir=up&secs=10&streams=1&rate=100&threshold=0&alert=0&keep=7')"
expect "schedule bad host" 400 "$(post "$me" schedule 'action=schedule&every=1h&host=%24(id)&port=5201&proto=tcp&dir=up&secs=10&streams=1&rate=100&threshold=0&alert=0&keep=90')"
expect "clearhist" 202 "$(post "$me" clearhist 'action=clearhist')"; request_is "clearhist request" "ACTION='clearhist'
BY='$me'"
expect "settings with the iperf3 port" 202 "$(post "$me" settings 'action=settings&url=http%3A%2F%2F192.168.1.20%3A8790&port=8790&ssl_proxy=0&tz=Europe%2FLondon&iperf_port=5201')"
grep -q "^IPERF_PORT='5201'$" "$CHASSIS_VAR/request" && { (( pass++ )); echo "  ok   the iperf3 port goes with the settings"; } || { (( fail++ )); echo "  FAIL settings: $(tr '\n' ' ' < "$CHASSIS_VAR/request")"; }; rm -f "$CHASSIS_VAR/request"
expect "settings iperf3 port = web port" 400 "$(post "$me" settings 'action=settings&url=http%3A%2F%2F192.168.1.20%3A8790&port=8790&ssl_proxy=0&tz=Europe%2FLondon&iperf_port=8790')"
expect "settings iperf3 port 80" 400 "$(post "$me" settings 'action=settings&url=http%3A%2F%2F192.168.1.20%3A8790&port=8790&ssl_proxy=0&tz=Europe%2FLondon&iperf_port=80')"
expect "historycsv none yet → 404" 404 "$(get "$me" 'action=historycsv')"
printf 'time_utc,source\n2026-10-12 10:00:00,run\n' > "$CHASSIS_VAR/history.csv"
expect "historycsv" 200 "$(get "$me" 'action=historycsv')"
expect "viewer historycsv → 403" 403 "$(CHASSIS_ADMINS=no-such-group get "$me" 'action=historycsv')"
