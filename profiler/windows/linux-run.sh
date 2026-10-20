#!/usr/bin/env bash
# linux-run.sh TAG [kept|kept-wN[-bF]|upstream] [TRIAL]: one Linux run on the laptop's Linux side, driven by
# profiler/windows/cross-os-trial.sh on the workstation right after a fresh boot (D0005, D0006 in
# profiler/plans/kernel-plan.md).
# Settles the boot as T0015/T0027 did (the timers that fire after every boot stopped, the desktop session up, 120 s,
# then until the 1-minute load is below 1.0, at most 600 s), then runs the three Sets for 120 s each through
# trial-lib's run_one, adds the history record, and prints one JSON line per Set in profiler/windows/summarise.py's
# format. The configuration:
#   kept      the kept configuration (posix_spawn, PipeASIO realtime, physcore with 5 workers, the new display
#             settings with golden, realtime throttling off; golden holds PipeASIO's 72-frame buffer since
#             2026-10-20, D0018)
#   kept-wN   the same with N workers (1 to 5), one per physical P-core from CPU 2 (kept-w2: CPUs 2 and 4; D0014)
#   kept-wN-bF  and PipeASIO's preferred buffer F frames (PIPEASIO_PREFERRED_BUFFERSIZE; kept-w2-b72: D0018)
#   upstream  upstream's defaults: none of our switches (no posix_spawn, PipeASIO realtime off as shipped), no
#             pinning, the launcher's automatic worker count (15 here), the old display (OpenGL, Live's GPU renderer
#             off: the golden before T0023), realtime throttling as booted. The runtime's own patches (0108-0112)
#             stay inert without their switches. Live at SCHED_RR 10 and the performance power hold are upstream's
#             launcher defaults and stay.
set -u
TAG=${1:?usage: linux-run.sh TAG [kept|kept-wN[-bF]|upstream] [TRIAL]}
CONFIG=${2:-kept}
TRIAL=${3:-D0005}
source "$(dirname "${BASH_SOURCE[0]}")/../trials/trial-lib.sh"
RT_BOOT=$(cat /proc/sys/kernel/sched_rt_runtime_us)
case $CONFIG in
  kept|kept-w[1-5]|kept-w[1-5]-b[1-9]*)
    workers=5 buffer=
    case $CONFIG in kept-w*) workers=${CONFIG#kept-w}; workers=${workers%%-*} ;; esac
    case $CONFIG in *-b*) buffer=${CONFIG##*-b} ;; esac
    export KEPT_LAYOUT=physcore KEPT_WORKERS=$workers KEPT_DISPLAY=new ABLETON_MAX_AUDIO_THREADS=$workers
    arm_env() {   # campaign_setup clears PIPEASIO_PREFERRED_BUFFERSIZE; a -bF configuration sets it per run
      export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6
      if [ -n "$buffer" ]; then export PIPEASIO_PREFERRED_BUFFERSIZE=$buffer; fi
    }
    arm_setup() { :; }
    golden_for() { echo golden; }
    pin_for() { pin_kept; } ;;
  upstream)
    unset KEPT_LAYOUT KEPT_WORKERS KEPT_DISPLAY ABLETON_MAX_AUDIO_THREADS
    arm_env() { unset PIPEASIO_REALTIME WINE_POSIX_SPAWN; }       # campaign_setup exports both
    arm_setup() { sudo -n sysctl -q kernel.sched_rt_runtime_us="$RT_BOOT"; }   # campaign_setup turns throttling off
    golden_for() { echo golden.20261019T153253Z; }
    pin_for() { :; } ;;
  *) echo "usage: linux-run.sh TAG [kept|kept-wN[-bF]|upstream] [TRIAL] (N: 1 to 5; F: frames)" >&2; exit 2 ;;
esac
arm_teardown() { :; }
arm_describe() { echo "linux $CONFIG configuration"; }
arm_record() { echo "boot $(cut -c1-8 /proc/sys/kernel/random/boot_id) uptime $(cut -d' ' -f1 /proc/uptime)s"; }

sudo -n systemctl stop snapper-cleanup.timer systemd-tmpfiles-clean.timer 2>/dev/null
systemctl --user stop arch-update.timer 2>/dev/null
for i in $(seq 1 60); do
  systemctl --user is-active -q graphical-session.target && pgrep -x kwin_wayland >/dev/null \
    && systemctl --user is-active -q pipewire.service && break
  sleep 5
done
t0=$SECONDS; sleep 120
while [ $((SECONDS - t0)) -lt 600 ]; do
  read -r la _ < /proc/loadavg; awk -v l="$la" 'BEGIN { exit !(l < 1.0) }' && break; sleep 5
done
echo "settled: load $(cut -d' ' -f1 /proc/loadavg) after $((SECONDS - t0)) s" >&2

campaign_setup >&2
echo "config $CONFIG; sched_rt_runtime_us at boot $RT_BOOT" >&2
run_one "$TAG" A >&2
echo "sched_rt_runtime_us after the run: $(cat /proc/sys/kernel/sched_rt_runtime_us)" >&2
profiler/bin/history-add "$R/$TAG/bench" --trial "$TRIAL" --arm A >/dev/null 2>&1
python3 - "$R/$TAG/bench" "$CONFIG" <<'PY'
import glob, json, os, sys
sys.path.insert(0, "profiler/trials")
import campaign_tools as ct
bench, config = sys.argv[1], sys.argv[2]
procs = ct.per_set(bench)
try:
    switches = json.load(open(f"{bench}/profile/profile.json"))["configuration"]["benchmark_gates"]
except (OSError, KeyError, ValueError):
    switches = None
for m in sorted(glob.glob(f"{bench}/sets/*/measurement.json")):
    s = m.split("/sets/")[1].split("/")[0].split("-", 1)[1]
    d = json.load(open(m))
    osc = d.get("osc_dsp") or {}
    raw = json.load(open(os.path.join(os.path.dirname(m), "raw", "proc-delta.json")))
    live = ct.live_process(raw)
    th = live.get("threads") or []
    audioc = sum(t.get("cpu_percent_of_one_core") or 0 for t in th if (t.get("comm") or "").startswith("AudioCalc"))
    cb = sum(t.get("cpu_percent_of_one_core") or 0 for t in th if t.get("comm") == "pipeasio-rt")
    print(json.dumps({"os": "linux", "config": config, "set": s, "dsp_average": osc.get("average_percent"),
                      "dsp_peak_median": osc.get("peak_median_percent"), "peaks_over_100": osc.get("peak_over_100_count"),
                      "live_cpu": round(live.get("cpu_percent_of_one_core") or 0, 2), "audiocalc_cpu": round(audioc, 2),
                      "audiocalc_threads": sum(1 for t in th if (t.get("comm") or "").startswith("AudioCalc")),
                      "callback_cpu": round(cb, 2), "audio_total": round(audioc + cb, 2),
                      "pipewire_errors": (((d.get("pipewire") or {}).get("pw_top") or {}).get("err_delta")),
                      "workers": (d.get("live") or {}).get("max_audio_threads_option"), "switches": switches}))
PY
