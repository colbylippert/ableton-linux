#!/usr/bin/env bash
# first-buffer.sh TAG [WORKERS] [SET] [DURATION]: how PipeASIO and PipeWire start Live's audio, from Live's first buffer
# (profiler/plans/kernel-plan.md, D0016). PipeASIO calls Live's bufferSwitch inside PipeWire's process callback, one
# block per graph cycle, but only once the graph's quantum equals Live's buffer size: until then it mutes and runs Live
# on a wall-clock cadence (patches/pipeasio/0005). This records the start and the hand-over to one block per cycle.
#   1. bpftrace arms PipeASIO's USDT probes on the runtime's pipeasio64.dll.so by file, before Live starts, so the first
#      cycle is caught; pw-profiler -J starts as the desktop user, so the graph's quantum when Live's node joins is too
#   2. one bench window (DURATION s, default 30, on SET, default Inbuilts) in the kept configuration with WORKERS audio
#      workers (default 2) and PIPEASIO_TELEMETRY=on (PipeASIO's per-second callback phase aggregates)
#   3. both stop after the bench; the launcher log's lines from this run are copied
# The same bpftrace session marks every /abl/bench/* command the bench sends (a sendto probe), so the play instant sits
# on the probes' clock: whether the first playing blocks keep one block per cycle with slack (user: "The start play
# instant in ableton if this isnt aligned internally with pipewire we have a window for unders").
# Output in $R/first-TAG: probes.txt (every probe hit in full for the first EVENTS, default 2000000, the whole run at
# about 4,000 a second, then one line per second), profiler.json, live.log, bench/. Then
# profiler/trials/first_buffer_analyze.py. BUFFER=F sets PipeASIO's preferred buffer (PIPEASIO_PREFERRED_BUFFERSIZE).
set -u
TAG=${1:?usage: first-buffer.sh TAG [WORKERS] [SET] [DURATION]}
WORKERS=${2:-2}
SET=${3:-Inbuilts}
DURATION=${4:-30}
EVENTS=${EVENTS:-2000000}
TRIAL=FIRSTBUF
source "$(dirname "${BASH_SOURCE[0]}")/trial-lib.sh"
SO=$HOME/.local/opt/wine-d2d1-nspa-11.13/lib/wine/x86_64-unix/pipeasio64.dll.so
[ -f "$SO" ] || { echo "first-buffer.sh: no $SO"; exit 2; }
export KEPT_LAYOUT=physcore KEPT_WORKERS=$WORKERS ABLETON_MAX_AUDIO_THREADS=$WORKERS PIPEASIO_TELEMETRY=on
campaign_setup
export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6
unset WINE_MMCSS ABLETON_RT
if [ -n "${BUFFER:-}" ]; then export PIPEASIO_PREFERRED_BUFFERSIZE=$BUFFER; fi   # campaign_setup clears it
out=$R/first-$TAG
rm -rf "${out:?}"; mkdir -p "$out"
cat > "$out/probes.bt" <<BT
BEGIN { printf("READY %lu\n", nsecs(monotonic)); @n = 0; }
usdt:$SO:pipeasio:cycle_start {
  @cyc = @cyc + 1; @dur = arg2;
  if (@n < $EVENTS) { printf("CS %lu %d %lu %lu %lu %lu %lu\n", nsecs(monotonic), tid, arg0, arg1, arg2, arg3, arg4); @n = @n + 1; }
}
usdt:$SO:pipeasio:cycle_end {
  @miss = @miss + arg0;
  if (@n < $EVENTS) { printf("CE %lu %d %lu %lu\n", nsecs(monotonic), tid, arg0, arg1); @n = @n + 1; }
}
usdt:$SO:pipeasio:block_start {
  \$now = nsecs(monotonic);
  @blk = @blk + 1; @bdl = arg4;
  if (arg5 & 4) { @mut = @mut + 1; }
  if (arg1 != @dur) { @mism = @mism + 1; }
  \$ph = \$now - arg3;
  if (@phmin == 0 || \$ph < @phmin) { @phmin = \$ph; }
  if (\$ph > @phmax) { @phmax = \$ph; }
  @phsum = @phsum + \$ph;
  if (@n < $EVENTS) { printf("BS %lu %d %lu %lu %lu %lu %lu %lu\n", \$now, tid, arg0, arg1, arg2, arg3, arg4, arg5); @n = @n + 1; }
}
usdt:$SO:pipeasio:block_before_live { if (@n < $EVENTS) { printf("BL %lu %lu\n", nsecs(monotonic), arg0); @n = @n + 1; } }
usdt:$SO:pipeasio:block_after_live { if (@n < $EVENTS) { printf("AL %lu %lu\n", nsecs(monotonic), arg0); @n = @n + 1; } }
usdt:$SO:pipeasio:block_end {
  \$now = nsecs(monotonic);
  if (@bdl > 0 && \$now > @bdl) { @late = @late + 1; }
  if (@n < $EVENTS) { printf("BE %lu %lu %lu %lu\n", \$now, arg0, arg1, arg2); @n = @n + 1; }
}
tracepoint:syscalls:sys_enter_sendto /comm == "python3"/ {
  \$a = str(args.buff, 32);
  if (strncmp(\$a, "/abl/bench/", 11) == 0) { printf("OSC %lu %s\n", nsecs(monotonic), \$a); }
}
interval:s:1 {
  printf("S %lu cycles=%lu blocks=%lu muted=%lu mismatched=%lu late=%lu missed=%lu quantum=%lu phase_ns=%lu/%lu/%lu\n",
         nsecs(monotonic), @cyc, @blk, @mut, @mism, @late, @miss, @dur, @phmin, @blk > 0 ? @phsum / @blk : 0, @phmax);
  @cyc = 0; @blk = 0; @mut = 0; @mism = 0; @late = 0; @miss = 0; @phmin = 0; @phmax = 0; @phsum = 0;
}
BT
log_lines=$(wc -l < "$LOGS/live.log" 2> /dev/null || echo 0)
sudo -n setsid bpftrace -q --no-warnings "$out/probes.bt" > "$out/probes.txt" 2> "$out/probes.err" < /dev/null &
for _ in $(seq 1 120); do grep -q '^READY' "$out/probes.txt" 2> /dev/null && break; sleep 0.25; done
grep -q '^READY' "$out/probes.txt" || { echo "first-buffer.sh: bpftrace did not attach: $(head -c 300 "$out/probes.err")"; exit 1; }
setsid pw-profiler -J -o "$out/profiler.log" > "$out/profiler.json" 2> "$out/profiler.err" < /dev/null &
profiler_pid=$!
profiler/bin/state restore --name golden > /dev/null 2>&1
PIN_LOG=$out/pin.log; : > "$PIN_LOG"
pin_kept & pinner=$!
echo "FIRSTBUF $TAG $(date +%T) workers=$WORKERS set=$SET duration=${DURATION}s buffer=${PIPEASIO_PREFERRED_BUFFERSIZE:-default}"
profiler/bin/bench --tag "first-$TAG" --sets "$SET" --duration "$DURATION" --output "$out/bench" > "$out/bench.log" 2>&1
rc=$?
kill "$pinner" 2> /dev/null; wait "$pinner" 2> /dev/null
kill -INT "$profiler_pid" 2> /dev/null
sudo -n pkill -INT -f "bpftrace -q --no-warnings $out/probes.bt"
sleep 2
tail -n +"$((log_lines + 1))" "$LOGS/live.log" > "$out/live.log" 2> /dev/null
profiler/bin/state restore --name golden > /dev/null 2>&1
echo "FIRSTBUF $TAG $(date +%T) exit=$rc pins=$(grep -c ' pinned ' "$PIN_LOG")"
python3 profiler/trials/first_buffer_analyze.py "$out" | tee "$out/analysis.txt"
echo "FIRSTBUF_DONE $(date +%T)"
