# LAN Speed's iperf3 image, built by the package on the Synology: Alpine's
# iperf3 (3.20 on Alpine 3.24), with sqlite3 and jq for the history it keeps.
FROM alpine:3.24
RUN apk add --no-cache iperf3 sqlite jq tzdata
COPY server.sh /usr/local/bin/lanspeed-server
RUN chmod 755 /usr/local/bin/lanspeed-server
LABEL org.opencontainers.image.title="lanspeed-iperf3" org.opencontainers.image.description="iperf3 for the LAN Speed package for Synology DSM"
CMD ["/usr/local/bin/lanspeed-server"]
