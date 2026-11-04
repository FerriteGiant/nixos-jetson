# VDD_IN (5 V input) monitor for the Jetson Nano's INA3221 (hwmon "ina3221").
# Samples every PERIOD seconds, averages over WINDOW samples, and logs to
# stdout with syslog-level prefixes (journald turns "<4>" into a warning).
#
#   LOW_MV     warn when the moving average drops below this (default 4700)
#   CLEAR_MV   leave the low state only above this (hysteresis, default 4750)
#   WINDOW     samples per average (default 5)      PERIOD  seconds (default 0.2)
#   REMIND_S   repeat warning while still low, at most this often (default 60)
#   SUMMARY_S  info summary interval (default 3600)
set -u
LOW_MV=${LOW_MV:-4700}
CLEAR_MV=${CLEAR_MV:-4750}
WINDOW=${WINDOW:-5}
PERIOD=${PERIOD:-0.2}
REMIND_S=${REMIND_S:-60}
SUMMARY_S=${SUMMARY_S:-3600}

hw=""
for _ in $(seq 1 60); do
  for h in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$h/name" 2>/dev/null)" = ina3221 ] && hw=$h
  done
  [ -n "$hw" ] && break
  sleep 1
done
[ -n "$hw" ] || { echo "<3>ina3221 hwmon device not found"; exit 1; }

# Fork-free sleep: read with timeout from a pipe that never gets data.
exec {tick}<> <(:)

declare -a buf=()
idx=0 sum=0 cnt=0
low=0 low_min=0 low_since=0 last_warn=0
s_min=999999 s_sum=0 s_n=0 s_imax=0 s_start=$SECONDS

echo "<6>monitoring VDD_IN on $hw: warn if the $WINDOW-sample average (${PERIOD}s period) < $LOW_MV mV, clear > $CLEAR_MV mV"

while :; do
  read -r v <"$hw/in1_input" || v=0
  read -r c <"$hw/curr1_input" || c=0

  old=${buf[idx]:-0}
  buf[idx]=$v
  idx=$(((idx + 1) % WINDOW))
  sum=$((sum - old + v))
  ((cnt < WINDOW)) && cnt=$((cnt + 1))
  avg=$((sum / cnt))

  if ((cnt == WINDOW)); then
    ((avg < s_min)) && s_min=$avg
    s_sum=$((s_sum + avg)) s_n=$((s_n + 1))
    ((c > s_imax)) && s_imax=$c

    if ((low == 0)); then
      if ((avg < LOW_MV)); then
        low=1 low_min=$avg low_since=$SECONDS last_warn=$SECONDS
        echo "<4>VDD_IN low: ${avg} mV average (< $LOW_MV mV), input current ${c} mA"
      fi
    else
      ((avg < low_min)) && low_min=$avg
      if ((avg > CLEAR_MV)); then
        echo "<5>VDD_IN recovered: ${avg} mV after $((SECONDS - low_since)) s low; lowest average ${low_min} mV"
        low=0
      elif ((SECONDS - last_warn >= REMIND_S)); then
        echo "<4>VDD_IN still low for $((SECONDS - low_since)) s: ${avg} mV now, lowest average ${low_min} mV"
        last_warn=$SECONDS
      fi
    fi
  fi

  if ((SECONDS - s_start >= SUMMARY_S && s_n > 0)); then
    echo "<6>VDD_IN last $((SECONDS - s_start)) s: lowest average ${s_min} mV, mean $((s_sum / s_n)) mV, peak input current ${s_imax} mA"
    s_min=999999 s_sum=0 s_n=0 s_imax=0 s_start=$SECONDS
  fi

  read -r -t "$PERIOD" -u "$tick" _ || true
done
