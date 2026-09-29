# iOS app icon

The iOS asset is `Assets.xcassets/AppIcon.appiconset/image.png`: an opaque 1024 × 1024 PNG with a prominent champagne-gold border. It replaces the transparent padding that appeared white on the home screen. The macOS artwork remains separate.

Edited with the built-in imagegen tool on 2026-09-29, using the previous iOS icon as the edit target. The generated PNG was resized to the asset catalog's required 1024 × 1024 dimensions using `sips`. Original generated output: `/Users/julianjaeger/.codex/generated_images/01a0ed75-279a-71e1-8faf-ac8cf2e37219/exec-79e8110f-df92-4919-9ae2-d8137a7e49c5.png`.

## Original thin-border prompt

> Edit target: supplied AsteroidKVM iOS app icon. Precise-object-edit. Change only the outer border/padding treatment. Preserve the existing photorealistic cratered warm-lit asteroid, blue orbital light, star and computer monitor composition and details. Current navy rounded-square artwork is inset by about 66 pixels inside a 1024px canvas with transparent padding, which becomes a thick white rim in iOS. Replace this with an elegant thin metallic champagne-gold rim, about 18 pixels wide at the middle of each edge (roughly one-third the old padding width). Expand the navy rounded-square artwork toward the edges to achieve this. Gold should harmonize with the asteroid's warm highlights; subtle polished gold shading, not yellow neon. Deliver a square 1024x1024 fully opaque RGB-style iOS app icon image, filling the entire canvas with no transparency and no white margins. Outer canvas is gold, inner navy rounded square almost fills it with a thin gold border; retain rounded interior corners shaped appropriately for iOS's rounded-square icon mask. No text, no added objects, no mockup, no shadow outside icon. Keep the central existing artwork as faithful as possible.

## Thicker border revision

The user requested a thicker gold border. Built-in imagegen edited the previous gold icon using the prompt below. Generated output: `/Users/julianjaeger/.codex/generated_images/01a0ed75-279a-71e1-8faf-ac8cf2e37219/exec-6190f6ec-1b77-462e-ae29-ad4e80c0051b.png`. It was normalized to an opaque 1024 × 1024 PNG with `sips`.

### Final prompt

> Precise-object-edit of the supplied AsteroidKVM iOS app icon. Increase ONLY the thickness of the existing metallic champagne-gold border: make the gold band approximately 36 to 40 pixels wide at the midpoint of all four edges on a 1024x1024 canvas, about 2.5 times thicker than it currently appears. Keep the same warm gold color and subtle polished metallic highlights. Inset the inner navy rounded square enough to make the gold clearly visible around every side after iOS applies its rounded-square icon mask. Preserve the asteroid, its craters and lighting, blue orbit, star, computer monitor, and overall composition with the highest possible fidelity. Do not redesign or add elements. Keep the central artwork unchanged except for a slight uniform scale-down if necessary to accommodate the thicker frame. Output a square, fully opaque 1024x1024 app icon with gold filling the outside corners; no transparency, no white padding, no text, no mockup.

## Verification

Generic Simulator and unsigned device builds passed. The installed icon was visually checked on the iPhone 17e Simulator home screen; the gold edge appears under the native rounded mask without a white rim. PNG dimensions and lack of alpha were checked with `sips`. Local app ZIP artifacts were refreshed.
