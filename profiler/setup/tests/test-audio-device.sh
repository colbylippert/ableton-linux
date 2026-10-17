#!/usr/bin/env bash
# Tests for the PipeWire device helpers of profiler/setup/lib/host.sh (the
# capture-node pairing rule, the retried node lookup behind profiler/bin/bench's
# audio gate) and setup phase audio's device resolution (phases/06-audio.sh
# _aud_resolve), on fixtures: fake pw-dump / pw-cli / wpctl / pw-metadata on
# PATH, no PipeWire needed. Needs bash, awk and jq.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
setup="$(cd "$here/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/profiler-audio-test.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
pass=0
t_ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
t_fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || t_fail "jq is installed (setup phase packages)"

# ------------------------------------------------------------ fixtures ----
# One graph: the built-in card (HiFi, Speaker + two Mic sources), the Scarlett in
# Pro Audio, a second Scarlett in HiFi (Line sinks, Mic sources), an output-only
# DAC, a duplex analog-stereo card and the profiler's null sink.
spk=alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Speaker__sink
mic1=alsa_input.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Mic1__source
mic2=alsa_input.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Mic2__source
pro_out=alsa_output.usb-Focusrite_Scarlett_2i4_USB-00.pro-output-0
pro_in=alsa_input.usb-Focusrite_Scarlett_2i4_USB-00.pro-input-0
hifi_line1=alsa_output.usb-Focusrite_Scarlett_2i4_USB-01.HiFi__Line1__sink
hifi_line2=alsa_output.usb-Focusrite_Scarlett_2i4_USB-01.HiFi__Line2__sink
hifi_mic1=alsa_input.usb-Focusrite_Scarlett_2i4_USB-01.HiFi__Mic1__source
hifi_mic2=alsa_input.usb-Focusrite_Scarlett_2i4_USB-01.HiFi__Mic2__source
dac=alsa_output.usb-Some_DAC-00.analog-stereo
duplex_out=alsa_output.usb-Generic_Duplex-00.analog-stereo
duplex_in=alsa_input.usb-Generic_Duplex-00.analog-stereo
duplex_mono=alsa_input.usb-Generic_Duplex-00.mono-fallback
# id class name device.id priority.session
node() { printf '%s\t%s\t%s\t%s\t%s\n' "$@"; }
{
    node 31 Audio/Sink profiler-null "" 0
    node 61 Audio/Sink "$spk" 54 1000
    node 62 Audio/Source "$mic2" 54 2000
    node 63 Audio/Source "$mic1" 54 1648
    node 112 Audio/Sink "$pro_out" 95 1600
    node 114 Audio/Source "$pro_in" 95 2600
    node 120 Audio/Sink "$hifi_line1" 96 1500
    node 121 Audio/Sink "$hifi_line2" 96 1400
    node 122 Audio/Source "$hifi_mic2" 96 1400
    node 123 Audio/Source "$hifi_mic1" 96 1500
    node 130 Audio/Sink "$dac" 97 1000
    node 140 Audio/Sink "$duplex_out" 98 1000
    node 141 Audio/Source "$duplex_mono" 98 900
    node 142 Audio/Source "$duplex_in" 98 1000
    node 150 Video/Source v4l2_input.webcam 67 0
} > "$work/nodes.tsv"
# pw-dump JSON and pw-cli ls Node text from the same table
awk -F'\t' 'BEGIN { print "[" }
    { if (NR > 1) print ","
      printf "{\"id\": %s, \"type\": \"PipeWire:Interface:Node\", \"info\": {\"props\": {\"node.name\": \"%s\", \"media.class\": \"%s\"", $1, $3, $2
      if ($4 != "") printf ", \"device.id\": %s", $4
      printf ", \"priority.session\": %s}}}", $5 }
    END { print ",\n{\"id\": 40, \"type\": \"PipeWire:Interface:Metadata\", \"props\": {\"metadata.name\": \"default\"}, \"metadata\": []}\n]" }' \
    "$work/nodes.tsv" > "$work/dump.json"
jq -e 'length == 16' "$work/dump.json" >/dev/null || t_fail "the pw-dump fixture is valid JSON"
awk -F'\t' '{ printf "\tid %s, type PipeWire:Interface:Node/3\n \t\tobject.serial = \"%s\"\n", $1, $1 + 700
              if ($4 != "") printf " \t\tdevice.id = \"%s\"\n", $4
              printf " \t\tpriority.session = \"%s\"\n \t\tnode.name = \"%s\"\n \t\tmedia.class = \"%s\"\n", $5, $3, $2 }' \
    "$work/nodes.tsv" > "$work/ls-node.txt"

# fake tools: FAKE_DUMP_FAIL / FAKE_CLI_FAIL = calls that fail before one succeeds
# (counted in $work/*.count); FAKE_DUMP_FILE / FAKE_CLI_FILE choose the fixture
mkdir -p "$work/bin"
cat > "$work/bin/pw-dump" <<'EOF'
#!/usr/bin/env bash
n="$(cat "$FAKE_STATE/dump.count" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$FAKE_STATE/dump.count"
[ "$n" -ge "${FAKE_DUMP_FAIL:-0}" ] || { echo "pw-dump: cannot connect" >&2; exit 1; }
cat "${FAKE_DUMP_FILE:?}"
EOF
cat > "$work/bin/pw-cli" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
    "info 0") exit 0 ;;
    "ls Node")
        n="$(cat "$FAKE_STATE/cli.count" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$FAKE_STATE/cli.count"
        [ "$n" -ge "${FAKE_CLI_FAIL:-0}" ] || exit 1
        cat "${FAKE_CLI_FILE:?}" ;;
    *) exit 1 ;;
esac
EOF
cat > "$work/bin/wpctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    status) printf 'PipeWire\n\nAudio\n ├─ Sinks:\n │      112. Scarlett 2i4 USB Pro [vol: 1.00]\n\nVideo\n ├─ Sinks:\n' ;;
    get-volume) printf 'Volume: 1.00\n' ;;
    *) exit 1 ;;
esac
EOF
printf '#!/bin/sh\nexit 1\n' > "$work/bin/pw-metadata"
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" FAKE_STATE="$work" FAKE_DUMP_FILE="$work/dump.json" FAKE_CLI_FILE="$work/ls-node.txt"
reset_counts() { rm -f "$work/dump.count" "$work/cli.count"; }

# shellcheck source=../lib/host.sh
. "$setup/lib/host.sh"

# ------------------------------------------------- the pairing rule ----
pair() { pwa_resolve_input "$1" 2>/dev/null || printf '<none>\n'; }
[ "$(pair "$pro_out")" = "$pro_in" ] || t_fail "Pro Audio pairs pro-output-0 with pro-input-0 (got $(pair "$pro_out"))"
t_ok "a Pro Audio sink pairs with the card's pro-input of the same index"
[ "$(pair "$spk")" = "$mic1" ] || t_fail "the built-in Speaker sink pairs with the card's first Mic source by name (got $(pair "$spk"))"
t_ok "the built-in Speaker sink pairs with the lexically first Mic source, whatever the priorities"
[ "$(pair "$hifi_line1")" = "$hifi_mic1" ] && [ "$(pair "$hifi_line2")" = "$hifi_mic1" ] \
    || t_fail "HiFi Line sinks pair with their own card's Mic source (got $(pair "$hifi_line1"), $(pair "$hifi_line2"))"
t_ok "HiFi Line sinks pair with their own card's Mic source, never another card's"
[ "$(pair "$duplex_out")" = "$duplex_in" ] || t_fail "an analog-stereo sink pairs with the analog-stereo source (got $(pair "$duplex_out"))"
t_ok "a duplex card pairs by the mirrored node name before any fallback"
[ "$(pair "$dac")" = '<none>' ] || t_fail "an output-only card yields no capture node (got $(pair "$dac"))"
[ "$(pair profiler-null)" = '<none>' ] || t_fail "a sink without a device yields no capture node"
[ "$(pair alsa_output.nowhere.analog-stereo)" = '<none>' ] || t_fail "an unknown sink yields no capture node"
[ "$(pair "$pro_in")" = '<none>' ] || t_fail "a source given as the sink yields no capture node"
t_ok "no capture node for an output-only card, a device-less sink or an unknown name"
reset_counts

# ---------------------------------------------- the retried lookup ----
id="$(pwa_node_lookup "$pro_out" 5 2>"$work/err")" || t_fail "the lookup finds a present node"
[ "$id" = 112 ] && [ ! -s "$work/err" ] || t_fail "an immediate hit prints the id and nothing else (got '$id', $(cat "$work/err"))"
t_ok "pwa_node_lookup returns the node id by node.name"
reset_counts
id="$(FAKE_DUMP_FAIL=2 FAKE_CLI_FAIL=2 pwa_node_lookup "$pro_out" 10 2>"$work/err")" \
    || t_fail "the lookup retries a daemon that fails twice: $(cat "$work/err")"
[ "$id" = 112 ] || t_fail "the retried lookup prints the id (got '$id')"
grep -q 'found as node 112 on attempt 3' "$work/err" || t_fail "a hit after misses is noted: $(cat "$work/err")"
t_ok "pwa_node_lookup retries with backoff and notes a late hit"
reset_counts
id="$(FAKE_DUMP_FAIL=99 pwa_node_lookup "$pro_out" 5 2>"$work/err")" || t_fail "pw-cli answers when pw-dump fails"
[ "$id" = 112 ] || t_fail "the pw-cli fallback prints the id (got '$id')"
t_ok "pwa_node_lookup falls back to pw-cli ls Node"
reset_counts
start=$SECONDS
if pwa_node_lookup alsa_output.usb-Gone-00.pro-output-0 1 >"$work/out" 2>"$work/err"; then
    t_fail "the lookup finds an absent node"
fi
[ ! -s "$work/out" ] || t_fail "a miss prints no id"
grep -q 'no node named alsa_output.usb-Gone-00.pro-output-0 after' "$work/err" || t_fail "a miss says what was looked for"
grep -q "pw-dump -N (timeout 15): exit 0.*Audio/Sink nodes: .*$pro_out" "$work/err" || t_fail "a miss shows what pw-dump saw: $(cat "$work/err")"
grep -q "pw-cli ls Node (timeout 10): exit 0.*Audio/Sink nodes: .*$spk" "$work/err" || t_fail "a miss shows what pw-cli saw"
grep -q "Audio/Source nodes: .*$pro_in" "$work/err" || t_fail "a miss lists the capture nodes too (a missing audio_input)"
grep -q 'Scarlett 2i4 USB Pro' "$work/err" || t_fail "a miss shows wpctl status's Audio section"
[ $((SECONDS - start)) -le 6 ] || t_fail "a miss with a 1 s budget took $((SECONDS - start))s"
t_ok "a real miss returns 1 and prints the evidence of both tools and wpctl"
reset_counts

# ------------------------------------------ phase audio's resolution ----
# shellcheck source=../lib/log.sh
LOG_FD=1; LOGFILE=""; CURRENT_PHASE=""
. "$setup/lib/log.sh"
# shellcheck source=../lib/phase.sh
. "$setup/lib/phase.sh"
trap 'rm -rf -- "$work"' EXIT          # phase.sh installs its own EXIT trap
# shellcheck source=../phases/01-sudo.sh
. "$setup/phases/01-sudo.sh"
# shellcheck source=../phases/06-audio.sh
. "$setup/phases/06-audio.sh"
resolve() { AUD_NODE="" AUD_INPUT="" AUD_MUTE="" AUD_NODE_ID="" AUD_WHY=""; _aud_resolve "$1"; }
resolve "$pro_out" || t_fail "phase audio resolves an explicit Scarlett node: $AUD_WHY"
[ "$AUD_NODE/$AUD_NODE_ID/$AUD_INPUT/$AUD_MUTE" = "$pro_out/112/$pro_in/0" ] \
    || t_fail "an explicit Pro Audio sink records its pro-input and no mute (got $AUD_NODE/$AUD_NODE_ID/$AUD_INPUT/$AUD_MUTE)"
[ -z "$AUD_WHY" ] || t_fail "a paired explicit node carries no warning (got '$AUD_WHY')"
t_ok "phase audio pairs --audio-device …pro-output-0 with …pro-input-0 (audio_input), unmuted"
resolve "$hifi_line1" || t_fail "phase audio resolves a HiFi Line sink: $AUD_WHY"
[ "$AUD_INPUT" = "$hifi_mic1" ] || t_fail "a HiFi Line sink records its card's Mic source (got $AUD_INPUT)"
t_ok "phase audio pairs a HiFi Line sink with the card's Mic source"
resolve builtin || t_fail "phase audio resolves builtin: $AUD_WHY"
[ "$AUD_NODE/$AUD_INPUT/$AUD_MUTE" = "$spk/$mic1/1" ] \
    || t_fail "builtin keeps the Speaker sink, the first Mic source and the mute (got $AUD_NODE/$AUD_INPUT/$AUD_MUTE)"
t_ok "builtin resolves as before: Speaker sink, lexically first Mic source, muted"
resolve null || t_fail "phase audio resolves null: $AUD_WHY"
[ "$AUD_NODE/$AUD_INPUT/$AUD_MUTE" = "profiler-null/profiler-null/0" ] || t_fail "null keeps profiler-null for both (got $AUD_NODE/$AUD_INPUT/$AUD_MUTE)"
t_ok "null keeps profiler-null for output and input"
resolve "$dac" || t_fail "phase audio resolves an output-only sink: $AUD_WHY"
[ -z "$AUD_INPUT" ] && [[ "$AUD_WHY" == *"no capture node"* ]] \
    || t_fail "an output-only sink leaves the input unset and says why (got '$AUD_INPUT', '$AUD_WHY')"
t_ok "an output-only card leaves input_device unset, with the reason"
if resolve alsa_output.usb-Gone-00.pro-output-0; then t_fail "phase audio resolves an absent node"; fi
[[ "$AUD_WHY" == *"no Audio/Sink named"* ]] || t_fail "an absent node is named as absent (got '$AUD_WHY')"
t_ok "an absent explicit node does not resolve"

printf 'PASS: %s audio device checks\n' "$pass"
