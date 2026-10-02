# Install layout-aware typing on a Comet

AsteroidKVM's **Use Native Keyboard Layout** requires the daemon's `mapped_text` capability. This repo includes a Python script that installs the two runtime changes from [GLKVM PR #158](https://github.com/gl-inet/glkvm/pull/158), pinned to commit [`e163db84`](https://github.com/gl-inet/glkvm/commit/e163db84a66ab3e0de0147e0b6d4e7a344baa37c). The patch adds the WebSocket handler and capability flag, plus Euro-sign keysym normalization.

The patch is bundled with the repo; neither the installer nor the KVM downloads code. Repeating installation leaves already-patched files and the original backup unchanged. Physical keyboard input and clipboard paste work without this extension.

## Requirements

- A checkout of this repo, Python 3.9 or later, and OpenSSH on your computer. No pip dependencies.
- Root SSH access to the Comet and Python 3.9 or later on the device. Normal SSH configuration, keys, password prompts, and host-key checks apply.
- A writable GLKVM Python source installation matching the patch's source context. The restart command below requires GL.iNet's `/etc/init.d/S98kvmd` service.

The installer detects `kvmd` using the remote `python3` interpreter. Firmware variants may need `--package-dir /absolute/path/to/kvmd`; choose the package actually used by the daemon. Compatibility is checked against source content, not a firmware version number. Unknown or ambiguous patch contexts are refused before any source writes. Equivalent but differently implemented firmware support may also be refused; if native typing already works, no patch is needed.

## Check, install, and activate

Run these commands from the checkout, replacing `root@kvm1.local` with your device or SSH configuration alias:

```sh
# Read-only: check both source files and report whether changes are needed.
python3 scripts/patch-layout-typing.py --check root@kvm1.local

# Back up and patch the installed source files.
python3 scripts/patch-layout-typing.py root@kvm1.local

# Activate the change and verify the keyboard worker.
./scripts/restart-kvm-keyboard.sh root@kvm1.local
```

The installer changes source files only. **Restart is a separate step and briefly disconnects video, keyboard, and mouse sessions.** Neither command reboots the Comet or the connected computer. Coordinate with anyone using the KVM before restarting, and avoid firmware updates while installing.

After restart, reconnect AsteroidKVM, open **Keyboard**, select the keymap matching the remote OS, and enable **Use Native Keyboard Layout**. The control becomes available when the daemon advertises `mapped_text`. The source check does not verify the running daemon or send keystrokes. If needed, check typing in an empty scratch document on the remote computer.

For a custom SSH port or key:

```sh
python3 scripts/patch-layout-typing.py --port 2222 --identity ~/.ssh/comet root@192.168.1.50
```

For settings shared by the installer and restart helper, use an alias in `~/.ssh/config` with `HostName`, `User root`, `Port`, and `IdentityFile`, and pass that alias to both commands.

## Backups, interrupted runs, and restore

Before writing either file, the installer validates and syntax-checks both results. It stores the exact pre-installation bytes on the Comet at `/var/lib/asteroidkvm/layout-typing-v1.json`, alongside the expected patched bytes. Files retain their owner and permissions; replacement is atomic per file. Installer writes are serialized with a device-side lock.

A repeat run does not duplicate handlers or overwrite backups. A partial installation can be completed by rerunning the same command. Ordinary write failures trigger rollback; power loss between file replacements can leave a partial installation, so reconnect and rerun before restarting the daemon. If SSH disconnects, use `--check` to inspect source state, then rerun installation as needed.

To restore the source state saved by this installer:

```sh
python3 scripts/patch-layout-typing.py --restore root@kvm1.local
./scripts/restart-kvm-keyboard.sh root@kvm1.local
```

Restore is also idempotent. It retains the backup so a repeat restore or later reinstallation remains possible. If the device was already partly patched before the first installation, restore returns to that exact state. If everything was already patched, installation makes no backup and cannot undo someone else's installation.

If a firmware update or manual edit changes either file after backup, the installer refuses to apply or restore over those changes. Do not restore an old backup onto new firmware. Inspect the new installation and archive the old backup before establishing a new baseline. Firmware updates may remove this patch; check again afterward.

## Validation and provenance

Only `kvmd/apps/kvmd/api/hid.py` and `kvmd/keyboard/printer.py` are patched. The bundled [patch](../scripts/patches/glkvm-layout-typing.patch) contains the exact runtime hunks from the pinned upstream commit; the installer verifies its SHA-256 before connecting. The upstream test file is not installed on the appliance.

Offline regression tests cover repeat installation/restoration, partial installation, unchanged backups, incompatible source, later edits, write rollback, and SSH payload construction:

```sh
python3 -m unittest discover -s Tests/LayoutTypingPatchTests -v
```

The patch was verified to reproduce both pinned upstream source files byte-for-byte. Installer tests use local fixtures; installation and activation still need verification on your firmware. Upstream source notices and license information are recorded in [patch provenance](../scripts/patches/README.md).
