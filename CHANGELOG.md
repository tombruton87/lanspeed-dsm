# Changelog

## 1.0.0 — 2026-10-12

First release. A web-based iperf for the home network, in Container Manager:
iperf3 3.20 (Alpine's, built on the Synology) as a server on port 5201, TCP and
UDP, always on, and LibreSpeed 6.3.0, the browser speed test, on port 8790 —
LAN only, nothing goes to the internet. The wizard suggests other ports when
those are taken, and both are in DSM's firewall list.

The DSM window adds:
- **Run a test:** iperf3 from the Synology to any device on the network — TCP
  or UDP, upload, download (-R) or both, how long, parallel streams — with
  Mbit/s, retransmits, and jitter and packet loss for UDP. Devices can be
  saved with a name.
- **History:** every test — run here, on the schedule, from other devices
  against the iperf3 server, and in the browser — with a chart over time,
  filters per device and kind of test, and every result as a CSV.
- **Schedule:** an iperf3 test to one device every 15 minutes to once a day,
  what counts as slow, and a DSM notification when a scheduled test is slow or
  fails.
- **How to test:** the browser test's address with a QR code for phones,
  iperf3 commands to copy for Windows, macOS and Linux, and what limits the
  results.
- **Site address:** the iperf3 port, beside the web port.

Also included: consistent backups of the history, restore, updates (a newer
LibreSpeed release, or Alpine's newer iperf3) and removal.
