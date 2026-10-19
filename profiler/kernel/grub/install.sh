#!/usr/bin/env bash
# install.sh: install (or, with --remove, remove) the profiler's GRUB boot variants on the laptop (kernel-plan.md I0).
# Run as root from the checkout: sudo profiler/kernel/grub/install.sh [--remove]
# It saves the normal linux-cachyos entry of /boot/grub/grub.cfg as the template (without savedefault), installs
# variants as /etc/default/profiler-grub-variants and 45_profiler-variants into /etc/grub.d/, regenerates grub.cfg and
# checks that every variant's entry is there and that the saved default is unchanged. GRUB_DEFAULT is never touched.
# Re-run it after editing variants or the kernel command line in /etc/default/grub.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
cfg=/boot/grub/grub.cfg
template=/etc/default/profiler-grub-template
die() { echo "install.sh: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo)"
saved_before=$(grub-editenv list 2>/dev/null | sed -n 's/^saved_entry=//p')

if [ "${1:-}" = --remove ]; then
    rm -f /etc/grub.d/45_profiler-variants /etc/default/profiler-grub-variants "$template"
    grub-mkconfig -o "$cfg" >/dev/null 2>&1 || die "grub-mkconfig failed"
    ! grep -q "(profiler: " "$cfg" || die "profiler entries are still in $cfg"
    echo "install.sh: removed; saved default: ${saved_before:-none}"
    exit 0
fi

while IFS='|' read -r name args; do
    case $name in ''|'#'*) continue ;; esac
    [[ "$name" =~ ^[a-z][a-z0-9-]{0,40}$ ]] || die "bad variant name '$name'"
    [[ "$args" =~ ^[A-Za-z0-9_.,=:\ -]+$ ]] || die "variant $name: arguments may hold letters, digits and _ . , = : - only"
done < "$here/variants"

title=$(grep -oE "^menuentry '[^']*with Linux linux-cachyos'" "$cfg" | head -n 1 | cut -d"'" -f2)
[ -n "$title" ] || die "no normal linux-cachyos entry in $cfg"
body=$(awk -v t="menuentry '$title'" 'index($0, t) == 1 { on = 1; next } on && /^}/ { exit } on' "$cfg" |
       grep -v '^[[:space:]]*savedefault')
grep -q '^[[:space:]]*linux[[:space:]]' <<<"$body" || die "the normal entry has no linux line"
grep -q '^[[:space:]]*initrd[[:space:]]' <<<"$body" || die "the normal entry has no initrd line"
printf 'title=%s\n%s\n' "$title" "$body" > "$template"
install -m 0644 "$here/variants" /etc/default/profiler-grub-variants
install -m 0755 "$here/45_profiler-variants" /etc/grub.d/45_profiler-variants
grub-mkconfig -o "$cfg" >/dev/null 2>&1 || die "grub-mkconfig failed"
while IFS='|' read -r name args; do
    case $name in ''|'#'*) continue ;; esac
    grep -qF "menuentry '$title (profiler: $name)'" "$cfg" || die "no entry for $name in $cfg"
    awk -v t="menuentry '$title (profiler: $name)'" 'index($0, t) == 1 { on = 1; next } on && /^}/ { exit } on' "$cfg" |
        grep -q "^[[:space:]]*linux[[:space:]].* $args\$" || die "the $name entry's linux line lacks '$args'"
    echo "install.sh: entry: $title (profiler: $name)"
done < "$here/variants"
saved_after=$(grub-editenv list 2>/dev/null | sed -n 's/^saved_entry=//p')
[ "$saved_before" = "$saved_after" ] || die "the saved default changed: '$saved_before' -> '$saved_after'"
echo "install.sh: installed; saved default unchanged: ${saved_after:-none}"
