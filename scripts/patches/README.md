# GLKVM layout typing patch

`glkvm-layout-typing.patch` contains the two runtime file diffs from [GLKVM PR #158](https://github.com/gl-inet/glkvm/pull/158), commit [`e163db84a66ab3e0de0147e0b6d4e7a344baa37c`](https://github.com/gl-inet/glkvm/commit/e163db84a66ab3e0de0147e0b6d4e7a344baa37c), by Yoshi Jäger. The upstream test-file diff and mail headers are omitted; runtime hunks are unchanged. The SSH installer pins the SHA-256 of this local patch.

`Tests/LayoutTypingPatchTests/fixtures/hid.py.txt` and `printer.py.txt` are the upstream files at that commit with these hunks reversed, reproducing the pre-patch source for offline installer tests. Their original copyright notices are retained. These GLKVM/PiKVM sources are licensed under GNU GPL version 3 or later; see [GLKVM-LICENSE](GLKVM-LICENSE), copied from the pinned upstream commit.

See the [installation guide](../../docs/layout-typing-patch.md) for use and recovery.

`bytecode-hid.py` and `bytecode-printer.py` support firmware distributed without Python source. They load the installed vendor `.pyc` modules, then add the PR's mapped-text behavior and Euro normalization. They are adaptations, not copies of the full upstream modules; the HID handler uses explicit `HidApi` private attribute names because it is attached after class creation. The printer wrapper also supports the older vendor implementation without a fallback function. These extensions are GPL-3.0-or-later.
