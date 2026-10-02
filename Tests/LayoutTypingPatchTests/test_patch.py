"""Offline installer tests using source fixtures from GLKVM PR #158's parent."""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/patch-layout-typing.py'
SPEC = importlib.util.spec_from_file_location('patcher', SCRIPT)
patcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(patcher)
PATCH = (ROOT / 'scripts/patches/glkvm-layout-typing.patch').read_text()


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.package = Path(self.temp.name).resolve() / 'kvmd'
        self.backup = Path(self.temp.name) / 'backup/state.json'
        self.original = {}
        for name in patcher.FILES:
            path = self.package / name
            path.parent.mkdir(parents=True, exist_ok=True)
            self.original[name] = (Path(__file__).parent / 'fixtures' / (path.name + '.txt')).read_bytes()
            path.write_bytes(self.original[name])
            path.chmod(0o640)

    def run_action(self, action='apply'):
        with contextlib.redirect_stdout(io.StringIO()):
            patcher.install(self.package, PATCH, action, self.backup)

    def test_check_is_read_only(self):
        self.run_action('check')
        self.assertFalse(self.backup.exists())
        for name, data in self.original.items():
            self.assertEqual((self.package / name).read_bytes(), data)

    def test_apply_repeat_restore_repeat_and_reapply(self):
        self.run_action()
        saved = self.backup.read_bytes()
        first = {name: (self.package / name).stat().st_mtime_ns for name in patcher.FILES}
        self.run_action()
        self.assertEqual(saved, self.backup.read_bytes())
        for name in patcher.FILES:
            self.assertEqual(first[name], (self.package / name).stat().st_mtime_ns)
            self.assertEqual((self.package / name).stat().st_mode & 0o777, 0o640)
        self.run_action('restore')
        self.run_action('restore')
        for name, data in self.original.items():
            self.assertEqual((self.package / name).read_bytes(), data)
        self.run_action()
        self.assertEqual(saved, self.backup.read_bytes())

    def test_unknown_source_aborts_before_any_write(self):
        path = self.package / patcher.FILES[1]
        path.write_text('# incompatible firmware\n')
        with self.assertRaises(RuntimeError):
            self.run_action()
        self.assertFalse(self.backup.exists())
        self.assertEqual((self.package / patcher.FILES[0]).read_bytes(), self.original[patcher.FILES[0]])

    def test_external_edits_are_never_overwritten(self):
        self.run_action()
        path = self.package / patcher.FILES[1]
        changed = path.read_bytes() + b'\n# firmware update\n'
        path.write_bytes(changed)
        for action in ('apply', 'restore', 'check'):
            with self.assertRaises(RuntimeError):
                self.run_action(action)
            self.assertEqual(path.read_bytes(), changed)

    def test_interrupted_install_can_be_completed(self):
        self.run_action()
        path = self.package / patcher.FILES[0]
        expected = path.read_bytes()
        path.write_bytes(self.original[patcher.FILES[0]])
        self.run_action()
        self.assertEqual(path.read_bytes(), expected)

    def test_write_failure_rolls_back(self):
        original_write = patcher.atomic_write
        def fail_second(path, *args):
            if path == self.package / patcher.FILES[1] and args[0] != self.original[patcher.FILES[1]]:
                raise OSError('simulated disk failure')
            return original_write(path, *args)
        with patch.object(patcher, 'atomic_write', side_effect=fail_second):
            with self.assertRaises(OSError):
                self.run_action()
        self.assertTrue(self.backup.exists())
        for name, data in self.original.items():
            self.assertEqual((self.package / name).read_bytes(), data)
        self.run_action()

    def test_already_patched_without_our_backup(self):
        self.run_action()
        self.backup.unlink()
        self.run_action()
        self.assertFalse(self.backup.exists())

    def test_partial_upstream_patch_is_completed(self):
        name = patcher.FILES[0]
        before, after = patcher.hunks(PATCH)[name][0]
        path = self.package / name
        path.write_text(path.read_text().replace(before, after))
        self.run_action()
        self.run_action()

    def test_symlink_is_rejected(self):
        path = self.package / patcher.FILES[0]
        target = Path(self.temp.name) / 'other.py'
        path.rename(target)
        path.symlink_to(target)
        with self.assertRaises(RuntimeError):
            self.run_action()

    def test_launcher_streams_payload_without_shell_interpolation(self):
        package = "/tmp/space and 'quote/$(touch BAD)/kvmd"
        with patch('sys.argv', [str(SCRIPT), 'root@host', '--check', '--package-dir', package]), \
             patch.object(patcher.subprocess, 'run') as run:
            run.return_value.returncode = 0
            self.assertEqual(patcher.main(), 0)
        command = run.call_args.args[0]
        payload = run.call_args.kwargs['input'].decode()
        self.assertEqual(command[-4:], ['root@host', 'python3', '-u', '-'])
        self.assertNotIn(package, command)
        compile(payload, '<ssh payload>', 'exec')
        self.assertIn(repr(package), payload)

    def test_syntax_error_aborts_before_writes(self):
        path = self.package / patcher.FILES[1]
        path.write_bytes(path.read_bytes() + b'\nthis is invalid python!\n')
        with self.assertRaises(SyntaxError):
            self.run_action()
        self.assertFalse(self.backup.exists())
        self.assertEqual((self.package / patcher.FILES[0]).read_bytes(), self.original[patcher.FILES[0]])

    def test_restore_requires_backup(self):
        with self.assertRaisesRegex(RuntimeError, 'No backup'):
            self.run_action('restore')

    def test_interrupted_restore_can_be_completed(self):
        self.run_action()
        (self.package / patcher.FILES[0]).write_bytes(self.original[patcher.FILES[0]])
        self.run_action('restore')
        for name, data in self.original.items():
            self.assertEqual((self.package / name).read_bytes(), data)

    def test_bad_destination_is_rejected(self):
        result = subprocess.run(['python3', str(SCRIPT), '--', '-oProxyCommand=bad'], capture_output=True)
        self.assertEqual(result.returncode, 2)


class BytecodeInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.package = Path(self.temp.name).resolve() / 'kvmd'
        self.backup = Path(self.temp.name) / 'backup.json'
        self.overlays = {name: (ROOT / 'scripts/patches' / ('bytecode-' + Path(name).name)).read_text()
                         for name in patcher.FILES}
        for name in patcher.FILES:
            path = (self.package / name).with_suffix('.pyc')
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'vendor bytecode fixture')
        # Real import/character validation is exercised by the on-device preflight.
        probe = patch.object(patcher, 'verify_bytecode')
        self.probe = probe.start()
        self.addCleanup(probe.stop)

    def run_action(self, action='apply'):
        with contextlib.redirect_stdout(io.StringIO()):
            patcher.install_bytecode(self.package, self.overlays, action, self.backup)

    def test_check_is_read_only(self):
        self.run_action('check')
        self.probe.assert_called_once()
        self.assertFalse(self.backup.exists())
        for name in patcher.FILES:
            self.assertFalse((self.package / name).exists())

    def test_apply_repeat_restore_repeat_and_reapply(self):
        self.run_action()
        backup = self.backup.read_bytes()
        mtimes = {name: (self.package / name).stat().st_mtime_ns for name in patcher.FILES}
        self.run_action()
        for name in patcher.FILES:
            self.assertEqual((self.package / name).stat().st_mtime_ns, mtimes[name])
        self.run_action('restore')
        self.run_action('restore')
        for name in patcher.FILES:
            self.assertFalse((self.package / name).exists())
            self.assertEqual((self.package / name).with_suffix('.pyc').read_bytes(), b'vendor bytecode fixture')
        self.run_action()
        self.assertEqual(self.backup.read_bytes(), backup)

    def test_incompatible_interfaces_prevent_any_write(self):
        self.probe.side_effect = RuntimeError('unsupported firmware')
        with self.assertRaises(RuntimeError):
            self.run_action()
        self.assertFalse(self.backup.exists())
        self.assertFalse(any((self.package / name).exists() for name in patcher.FILES))

    def test_firmware_changes_are_refused(self):
        self.run_action()
        (self.package / patcher.FILES[0]).with_suffix('.pyc').write_bytes(b'new firmware')
        for action in ('apply', 'restore', 'check'):
            with self.assertRaisesRegex(RuntimeError, 'Vendor bytecode changed'):
                self.run_action(action)

    def test_unknown_source_is_not_overwritten(self):
        source = self.package / patcher.FILES[0]
        source.write_text('# third-party source\n')
        with self.assertRaisesRegex(RuntimeError, 'existing source'):
            self.run_action()
        self.assertEqual(source.read_text(), '# third-party source\n')
        self.assertFalse(self.backup.exists())

    def test_partial_install_and_restore_are_recoverable(self):
        self.run_action()
        (self.package / patcher.FILES[1]).unlink()
        self.run_action()
        self.assertTrue((self.package / patcher.FILES[1]).is_file())
        (self.package / patcher.FILES[0]).unlink()
        self.run_action('restore')
        self.assertFalse(any((self.package / name).exists() for name in patcher.FILES))

    def test_write_failure_removes_new_sources(self):
        original = patcher.atomic_write
        def fail_second(path, *args):
            if path == self.package / patcher.FILES[1]:
                raise OSError('disk failure')
            return original(path, *args)
        with patch.object(patcher, 'atomic_write', side_effect=fail_second):
            with self.assertRaises(OSError):
                self.run_action()
        self.assertFalse(any((self.package / name).exists() for name in patcher.FILES))
        self.run_action()

    def test_edited_overlay_and_missing_manifest_are_refused(self):
        self.run_action()
        source = self.package / patcher.FILES[0]
        source.write_bytes(source.read_bytes() + b'\n# edited\n')
        with self.assertRaisesRegex(RuntimeError, 'Overlay changed'):
            self.run_action('restore')
        self.backup.unlink()
        with self.assertRaisesRegex(RuntimeError, 'without its backup'):
            self.run_action()


if __name__ == '__main__':
    unittest.main()
