"""Device/precision regressions for the PR #195 port; no GPU or weights needed."""
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from backend import (OmniParserBackend, detect_device, caption_dtype,
                     SERVICE_VERSION, MPS_PATCH_REVISION)


def torch_stub(cuda=False, mps=False):
    # Deliberately omit torch.mps: detection must use torch.backends.mps.
    return SimpleNamespace(cuda=SimpleNamespace(is_available=lambda: cuda),
        backends=SimpleNamespace(mps=SimpleNamespace(is_available=lambda: mps)),
        float16='fp16', float32='fp32', device=lambda value: value)


class MPSTests(unittest.TestCase):
    def test_auto_uses_cuda_then_mps_then_cpu(self):
        for cuda, mps, expected in ((True, True, 'cuda'), (False, True, 'mps'),
                                    (False, False, 'cpu')):
            with self.subTest(cuda=cuda, mps=mps):
                self.assertEqual(detect_device(torch_stub(cuda, mps)), expected)

    def test_missing_mps_backend_is_supported(self):
        torch = torch_stub()
        del torch.backends.mps
        self.assertEqual(detect_device(torch), 'cpu')
        self.assertEqual(detect_device(torch, 'mps'), 'cpu')

    def test_explicit_device_overrides_automatic_selection(self):
        self.assertEqual(detect_device(torch_stub(True, True), 'cpu'), 'cpu')
        self.assertEqual(detect_device(torch_stub(True, True), 'mps'), 'mps')
        self.assertEqual(detect_device(torch_stub(True, False), 'mps'), 'cpu')
        with self.assertRaises(ValueError):
            detect_device(torch_stub(), 'invalid')

    def test_caption_precision_matches_pr195(self):
        torch = torch_stub()
        for device in ('mps', 'cuda'):
            self.assertEqual(caption_dtype(torch, device), torch.float16)
        self.assertEqual(caption_dtype(torch, 'cpu'), torch.float32)

    def backend(self):
        backend = OmniParserBackend.__new__(OmniParserBackend)
        backend.torch = torch_stub(mps=True)
        backend.detector = SimpleNamespace(model=Mock(), device='cpu')
        backend.caption = Mock()
        backend.fallback = False
        return backend

    def test_moving_to_cpu_restores_full_precision(self):
        backend = self.backend()
        backend._move('mps')
        backend.caption.to.assert_called_with(device='mps', dtype='fp16')
        self.assertEqual(backend.detector.device, 'mps')
        backend._move('cpu')
        backend.caption.to.assert_called_with(device='cpu', dtype='fp32')
        self.assertEqual(backend.detector.device, 'cpu')

    def test_half_precision_failure_recovers_both_models_on_cpu(self):
        backend = self.backend()
        backend.caption.to.side_effect = [RuntimeError('MPS unavailable'), None]
        backend._move('mps')
        backend.caption.to.assert_called_with(device='cpu', dtype='fp32')
        backend.detector.model.to.assert_called_with('cpu')
        self.assertEqual(backend.device, 'cpu')
        self.assertTrue(backend.fallback)

    def test_cpu_move_failure_is_reported(self):
        backend = self.backend()
        backend.caption.to.side_effect = RuntimeError('CPU failure')
        with self.assertRaises(RuntimeError):
            backend._move('cpu')

    def test_install_manifest_identifies_the_ported_revision(self):
        manifest = json.loads((Path(__file__).resolve().parents[1] / 'parser-runtime.json').read_text())
        self.assertEqual(manifest['version'], SERVICE_VERSION)
        self.assertEqual(manifest['mps_patch']['revision'], MPS_PATCH_REVISION)


if __name__ == '__main__':
    unittest.main()
