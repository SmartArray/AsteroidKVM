# Gesture onboarding artwork

Generated with the built-in image generation tool on September 29, 2026. The previous bundled gesture diagrams were edit references; the original compositions and cobalt / magenta / turquoise / lavender color roles are retained. Native SwiftUI draws all instructional text and controls.

| Gesture | Light asset | Dark asset |
| --- | --- | --- |
| Point and click | `Assets.xcassets/GesturePointer.imageset/image.png` | `Assets.xcassets/GesturePointer.imageset/dark.png` |
| Pan and zoom | `Assets.xcassets/GesturePanZoom.imageset/image.png` | `Assets.xcassets/GesturePanZoom.imageset/dark.png` |
| Scroll | `Assets.xcassets/GestureScroll.imageset/image.png` | `Assets.xcassets/GestureScroll.imageset/dark.png` |

The asset catalog selects the dark luminosity variant automatically. Both variants are bundled locally. The fourth page is a native interactive preview and uses the same adaptive palette.

## Prompt set

Each gesture/appearance pair was a separate edit. Pointer and PanZoom used the template below for both appearances; Scroll used the dark template and the refined light prompt below.

```text
Use case: style-transfer. Asset type: square production illustration for AsteroidKVM iOS gesture onboarding, {theme} appearance.
Input image 1 is the edit target. Create a polished {theme} version of this EXACT gesture illustration, retaining its meaning, anatomy, count of fingers, phone outline, and composition: {detail}.
Art direction: sophisticated tactile vector-like illustration, precise smooth silhouettes, subtly layered matte surfaces, restrained soft highlights and fine depth. Keep the existing cobalt-blue, vivid pink/magenta, turquoise and lavender color pattern. Beautiful, readable at small mobile size. Phone and hand centered, fully visible with generous margins. No text or letters, no logos, no extra symbols, no new dots, no photographic skin, no busy scenery, no heavy glow.
{appearance direction}
Preserve the same diagram in both appearances. Output one square illustration only, no surrounding UI, no comparison layout.
```

Details:
- Pointer: one extended index finger touching one magenta contact point; blue directional arrows and turquoise pointer
- PanZoom: exactly two extended fingers on two magenta contact points; blue outward diagonal zoom arrows and turquoise four-way pan arrow
- Scroll: exactly three extended fingers touching three magenta contact points; vertical blue bidirectional arrow and turquoise scrollbar

Light appearance direction:
> Light theme: very pale ivory-lavender background #F6F5FE with a barely perceptible lavender ambient wash. Deep indigo phone outline, pale lavender screen and window panels with delicate indigo edges, softly sculpted lavender hand with darker lavender contour and pale highlights. Saturated cobalt #4862FF, magenta #ED1699 and turquoise #00BEBB functional accents. The illustration must feel luminous, airy and premium while preserving strong gesture contrast.

Dark appearance direction:
> Dark theme: deep midnight navy background #090919 with a barely perceptible indigo ambient wash. Indigo-violet phone outline, layered dark indigo screen/window panels, softly sculpted luminous lavender hand. Saturated cobalt #4862FF, magenta #ED1699 and turquoise #00D4C8 functional accents, exactly the same positions/color roles as the reference. Elegant depth and improved edge definition; avoid pure-black crushed detail and excessive neon.

Final light Scroll prompt (original Scroll diagram plus the generated light Pointer image as references):
> Use case: style-transfer. Create the LIGHT APPEARANCE counterpart of image 1 (the three-finger scrolling diagram). Image 2 is the visual style reference for the matching one-finger light illustration. Preserve image 1's exact composition and finger anatomy: THREE extended fingers touching THREE magenta circles, indigo phone with three cobalt list rows, blue vertical bidirectional scroll arrow at left and turquoise scrollbar at right. Match image 2's pale ivory-lavender background #F6F5FE, deep indigo phone outline, pale lavender hand with a darker lavender contour, clean subtly sculpted matte surfaces and delicate highlights. Keep cobalt blue, magenta, turquoise functional color roles. Square, centered, generous margins, full phone and hand visible, highly readable at mobile size. No text, no labels, no new symbols, no extra fingers, no new dots, no photorealism, no heavy glow. One production illustration only.

