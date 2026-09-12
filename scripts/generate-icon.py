#!/usr/bin/env python3
# Rebuild the macOS icon with native tools after replacing the original artwork in Resources/AppIcon.png.
import pathlib
import subprocess
import tempfile


# Resolve assets relative to this script so icon generation works from any working directory.
root = pathlib.Path(__file__).resolve().parent.parent
source = root / "Resources/AppIcon.png"
destination = root / "Resources/AppIcon.icns"


# Supply every standard and Retina size while preserving the original artwork and transparent padding.
with tempfile.TemporaryDirectory(prefix="asteroid-icon-") as directory:
    iconset = pathlib.Path(directory) / "AppIcon.iconset"
    iconset.mkdir()
    for points in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            pixels = points * scale
            suffix = "@2x" if scale == 2 else ""
            image = iconset / f"icon_{points}x{points}{suffix}.png"
            subprocess.run(
                ["sips", "-z", str(pixels), str(pixels), str(source), "--out", str(image)],
                check=True,
                stdout=subprocess.DEVNULL,
            )

    # Package the sizes into the resource Finder, the Dock, and application windows load from the bundle.
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(destination)], check=True)


# Report the generated resource without modifying the supplied master PNG.
print(destination.relative_to(root))
