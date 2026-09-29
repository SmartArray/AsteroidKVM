# iOS app icon

The iOS asset is `Assets.xcassets/AppIcon.appiconset/image.png`: an opaque 1024 × 1024 PNG with a thin champagne-gold rim. It replaces the transparent padding that appeared white on the home screen. The macOS artwork remains separate.

Edited with the built-in imagegen tool on 2026-09-29, using the previous iOS icon as the edit target. The generated PNG was resized to the asset catalog's required 1024 × 1024 dimensions using `sips`. Original generated output: `/Users/julianjaeger/.codex/generated_images/01a0ed75-279a-71e1-8faf-ac8cf2e37219/exec-79e8110f-df92-4919-9ae2-d8137a7e49c5.png`.

## Final prompt

> Edit target: supplied AsteroidKVM iOS app icon. Precise-object-edit. Change only the outer border/padding treatment. Preserve the existing photorealistic cratered warm-lit asteroid, blue orbital light, star and computer monitor composition and details. Current navy rounded-square artwork is inset by about 66 pixels inside a 1024px canvas with transparent padding, which becomes a thick white rim in iOS. Replace this with an elegant thin metallic champagne-gold rim, about 18 pixels wide at the middle of each edge (roughly one-third the old padding width). Expand the navy rounded-square artwork toward the edges to achieve this. Gold should harmonize with the asteroid's warm highlights; subtle polished gold shading, not yellow neon. Deliver a square 1024x1024 fully opaque RGB-style iOS app icon image, filling the entire canvas with no transparency and no white margins. Outer canvas is gold, inner navy rounded square almost fills it with a thin gold border; retain rounded interior corners shaped appropriately for iOS's rounded-square icon mask. No text, no added objects, no mockup, no shadow outside icon. Keep the central existing artwork as faithful as possible.

## Verification

Generic Simulator and unsigned device builds passed. The installed icon was visually checked on the iPhone 17e Simulator home screen; the gold edge appears under the native rounded mask without a white rim. PNG dimensions and lack of alpha were checked with `sips`. Local app ZIP artifacts were refreshed.
