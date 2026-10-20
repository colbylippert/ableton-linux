#!/usr/bin/env bash
# Trial T0031: shallow idle on the audio cores: C1E off on every CPU and C2/C3 off on the P-cores (from D0009;
# pre-registered in profiler/plans/kernel-plan.md).
# Usage: KEPT_LAYOUT=physcore KEPT_WORKERS=5 KEPT_DISPLAY=new profiler/trials/trial-T0031.sh
# A: as is (C1E on, as the firmware sets it; every idle state allowed). B, applied before and undone after each B run:
# C1E off on every CPU (MSR_POWER_CTL 0x1FC bit 1 cleared through /dev/cpu/N/msr, the saved values written back
# after) and C2_ACPI/C3_ACPI (state2, state3) disabled on every P-core CPU through the root helper (T0028's B).
# Writing the MSR taints the kernel CPU_OUT_OF_SPEC until the next reboot (the msr driver's rule for MSRs it does not
# know); the MSR itself resets at reboot.
# Rule D (G4: audio-thread CPU at most +5 %). Mechanism: every CPU's C1E bit reads 0 and the audio CPUs' state2/state3
# entries do not move during each B run (1 and moving during A runs). Reported: package power and temperature.
set -u
TRIAL=T0031
source "$(dirname "${BASH_SOURCE[0]}")/trial-lib.sh"
: "${KEPT_LAYOUT:?}" "${KEPT_WORKERS:?}" "${KEPT_DISPLAY:?}"
[ "$KEPT_LAYOUT" = physcore ] || { echo "T0031 needs KEPT_LAYOUT=physcore"; exit 2; }
export ABLETON_MAX_AUDIO_THREADS=$KEPT_WORKERS
AUDIO_CPUS="0 2 4 6 8 10"
LIMIT_CPUS=$(awk -F- '{ for (i = $1; i <= $2; i++) printf "%d ", i }' /sys/devices/cpu_core/cpus)
SAVED=$R/T0031-power-ctl.saved

msr() {  # save | c1e-off | restore | bits: MSR_POWER_CTL (0x1FC) on every CPU; prints the C1E bit per CPU
  sudo -n python3 - "$1" "$SAVED" <<'PY'
import glob, os, struct, sys
verb, saved = sys.argv[1], sys.argv[2]
REG = 0x1FC
cpus = sorted(int(p.split("/")[3]) for p in glob.glob("/dev/cpu/[0-9]*/msr"))
def rw(cpu, value=None):
    fd = os.open(f"/dev/cpu/{cpu}/msr", os.O_RDWR)
    try:
        if value is not None:
            os.pwrite(fd, struct.pack("<Q", value), REG)
        return struct.unpack("<Q", os.pread(fd, 8, REG))[0]
    finally:
        os.close(fd)
if verb == "save":
    with open(saved, "w") as f:
        for c in cpus:
            f.write(f"{c} {rw(c):#x}\n")
elif verb == "c1e-off":
    for c in cpus:
        v = rw(c)
        if v & 2:
            rw(c, v & ~2)
elif verb == "restore":
    for line in open(saved):
        c, v = line.split()
        if rw(int(c)) != int(v, 16):
            rw(int(c), int(v, 16))
print("".join(str((rw(c) >> 1) & 1) for c in cpus))
PY
}
cstates() {  # 0|1: the disable flag of state2 and state3 on LIMIT_CPUS
  local c s
  for c in $LIMIT_CPUS; do
    for s in 2 3; do sudo -n "$HELPER" knob set "cpuidle.$c.$s" "$1" > /dev/null || echo "cpuidle.$c.$s: failed"; done
  done
}
deep_usage() {  # the audio CPUs' state2 + state3 entries so far
  local c n=0
  for c in $AUDIO_CPUS; do
    n=$((n + $(cat /sys/devices/system/cpu/cpu$c/cpuidle/state2/usage) + $(cat /sys/devices/system/cpu/cpu$c/cpuidle/state3/usage)))
  done
  echo $n
}
arm_env() {
  if [ "$KEPT_DISPLAY" = new ]; then export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6
  else unset WINE_D3D_CONFIG WINED3D_PRESENT_SKIP; fi
}
arm_setup() {  # $tag: run_one's
  if [ "$1" = B ]; then msr c1e-off > /dev/null; cstates 1; fi
  D0=$(deep_usage)
  sampler_start "$R/$tag.power.tsv"
}
arm_teardown() {
  sampler_stop
  DEEP=$(( $(deep_usage) - D0 ))
  C1E=$(msr bits)          # what was in force during the run, read before the restore
  cstates 0
  msr restore > /dev/null
  return 0
}
golden_for() { echo golden; }
pin_for() { pin_kept; }
arm_describe() { if [ "$1" = B ]; then echo "C1E off, C2/C3 off on $LIMIT_CPUS"; else echo "as is"; fi; }
arm_record() { echo "c1e=$C1E audio_c2c3_entries=$DEEP $(power_summary "$R/$2.power.tsv")"; }

sudo -n modprobe msr || { echo "T0031: no msr module"; exit 2; }
msr save > /dev/null
trap 'cstates 0; msr restore > /dev/null' EXIT
campaign_main
