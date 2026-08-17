#!/bin/bash
set -euo pipefail

# ============================================================
# ct-rpi-fleet-maintenance
#
# Automatic maintenance for Raspberry Pi
#
# - APT package list update       -> 02:30
# - unattended-upgrades           -> 03:00
# - 3cxsbc automatic update
# - reboot if uptime >= 15 days  -> 04:00
#
# No full-upgrade/dist-upgrade
# No automatic reboot by apt
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo "1.0.0")"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this script must be run as root."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo
echo "============================================================"
echo " ct-rpi-fleet-maintenance ${VERSION}"
echo "============================================================"
echo

# ------------------------------------------------------------
# Prevent concurrent installer executions
# ------------------------------------------------------------

exec 9>/var/run/ct-rpi-fleet-maintenance.lock

if ! flock -n 9; then
    echo "Another installation is already running."
    exit 1
fi

# ------------------------------------------------------------
# Architecture
# ------------------------------------------------------------

ARCH="$(dpkg --print-architecture)"

echo "Architecture: ${ARCH}"

if [ "${ARCH}" != "arm64" ]; then
    echo "WARNING: expected arm64, detected ${ARCH}"
fi

# ------------------------------------------------------------
# APT
# ------------------------------------------------------------

echo
echo "==> Updating APT package lists"

apt-get update

echo
echo "==> Installing unattended-upgrades"

apt-get install -y \
    unattended-upgrades \
    apt-listchanges

# ------------------------------------------------------------
# Automatic updates
# ------------------------------------------------------------

echo
echo "==> Configuring automatic updates"

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# ------------------------------------------------------------
# Allowed origins
#
# NOTE: Unattended-Upgrade::Package-Whitelist is NOT used here.
# Once that list is non-empty, unattended-upgrades restricts
# ALL automatic upgrades to only the whitelisted packages,
# silently disabling regular security updates.
#
# Debian's own origin/label lines are already enabled by default
# in 50unattended-upgrades. This file adds the origins needed for
# a Raspberry Pi running 3cxsbc: Raspberry Pi Foundation, Raspbian,
# and 3CX (stable channel only - matched by codename, so the
# bookworm-testing repo that the 3CX installer also configures is
# never picked up here, in addition to its own low pin priority).
# ------------------------------------------------------------

echo
echo "==> Removing legacy 3cxsbc whitelist config (if present)"

rm -f /etc/apt/apt.conf.d/52unattended-upgrades-3cx

echo
echo "==> Configuring additional allowed origins (Raspberry Pi, 3cxsbc)"

cat > /etc/apt/apt.conf.d/80unattended-upgrades-3cx <<'EOF'
Unattended-Upgrade::Origins-Pattern {
        // Raspberry Pi Foundation packages.
        // No archive/suite constraint: archive.raspberrypi.com's Release
        // file reports Suite: oldstable even for the current release, so
        // matching on origin+codename only is what actually works.
        "origin=Raspberry Pi Foundation,codename=${distro_codename}";

        // Raspbian packages (legacy repo, not present on current
        // Raspberry Pi OS images, kept for older installs)
        "origin=Raspbian,codename=${distro_codename}";

        // 3cxsbc (stable channel only, not bookworm-testing)
        "origin=3CX,label=3CX,codename=${distro_codename}";
};
EOF

# ------------------------------------------------------------
# Disable APT automatic reboot
# Reboot is handled by our own timer.
# ------------------------------------------------------------

echo
echo "==> Disabling unattended-upgrades automatic reboot"

cat > /etc/apt/apt.conf.d/53unattended-no-reboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF

# ------------------------------------------------------------
# apt-daily
# ------------------------------------------------------------

echo
echo "==> Scheduling APT update at 02:30"

mkdir -p /etc/systemd/system/apt-daily.timer.d

cat > /etc/systemd/system/apt-daily.timer.d/override.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 02:30:00
RandomizedDelaySec=15m
Persistent=true
EOF

# ------------------------------------------------------------
# apt-daily-upgrade
# ------------------------------------------------------------

echo
echo "==> Scheduling unattended-upgrades at 03:00"

mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d

cat > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=30m
Persistent=true
EOF

# ------------------------------------------------------------
# Periodic reboot script
# ------------------------------------------------------------

echo
echo "==> Installing periodic reboot script"

cat > /usr/local/sbin/ct-rpi-reboot-if-needed.sh <<'EOF'
#!/bin/bash

set -u

LOG="/var/log/ct-rpi-periodic-reboot.log"

log()
{
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

UPTIME_SECONDS=$(awk '{print int($1)}' /proc/uptime)
FIFTEEN_DAYS=$((15 * 24 * 60 * 60))

if [ "$UPTIME_SECONDS" -lt "$FIFTEEN_DAYS" ]; then
    DAYS=$((UPTIME_SECONDS / 86400))
    log "No reboot required. Uptime: ${DAYS} days."
    exit 0
fi

# Never reboot while package management is active.

if pgrep -x apt-get >/dev/null 2>&1 ||
   pgrep -x apt >/dev/null 2>&1 ||
   pgrep -x dpkg >/dev/null 2>&1 ||
   pgrep -x unattended-upgrade >/dev/null 2>&1; then

    log "Reboot skipped: package manager is running."
    exit 0
fi

# Check common APT locks.

for LOCK in \
    /var/lib/dpkg/lock \
    /var/lib/dpkg/lock-frontend \
    /var/lib/apt/lists/lock \
    /var/cache/apt/archives/lock
do
    if [ -e "$LOCK" ] && fuser "$LOCK" >/dev/null 2>&1; then
        log "Reboot skipped: lock in use: $LOCK"
        exit 0
    fi
done

DAYS=$((UPTIME_SECONDS / 86400))

log "Rebooting system. Uptime: ${DAYS} days."

/sbin/shutdown -r now "Scheduled reboot: uptime >= 15 days"

EOF

chmod 755 /usr/local/sbin/ct-rpi-reboot-if-needed.sh

# ------------------------------------------------------------
# Periodic reboot service
# ------------------------------------------------------------

echo
echo "==> Installing periodic reboot service"

cat > /etc/systemd/system/ct-rpi-periodic-reboot.service <<'EOF'
[Unit]
Description=Reboot Raspberry Pi if uptime is 15 days or more
After=apt-daily-upgrade.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ct-rpi-reboot-if-needed.sh
EOF

# ------------------------------------------------------------
# Periodic reboot timer
# ------------------------------------------------------------

cat > /etc/systemd/system/ct-rpi-periodic-reboot.timer <<'EOF'
[Unit]
Description=Daily check for 15-day reboot

[Timer]
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF

# ------------------------------------------------------------
# Reload systemd
# ------------------------------------------------------------

echo
echo "==> Reloading systemd"

systemctl daemon-reload

# ------------------------------------------------------------
# Enable timers
# ------------------------------------------------------------

echo
echo "==> Enabling timers"

systemctl enable --now apt-daily.timer
systemctl enable --now apt-daily-upgrade.timer
systemctl enable --now ct-rpi-periodic-reboot.timer

# ------------------------------------------------------------
# Status
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Timers"
echo "============================================================"

systemctl list-timers \
    apt-daily.timer \
    apt-daily-upgrade.timer \
    ct-rpi-periodic-reboot.timer \
    --no-pager

# ------------------------------------------------------------
# 3CX status
# ------------------------------------------------------------

echo
echo "============================================================"
echo " 3cxsbc"
echo "============================================================"

apt-cache policy 3cxsbc || true

# ------------------------------------------------------------
# Dry run
# ------------------------------------------------------------

echo
echo "============================================================"
echo " unattended-upgrades dry-run"
echo "============================================================"

unattended-upgrade --dry-run --debug || true

# ------------------------------------------------------------
# Done
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Installation completed"
echo "============================================================"
echo
echo "Version:             ${VERSION}"
echo "APT update:          02:30 (+15m random)"
echo "unattended-upgrade:  03:00 (+30m random)"
echo "3cxsbc (stable):     via unattended-upgrade at 03:00"
echo "full-upgrade:        disabled"
echo "automatic reboot:    every 15 days, around 04:00"
echo