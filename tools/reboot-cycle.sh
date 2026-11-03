#!/usr/bin/env bash
# Reboot the Nano N times; time each cycle until SSH answers and run checks.
#   tools/reboot-cycle.sh [COUNT] [HOST]
# Serial output is captured to logs/serial-<date>.log meanwhile.
set -u
COUNT=${1:-3}
HOST=${2:-sirhc@unicomplex}
cd "$(dirname "$0")/.."

python3 -u tools/nano-serial.py log $((COUNT * 240)) >/dev/null 2>&1 &
LOGGER=$!
trap 'kill $LOGGER 2>/dev/null' EXIT

for i in $(seq 1 "$COUNT"); do
  t0=$(date +%s)
  ssh -o ConnectTimeout=10 "$HOST" 'sudo systemctl reboot' >/dev/null 2>&1
  sleep 15
  until ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" true 2>/dev/null; do
    sleep 3
    if (( $(date +%s) - t0 > 600 )); then echo "cycle $i: no SSH after 600 s"; exit 1; fi
  done
  t1=$(date +%s)
  ssh "$HOST" 'echo "  up $(cut -d" " -f1 /proc/uptime)s, state=$(systemctl is-system-running), failed=[$(systemctl --failed --no-legend --plain | cut -d" " -f1 | paste -sd,)], emc=$(sudo cat /sys/kernel/debug/clk/emc/clk_rate), link=$(cat /sys/class/net/eth0/speed)Mb, errs=$(sudo dmesg -l err,crit,alert,emerg | wc -l)"' |
    sed "s/^/cycle $i: reboot->ssh $((t1 - t0))s/"
done
