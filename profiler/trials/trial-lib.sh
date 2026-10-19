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
