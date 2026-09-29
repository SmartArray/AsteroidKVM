#!/bin/bash
# Recover a dead keyboard worker on GL.iNet KVM firmware using its SysV service.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/restart-kvm-keyboard.sh [--check] [user@host]

Default destination: root@kvm1.local
Restarts the KVM control daemon and verifies its keyboard worker. This briefly
interrupts video, mouse, and keyboard sessions; it does not reboot either machine.
--check only inspects worker health without restarting anything.

Uses your normal SSH configuration, keys, password prompt, and host-key checks.
Requires root access and /etc/init.d/S98kvmd on the KVM.
USAGE
}

mode=restart
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --check) mode=check; shift ;;
esac
if [[ $# -gt 1 || "${1:-}" == -* ]]; then
  usage >&2
  exit 2
fi
destination=${1:-root@kvm1.local}

if [[ "$mode" == restart ]]; then
  echo "Restarting KVM control on $destination; the KVM session will briefly disconnect."
fi
# No remote command interpolation: the destination is one SSH argument, and mode
# is one of two constants. Do not disable SSH host-key verification.
ssh -T -o ConnectTimeout=45 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
  -- "$destination" python3 -u - "$mode" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import time

SERVICE = Path('/etc/init.d/S98kvmd')


def workers():
    result = []
    for directory in Path('/proc').iterdir():
        if not directory.name.isdigit():
            continue
        try:
            fields = dict(line.split(':', 1) for line in
                          (directory / 'status').read_text().splitlines() if ':' in line)
            name = fields['Name'].strip()
            if not (name.startswith('kvmd/main') or name.startswith('kvmd/hid-keyboa')):
                continue
            hid_open = False
            for fd in (directory / 'fd').iterdir():
                try:
                    hid_open |= os.readlink(fd).startswith('/dev/hidg')
                except FileNotFoundError:
                    pass
            result.append(dict(pid=int(directory.name), parent=int(fields['PPid']),
                               name=name, state=fields['State'].split()[0], hid_open=hid_open))
        except (FileNotFoundError, ProcessLookupError):
            continue  # A process exited during inspection.
    return result


def main_workers(items):
    return [item for item in items if item['name'].startswith('kvmd/main')]


def ready(items):
    mains = main_workers(items)
    keyboards = [item for item in items if item['name'].startswith('kvmd/hid-keyboa')]
    return (len(mains) == 1 and mains[0]['state'] not in ('Z', 'X')
            and len(keyboards) == 1 and keyboards[0]['state'] not in ('Z', 'X')
            and keyboards[0]['parent'] == mains[0]['pid'] and keyboards[0]['hid_open'])


def report(items):
    for item in items:
        print(f"{item['name']}: PID {item['pid']}, state {item['state']}, "
              f"USB HID open: {item['hid_open']}")
    if not items:
        print('No KVM control or keyboard worker found.')
    for state in Path('/sys/class/udc').glob('*/state'):
        print(f'USB controller {state.parent.name}: {state.read_text().strip()}')


def wait_until(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(1)
    return False


def main():
    if os.geteuid() != 0:
        raise RuntimeError('Log in as root to inspect and restart the KVM service.')
    if sys.argv[1] == 'check':
        items = workers()
        report(items)
        return 0 if ready(items) else 1
    if not SERVICE.is_file() or not os.access(SERVICE, os.X_OK):
        raise RuntimeError(f'Unsupported firmware: executable {SERVICE} not found.')

    report(workers())
    # The vendor restart action does not wait for the previous daemon to exit.
    # Stop and wait explicitly so a slow shutdown cannot create duplicate daemons.
    # Our remote command line is only "python3 -u - restart", so the vendor's
    # pgrep -f kvmd/main cannot accidentally match this recovery process.
    subprocess.run([str(SERVICE), 'stop'], check=True, timeout=20)
    if not wait_until(lambda: not main_workers(workers()), 20):
        raise RuntimeError('Previous daemon did not exit; refusing to start a duplicate.')
    subprocess.run([str(SERVICE), 'start'], check=True, timeout=20)
    if not wait_until(lambda: ready(workers()), 30):
        report(workers())
        raise RuntimeError('Keyboard worker did not become ready. Inspect logread on the KVM.')
    time.sleep(2)
    items = workers()
    report(items)
    if not ready(items):
        raise RuntimeError('Keyboard worker exited again. Inspect logread on the KVM.')
    print('Keyboard worker is running with its USB HID device open. Try typing in AsteroidKVM.')
    print('This recovers the worker; it does not fix the firmware timeout that stopped it.')
    return 0


try:
    sys.exit(main())
except (OSError, RuntimeError, subprocess.SubprocessError) as error:
    print(f'Recovery failed: {error}', file=sys.stderr)
    sys.exit(1)
PY
