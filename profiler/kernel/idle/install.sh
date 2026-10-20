#!/usr/bin/env bash
# install.sh: install (or, with --remove, remove) the P-cores' every-boot shallow idle on the laptop (kernel-plan.md
# T0031): profiler-shallow-idle into /usr/local/sbin and profiler-shallow-idle.service, enabled and started.
# Run as root from the checkout: sudo profiler/kernel/idle/install.sh [--remove]
# C1E is the other half, turned off by GRUB: profiler/kernel/grub/install-c1e-off.sh.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
die() { echo "idle/install.sh: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo)"
if [ "${1:-}" = --remove ]; then
    systemctl disable --now profiler-shallow-idle.service 2> /dev/null || true
    rm -f /etc/systemd/system/profiler-shallow-idle.service /usr/local/sbin/profiler-shallow-idle
    systemctl daemon-reload
    echo "idle/install.sh: removed (every idle state allowed again)"
    exit 0
fi
install -m 0755 "$here/profiler-shallow-idle" /usr/local/sbin/profiler-shallow-idle
install -m 0644 "$here/profiler-shallow-idle.service" /etc/systemd/system/profiler-shallow-idle.service
systemctl daemon-reload
systemctl enable --now profiler-shallow-idle.service > /dev/null 2>&1 || die "could not enable the service"
systemctl is-active -q profiler-shallow-idle.service || die "the service is not active"
echo "idle/install.sh: installed and enabled"
/usr/local/sbin/profiler-shallow-idle status
