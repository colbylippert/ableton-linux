# trial-lib.sh: shared parts of the headroom campaign drivers (T0021-T0025), sourced by each driver.
# The driver sets TRIAL and defines the arm hooks: arm_env ARM, arm_setup ARM, arm_teardown ARM, pin_for ARM,
# golden_for ARM, arm_describe ARM, arm_record ARM TAG; optional traced_runs. Then it calls campaign_main.
# It lives in profiler/trials/ beside the drivers and tools (T); state (the session lock, *.out) stays in S.
S=~/.local/state/profiler
T=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
R=~/.local/share/profiler/runs
SETS=Inbuilts,Max4Live,VSTs
LOGS=~/.local/state/ableton-wine/logs
P_CPUS=$(cat /sys/devices/cpu_core/cpus)
TOOLS="python3 $T/campaign_tools.py"

set_aff() {  # TASK_DIR CPUS NAME: set the thread's affinity when it differs, and log it
  local allowed= k v
  { while read -r k v; do [ "$k" = Cpus_allowed_list: ] && { allowed=$v; break; }; done < "$1/status"; } 2>/dev/null
  if [ -n "$allowed" ] && [ "$allowed" != "$2" ] && taskset -p -c "$2" "${1##*/}" >/dev/null 2>&1; then
    echo "$(date +%s.%N) pinned ${1##*/} $3 $2" >> "$PIN_LOG"
  fi
}

pin_loop_shared() {  # the kept pinning (T0004): pipeasio-rt and every AudioCalc thread on the P-core CPUs
  local p t name
  while :; do
    for p in $(pgrep -f 'Live 12 Trial.exe'); do
      for t in /proc/$p/task/[0-9]*; do
        { read -r name < "$t/comm"; } 2>/dev/null || continue
        case $name in AudioCalc*|pipeasio-rt) set_aff "$t" "$P_CPUS" "$name" ;; esac
      done
    done
    sleep 1
  done
}

pin_loop_1to1() {  # PIN_RT_CPU, PIN_WORKER_CPUS: pipeasio-rt on its CPU, each AudioCalc thread on a CPU of its own
  local p t tid name cpu used v
  declare -A cpu_of path_of alive
  while :; do
    alive=(); path_of=()
    for p in $(pgrep -f 'Live 12 Trial.exe'); do
      for t in /proc/$p/task/[0-9]*; do
        { read -r name < "$t/comm"; } 2>/dev/null || continue
        tid=${t##*/}
        case $name in
          pipeasio-rt) set_aff "$t" "$PIN_RT_CPU" pipeasio-rt ;;
          AudioCalc*) alive[$tid]=1; path_of[$tid]=$t ;;
        esac
      done
    done
    for tid in "${!cpu_of[@]}"; do [ -n "${alive[$tid]:-}" ] || unset "cpu_of[$tid]"; done
    for tid in $(printf '%s\n' "${!path_of[@]}" | sort -n); do
      if [ -z "${cpu_of[$tid]:-}" ]; then
        for cpu in $PIN_WORKER_CPUS; do
          used=0
          for v in "${cpu_of[@]}"; do [ "$v" = "$cpu" ] && { used=1; break; }; done
          if [ "$used" = 0 ]; then cpu_of[$tid]=$cpu; break; fi
        done
      fi
      set_aff "${path_of[$tid]}" "${cpu_of[$tid]:-$P_CPUS}" AudioCalc   # no free CPU yet: the shared mask
    done
    sleep 1
  done
}

# The kept pinning after T0021/T0022, from KEPT_LAYOUT: shared (T0004: every audio thread on CPUs 0-11),
# 1to1 (T0021: pipeasio-rt on CPU 0, nine workers on CPUs 2-10), physcore (T0022: pipeasio-rt on CPU 0, five workers
# on CPUs 2,4,6,8,10, one audio thread per physical P-core). KEPT_WORKERS sets ABLETON_MAX_AUDIO_THREADS (9 or 5).
pin_kept() {
  case ${KEPT_LAYOUT:-shared} in
    1to1) PIN_RT_CPU=0; PIN_WORKER_CPUS="2 3 4 5 6 7 8 9 10"; pin_loop_1to1 ;;
    physcore) PIN_RT_CPU=0; PIN_WORKER_CPUS="2 4 6 8 10"; pin_loop_1to1 ;;
    *) pin_loop_shared ;;
  esac
}

# RAPL package power, package temperature and the mean P-core clock, every 5 s, for a driver's arm hooks
sampler_start() {  # TSV: epoch, RAPL package energy (uJ), package temp (m°C), mean P-core kHz; every 5 s
  local hw= h
  SAMPLER_FLAG=$S/trial-$TRIAL.sampler.on; touch "$SAMPLER_FLAG"
  for h in /sys/class/hwmon/hwmon*; do [ "$(cat "$h/name")" = coretemp ] && { hw=$h/temp1_input; break; }; done
  : > "$1"
  sudo -n bash -c '
    out=$1; flag=$2; temp=$3; cpus=$4; end=$((SECONDS + 1800))
    while [ -e "$flag" ] && [ $SECONDS -lt $end ]; do
      read -r e < /sys/class/powercap/intel-rapl:0/energy_uj
      read -r t < "$temp"
      s=0; n=0
      for c in $cpus; do read -r f < /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq 2>/dev/null || continue; s=$((s + f)); n=$((n + 1)); done
      echo "$EPOCHREALTIME $e $t $((s / (n ? n : 1)))" >> "$out"
      sleep 5
    done' bash "$1" "$SAMPLER_FLAG" "$hw" "$(seq -s ' ' 0 11)" &
  SAMPLER_PID=$!
}
sampler_stop() { rm -f "$SAMPLER_FLAG"; wait "$SAMPLER_PID" 2>/dev/null; }

power_summary() {
  python3 - "$1" <<'PY'
import statistics, sys
rows = []
for line in open(sys.argv[1]):
    p = line.split()
    if len(p) == 4:
        rows.append((float(p[0]), int(p[1]), int(p[2]), int(p[3])))
w = [(b[1] - a[1]) / (b[0] - a[0]) / 1e6 for a, b in zip(rows, rows[1:]) if b[1] >= a[1] and b[0] > a[0]]
if not w:
    print("power=n/a")
else:
    print("pkg_w_median=%.1f pkg_temp_median=%.0f pkg_temp_max=%.0f pcore_mhz_median=%.0f samples=%d" % (
        statistics.median(w), statistics.median(r[2] for r in rows) / 1000, max(r[2] for r in rows) / 1000,
        statistics.median(r[3] for r in rows) / 1000, len(rows)))
PY
}

# Audio cores kept clear (T0024's B arm, for drivers whose kept configuration includes it; T0024's driver keeps its
# own copy, as run): every movable IRQ on CPUs 12-15 except the Focusrite's xhci controller (CPU 11 for the 1to1
# layout, else CPU 12); system.slice, init.scope and, in the user manager, app.slice, background.slice and every
# session.slice unit except pipewire.service on AllowedCPUs=12-15; the unbound-workqueue cpumask on CPUs 12-15.
# The IRQ affinities before the first clearing are saved once per trial, and cores_clear_off restores them.
cores_clear_on() {
  local d i unit xhci xcpu=12 saved=$R/$TRIAL-irq-affinity.saved units=$R/$TRIAL-units.changed
  [ "${KEPT_LAYOUT:-}" = 1to1 ] && xcpu=11
  xhci=$(awk -F: '/xhci_hcd/ {gsub(/ /, "", $1); print $1; exit}' /proc/interrupts)
  [ -s "$saved" ] || for d in /proc/irq/[0-9]*; do echo "${d##*/} $(cat "$d/smp_affinity_list" 2>/dev/null)"; done > "$saved"
  for d in /proc/irq/[0-9]*; do
    i=${d##*/}
    if [ "$i" = "$xhci" ]; then echo "$xcpu" | sudo -n tee "$d/smp_affinity_list" >/dev/null 2>&1
    else echo 12-15 | sudo -n tee "$d/smp_affinity_list" >/dev/null 2>&1; fi
  done
  : > "$units"
  for unit in system.slice init.scope; do
    sudo -n systemctl set-property --runtime "$unit" AllowedCPUs=12-15 && echo "system $unit" >> "$units"
  done
  for unit in app.slice background.slice $(ls /sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/session.slice | grep -E '\.(service|scope)$' | grep -vx pipewire.service); do
    systemctl --user set-property --runtime "$unit" AllowedCPUs=12-15 2>/dev/null && echo "user $unit" >> "$units"
  done
  echo f000 | sudo -n tee /sys/devices/virtual/workqueue/cpumask >/dev/null
}
cores_clear_off() {
  local i aff kind unit saved=$R/$TRIAL-irq-affinity.saved units=$R/$TRIAL-units.changed
  if [ -s "$saved" ]; then
    while read -r i aff; do [ -n "$aff" ] && echo "$aff" | sudo -n tee "/proc/irq/$i/smp_affinity_list" >/dev/null 2>&1; done < "$saved"
  fi
  if [ -f "$units" ]; then
    while read -r kind unit; do
      if [ "$kind" = system ]; then sudo -n systemctl set-property --runtime "$unit" AllowedCPUs=
      else systemctl --user set-property --runtime "$unit" AllowedCPUs= 2>/dev/null; fi
    done < "$units"
    rm -f "$units"
  fi
  echo ffff | sudo -n tee /sys/devices/virtual/workqueue/cpumask >/dev/null
}

# The audio cores' SMT siblings (CPUs 1, 3, 5, 7, 9, 11) offline or online through the root helper (T0026, K1)
HELPER=/usr/local/sbin/profiler-root-helper
SMT_SIBLINGS="1 3 5 7 9 11"
smt_siblings_off() { local c; for c in $SMT_SIBLINGS; do sudo -n "$HELPER" knob set "cpu-online.$c" 0 >/dev/null || echo "cpu$c: offline failed"; done; }
smt_siblings_on() { local c; for c in $SMT_SIBLINGS; do sudo -n "$HELPER" knob set "cpu-online.$c" 1 >/dev/null || echo "cpu$c: online failed"; done; }

run_one() {  # TAG ARM
  local tag=$1 arm=$2 rc pinner
  profiler/bin/state restore --name "$(golden_for "$arm")" >/dev/null 2>&1
  arm_env "$arm"
  arm_setup "$arm"
  PIN_LOG=$R/$tag.pin.log; : > "$PIN_LOG"
  pin_for "$arm" & pinner=$!
  echo "RUN $tag $(date +%T) $(arm_describe "$arm")"
  profiler/bin/bench --tag "$tag" --sets "$SETS" --duration 120 --output "$R/$tag/bench" > "$R/$tag.bench.log" 2>&1; rc=$?
  kill "$pinner" 2>/dev/null; wait "$pinner" 2>/dev/null
  arm_teardown "$arm"
  echo "RUN $tag $(date +%T) exit=$rc pins=$(grep -c ' pinned ' "$PIN_LOG") $(arm_record "$arm" "$tag")"
  echo "  affinity: $($TOOLS affinity "$R/$tag/bench" 2>&1)"
  echo "  audiocpu: $($TOOLS audiocpu "$R/$tag/bench" 2>&1)"
  return $rc
}

traced_one() {  # TAG ARM SETS DURATION TRACER: one bench run with a d0003 capture as the bench's tracer
  local tag=$1 arm=$2 sets=$3 dur=$4 tracer=$5 rc pinner
  rm -rf "${R:?}/$tag"
  profiler/bin/state restore --name "$(golden_for "$arm")" >/dev/null 2>&1
  arm_env "$arm"
  arm_setup "$arm"
  PIN_LOG=$R/$tag.pin.log; : > "$PIN_LOG"
  pin_for "$arm" & pinner=$!
  ABLETON_BENCH_ROOT_HELPER=/nonexistent/profiler-root-helper ABLETON_BENCH_TRACER=$tracer \
    profiler/bin/bench --tag "$tag" --sets "$sets" --duration "$dur" --trace interface --output "$R/$tag/bench" \
    > "$R/$tag.bench.log" 2>&1; rc=$?
  kill "$pinner" 2>/dev/null; wait "$pinner" 2>/dev/null
  arm_teardown "$arm"
  echo "TRACED $tag $(date +%T) exit=$rc $(arm_record "$arm" "$tag")"
  echo "  affinity: $($TOOLS affinity "$R/$tag/bench" 2>&1)"
}

campaign_setup() {  # the session lock, kernel and runtime checks, the common environment; leaves the shell in the checkout
  exec 9>"$S/live-session.lock"
  flock -w 900 9 || { echo "lock busy"; exit 9; }
  case $(uname -v) in *PREEMPT_RT*) echo "the laptop runs the RT kernel; the campaign runs on the normal kernel"; exit 2 ;; esac
  cd ~/Projects/ableton-linux || exit 1
  grep -q WINE_POSIX_SPAWN ~/.local/opt/wine-d2d1-nspa-11.13/lib/wine/x86_64-unix/ntdll.so || { echo "the official runtime has no 0112"; exit 2; }
  export PIPEASIO_REALTIME=1 WINE_POSIX_SPAWN=1
  unset ABLETON_BENCH_LIVE_WINDOW WINE_APC_FASTPATH WINE_QPC_TSC ABLETON_WINE_ROOT WINED3D_PRESENT_FPS WINED3D_PRESENT_SKIP \
    WINED3D_PRESENT_SKIP_OCCLUDED WINE_REPORTED_REFRESH_RATE PIPEASIO_PREFERRED_BUFFERSIZE WINE_D3D_CONFIG WINED3D_NO_ALT_ENTER_HOOK \
    ABLETON_BENCH_TRACER ABLETON_BENCH_ROOT_HELPER
  sudo -n sysctl -q kernel.sched_rt_runtime_us="$(cat /proc/sys/kernel/sched_rt_period_us)"
  echo "$TRIAL: kernel $(uname -r); sched_rt_runtime_us=$(cat /proc/sys/kernel/sched_rt_runtime_us); checkout $(git log --oneline -1 | cut -c1-72)"
}

campaign_main() {
  campaign_setup
  local i arm tag
  for i in 1 2 3; do
    for arm in A B; do
      tag=trial-$TRIAL-$arm$i
      run_one "$tag" "$arm"
      profiler/bin/history-add "$R/$tag/bench" --trial "$TRIAL" --arm "$arm" >/dev/null 2>&1
    done
  done
  echo "ABAB_DONE $(date +%T)"
  if declare -F traced_runs >/dev/null; then traced_runs; fi
  arm_env A; arm_teardown A
  profiler/bin/state restore --name golden >/dev/null 2>&1
  echo "TRIAL_DONE $(date +%T)"
}
