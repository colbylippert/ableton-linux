#!/usr/bin/env bash
# install-c1e-off.sh: install (or, with --remove, remove) the C1E-off boot entries on the laptop (46_profiler-c1e-off,
# kernel-plan.md T0031). Run as root from the checkout: sudo profiler/kernel/grub/install-c1e-off.sh [--remove]
# It saves the os-prober Windows entry of /boot/grub/grub.cfg as the Windows template, installs 46_profiler-c1e-off
# into /etc/grub.d/, regenerates grub.cfg, and checks the entries, the file's syntax (grub-script-check) and that the
# saved default is unchanged. The Linux entry uses install.sh's template; run install.sh first for it.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cfg=/boot/grub/grub.cfg
win=/etc/default/profiler-grub-windows-template
die() { echo "install-c1e-off.sh: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo)"
saved_before=$(grub-editenv list 2>/dev/null | sed -n 's/^saved_entry=//p')

if [ "${1:-}" = --remove ]; then
    rm -f /etc/grub.d/46_profiler-c1e-off "$win"
    grub-mkconfig -o "$cfg" > /dev/null 2>&1 || die "grub-mkconfig failed"
    ! grep -qE "C1E off \(profiler\)|\(profiler: c1e-off\)" "$cfg" || die "C1E-off entries are still in $cfg"
    echo "install-c1e-off.sh: removed; saved default: ${saved_before:-none}"
    exit 0
fi

# regenerate first, so the template is the current os-prober entry
rm -f /etc/grub.d/46_profiler-c1e-off
grub-mkconfig -o "$cfg" > /dev/null 2>&1 || die "grub-mkconfig failed"
title=$(grep -oE "^menuentry 'Windows Boot Manager[^']*'" "$cfg" | head -n 1 | cut -d"'" -f2)
[ -n "$title" ] || die "no Windows Boot Manager entry in $cfg (os-prober)"
body=$(awk -v t="menuentry '$title'" 'index($0, t) == 1 { on = 1; next } on && /^}/ { exit } on' "$cfg")
grep -q '^[[:space:]]*chainloader[[:space:]]' <<<"$body" || die "the Windows entry has no chainloader line"
printf 'title=%s\n%s\n' "$title" "$body" > "$win"
[ -r /etc/default/profiler-grub-template ] || echo "install-c1e-off.sh: no Linux template (install.sh); the Windows entry only"
install -m 0755 "$here/46_profiler-c1e-off" /etc/grub.d/46_profiler-c1e-off
grub-mkconfig -o "$cfg" > /dev/null 2>&1 || die "grub-mkconfig failed"
grub-script-check "$cfg" || die "grub-script-check found an error in $cfg"
for entry in "Windows Boot Manager, C1E off (profiler)" \
             "$(sed -n '1s/^title=//p' /etc/default/profiler-grub-template 2>/dev/null) (profiler: c1e-off)"; do
    case $entry in " (profiler: c1e-off)") continue ;; esac
    awk -v t="menuentry '$entry'" 'index($0, t) == 1 { on = 1; next } on && /^}/ { exit } on' "$cfg" |
        grep -q '^[[:space:]]*wrmsr 0x1fc ' || die "no C1E-off entry '$entry' with its wrmsr in $cfg"
    echo "install-c1e-off.sh: entry: $entry"
done
saved_after=$(grub-editenv list 2>/dev/null | sed -n 's/^saved_entry=//p')
[ "$saved_before" = "$saved_after" ] || die "the saved default changed: '$saved_before' -> '$saved_after'"
echo "install-c1e-off.sh: installed; saved default unchanged: ${saved_after:-none}"
