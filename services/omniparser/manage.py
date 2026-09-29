#!/usr/bin/env python3
"""Explicit per-user launchd management for the independently managed local parser."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys

LABEL = "app.asteroidkvm.omniparser"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("install", "stop", "restart", "status"))
    parser.add_argument("--model-root", type=Path)
    parser.add_argument("--port", type=int, default=9120)
    parser.add_argument("--device", choices=("auto", "mps", "cpu"), default="auto")
    args = parser.parse_args()
    domain = f"gui/{os.getuid()}"
    path = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
    if args.action == "install":
        if not args.model_root or not 1024 <= args.port <= 65535:
            parser.error("install requires --model-root and a valid port")
        root = args.model_root.expanduser().resolve()
        if not (root / "manifest.json").is_file() or not (root / "service.token").is_file():
            parser.error("Run setup.py --download-models first")
        config = {"Label": LABEL, "ProgramArguments": [sys.executable, str(Path(__file__).with_name("server.py").resolve()),
                  "--model-root", str(root), "--token-file", str(root / "service.token"), "--port", str(args.port), "--device", args.device],
                  "RunAtLoad": True, "KeepAlive": {"SuccessfulExit": False}, "ThrottleInterval": 30,
                  "StandardOutPath": str(root / "service.log"), "StandardErrorPath": str(root / "service.log")}
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            subprocess.run(["launchctl", "bootout", domain, str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        path.write_bytes(plistlib.dumps(config))
        path.chmod(0o600)
        subprocess.run(["launchctl", "bootstrap", domain, str(path)], check=True)
        print("Installed local parser launch agent. It runs independently of AsteroidKVM.")
    elif args.action == "stop":
        subprocess.run(["launchctl", "bootout", domain, str(path)], check=True)
    elif args.action == "restart":
        subprocess.run(["launchctl", "kickstart", "-k", f"{domain}/{LABEL}"], check=True)
    else:
        subprocess.run(["launchctl", "print", f"{domain}/{LABEL}"], check=True)


if __name__ == "__main__":
    main()
