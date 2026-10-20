#!/usr/bin/env bash
# D0009, C1E and the audio cores' clock (profiler/plans/kernel-plan.md), in the kept configuration.
# Usage: profiler/kernel/clock/d0009.sh       (run like a trial driver, profiler/trials/README.md)
# Four bench runs in one session, A B A B, with clock-capture as the bench's tracer, the three Sets for 120 s each:
#   A  as is (C1E on: MSR_POWER_CTL 0x1FC bit 1, set by the firmware; every idle state allowed)
#   B  C1E off on every CPU (bit 1 cleared through /dev/cpu/N/msr) and C2_ACPI/C3_ACPI off on every P-core CPU
#      (the root helper, as T0028's B): idle audio cores only clock-gate in C1 and keep their voltage and clock
# The saved MSR values and the idle states are restored after each run and on any exit; the MSR resets at reboot
# anyway. Writing the MSR taints the kernel CPU_OUT_OF_SPEC until the next reboot (the msr driver's rule for MSRs it
# does not know). Then the summary (~/.local/share/profiler/runs/d0009.summary.txt), each B run against its A run.
set -u
TRIAL=D0009
source "$(dirname "${BASH_SOURCE[0]}")/../../trials/trial-lib.sh"
C=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export KEPT_LAYOUT=physcore KEPT_WORKERS=5 ABLETON_MAX_AUDIO_THREADS=5
P_CORE_CPUS=$(awk -F- '{ for (i = $1; i <= $2; i++) printf "%d ", i }' /sys/devices/cpu_core/cpus)
SAVED=$R/d0009-power-ctl.saved

msr() {  # save | c1e-off | restore: MSR_POWER_CTL (0x1FC) on every CPU
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
        v = int(v, 16)
        if rw(int(c)) != v:
            rw(int(c), v)
print(f"{verb}: C1E bit per CPU now " + "".join(str((rw(c) >> 1) & 1) for c in cpus))
PY
}
cstates() {  # 0|1: the disable flag of state2 and state3 on every P-core CPU
  local c s
  for c in $P_CORE_CPUS; do
    for s in 2 3; do sudo -n "$HELPER" knob set "cpuidle.$c.$s" "$1" > /dev/null || echo "cpuidle.$c.$s: failed"; done
  done
}
restore_all() { cstates 0; msr restore; }
arm_env() { export WINE_D3D_CONFIG=csmt=0x1,renderer=vulkan WINED3D_PRESENT_SKIP=6; }
arm_setup() { if [ "$1" = B ]; then msr c1e-off; cstates 1; fi; return 0; }
arm_teardown() { restore_all > /dev/null; return 0; }
golden_for() { echo golden; }
pin_for() { pin_kept; }
arm_describe() { if [ "$1" = B ]; then echo "C1E off, C2/C3 off on CPUs $P_CORE_CPUS"; else echo "as is"; fi; }
arm_record() { echo "layout=$KEPT_LAYOUT workers=$KEPT_WORKERS"; }

sudo -n modprobe msr || { echo "D0009: no msr module"; exit 2; }
msr save
trap restore_all EXIT
campaign_setup
traced_one d0009-A1 A Inbuilts,Max4Live,VSTs 120 "$C/clock-capture"
traced_one d0009-B1 B Inbuilts,Max4Live,VSTs 120 "$C/clock-capture"
traced_one d0009-A2 A Inbuilts,Max4Live,VSTs 120 "$C/clock-capture"
traced_one d0009-B2 B Inbuilts,Max4Live,VSTs 120 "$C/clock-capture"
restore_all
echo "after: state2/3 disabled $(cat /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state[23]/disable | sort | uniq -c | tr -s ' \n' ' ')"
profiler/bin/state restore --name golden > /dev/null 2>&1
{ echo "### pair 1"; python3 "$C/clock_summary.py" A1="$R/d0009-A1/bench" B1="$R/d0009-B1/bench"
  echo "### pair 2"; python3 "$C/clock_summary.py" A2="$R/d0009-A2/bench" B2="$R/d0009-B2/bench"; } > "$R/d0009.summary.txt" 2>&1
echo "D0009_DONE $(date +%T)"
