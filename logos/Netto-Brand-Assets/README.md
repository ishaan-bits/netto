# Netto Brand Assets

Hand-built SVG reconstruction of the approved Netto identity (abstract N formed by two leaf shapes).
The reference PNG was used as a visual and measurement source only. Nothing is auto-traced and no raster
is embedded. **This is a faithful reconstruction, not a pixel-perfect copy: the original vector source was not available.**

## Files

| File | Use |
|---|---|
| `netto-symbol.svg` | Primary gradient symbol, transparent, 512x512. Marketing, web, decks. |
| `netto-symbol-dark.svg` | Same paths, solid `#0B2E21`. For light backgrounds / one-colour print. |
| `netto-symbol-light.svg` | Same paths, solid `#FFFFFF`. For dark or photographic backgrounds. |
| `netto-symbol-green.svg` | Same paths, solid `#1F7A55` (5.3:1 contrast on white). Gradient-free brand green. |
| `netto-wordmark.svg` | "Netto" wordmark, outlines, `#092F23`. |
| `netto-logo-horizontal.svg` | Symbol left of wordmark. Headers, nav bars, email signatures. |
| `netto-logo-stacked.svg` | Symbol above wordmark. Square-ish placements, splash screens. |
| `netto-logo-tagline.svg` | Stacked logo + "Clear space. Keep what matters." Brand sheets, landing pages. |
| `netto-app-icon.svg` | 1024x1024 master icon: dark emerald glass-style tile with gradient symbol. |
| `netto-app-icon-flat.svg` | Flat alternative: solid `#0E3A2A` tile, no glow or rim. Use if the detailed icon gets muddy small. |
| `netto-logo-preview.png` | Comparison sheet rendered from the actual SVG files above. |
| `FONT-LICENSE-OFL.txt` | SIL Open Font License 1.1 for Plus Jakarta Sans. |

All logo files have genuinely transparent backgrounds. The two app icons have a rounded-square tile with transparent corners.

## Palette

| Role | Hex |
|---|---|
| Mint (left leaf, top-left) | `#A3D29A` |
| Leaf mid | `#6DB283` |
| Leaf deep | `#3B896A` |
| Leaf dark (left leaf, bottom-right) | `#1F6756` |
| Lime (right leaf, top) | `#CDEAA1` |
| Lime mid | `#9CCB86` |
| Teal mid | `#5DAE88` |
| Teal deep (right leaf, bottom) | `#2F8466` |
| Solid green | `#1F7A55` |
| Dark mono / ink | `#0B2E21` |
| Wordmark | `#092F23` |
| Tagline grey-green | `#5A6862` (5.9:1 on white) |
| Icon tile (flat) | `#0E3A2A` |
| Icon tile (glass) | `#215C47` > `#14402F` > `#0C2A22` (top to bottom), glow `#63B67F` at top right |

Stops were sampled from the reference image and then simplified.

## Gradients (user-space coordinates of the 512 symbol box)

- `netto-grad-left`: `(110,100)` to `(320,432)`; stops 0 `#A3D29A`, .42 `#6DB283`, .78 `#3B896A`, 1 `#1F6756`.
- `netto-grad-right`: `(392,84)` to `(410,388)`; stops 0 `#CDEAA1`, .35 `#9CCB86`, .70 `#5DAE88`, 1 `#2F8466`.

Both use `gradientUnits="userSpaceOnUse"`, so they stay correct when the symbol group is scaled or moved.

## Typography

- Wordmark: **Plus Jakarta Sans ExtraBold (wght 800)**, tracking -2%, "tt" pulled together so the crossbars join.
- Tagline: Plus Jakarta Sans Regular (wght 400).
- Source: https://github.com/tokotype/PlusJakartaSans (via Google Fonts). Licence: SIL OFL 1.1, free for commercial use, and outlined text is permitted. Licence text is included.
- All text is converted to vector outlines, so no font is needed to render the files.
- This is a close stylistic match to the reference wordmark, not an identical font.

## Editing

- Each leaf is one `<path>` (`netto-leaf-left`, `netto-leaf-right`) with about 6 anchors, authored in a 512 box. Open in Figma / Illustrator / Inkscape and edit anchors directly.
- Colour variants share identical `d` attributes; only `fill` differs. Change a fill to recolour.
- In the lockups the symbol is a `<g transform="translate scale translate">`; resize by changing the scale.
- In the app icon the symbol sits in `#netto-icon-symbol` (scale 1.92 about the centre, about 58% of tile width, matching the reference).

## Exporting for iOS

SVG alone is not an iOS app-icon asset. Xcode wants a PNG.

1. iOS applies its own corner mask, so the App Store icon must be a **full-bleed square with no transparency**. In `netto-app-icon.svg` set `rx="0"` on `#netto-icon-bg` and on the clipPath rect, and delete the two ring `<rect>` strokes. (Edit `netto-app-icon-flat.svg` the same way for the flat version: just `rx="0"`.)
2. Export 1024x1024 PNG, e.g. `rsvg-convert -w 1024 -h 1024 icon.svg -o AppIcon.png` or `inkscape icon.svg -w 1024 -h 1024 -o AppIcon.png`. Make sure the PNG has no alpha channel (flatten onto `#0E3A2A`).
3. In Xcode, open `Assets.xcassets` > `AppIcon` and drop the 1024 PNG into the single-size slot (Xcode 14+ generates the rest), or supply individual sizes.
4. Dark / tinted iOS 18 variants: use `netto-symbol.svg` / `netto-symbol-light.svg` on the dark and tinted slots.

## Deviations from the reference

- Symbol geometry was measured from the standalone mark (row-by-row edge positions) and rebuilt with Bezier curves; edges are within roughly 1-3 px on the 141 px-wide source mark. The reference's soft edge-lighting on the leaves is not reproduced; the leaves use clean gradients.
- App-icon glass look (glow, rim light, soft shadow) is approximated with gradients and opacity only. The reference's blur, refraction and depth are intentionally not used, because SVG filters render inconsistently across tools.
- Icon tile uses a rounded rectangle (`rx=232`), not Apple's continuous-curvature squircle.
- Wordmark and tagline use Plus Jakarta Sans, close to but not the same as the reference lettering.
- The Light / Dark / Mono / Color icon variations on the board are not part of this package.

## Validation performed

- All SVGs parse as XML; no raster images, scripts, styles, filters, external links or live text.
- Rendered every SVG with CairoSVG (Cairo). Inkscape and rsvg-convert were not available, and I did not open the files in Figma, Illustrator or multiple browsers.
- Visually compared the symbol against the reference crop side by side, and inspected the icon and lockups.
- Confirmed the three monochrome symbols and all lockups use byte-identical path data.
- Confirmed transparent corners on every file and no clipping (edge margins measured from renders).
- Small-size renders (64 / 32 / 24 px) are on the preview sheet; both leaves stay distinct.
