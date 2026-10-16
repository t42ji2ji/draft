# iA Writer 8.0.6 editor: extracted measurements

Read-only reverse engineering of `/Applications/iA Writer.app` (8.0.6, universal; arm64 slice analysed). The app was not launched.

Confidence levels:
- **extracted**: the literal value was read from a resource file or a disassembled constant.
- **inferred**: derived from code flow or by combining extracted values.

Abbreviations:
- `Main` = `Contents/MacOS/iA Writer`
- `Kit` = `Frameworks/Kit.framework`
- `TK` = `Frameworks/TypographyKit.framework`

Colours built with `colorWithWhite:` are generic gamma-2.2 grey, which is about the same as sRGB grey. Colours built with `colorWithRed:` are sRGB. Colours built with `colorWithWidestGamutRed:` are Display P3 on macOS 10.12 and later; the sRGB hex given for them is clipped to the sRGB gamut.

## 1. Fonts

| Item | Value | Source | Conf. |
|---|---|---|---|
| Body font, Mono | `iAWriterMono-Regular` (variable; axes `wght` 400–700, `SPCG` 0–150) | `TK/Resources/Mono.plist` → `Styles/Normal/Font` | extracted |
| Body font, Duo / Quattro | `iAWriterDuo-Regular` / `iAWriterQuattro-Regular` | `Duo.plist`, `Quattro.plist` | extracted |
| Italic | `iAWriter{Mono,Duo,Quattro}-Italic`. The CJK fallback uses an oblique of 9.5° | plist `Styles/Emphasis` | extracted |
| Bold (Strong) | same family, `wght` 700 (650 for ja/ko/zh) | plist `Variations/Strong/wght` | extracted |
| Fallback chain (Normal) | `Keyboard` (Apple) → PingFang TC/SC/HK, Hiragino Sans W3, Apple SD Gothic Neo → `iAWriterDuo-Regular` → system | plist `CascadeList` | extracted |
| CJK punctuation | `iAWriterFullSpace{JA,KR,SC,TC}` replaces full-width punctuation (U+FF01…, …); for zh/ja/ko it is listed first | plist `FontList` | extracted |
| Greek in Mono | taken from Duo (U+0370–03FF, U+1F00–1FFF) | Mono.plist `FontList` | extracted |
| Emphasis mark | `iAWriterEmphasis-*` (glyphs U+E000/E001 only), used when the Emphasis setting is "Emphasis Mark" | plist `EmphasisMark` | extracted |
| `Editor Typeface` enum | 0 = Mono, 1 = Duo, 2 = Quattro (Dora's value is 0, so Mono) | `TK _IATypefaceToString` + `EditorPreferences.nib` menu tags | extracted |
| Font vertical metrics | UPM 1000; hhea ascent 1025, descent −275, gap 0 (natural line = 1.3 em); typo 780/−220/300; cap height 698; x-height 516 | fontTools | extracted |
| Advance width | Mono: every glyph = 600 + 2·SPCG units. Duo: `m` is 900 + 2·SPCG. Quattro: `i` and space are 300 + 2·SPCG. | fontTools instancer | extracted |

Files copied unmodified to `Resources/Fonts/`:
- Mono, Duo and Quattro (regular and italic)
- FullSpace JA, KR, SC, TC
- Emphasis and EmphasisSpaced (all weights)

Licensing:
- The Duo, Emphasis and FullSpace files carry the SIL OFL string in name ID 13.
- The bundled Mono and Quattro files have an empty license field, and their copyright string reads "All rights reserved". The public iaolo/iA-Fonts release of these families is OFL.
- `Keyboard.ttf` is © Apple and was not copied. The IBM Plex and KaTeX fonts are used only by the preview and were not copied either.

## 2. Size, line height, weight, spacing

These values come from `TK/Resources/{Mono,Duo,Quattro}.plist` and are extracted. The same values appear in the preview CSS, `Templates/*/style/typography-*.css`.

**Content size (point size).** Dora's `Typography Content Size` is `M`, so her editor uses **16 pt**.

| Size | 4XS | 3XS | 2XS | XS | S | **M** | L | XL | 2XL | 3XL | 4XL | 5XL | 6XL | 7XL | 8XL | 9XL | 10XL |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| pt | 11 | 12 | 13 | 14 | 15 | **16** | 18 | 20 | 24 | 28 | 32 | 36 | 42 | 48 | 54 | 60 | 72 |

**Line height (Mono and Duo).** The value is a percentage of the font size. Columns are viewport size classes (see §3).

| Size | Compact | Regular | ≥Wide |
|---|---|---|---|
| S | 167% | 177% | 187% |
| **M** | **166%** | **176%** | **186%** |
| L | 165% | 175% | 185% |
| XL | 163% | 173% | 183% |

- At other sizes, Regular runs from 179% at 3XS down to 128% at 10XL. Compact is always Regular − 10 and Wide is always Regular + 10.
- Quattro is 11 points lower: M is 155 / 165 / 175%.
- `lineHeight = fontSize × pct / 100`, with no rounding (`-[IATypographyTable lineHeightWithRequest:]`).
- At M, line height is **28.16 pt** in Regular and **29.76 pt** in Wide.

**Weight (`wght`) on Retina (>1×).** The base value depends on size: 4XS 490, 3XS 482, 2XS 475, XS 470, S 465, **M 460**, L 455, XL 450, 2XL 445, 3XL 440, 4XL 435, 5XL 430, and 425 from 6XL up. Two adjustments apply: −35 on macOS and another −20 in dark appearance.

At M this gives **425 in light and 405 in dark**. On 1× screens and for ja/ko/zh the weight is fixed at 400. Strong (bold) is 700.

**Spacing axis (`SPCG`).** The base value depends on the size class:
- Mono and Duo: Compact 10, Regular 15, ≥Wide 20, Print 20.
- Quattro: Compact 0, Regular 1, Wide 2.

A per-size adjustment is added on ≥Regular: 4XS +22, 3XS +18, 2XS +14, XS +8, S +4, **M +2**, L/XL/2XL 0, 3XL −1, … down to 10XL −8.

For Mono at M:
- Regular: SPCG 17, so the advance is 634 units and **enWidth = 10.144 pt**.
- Wide: SPCG 22, so the advance is 644 units and enWidth = 10.304 pt.

`enWidth` is the advance of the glyph **'N'** (U+004E) in the body font with these variations applied (`TK _IATypographyEnWidth` → `CTFontGetAdvancesForGlyphs`; it falls back to 10 if the glyph is missing). Extracted.

## 3. Column width and horizontal layout

**Viewport size class** (extracted, `TK _IATypographyViewportSizeClassWithWidth`, thresholds read from `__const`). W is the text view's width, not the window's:

| Width W | Class |
|---|---|
| W ≤ 440 | Compact (−1) |
| 440 < W ≤ 1250 | Regular (0) |
| 1250 < W ≤ 1660 | Wide (1) |
| W > 1660 | Full (2) |

**Line length limit** (extracted):
- Options are 64, 72 or 80 characters (`EditorPreferences.nib` menu tags).
- The default is **64** (`+[IAEditorPreferences sharedPreferences]` block 19 calls `setLineLengthLimit:0x40`). The value transformer also maps anything other than 64/72/80 back to 64.
- Dora has no stored value, so her limit is 64.

**Preferred margin characters** (extracted, plist `MarginCharacterCounts`):
- Compact: 0
- Regular, W ≤ 512: 3
- Regular, 512 < W ≤ 768: 4
- Regular, W > 768: 6
- Wide and Full: 8

**Layout algorithm** (`TK -[IATypographyLayout initWithViewportWidth:viewportSizeClass:enWidth:maxLineCharacterCount:preferredMarginCharacterCount:]`). The pseudocode is transcribed from the arm64 disassembly; individual constants are extracted, the overall reading is inferred.

```
E = enWidth, N = lineLengthLimit (64), P = preferred margin chars, W = viewport width
g = (class == Compact) ? (W > 390 ? 18 : 13) : 6        // minimum side gutter
g = min(g, W)
avail = ceil(max(W - 2g, 0))
k = smallest k with ceil(E*k) >= avail                   // chars that fit across
maxMargin = (class == Compact) ? 1 : min(floor(k/9), 7)
lineW = ceil(E*N) + 10                                    // +10 = 2 × NSTextContainer lineFragmentPadding (default 5)
side  = max(g, floor(max((W - lineW - 2g)/2, 0)))
m = min(P, maxMargin); while (ceil(E*m) < side && m < maxMargin) m++
total = 2*m*E + lineW
inset = max(g - m*E, max((W - total)/2, 0))              // -> textContainerInset.width
containerW = min(total, max(W - 2*inset, 0))             // -> NSTextContainer width
lineChars = min(N, smallest n with ceil(E*n) >= containerW)
marginChars = m
```

The margin columns sit **inside** the text container. The paragraph style is built in `Kit -[IATextController initWithConfiguration:textStorage:]` (extracted):
- `minimumLineHeight = maximumLineHeight = lineHeight`
- `headIndent = firstLineHeadIndent = E × marginChars`
- `tailIndent = −E × marginChars`
- `defaultTabInterval = E × tabWidth`, with no tab stops
- `indentWidth = 4`

Markdown markers (`# `, list bullets) hang into this margin.

Worked examples for Mono, M, limit 64:
- **W = 1000** (Regular, P = 6): k = 98, maxMargin = 7, m = 7, inset = 99 pt, container = 802 pt, text column = 64 chars ≈ 649 pt. The text starts at x = 99 + 5 + 71.0 ≈ **175 pt**.
- **W = 720** (Regular, P = 4): side = 24, so m stays at 4. inset = 0, container = 720, text starts at x = 5 + 40.6 ≈ 45.6 pt.

## 4. Vertical insets and typewriter mode

| Item | Value | Source | Conf. |
|---|---|---|---|
| Top/bottom inset, normal | `ceil(minimumInsetHeight + 4 + min(E × marginChars, 20))` on macOS 27 (and when Liquid Glass is off). On Glass with macOS < 27 the third term is `E × max(0.25·m − 1, 0)`. | `-[IAEditorTextView insetHeight]` | extracted |
| `minimumInsetHeight` | 30 at `loadView`, later replaced by the window's titlebar height (`currentTitlebarHeight`/`titlebarHeight`) | `IAEditorViewController loadView`, `IALibraryWindowController _updateForWindowTitlebar:` | extracted |
| Inset, typewriter mode | `ceil((visibleRect.height − lineHeight) / 2) − 3` | `-[IAEditorTextView textContainerInsetHeight]` | extracted |
| Typewriter position | The caret line is scrolled so that its **midY equals the visible midY** (exact vertical centre): `originY = rect.midY − visibleHeight/2` | `-[IAEditorTextView scrollRangeToCenter:animated:]` | extracted |
| Typewriter animation | `NSAnimationContext` duration 0.15 s (a 0.03 constant is involved in the "small jump" branch). Scroll and centring timers fire after 0.15 s with tolerance 0.02. | same, plus `schedule…Timer` | extracted |
| Baseline in line box | `baselineOffset = (fragmentHeight + capHeight) / 2`. Cap height is centred vertically in the line. | `Kit -[IALayoutManager layoutManager:shouldSetLineFragmentRect:…]` (ivar `_capHeight`) | extracted |
| Font leading | `usesFontLeading = NO` on the layout manager | `IAEditorViewController loadView` | extracted |
| Text view | `NSTextView` subclass `IAEditorTextView`. Container does not track width or height; vertically resizable; `richText = NO`; `layerContentsRedrawPolicy = 3` | `-[IAEditorTextView initWithTypography:]` | extracted |

## 5. Editor colours

All values come from the `NSColor(Writer)` category in `Main`, applied in `-[IAEditorViewController updateColors]`. The asset-catalog colours are app-icon layers (`Writer_Assets/Color-*`) or sidebar file-icon tints, not editor colours. `Color-5 #141414` and the preview CSS `#1a1a1a` / `#cccccc` serve only as cross-checks.

| Role (setter) | Light | Dark | Notes / source | Conf. |
|---|---|---|---|---|
| Background (`setBackgroundColor:` on the text view and scroll view) | `white 0.96` = **#F5F5F5** | `white 0.08` = **#141414** | `writerBackgroundColorForDarkAppearance:`. On macOS ≥ 10.16 this is white blended 4% toward black (light) and black blended 8% toward white (dark). Older macOS: #F7F7F7 / #1A1A1A. | extracted |
| Text (`setTextColor:`) | `white 0.10` = **#1A1A1A** | `white 0.80` = **#CCCCCC** | `writerTextColorForDarkAppearance:` | extracted |
| Secondary: link/image brackets, footnote markers, reference definitions, escapes, `//` comments, HTML, completed tasks. **Not** `#`, `*`, `_`, `-`, `>`, `~~`, `==`, backticks — those keep the text colour (docs/markdown-styling.md) | rgb(.71,.70,.69) = **#B5B2B0** | rgb(.48,.48,.47) = **#7A7A78** | `writerSecondaryTextColor…`; usage from `Kit IATextController handle*` | extracted |
| Tertiary: link URLs, reference definitions, highlight marks | rgb(.84,.83,.82) = **#D6D4D1** | rgb(.33,.33,.32) = **#545452** | `writerTertiaryTextColor…` | extracted |
| Quaternary: autolink and wikilink extras | rgb(.90,.89,.88) = #E6E3E0 | rgb(.20,.20,.19) = #333330 | With Increase Contrast: #D9D6D4 / #40403D | extracted |
| Focus mode, dimmed text (`setDimmedTextColor:`) | rgb(.78,.77,.76) = **#C7C4C2** | rgb(.44,.44,.44) = **#707070** | `writerDimmedTextColor…` | extracted |
| Focus mode, dimmed markers (`setSecondaryDimmedTextColor:`) | rgb(.88,.87,.86) = **#E0DEDB** | rgb(.24,.24,.24) = **#3D3D3D** | `writerSecondaryDimmedTextColor…` | extracted |
| Code background | `white 0.14 α 0.045` | `white 0.96 α 0.05` | `writerCodeBackgroundColor…` | extracted |
| Content-block background / border | #FFFFFF / #E6E6E6 | #0D0D0D / #2E2E2E | `writerContentBlock{Background,Border}Color…` | extracted |
| Active link underline | rgb(.52,.51,.50) = #858280 | rgb(.58,.58,.57) = #949491 | `writerActiveLinkUnderlineColor…`. The active link text uses the normal text colour. | extracted |
| Hashtag text | `white 0.55` = #8C8C8C | same | `writerHashtagTextColor…` | extracted |
| Accent / tint | **writerBlue** = Display P3 (0, 0.75, 1) ≈ sRGB **#00C3FF** | same | `writerBlueColorWithAlpha:` | extracted |

## 6. Caret and selection

| Item | Value | Source | Conf. |
|---|---|---|---|
| Caret colour | writerBlue, P3 (0, .75, 1) ≈ #00C3FF, in light and dark. It is overridden by the `IAEditorTextViewInsertionPointColorAttribute` at the caret (authorship colours). | `-[IAEditorTextView _updateInsertionPointColorWithSelectedRange:]` | extracted |
| Caret rect | Applies only when the system rect has width ≈ 1. Inset 1 pt top and bottom (y+1, h−2). Then by the new height: > 58 → width 5 (x−2); > 40 → width 4 (x−1); ≥ 20.05 → width 3 (x−1); otherwise width 2 (x unchanged). Example: a 16 pt font on a 28 pt line gives **3 pt**. | helper `0x100055128` called from `drawInsertionPointInRect:color:turnedOn:` and `_drawInsertionPointInRect:color:` | extracted (the caret height NSTextView passes in is inferred to be the line-fragment height) |
| Selection background | On macOS ≥ 10.16, `+[NSColor selectedTextBackgroundColor]` is swizzled to return **writerBlue α 0.25** (P3 0, .75, 1, a .25), cached. Light and dark are identical. | `+[NSColor(Writer) load]`, `_writerSelectedTextBackgroundColor` | extracted |
| Selection, secondary variant | The instance method `-[NSColor(Writer) selectedTextBackgroundColor]` builds a dynamic colour. It keeps the receiver's Oklab a and b, sets L to 0.75 (light) or 0.55 (dark), and sets alpha to 0.175 (light) or 0.35 (dark), falling back to α 0.25. Where this is used is not traced. | same category | extracted values, usage unknown |

## 7. Highlight (`==text==`)

The style enum has six values: 0 Yellow, 1 Orange, 2 Pink, 3 Purple, 4 Blue, 5 **Green**. Dora's setting is `Green`, stored as a string in `Editor Text Highlight Style`.

Base colours (`writerTextHighlightColorWithStyle:alpha:`, widest gamut = P3):

| Style | P3 | ≈ sRGB | Background α (light / dark) |
|---|---|---|---|
| Yellow | (1, .85, 0) | #FFD700 | .35 / .175 |
| Orange | (1, .5, .25) | #FF7626 | .30 / .175 |
| Pink | (.95, 0, .7) | #FF00B7 | .20 / .225 |
| Purple | (.5, 0, .95) | #8C00FC | .20 / .30 |
| Blue | writerBlue | #00C3FF | .20 / .175 |
| **Green** | **(.6, .9, 0)** | **#7FE800** | **.35 / .175** |

- **Background** is the base colour at the alpha in the table above.
- **Text colour:**
  - Light: the normal text colour.
  - Dark: the text colour blended 30% toward the base colour.
- **Underline:** the base colour at α 1.0 (light) or 0.75 (dark).

Source: `writerTextHighlight{Background,Text,Underline}Color…` and `IAEditorViewController updateTextHighlightColors`. All values are extracted.

## 8. Preferences: defaults and decoding

The store is `IAPreferences` with identifier `"Editor"`, so each key is written as `"Editor <Prop>"`. The defaults are registered in `Kit +[IAEditorPreferences sharedPreferences]` block 19. Everything in this section is extracted.

| Key | Meaning | Default | Dora's value |
|---|---|---|---|
| `Editor Typeface` | 0 Mono / 1 Duo / 2 Quattro | computed at runtime by an unnamed helper (not resolved) | 0 (Mono) |
| `Editor Focus Mode` | Bool, Focus on or off | — | **1 (on)** |
| `Editor Focus Scope` | stored as a string: `Text` (UI label "Typewriter": typewriter scrolling only, no dimming), `Paragraph`, `Sentence` | **Sentence (2)** | not stored → **Sentence** |
| `Editor Line Length Limit` | 64 / 72 / 80 | **64** | not stored → 64 |
| `Editor Text Highlight Style` | Yellow…Green | not registered (an unknown string maps to 0 = Yellow) | Green |
| `Editor Syntax Control` | syntax-highlight targets bitmask (adjectives, nouns, …) | 0 (off) | 0 |
| `Typography Content Size` | 4XS…10XL | default not resolved; the preferences slider runs −5…+8 with 14 ticks | **M** |
| Emphasis | Italic / Emphasis Mark | — | — |

Conclusion for Dora's setup: Mono, 16 pt, 64-character limit, Focus mode on with Sentence scope. Typewriter scrolling comes with focus mode.

## 9. Window

| Item | Value | Source | Conf. |
|---|---|---|---|
| Window | A single `IATitlebarWindow` holds the library, the editor and the preview (`IALibraryWindowController`). It is created in code; there is no editor nib. | `IALibraryWindowController init` | extracted |
| Default frame | 720 × 600, centred, then cascaded. It is replaced by the `Library Window Frame` default when that exists (Dora: `{{0,20},{1492,929}}`). | same (`setFrame:display:` with 720.0 / 600.0) | extracted |
| Toolbar | `NSToolbar` with `showsBaselineSeparator = NO`; the titlebar height feeds the editor's top inset | same | extracted |

## 10. Could not extract (measure from a screenshot)

1. The rendered text x-origin and caret height after TextKit rounding. The algorithm in §3 and §4 predicts them; check the predictions against a screenshot.
2. Whether "viewport width W" includes the sidebar or preview. It should be the editor text view's width, and that should be confirmed.
3. The actual titlebar height on macOS 27 (this sets the top inset).
4. Focus-mode transitions: whether the dimming change is animated and how long it takes.
5. Heading rendering. `handleHeadingInRange:` was not read, so it is unknown whether headings change size or weight in the editor. Probably same size and bold, with `#` hanging in the margin.
6. Window minimum size. No `setContentMinSize:` was found for the library window, and `setMinSize:` there is a toolbar item.
7. The default typeface and default content size on a fresh install (both come from runtime helpers).
8. Font-size multipliers 0.86, 0.94 and 0.85 in TypographyKit (composite fallback sources; purpose unknown).
9. Whether the Oklab-based instance `selectedTextBackgroundColor` (§6) is ever used for the visible selection instead of writerBlue α 0.25.
10. How large Wide and Full margins get. The plist prefers 8 margin characters, but the code caps them at 7, so the cap wins. Confirm at window widths above 1250.
