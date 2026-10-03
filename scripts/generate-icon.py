#!/usr/bin/env python3
# Rebuild both platform icons from the full-bleed master in Resources/AppIcon.png.
import pathlib
import subprocess
import tempfile


# Resolve assets relative to this script so icon generation works from any working directory.
root = pathlib.Path(__file__).resolve().parent.parent
source = root / "Resources/AppIcon.png"
destination = root / "Resources/AppIcon.icns"


# macOS needs its rounded silhouette baked in; iOS applies its own platform mask.
with tempfile.TemporaryDirectory(prefix="asteroid-icon-") as directory:
    mac_source = pathlib.Path(directory) / "mac-icon.png"
    subprocess.run(
        ["xcrun", "swift", str(root / "scripts/prepare-mac-icon.swift"), str(source), str(mac_source)],
        check=True,
    )
    iconset = pathlib.Path(directory) / "AppIcon.iconset"
    iconset.mkdir()
    for points in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            pixels = points * scale
            suffix = "@2x" if scale == 2 else ""
            image = iconset / f"icon_{points}x{points}{suffix}.png"
            subprocess.run(
                ["sips", "-z", str(pixels), str(pixels), str(mac_source), "--out", str(image)],
                check=True,
                stdout=subprocess.DEVNULL,
            )

    # Package the sizes into the resource Finder, the Dock, and application windows load from the bundle.
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(destination)], check=True)

ios_destination = root / "ios/Assets.xcassets/AppIcon.appiconset/image.png"
subprocess.run(
    ["sips", "-z", "1024", "1024", str(source), "--out", str(ios_destination)],
    check=True,
    stdout=subprocess.DEVNULL,
)


# Report the generated resource without modifying the supplied master PNG.
print(destination.relative_to(root))
print(ios_destination.relative_to(root))
