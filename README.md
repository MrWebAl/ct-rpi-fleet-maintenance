# ct-rpi-fleet-maintenance

Automatic maintenance for a fleet of Raspberry Pi single-board computers
running [3CX SBC](https://www.3cx.com/), with room to support other
appliances in the future.

The installer configures a Raspberry Pi to keep itself patched and
healthy with no manual intervention, while staying predictable: every
automated action runs in a fixed, quiet, early-morning window instead of
at a random time of day.

## What it does

- **02:30** — refreshes the APT package lists.
- **03:00** — runs `unattended-upgrades`, installing security updates for:
  - Debian
  - Raspberry Pi Foundation packages (firmware, `rpi-eeprom`, etc.)
  - Raspbian (legacy repo, kept for older images)
  - `3cxsbc`, from its stable channel only — the `bookworm-testing`
    channel that the official 3CX installer also configures is never
    picked up automatically.
- **04:00** — reboots the device only if uptime is 15 days or more, and
  only if no `apt`/`dpkg` operation is currently running.

Explicitly **not** done:

- No `full-upgrade` / `dist-upgrade` — only security updates from the
  origins above are installed automatically.
- No automatic reboot triggered directly by `apt`/`unattended-upgrades`;
  reboots only happen through the dedicated 15-day timer, so they are
  never a surprise side effect of a package update.

## Requirements

- Raspberry Pi OS on `arm64`. Running on another architecture only
  prints a warning, it doesn't block the install.
- Root privileges.
- 3CX SBC already installed is not required — if `3cxsbc` isn't present,
  it's simply never a candidate for upgrade.

Nothing in the script hardcodes a specific Debian release: the allowed
origins are matched against `${distro_codename}`, a macro that
`unattended-upgrades` resolves from the running system itself, and the
3CX installer builds its own repo the same dynamic way. So far it has
only been verified end-to-end on Debian 12 "bookworm"; other releases
should work the same way but haven't been tested.

## Installation

Clone the repository on the device and run the installer as root:

```bash
git clone https://github.com/MrWebAl/ct-rpi-fleet-maintenance.git
cd ct-rpi-fleet-maintenance
sudo ./install.sh
```

Or, without cloning:

```bash
curl -fsSL https://raw.githubusercontent.com/MrWebAl/ct-rpi-fleet-maintenance/main/install.sh -o install.sh
sudo bash install.sh
```

The script is idempotent — it can be re-run safely (e.g. after an
update) and will simply reapply its configuration.

At the end of the run it prints a summary and a dry-run of
`unattended-upgrades`, so you can check what it would install on the
next scheduled run.

## What gets installed

| Path | Purpose |
|---|---|
| `/etc/apt/apt.conf.d/20auto-upgrades` | Enables periodic APT list updates and unattended upgrades |
| `/etc/apt/apt.conf.d/80unattended-upgrades-3cx` | Allowed origins: Raspberry Pi Foundation, Raspbian, 3CX (stable) |
| `/etc/apt/apt.conf.d/53unattended-no-reboot` | Disables `unattended-upgrades`' own automatic reboot |
| `/etc/systemd/system/apt-daily.timer.d/override.conf` | Pins the APT list refresh to 02:30 |
| `/etc/systemd/system/apt-daily-upgrade.timer.d/override.conf` | Pins the upgrade run to 03:00 |
| `/usr/local/sbin/ct-rpi-reboot-if-needed.sh` | Reboot-if-uptime->=15-days logic |
| `/etc/systemd/system/ct-rpi-periodic-reboot.service` / `.timer` | Runs the check above daily at 04:00 |

Logs for the periodic reboot check are written to
`/var/log/ct-rpi-periodic-reboot.log`.

## Version

The current version is tracked in [`VERSION`](VERSION) and printed by
the installer at the start and end of the run.
