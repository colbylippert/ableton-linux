#!/usr/bin/env bash
# focusrite-tsched.sh on|off|status: timer scheduling for the Focusrite's pro-audio nodes (D0017 in
# profiler/plans/kernel-plan.md). on installs 51-profiler-focusrite-tsched.conf into WirePlumber's user configuration
# and restarts PipeWire, its Pulse server and WirePlumber; off removes it and restarts them; status prints the nodes'
# scheduling properties (no restart). Run as the desktop user, with Live closed. The file survives reboots.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
conf=51-profiler-focusrite-tsched.conf
dest=$HOME/.config/wireplumber/wireplumber.conf.d
nodes="alsa_input.usb-Focusrite_Scarlett_2i4_USB-00.pro-input-0 alsa_output.usb-Focusrite_Scarlett_2i4_USB-00.pro-output-0"

status() {
  local name id props
  echo "rule installed: $([ -f "$dest/$conf" ] && echo yes || echo no)"
  for name in $nodes; do
    id=$(pw-cli ls Node 2>/dev/null | awk -v n="node.name = \"$name\"" '/^[[:space:]]*id [0-9]+,/ {id = $2} index($0, n) {print id; exit}' | tr -d ,)
    props=$( [ -n "$id" ] && pw-cli info "$id" 2>/dev/null | grep -oE 'api\.alsa\.(disable-tsched|headroom) = "[^"]*"' | tr '\n' ' ')
    echo "$name (id ${id:-missing}): ${props:-no scheduling properties shown}"
  done
}

restart() {
  if pgrep -f '[L]ive 12 Trial.exe' > /dev/null; then echo "focusrite-tsched.sh: Live is running; quit it first" >&2; exit 1; fi
  systemctl --user restart pipewire.service pipewire-pulse.service wireplumber.service
  for _ in $(seq 1 60); do
    pw-cli ls Node 2>/dev/null | grep -q 'alsa_output.usb-Focusrite' && break
    sleep 0.5
  done
  sleep 1
}

case ${1:-status} in
  on) mkdir -p "$dest"; cp "$here/$conf" "$dest/$conf"; restart; status ;;
  off) rm -f "$dest/$conf"; restart; status ;;
  status) status ;;
  *) echo "usage: focusrite-tsched.sh on|off|status" >&2; exit 2 ;;
esac
