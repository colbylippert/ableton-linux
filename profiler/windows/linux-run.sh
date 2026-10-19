#!/usr/bin/env bash
# linux-run.sh TAG: one Linux run of the cross-OS comparison (D0005, profiler/plans/kernel-plan.md), on the laptop's
# Linux side, driven by profiler/windows/cross-os-trial.sh on the workstation right after a fresh boot.
# Settles the boot as T0015/T0027 did (the timers that fire after every boot stopped, the desktop session up, 120 s,
# then until the 1-minute load is below 1.0, at most 600 s), then runs the three Sets for 120 s each in the kept
# configuration (posix_spawn, physcore with 5 workers, the new display settings, golden) through trial-lib's run_one,
# adds the history record, and prints one JSON line per Set in profiler/windows/summarise.py's format.
set -u
TAG=${1:?usage: linux-run.sh TAG}
TRIAL=D0005
source "$(dirname "${BASH_SOURCE[0]}")/../trials/trial-lib.sh"
export KEPT_LAYOUT=physcore KEPT_WORKERS=5 KEPT_DISPLAY=new ABLETON_MAX_AUDIO_THREADS=5
arm_env() { export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6; }
arm_setup() { :; }
arm_teardown() { :; }
golden_for() { echo golden; }
pin_for() { pin_kept; }
arm_describe() { echo "linux kept configuration"; }
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
run_one "$TAG" A >&2
profiler/bin/history-add "$R/$TAG/bench" --trial D0005 --arm A >/dev/null 2>&1
python3 - "$R/$TAG/bench" <<'PY'
import glob, json, os, sys
sys.path.insert(0, "profiler/trials")
import campaign_tools as ct
bench = sys.argv[1]
procs = ct.per_set(bench)
for m in sorted(glob.glob(f"{bench}/sets/*/measurement.json")):
    s = m.split("/sets/")[1].split("/")[0].split("-", 1)[1]
    d = json.load(open(m))
    osc = d.get("osc_dsp") or {}
    raw = json.load(open(os.path.join(os.path.dirname(m), "raw", "proc-delta.json")))
    live = ct.live_process(raw)
    th = live.get("threads") or []
    audioc = sum(t.get("cpu_percent_of_one_core") or 0 for t in th if (t.get("comm") or "").startswith("AudioCalc"))
    cb = sum(t.get("cpu_percent_of_one_core") or 0 for t in th if t.get("comm") == "pipeasio-rt")
    print(json.dumps({"os": "linux", "set": s, "dsp_average": osc.get("average_percent"),
                      "dsp_peak_median": osc.get("peak_median_percent"), "peaks_over_100": osc.get("peak_over_100_count"),
                      "live_cpu": round(live.get("cpu_percent_of_one_core") or 0, 2), "audiocalc_cpu": round(audioc, 2),
                      "audiocalc_threads": sum(1 for t in th if (t.get("comm") or "").startswith("AudioCalc")),
                      "callback_cpu": round(cb, 2), "audio_total": round(audioc + cb, 2),
                      "pipewire_errors": (((d.get("pipewire") or {}).get("pw_top") or {}).get("err_delta"))}))
PY
