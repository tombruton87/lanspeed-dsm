    echo "IPERF_PORT='$(printf '%s' "${wizard_iperf_port:-5201}" | tr -cd '0-9' | head -c 5)'"
