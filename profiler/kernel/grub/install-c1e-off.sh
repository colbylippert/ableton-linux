#!/usr/bin/env bash
# install-c1e-off.sh: install (or, with --remove, remove) C1E off for every boot of the laptop (01_profiler-c1e-off,
# kernel-plan.md T0031, D0010). Run as root from the checkout: sudo profiler/kernel/grub/install-c1e-off.sh [--remove]
# It installs 01_profiler-c1e-off into /etc/grub.d/ (and removes D0010's per-entry 46_profiler-c1e-off), regenerates
# grub.cfg, and checks that the block is there once, before the first menu entry, that grub-script-check accepts the
# file and that the saved default is unchanged. One boot with C1E on: grub-editenv - set profiler_c1e=on (unset after).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cfg=/boot/grub/grub.cfg
die() { echo "install-c1e-off.sh: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo)"
saved_before=$(grub-editenv list 2>/dev/null | sed -n 's/^saved_entry=//p')
rm -f /etc/grub.d/46_profiler-c1e-off /etc/default/profiler-grub-windows-template

if [ "${1:-}" = --remove ]; then
    rm -f /etc/grub.d/01_profiler-c1e-off
    grub-mkconfig -o "$cfg" > /dev/null 2>&1 || die "grub-mkconfig failed"
    ! grep -q 'wrmsr 0x1fc' "$cfg" || die "a C1E write is still in $cfg"
    echo "install-c1e-off.sh: removed; saved default: ${saved_before:-none}"
    exit 0
fi

install -m 0755 "$here/01_profiler-c1e-off" /etc/grub.d/01_profiler-c1e-off
grub-mkconfig -o "$cfg" > /dev/null 2>&1 || die "grub-mkconfig failed"
grub-script-check "$cfg" || die "grub-script-check found an error in $cfg"
[ "$(grep -c 'wrmsr 0x1fc' "$cfg")" = 1 ] || die "expected exactly one C1E write in $cfg"
awk '/^# profiler \(01_profiler-c1e-off\)/ { block = NR } /^menuentry / && !first { first = NR }
     END { exit !(block && first && block < first) }' "$cfg" || die "the C1E block is not before the first menu entry"
saved_after=$(grub-editenv list 2>/dev/null | sed -n 's/^saved_entry=//p')
[ "$saved_before" = "$saved_after" ] || die "the saved default changed: '$saved_before' -> '$saved_after'"
echo "install-c1e-off.sh: installed (every boot, before the menu); saved default unchanged: ${saved_after:-none}"
grub-editenv list 2>/dev/null | grep '^profiler_c1e=' || echo "install-c1e-off.sh: profiler_c1e unset, so C1E is off on every boot"
