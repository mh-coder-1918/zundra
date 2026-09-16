# Zundra brand assets

The visual half of the *Pink Noise / Edition 02* identity kit, reduced to the files this repository actually uses. The full kit — the identity guide, the campaign templates, the wordmark study and the PNG exports — is not committed here; it lives with the design source. Nothing in this folder is compiled into the app: the app carries one brand colour (`Sources/Brand.swift`) and builds its icon from `Resources/brain.svg`.

## Colour

| Token | Hex | Where it is used |
|---|---|---|
| Pink | `#FF3D95` | The brand colour. The app icon's field, the panel's tint, the page's pink blocks. |
| Ink | `#171217` | Text on pink, the glyph on the icon, the dark surfaces on the page. |
| White | `#FFFFFF` | The page's light ground. |
| Blush | `#FFF0F6` | A supporting light surface — banded sections, code blocks. |
| Berry | `#AC1552` | Links and small text on a light ground, where pink is too weak to read (7.04:1 against white; pink is 3.1:1). |
| Grey | `#6B5D65` | Secondary text. |
| Line | `#E4D8DF` | Hairlines. |

Dark text on hot pink, never white: white on `#FF3D95` is 3.31:1, which the kit reserves for decoration. `tokens.css` and `design-tokens.json` are the kit's own token files, copied unchanged.

## The wordmark already carries its slant

`wordmark-12-*.svg` and `lockup-12-*.svg` are outlined vectors with the 12° shear baked into the path data — never skew them again in CSS or in a design tool, and keep the brain upright. The letterforms derive from DejaVu Sans Bold, compressed and sheared as artwork; this is a wordmark treatment, not a typeface, so a new line of display text cannot simply be typed in it. Body copy, navigation, dates, task names and shortcuts all stay upright.

Clear space is at least a quarter of the wordmark's height on every side, including the italic overhang. Minimum widths: wordmark 100px, lockup 180px, symbol 24px outside the menu bar.

## What the product keeps

The identity stops at the edge of the panel's meaning. The menu-bar glyph stays a monochrome template image — no slant, no halftone, no colour, because macOS tints it. Inside the panel, red `!`, blue `↑`, purple long-term, orange "Plan the day", green tallies, teal agent boxes and the sixteen area hues are all untouched: they say what a row *is*. Pink replaces only what was previously the Mac's own accent colour.

## Files

- `symbol-{ink,pink,white}.svg` — the brain on its own, upright, 512×512.
- `wordmark-12-{ink,pink,white}.svg` — the recommended 12° master.
- `lockup-12-{ink,white}.svg` — brain and wordmark locked up horizontally.
- `app-artwork-square.svg` — flat marketing square. The shipped macOS icon is built separately by `scripts/make-icon.swift`, which puts the same artwork on the rounded square macOS expects.
- `halftone-brain.svg` — the decorative halftone field, one texture per layout, starting at 10–20% coverage.
- `favicon.svg`, `social-card.png` (1200×630), `readme-banner.png` (1280×240) — generated for this repository from the assets above.
