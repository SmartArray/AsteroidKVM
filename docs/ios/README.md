# AsteroidKVM iOS implementation handoff

Start with **[implementation-plan.md](implementation-plan.md)**. It is the complete product specification, architecture plan, implementation sequence, and acceptance checklist for a native iPhone/iPad app based on the existing AsteroidKVM code.

This package contains a plan and original assets, not an implemented iOS application. The implementor also needs the AsteroidKVM repository. The inspected source baseline is commit `8e56ac187cdd98bde902684fe55220c66b156e7f`. Review later source changes before applying the file-level recommendations.

## Contents

```text
AsteroidKVM-iOS-Implementation-Handoff/
  README.md
  implementation-plan.md
  asset-manifest.json
  SHA256SUMS.txt
  onboarding/
    README.md                       # exact image-generation prompts/provenance
    one-finger-pointer.png
    two-finger-pan-zoom.png
    three-finger-scroll.png
  branding/
    AppIcon.png                     # existing brand master
    ThirdPartyNotices.txt            # existing notices for mobile audit
```

The original three onboarding images are 1254 × 1254 PNGs. They were generated with the built-in image generation tool and approved by the user. They contain no text. All labels belong in native code **above** the illustrations. Do not add font files, bake captions into the PNGs, crop out gesture arrows/fingers, or recreate the supplied artwork unnecessarily.

The app-icon master is also a 1254 × 1254 PNG. Prepare a valid Xcode mobile icon set from it during implementation; it is not a finished mobile app-icon catalog. Audit included notices against actual mobile dependencies.

`asset-manifest.json` records image names, intended asset-catalog names, dimensions, sizes, and SHA-256 hashes. `SHA256SUMS.txt` covers every other file in this handoff. The checksum list intentionally does not hash itself.

## Verify after extracting

From the extracted handoff directory on macOS:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

The ZIP has a separate sibling `.zip.sha256` file for verifying the archive before extraction. No credentials, captured KVM screens, build products, model weights, or Python environments are included.

## Implementation starting point

1. Read the complete plan, including the fixed product decisions and engineering defaults.
2. Open the indicated source files in the existing repository; first verify the shared iOS dependency graph compiles.
3. Implement the milestones in order, preserving macOS behavior and the existing typing/credential safeguards.
4. Import the supplied originals into the new mobile asset catalog; keep their source files and provenance.
5. Record automated and physical-device acceptance results before calling the port complete.

Mobile schemes and build commands in the plan describe work to be implemented. They do not exist at the inspected baseline. No release, signing, upload, or publication has been performed by creating this handoff.
