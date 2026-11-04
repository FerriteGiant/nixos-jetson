# Small board-health commands (work interactively and over `ssh host cmd`).
#   voltage [-w]      INA3221 rails: volts, amps, watts (-w: refresh every 1 s)
#   bootreason [N]    why the last N boots (default 5) happened (PMIC NVERC +
#                     Tegra PMC reset status, from pmic-reset-reason.service)
{ pkgs, ... }:

let
  voltage = pkgs.writeShellScriptBin "voltage" ''
    hw=""
    for h in /sys/class/hwmon/hwmon*; do
      [ "$(cat "$h/name" 2>/dev/null)" = ina3221 ] && hw=$h
    done
    [ -n "$hw" ] || { echo "ina3221 not found" >&2; exit 1; }
    show() {
      for i in 1 2 3; do
        read -r l <"$hw/in''${i}_label"; read -r mv <"$hw/in''${i}_input"; read -r ma <"$hw/curr''${i}_input"
        printf "%-8s %5d.%02d V  %5d mA  %6d mW\n" "$l" $((mv / 1000)) $((mv % 1000 / 10)) "$ma" $((mv * ma / 1000))
      done
    }
    if [ "''${1:-}" = -w ]; then
      while :; do clear; date; show; sleep 1; done
    else
      show
    fi
  '';

  bootreason = pkgs.writeShellScriptBin "bootreason" ''
    n=''${1:-5}
    ${pkgs.systemd}/bin/journalctl --list-boots --no-pager -q | tail -n "$n" |
      while read -r idx _id _dow _d _t _tz _dow2 end_d end_t _tz2; do
        case $idx in "" | *[!0-9-]*) continue ;; esac # skip header
        r=$(${pkgs.systemd}/bin/journalctl -b "$idx" -u pmic-reset-reason -o cat --no-pager -q \
              --grep 'NVERC' 2>/dev/null | head -n 1)
        [ "$idx" = 0 ] && end="now" || end="$end_d $end_t"
        printf "boot %3s (up until %-19s)  %s\n" "$idx" "$end" "''${r:-(no record)}"
      done
  '';
in
{
  environment.systemPackages = [ voltage bootreason ];
}
