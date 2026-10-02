#!/usr/bin/env python3
"""Install the bundled GLKVM layout typing patch over OpenSSH (stdlib only)."""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

FILES = ('apps/kvmd/api/hid.py', 'keyboard/printer.py')
BACKUP = '/var/lib/asteroidkvm/layout-typing-v1.json'


def hunks(patch):
    result = {}
    current = None
    for line in patch.splitlines(keepends=True):
        if line.startswith('diff --git '):
            current = line.split()[2].removeprefix('a/kvmd/')
            result[current] = []
        elif line.startswith('@@ '):
            result[current].append(['', ''])
        elif line.startswith(('---', '+++', 'index ')):
            continue
        elif current and result[current]:
            if line.startswith((' ', '-')):
                result[current][-1][0] += line[1:]
            if line.startswith((' ', '+')):
                result[current][-1][1] += line[1:]
    if set(result) != set(FILES):
        raise RuntimeError('Unexpected files in bundled patch.')
    return result


def patched(data, changes):
    text = data.decode('utf-8')
    for before, after in changes:
        if text.count(after) == 1 and before not in text:
            continue
        if text.count(before) != 1 or after in text:
            raise RuntimeError('Source does not uniquely match the upstream patch; no files changed.')
        text = text.replace(before, after, 1)
    compile(text, '<patched source>', 'exec')
    return text.encode('utf-8')


def atomic_write(path, data, mode, uid, gid):
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fchown(stream.fileno(), uid, gid)
            os.fchmod(stream.fileno(), mode)
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def encode(data):
    return base64.b64encode(data).decode('ascii')


def decode(data):
    return base64.b64decode(data, validate=True)


def install(package, patch, action, backup):
    """Preflight every file before writes; retain originals across interrupted runs."""
    package = package.resolve()
    changes = hunks(patch)
    current = {}
    metadata = {}
    for name in FILES:
        path = package / name
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(package):
            raise RuntimeError('Expected a regular source file inside the package: ' + str(path))
        current[name] = path.read_bytes()
        metadata[name] = path.stat()
    manifest = None
    if backup.exists():
        manifest = json.loads(backup.read_text())
        if manifest['package'] != str(package) or set(manifest['files']) != set(FILES):
            raise RuntimeError('Backup belongs to a different installation.')
        for name, entry in manifest['files'].items():
            if current[name] not in (decode(entry['before']), decode(entry['after'])):
                raise RuntimeError('Source changed since backup: ' + name + '. Refusing to overwrite it.')
    if action == 'restore':
        if manifest is None:
            raise RuntimeError('No backup found at ' + str(backup))
        desired = {name: decode(entry['before']) for name, entry in manifest['files'].items()}
    else:
        desired = {name: patched(current[name], changes[name]) for name in FILES}
        if manifest:
            for name in FILES:
                if desired[name] != decode(manifest['files'][name]['after']):
                    raise RuntimeError('Backup does not match this patch version.')
    modified = [name for name in FILES if desired[name] != current[name]]
    for name in FILES:
        compile(desired[name], str(package / name), 'exec')
        print(('Would update: ' if name in modified else 'Unchanged: ') + name, flush=True)
    if action == 'check':
        print('Patch is applicable.' if modified else 'Patch is already installed.')
        return
    if not modified:
        print('Already restored.' if action == 'restore' else 'Patch is already installed; no files changed.')
        return
    if manifest is None:
        manifest = {'package': str(package), 'files': {
            name: {'before': encode(current[name]), 'after': encode(desired[name])}
            for name in FILES}}
        backup.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        atomic_write(backup, json.dumps(manifest, indent=2).encode(), 0o600, os.geteuid(), os.getegid())
    # Individual files are replaced atomically. A durable backup allows recovery
    # after power loss between files; a rerun completes the same operation.
    attempted = []
    try:
        for name in modified:
            path = package / name
            if path.read_bytes() != current[name]:
                raise RuntimeError('Source changed during installation: ' + name)
            attempted.append(name)
            info = metadata[name]
            atomic_write(path, desired[name], stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid)
            # Avoid stale timestamp-based bytecode after a same-size restoration.
            for cache in (path.parent / '__pycache__').glob(path.stem + '.*.pyc'):
                cache.unlink()
    except Exception:
        for name in reversed(attempted):
            info = metadata[name]
            atomic_write(package / name, current[name], stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid)
        raise
    print('Restored original files.' if action == 'restore' else 'Patch installed.')
    print('Backup: ' + str(backup))
    print('Restart the KVM daemon before using native typing (see the guide).')


OVERLAY_MARKER = b'# AsteroidKVM layout typing bytecode overlay v1\n'
BYTECODE_BACKUP = '/var/lib/asteroidkvm/layout-typing-bytecode-v1.json'
BYTECODE_PROBE = r'''
import asyncio, importlib, inspect, json, sys
from pathlib import Path
from unittest.mock import AsyncMock, Mock, patch
options = json.loads(sys.stdin.read())
package = Path(options['package'])
sys.path.insert(0, str(package.parent))
printer = importlib.import_module('kvmd.keyboard.printer')
hid = importlib.import_module('kvmd.apps.kvmd.api.hid')
from kvmd.htserver import _get_exposed_ws
from kvmd.plugins.hid import BaseHid
assert inspect.iscoroutinefunction(BaseHid.send_key_events), 'HID emission is not async'
assert {'no_ignore_keys', 'slow'} <= set(inspect.signature(BaseHid.send_key_events).parameters)
# Execute candidate overlays in an isolated process without writing source/cache files.
for module, name in [(printer, 'keyboard/printer.py'), (hid, 'apps/kvmd/api/hid.py')]:
    assert Path(module.__file__).resolve().parent == (package / name).parent, 'Wrong installed package'
    module.__file__ = str(package / name)
    exec(compile(options['overlays'][name], module.__file__, 'exec'), module.__dict__)
assert printer._ch_to_keysym('€') == 0x20AC
assert printer._ch_to_keysym('a') == ord('a')
async def check():
    output = Mock(send_key_events=AsyncMock())
    with patch.object(hid.HidApi, '_HidApi__load_jiggler_schedule', lambda self: None):
        api = hid.HidApi(output, '/usr/share/kvmd/keymaps/de')
    state = await api.get_keymaps()
    assert state['mapped_text'] is True and 'de' in state['keymaps']['available']
    handlers = [item.handler for item in _get_exposed_ws(api) if item.event_type == 'mapped_text']
    assert len(handlers) == 1, 'Expected exactly one mapped_text handler'
    handler = handlers[0]
    for text in 'aAzZäöüÄÖÜß@€[]{}\\|~ ':
        ws = Mock(send_event=AsyncMock())
        output.send_key_events.reset_mock()
        await handler(ws, {'text': text, 'keymap': 'de'})
        ws.send_event.assert_awaited_once_with('mapped_text_result', {'mapped': True, 'text': text})
        output.send_key_events.assert_awaited_once()
        held = set()
        for key, pressed in output.send_key_events.call_args.args[0]:
            if pressed:
                assert key not in held
                held.add(key)
            else:
                assert key in held
                held.remove(key)
        assert not held, 'Unbalanced key sequence'
    for event in [{}, {'text': ''}, {'text': 'ab'}, {'text': '\n'}, {'text': 'a', 'keymap': '../de'}]:
        ws = Mock(send_event=AsyncMock())
        output.send_key_events.reset_mock()
        await handler(ws, event)
        output.send_key_events.assert_not_called()
        ws.send_event.assert_awaited_once_with('mapped_text_result', {'mapped': False, 'reason': 'invalid'})
asyncio.run(check())
print('Device preflight passed: capability, German keymap, Euro, balanced HID sequences, invalid input.')
'''


def verify_bytecode(package, overlays):
    subprocess.run([sys.executable, '-B', '-c', BYTECODE_PROBE],
                   input=json.dumps({'package': str(package), 'overlays': overlays}).encode(),
                   check=True, timeout=45)


def install_bytecode(package, overlays, action, backup):
    package = package.resolve()
    current = {}
    vendor = {}
    for name in FILES:
        path = package / name
        compiled = path.with_suffix('.pyc')
        if (compiled.is_symlink() or not compiled.is_file()
                or not compiled.resolve().is_relative_to(package) or path.is_symlink()):
            raise RuntimeError('Expected original vendor bytecode: ' + str(compiled))
        vendor[name] = hashlib.sha256(compiled.read_bytes()).hexdigest()
        current[name] = path.read_bytes() if path.exists() else None
        if current[name] is not None and not current[name].startswith(OVERLAY_MARKER):
            raise RuntimeError('Refusing to replace existing source: ' + str(path))
    manifest = None
    if backup.exists():
        manifest = json.loads(backup.read_text())
        if manifest['package'] != str(package) or manifest['vendor'] != vendor:
            raise RuntimeError('Vendor bytecode changed since installation; refusing to overwrite firmware changes.')
        if set(manifest['overlays']) != set(FILES):
            raise RuntimeError('Invalid bytecode overlay backup.')
        for name in FILES:
            if current[name] not in (None, manifest['overlays'][name].encode()):
                raise RuntimeError('Overlay changed since installation: ' + name)
    elif any(value is not None for value in current.values()):
        raise RuntimeError('Overlay exists without its backup manifest; refusing to overwrite it.')
    if action == 'restore':
        if manifest is None:
            raise RuntimeError('No bytecode overlay backup found at ' + str(backup))
        desired = dict.fromkeys(FILES)
    else:
        if manifest and manifest['overlays'] != overlays:
            raise RuntimeError('Installed overlays belong to a different installer version; restore first.')
        desired = {name: overlays[name].encode() for name in FILES}
        for name in FILES:
            compile(desired[name], str(package / name), 'exec')
        verify_bytecode(package, overlays)
    modified = [name for name in FILES if desired[name] != current[name]]
    for name in FILES:
        print(('Would update: ' if name in modified else 'Unchanged: ') + name, flush=True)
    if action == 'check':
        print('Bytecode overlays are applicable.' if modified else 'Bytecode overlays are already installed.')
        return
    if not modified:
        print('Already restored.' if action == 'restore' else 'Already installed; no files changed.')
        return
    if manifest is None:
        manifest = {'package': str(package), 'vendor': vendor, 'overlays': overlays}
        backup.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        atomic_write(backup, json.dumps(manifest, indent=2).encode(), 0o600, os.geteuid(), os.getegid())
    attempted = []
    def replace(name, data):
        path = package / name
        if data is None:
            path.unlink(missing_ok=True)
        else:
            info = path.with_suffix('.pyc').stat()
            atomic_write(path, data, stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid)
        for cache in (path.parent / '__pycache__').glob(path.stem + '.*.pyc'):
            cache.unlink()
    try:
        for name in modified:
            path = package / name
            if (path.read_bytes() if path.exists() else None) != current[name]:
                raise RuntimeError('Source changed during installation: ' + name)
            if hashlib.sha256(path.with_suffix('.pyc').read_bytes()).hexdigest() != vendor[name]:
                raise RuntimeError('Vendor bytecode changed during installation: ' + name)
            attempted.append(name)
            replace(name, desired[name])
    except Exception as error:
        failures = []
        for name in reversed(attempted):
            try:
                replace(name, current[name])
            except Exception as rollback_error:
                failures.append(name + ': ' + str(rollback_error))
        if failures:
            raise RuntimeError('Rollback incomplete; rerun or restore using ' + str(backup)
                               + '. ' + '; '.join(failures)) from error
        raise
    print('Vendor bytecode restored.' if action == 'restore' else 'Bytecode overlays installed.')
    print('Original vendor .pyc files are unchanged. Backup manifest: ' + str(backup))
    print('Restart the KVM daemon to activate this change.')


def remote_main(options, patch, overlays):
    import fcntl  # Linux appliance only; the launcher also runs on macOS.
    if os.geteuid() != 0:
        raise RuntimeError('Connect as root; source installation and backups require root access.')
    if options['package_dir']:
        package = Path(options['package_dir']).resolve()
    else:
        spec = importlib.util.find_spec('kvmd')
        if spec is None or not spec.origin:
            raise RuntimeError('Cannot locate kvmd. Supply --package-dir /absolute/path/to/kvmd.')
        package = Path(spec.origin).resolve().parent
    print('Package: ' + str(package), flush=True)
    bytecode = any(not (package / name).exists() or (package / name).read_bytes().startswith(OVERLAY_MARKER)
                   for name in FILES)
    def perform():
        if bytecode:
            install_bytecode(package, overlays, options['action'], Path(BYTECODE_BACKUP))
        else:
            install(package, patch, options['action'], Path(BACKUP))
    if options['action'] == 'check':
        perform()
    else:
        with open('/run/asteroidkvm-layout-typing.lock', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            perform()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', help='Root SSH destination, e.g. root@kvm1.local or an SSH config alias')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--check', action='store_true', help='Read-only source compatibility check')
    mode.add_argument('--restore', action='store_true', help='Restore backed-up source files')
    parser.add_argument('--package-dir', help='Absolute remote kvmd package directory (normally detected)')
    parser.add_argument('--port', type=int, help='SSH port; otherwise use SSH config')
    parser.add_argument('--identity', help='SSH private key path; otherwise use SSH config/agent')
    args = parser.parse_args()
    if args.destination.startswith('-') or any(c.isspace() for c in args.destination):
        parser.error('Invalid SSH destination')
    if args.port is not None and not 1 <= args.port <= 65535:
        parser.error('--port must be between 1 and 65535')
    if args.package_dir and not args.package_dir.startswith('/'):
        parser.error('--package-dir must be absolute')
    script = Path(__file__).resolve()
    patch = (script.parent / 'patches/glkvm-layout-typing.patch').read_text()
    if hashlib.sha256(patch.encode()).hexdigest() != PATCH_SHA256:
        raise RuntimeError('Bundled patch checksum mismatch.')
    overlays = {name: (script.parent / 'patches' / ('bytecode-' + Path(name).name)).read_text()
                for name in FILES}
    options = {'package_dir': args.package_dir,
               'action': 'check' if args.check else 'restore' if args.restore else 'apply'}
    # All variable values travel over stdin, never through the remote shell.
    source = script.read_text().split('\nif __name__ == "__main__":')[0]
    payload = source + '\ntry:\n    remote_main(' + repr(options) + ', ' + repr(patch) + ', ' + repr(overlays) + ')\n'
    payload += 'except Exception as error:\n    print("Patch failed: " + str(error), file=sys.stderr)\n    sys.exit(1)\n'
    command = ['ssh', '-T', '-o', 'ConnectTimeout=45', '-o', 'ServerAliveInterval=10',
               '-o', 'ServerAliveCountMax=3']
    if args.port:
        command += ['-p', str(args.port)]
    if args.identity:
        command += ['-i', args.identity]
    command += ['--', args.destination, 'python3', '-u', '-']
    return subprocess.run(command, input=payload.encode()).returncode


PATCH_SHA256 = 'c0de9e085f739a02c3c8150ca6c5775ee6a7c541f8b40b1f9c1a1b5178504b59'

if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print('Patch failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
