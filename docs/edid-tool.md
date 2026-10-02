# Constructing an EDID

`scripts/create-edid.sh` creates a complete HDMI EDID using the app's shared Swift timing generator. Its defaults identify the display as **ASUS Display**, manufacturer **AUS** (ASUSTek), at **2560 × 1440 / approximately 60 Hz**. Generated defaults contain no Asteroid or KVM display name.

The tool runs locally on macOS with Swift/Xcode command-line tools. Run from a source checkout; the wrapper builds the executable on first use and incrementally thereafter. It does not connect to or change a KVM.

## Quick start

```sh
# Print a single line of uppercase hex for a KVM's EDID text field.
./scripts/create-edid.sh

# Save hex or a 256-byte binary file. Output folders must already exist.
./scripts/create-edid.sh --output asus-1440p.hex
./scripts/create-edid.sh --format bin --output asus-1440p.bin

# Choose another supported mode and identity.
./scripts/create-edid.sh --mode 1920x1080 --name "ASUS Monitor" \
  --product 0x24B2 --serial 0x12345678 --week 33 --year 2020 \
  --output asus-1080p.hex
```

Relative output paths are relative to your current directory, even when invoking the wrapper from elsewhere. Existing files are never overwritten. Build diagnostics and file summaries go to stderr; stdout contains only EDID hex unless asking for help. Binary output requires a file so binary data is not printed to the terminal.

You can also build and run the executable directly:

```sh
swift build --product create-edid
.build/debug/create-edid --help
```

## Options

| Option | Default | Accepted values |
| --- | --- | --- |
| `--name` | `ASUS Display` | 1–13 printable ASCII characters; no newlines or leading/trailing spaces |
| `--manufacturer` | `AUS` | Three uppercase letters |
| `--product` | `0x24B2` | Unsigned 16-bit integer |
| `--serial` | `0x01010101` | Unsigned 32-bit integer |
| `--week` | `33` | 0–54; 0 means unspecified |
| `--year` | `2020` | 1990–2245 |
| `--mode` | `2560x1440` | `1920x1080`, `1920x1200`, or `2560x1440` |
| `--format` | `hex` | `hex` or `bin` |
| `--output` | Standard output | New file path |

Numbers are decimal unless prefixed with `0x`. A name longer than the EDID field is rejected rather than silently truncated. Unknown/duplicate arguments, invalid numeric ranges, unsupported modes, and malformed names fail with a nonzero exit status before producing an EDID.

## What the generated profile says

- EDID 1.3, exactly two 128-byte blocks, with independently validated checksums.
- A digital RGB display with one preferred progressive mode at approximately 60 Hz and a 640 × 480 / 60 Hz fallback.
- HDMI stereo PCM audio at 32/44.1/48 kHz and 16/20/24-bit sample sizes.
- A 260 MHz maximum TMDS clock, sufficient for the included 241.5 MHz 1440p timing.
- The existing template's physical dimensions: 52 × 29 cm for 1080p/1440p, or 52 × 32 cm for 1200p; gamma 2.2.
- The chosen display name, manufacturer, product code, numeric serial, and manufacture date.

The default numeric identity preserves the values from the supplied EDID: product `0x24B2`, serial `0x01010101`, week 33 of 2020. The name is changed to `ASUS Display`. These are configurable declarations, not a verified dump of a particular ASUS model. This controls the HDMI display identity; USB keyboard/mouse identity is separate.

The generated file has exactly 256 bytes (512 hex digits plus a newline in text format), avoiding the excess padding in the previously pasted EDID. It advertises only the listed modes; it does not add 4K, HDR, VRR, or 1440p at 75 Hz. The remote OS chooses the actual display mode.

Import the `.hex` text or `.bin` file using the KVM firmware's EDID editor/import function, depending on its accepted format. Keep its current EDID for restoration before applying a replacement. The desktop app's current Display settings remain a separate editor; this tool does not automatically upload generated files or change existing device identities.

## Validation

```sh
swift test --filter EDIDTests
swift build --product create-edid
python3 -m unittest discover -s Tests/EDIDToolTests -v
```

Swift tests verify descriptor editing preserves identity, timings, audio, and unknown extension bytes. CLI tests independently decode output lengths, identity byte order, timing dimensions, audio bytes, and block checksums; exercise all modes; reject invalid input; and verify existing output files are preserved.
