"""Run after `swift build --product create-edid`; no KVM or network is used."""
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOL = Path(os.environ.get("EDID_TOOL", ROOT / ".build/debug/create-edid"))


class EDIDToolTests(unittest.TestCase):
    def run_tool(self, *args):
        return subprocess.run([str(TOOL), *args], capture_output=True, check=False)

    def validate(self, data):
        self.assertEqual(len(data), 256)
        self.assertEqual(data[:8], bytes.fromhex("00FFFFFFFFFFFF00"))
        self.assertEqual(data[126], 1)
        self.assertEqual(sum(data[:128]) % 256, 0)
        self.assertEqual(sum(data[128:]) % 256, 0)
        self.assertNotIn(b"Asteroid", data)
        self.assertNotIn(b"KVM", data)
        self.assertEqual(data[132:136], bytes([0x23, 9, 7, 7]))

    def test_asus_defaults(self):
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(result.stdout.strip()), 512)
        data = bytes.fromhex(result.stdout.decode())
        self.validate(data)
        self.assertEqual(data[8:18], bytes.fromhex("06B3B22401010101211E"))
        self.assertEqual(data[77:90], b"ASUS Display\n")
        self.assertEqual(data[54:56], struct.pack("<H", 24150))

    def test_modes_and_custom_identity(self):
        for mode, width, height in [("1920x1080", 1920, 1080), ("1920x1200", 1920, 1200), ("2560x1440", 2560, 1440)]:
            result = self.run_tool("--mode", mode, "--name", "ASUS Monitor", "--product", "65535",
                                   "--serial", "0xFEDCBA98", "--week", "0", "--year", "2026")
            self.assertEqual(result.returncode, 0, result.stderr)
            data = bytes.fromhex(result.stdout.decode())
            self.validate(data)
            self.assertEqual(data[77:90], b"ASUS Monitor\n")
            self.assertEqual(data[10:16], bytes.fromhex("FFFF98BADCFE"))
            self.assertEqual(data[16:18], bytes([0, 36]))
            d = data[54:72]
            self.assertEqual(d[2] | (d[4] & 0xF0) << 4, width)
            self.assertEqual(d[5] | (d[7] & 0xF0) << 4, height)

    def test_binary_and_hex_files_never_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            for format in ["hex", "bin"]:
                path = Path(directory) / ("monitor." + format)
                result = self.run_tool("--format", format, "--output", str(path))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, b"")
                original = path.read_bytes()
                self.validate(bytes.fromhex(original.decode()) if format == "hex" else original)
                result = self.run_tool("--name", "Changed", "--output", str(path))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(path.read_bytes(), original)

    def test_invalid_options_produce_no_edid(self):
        invalid = [
            ["--name", "Asteroid KVM is too long"], ["--name", ""], ["--name", "ASUS\nTest"],
            ["--name", "ASÜS"], ["--name", "ASUS "], ["--manufacturer", "AA"], ["--manufacturer", "123"],
            ["--product", "65536"], ["--serial", "4294967296"], ["--week", "55"],
            ["--week", "255"], ["--year", "1989"], ["--year", "2246"], ["--serial", "-1"],
            ["--mode", "4k"], ["--format", "json"], ["--format", "bin"],
            ["--unknown"], ["--name"], ["--name", "--output", "unused.hex"],
            ["--name", "First", "--name", "Second"],
        ]
        for args in invalid:
            with self.subTest(args=args):
                result = self.run_tool(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertTrue(result.stderr.startswith(b"create-edid:"))

    def test_help(self):
        result = self.run_tool("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn(b"ASUS Display", result.stdout)


if __name__ == "__main__":
    unittest.main()
