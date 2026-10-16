# iA Writer 8.0.6: how the editor styles Markdown

Read-only reverse engineering of `/Applications/iA Writer.app` (8.0.6, arm64 slice). The app was not launched. This file covers the **editor** only (not Preview). Base typography, colours, caret, focus dimming, syntax highlight and style check are in `measurements.md`; this file only refers to them.

Confidence levels:
- **extracted**: read literally from a decompiled function, a disassembled constant, a resource file or a nib.
- **inferred**: derived from code flow, from combining extracted values, or from how AppKit normally behaves.

Abbreviations: `TC` = `Kit -[IATextController …]`, `LM` = `Kit -[IALayoutManager …]`, `TK` = TypographyKit, `Main` = the app binary. E = enWidth (10.144 pt for Mono M Regular), h = line-fragment height (= line height, 28.16 pt at M Regular), m = margin character count. Colour names (secondary, tertiary, quaternary, codeBackground, …) are the `NSColor(Writer)` values in `measurements.md` §5.

Tools: Ghidra 12.1.4 headless decompilation of Kit, Main and TypographyKit; `otool`; a NIB parser.

## 0. Corrections to the existing docs

These come out of the decompilation and contradict earlier statements:

1. **Block and emphasis markers are not grey.** `measurements.md` §5 lists `# * _` as using the secondary colour. No code path does that. The secondary colour is only written by: link/image/footnote/reference-definition sub-markers (`TC foundSubMarkerForElement:inRange:` filters on exactly these four element types), backslash escapes, `\` line breaks, `// comments`, `<html>` tags, autolink `<` `>`, wikilink brackets, reference definitions, completed tasks, and style-check matches. `#`, `-`/`*`/`+`, `1.`, `>`, `**`, `*`, `_`, `~~`, `==` and backticks keep the normal text colour (they do get the font/strike/background of their span, see §2). The text storage is a plain `NSTextStorage`; the only hook on it (`TC patchTextStorageIfNeeded:`) adjusts a word-range lookup for hashtags/links, not colours. The Main runtime patches (`IAEditorTextView patchLayoutManager`, `patchFBTBA`, `+initialize`) handle split-view animation display, the link context menu and text-checking, not colours. `IAEditorTextView updateColors` only forces layout and re-dims. Consistency check: `parseLoopSecondaryTextColorIndexes` (the set used to pick tertiary vs quaternary for nested autolinks/hashtags) never receives `#`, list or emphasis markers, so a hashtag inside `**…**` gets the normal secondary underline, which only makes sense if the asterisks are not grey. Conf: extracted (every `secondaryTextColor` reader in Kit and Main checked).
2. **Only headings hang into the margin.** `measurements.md` §3 says list bullets hang. Lists and blockquotes call the indent helper with `shouldHang:NO`; their markers sit inside the text column. See §3. Conf: extracted.
3. **Task markers `- [ ]` are not grey** unless the task is completed (then the whole item is, with the default style). Conf: extracted.

## 1. Pipeline

| Step | What happens | Source | Conf. |
|---|---|---|---|
| Parser choice | `_IALiveParserTargetForPathExtension` returns one of four targets: **3** Markdown types (live Markdown parser); **2** plain text (base attributes + text check, no Markdown); **1** code file types (whole document styled as an indented code block via `applyCodeStylesWithChangeInRange:`); **0** anything else (base attributes only). Text check (style check / syntax) runs only for 2 and 3. | Kit `_IALiveParserTargetForPathExtension`, `TC stringDidChangeInRange:delta:`, `shouldPerformTextCheck` | extracted |
| Reset | Before each parse of a range, `setAttributes:` replaces everything with the base dictionary: font = Normal/Text, paragraph style (see §3), foreground = textColor, `NSLigature` = 0, `IAInlineAttributeMask` = 0. Ligatures are off everywhere. | `TC initWithConfiguration:` (`attributes`), `parser:willStartParsingInRange:` | extracted |
| Block pass | `IAMarkdownLiveParser parseLoopInRange:` works line by line. Fenced and indented code ranges are found first (multi-line regexes) and reported as whole blocks. Every other line is matched against an ordered rule list; a match reports the element and continues on the rest of the line, so containers nest (`> - item`). | `IAMarkdownLiveParser` | extracted |
| Rule order | horizontal rule (stop) → page break (stop) → comment `//` → unordered list / task → blockquote → heading → reference definition → footnote definition → content block (local) → content block (remote image URL) → content block completion → ordered list / task. A line matching nothing gets `indented_line` if it has leading whitespace; an empty line gets `empty_line`. | same, `parseLoopInRange:` block 81 | extracted |
| Inline pass | Markdown.framework (`MDConfiguration`, options 1) calls handlers for emphasis(0), strong(1), strikethrough(2), mark(3), code(4), links, images, reference links, citations, footnotes, autolinks, math, hashtags, HTML tags, wikilinks (+embed, +hashtag forms), backslash escapes. | `TC initWithConfiguration:` blocks, table at Kit `0x660cc0` | extracted |
| Dispatch | Element name → selector dictionaries built in `TC setUpElementHandlerSelectors`. | | extracted |
| End | `parser:didEndParsingInRange:` runs style check / syntax tagging, re-applies saved `IATextAlternatives`, applies authorship colours, `invalidateAttributesInRange:`, `endEditing`. | | extracted |

The block rules (headings, lists, quotes, code, footnotes, content blocks…) are regular expressions inside iA's Kit.framework; they are not reproduced here. Draft's own patterns are in `Markdown.swift` and `EditorTextView.swift`.

## 2. Per-element spec

"Whole span" means the inline element including its markers (MDSpan field `+0x30`; `+0x00` opener, `+0x10` contents, `+0x20` closer — field meaning inferred from usage). All font changes keep the size: **no element changes font size**. Styles: 0 Normal, 1 Strong (`wght` 700, 650 for CJK), 2 Emphasis (Italic face), 3 StrongEmphasis. Font contexts: 0 Text, 1 Code, 2 Indent, 3 Metadata; none of Mono/Duo/Quattro.plist defines a context-specific style (`"Strong Code"` etc.), so every context falls back to the Text font: **code uses the body font** (Mono in Mono, Duo in Duo). Conf: extracted (TK `fontStylePropertiesWithStyle:context:` fallback + plist keys).

### Block elements

| Element | Rule / marker range | Attributes written | Marker treatment | Custom drawing | Conf. |
|---|---|---|---|---|---|
| Heading `#`…`######` | `headingExpression` `^#{1,6}[\t ]+`; marker = the `#`s plus trailing whitespace. Level = count of `#` (1–6). Setext (`===`/`---` underline) is **not** recognised. | Whole line: font style 1 (bold), `IAMarkdownAttributeHeading` = level. Paragraph style = base copy with hanging indent (§3). | Same bold, normal colour. Hangs into the margin. | none | extracted |
| Paragraph / plain line | none | base attributes only | — | — | extracted |
| Empty line | `empty_line` | base paragraph style | — | — | extracted |
| Unordered list `-` `*` `+` | `unorderedListExpression`; marker = group 1 = leading-marker run + optional ` [ ]` + trailing whitespace | `IAMarkdownAttributeList` = NO on the line; paragraph style: leading whitespace and marker widths added to `headIndent` (wrapped lines align under the text); `firstLineHeadIndent` unchanged | normal colour, not hanging; `IATextControllerBlockElementMarker`, checking disabled on marker | none | extracted |
| Ordered list `1.` (also `1.1.`) | `orderedListExpression` group 1 | `IAMarkdownAttributeList` = YES; same paragraph handling | same | none | extracted |
| Task `- [ ]`, `1. [x]` | list rule with group 6 (state char) → `TaskList` element, secondary range = state char | as list, plus `IAMarkdownAttributeTaskBox` on `[ ]` (state−1, len 3), arrow cursor on the state char. If state is `x`/`X`: completed-task style (§4) | `[ ]` normal colour | none | extracted |
| Blockquote `>` (nested `> >`) | `blockQuoteExpression` group 1 (all `>` + spaces) | `IAMarkdownAttributeBlockquote`, Writing Tools disabled; paragraph style as list | normal colour, not hanging; **no bar, no background** | none | extracted |
| Comment `// text` | `commentExpression` group 1 | container attribute (as quote) + **whole line secondary colour** | secondary | none | extracted |
| Horizontal rule `---` `***` `___` (≥3, spaces allowed, ≤3 leading spaces) | `horizontalRuleExpression`, stop | `IAMarkdownAttributeHorizontalRule`, inline-excluded | text stays as typed, normal colour | **none: no line is drawn** | extracted |
| Page break `+++` / `===` | `pageBreakExpression`, stop | `IAMarkdownAttributePageBreak` | plain | none | extracted |
| Fenced code ```` ``` ```` / `~~~` | `fencedCodeExpression` (multi-line, fences included in the range; an unclosed fence is not a block) | `setAttributes:` (replaces everything) with code-block dict: Code-context font (= body font), textColor, `IACodeBlockBackgroundColor` = codeBackground, `IAMarkdownAttributeCode`, checking/correction/Writing Tools disabled, ligatures 0. Per line: leading whitespace width added to `headIndent` (when wrapped-line indent includes whitespace). `IATextAttributeCodeBlock` = YES on fences. | fences normal colour | block background (§5) | extracted |
| Indented code (4 spaces / tab, after a blank line or document start) | `indentedCodeExpression` | same as fenced, `IATextAttributeCodeBlock` = NO | — | block background | extracted |
| Indented plain line | `indented_line` | leading whitespace width added to `headIndent` | — | none | extracted |
| Reference definition `[id]: url "title"` | `referenceDefinitionExpression` | **whole line secondary**; URL (group 6) is a link: fg secondary, single underline tertiary; line inline-excluded, checking disabled | secondary | underline | extracted |
| Footnote definition `[^id]: text` | `footnoteDefinitionExpression` | inline-excluded + checking disabled on the marker range only; no colour | `[^` `]:` secondary (sub-marker) | none | extracted (marker colour inferred from sub-marker path) |
| Citation definition `[#key]: …` | reference rule with `#` | inline-excluded, checking disabled | — | none | extracted |
| Content block `/path/file.png`, `https://…/img.png` | `contentBlockExpression` / `contentBlockRemoteExpression` (whole line, optional title) | removes inline-code bg; `IAContentBlockBackgroundColor` (#FFFFFF / #0D0D0D), `IABackgroundBorderColor` (#E6E6E6 / #2E2E2E), textColor, link type 7, inline-excluded, checking disabled | — | rounded box behind the path text (§5) | extracted |
| Table | no rule, no handler | none: rendered as plain text (monospaced only because Mono is) | — | none | extracted (absence) |
| Front matter `---` … `---` | no rule; both `---` lines match the horizontal-rule rule; Metadata font context never used in the editor | plain | — | none | extracted (absence) |
| Definition list `: text`, super/subscript `^` `~` | no handler | plain | — | none | extracted (absence) |

### Inline elements

| Element | Attributes written (whole span unless noted) | Marker colour | Custom drawing | Conf. |
|---|---|---|---|---|
| Bold `**x**` `__x__` | font style 1 (bold) incl. markers; `IAMarkdownAttributeStrong` | normal, bold | none | extracted |
| Italic `*x*` `_x_` | font style 2 (Italic face, `iAWriter*-Italic`; CJK uses 9.5° oblique of PingFang/Hiragino) incl. markers. In Emphasis-Mark mode the face stays upright and marks are drawn (§6). | normal | emphasis marks (CJK traditions only) | extracted |
| Bold-italic `***x***` | style merge 1+2 → 3 (StrongEmphasis) | normal | — | extracted (merge table in `applyFontWithStyle` block) |
| Strikethrough `~~x~~` | `NSStrikethroughStyle` = 1 (single) incl. markers; colour = foreground (AppKit default thickness/position) | normal, struck | AppKit | extracted |
| Highlight `==x==` | `IABackgroundColor` = highlight bg (style colour × α, `measurements.md` §7); `IATextHighlightUnderlineColor` = highlight underline; runs whose fg is text or secondary → fg = highlight text colour; runs with secondary/tertiary underline → underline = highlight text colour α .35. Inside a completed task: fg secondary, bg tertiary α .25, underline tertiary. | markers highlighted too | square bg + 2 pt bar (§5) | extracted |
| Inline code `` `x` `` | code dict: `IAInlineCodeBackgroundColor` = codeBackground, `IAMarkdownAttributeCode`, checking/correction/Writing Tools off, ligatures 0; Code-context font (= body font) | normal, inside the bg | rounded bg (§5) | extracted |
| Math `$x$`, `\(x\)`, `$$x$$`, `\[x\]` | math dict = inline-code look (same bg, same font) + contiguous + delimiter auto-insertion disabled | normal | same as inline code | extracted |
| Link `[text](url "t")`, image `![alt](url)` | URL contents: link attr type 6, fg secondary, `NSUnderlineStyle` 1, underline tertiary, checking off. Whole link contiguous. | `[` / `![` and the closer `](…)` (incl. title) secondary | AppKit underline | extracted (handler), inferred (span field meaning) |
| Reference link `[text][id]`, `[text][]` | when the `[id]` span is present (non-zero length): opener, closer and the `[id]` part secondary; no link attribute | secondary | — | extracted/inferred |
| Footnote `[^1]`, `[^inline text]` | `[^` and `]` secondary | secondary | — | extracted |
| Citation `[p. 23][#key]` | union of locator/key brackets secondary | secondary | — | extracted |
| Autolink `<https://…>`, bare URL/email | link (type 1–3 by kind) on contents: no fg change, underline tertiary (quaternary when inside an already-secondary range); `<` `>` secondary + contiguous | `<` `>` secondary | underline | extracted |
| Wikilink `[[Page]]`, `[[Page|Label]]`, `![[embed]]` | link type 4 over the target range; fg = secondary **only when an alias exists**, underline = quaternary with alias, tertiary without; opening `[[`, closing `]]` and the separator range secondary | secondary | underline | extracted (colours), inferred (which sub-range is the separator vs label) |
| Hashtag `#tag` (after start/whitespace, needs a letter, ends at whitespace/EOL) | link type 5: **no fg change**, single underline in secondary (tertiary if inside a secondary range), `IAInlineAttributeHashtag`. `writerHashtagTextColor` (#8C8C8C) and `hashtagFont` (system font × 0.85) are **not** used by the editor handler. | `#` not separately coloured | underline only (pill drawing exists in LM but no editor code sets `IAHashtagBackgroundColor`) | extracted |
| HTML tag / comment `<span>`, `<!-- -->` (fixed tag whitelist) | **secondary** fg, contiguous, checking off, inline-code bg removed | secondary | none | extracted |
| Backslash escape `\*` (escapable set: `[ ] \ * + _ # . ! - \` { } ( ) =`) | `\` secondary; escaped char normal | secondary | — | extracted |
| Hard break `\` at end of line | `\` secondary + inline-excluded | secondary | — | extracted |
| Two trailing spaces | nothing | — | — | extracted (absence) |
| Active link (caret inside or mouse over) | fg = `writerActiveLinkTextColor`, underline/strike = active underline colour; wikilinks and content blocks (types 4, 7) outside code get a per-word gradient from `writerLinkGradientColorSequence` instead | — | — | extracted (`Main -[IAEditorTextView _applyActiveAttributesForLinkType:…]`), gradient values not decoded |

## 3. Paragraph style and indentation math

Base paragraph style (`TC initWithConfiguration:`), extracted:
- `min = max lineHeight = h`, `firstLineHeadIndent = headIndent = m·E`, `tailIndent = −m·E`.
- `defaultTabInterval = E · tabWidth`. tabWidth default **2** (registered through `restoreDefaultIndentation`, called from the defaults block); values < 2 become 1 and > 7 become 8.
- Tab stops (left aligned) at `E · ((m mod tabWidth) + k·tabWidth)` for every value below `m + lineCharacterCountLimit` — i.e. aligned to the text column, not to the container edge.
- **No `paragraphSpacing`, `paragraphSpacingBefore`, `lineSpacing` or alignment is ever set.** A blank line is just one more line of height h. There is no extra space around headings, lists, quotes or code blocks.
- A second copy without tab stops (`paragraphStyleForMarkers`) is used only to measure marker widths.

Option bits (`TC options`), extracted:
- bit 0 (`shouldUseHangingMarkdownMarkers`) = viewport class is not Compact.
- bit 1 (`…WrappedLinesWithWhitespace`) and bit 2 (`…WrappedLinesWithMarkdownMarkers`) come from the "Wrapped line indent includes: Whitespace / Markdown block markers" preference (`wrappedLineIndentation`, default 3 = both). Both are forced off when the class is Compact **and** content size ≥ S.

`markerWidth(range)` = `-[NSAttributedString size].width` of the marker substring with its current attributes (headings are already bold; in Mono the advance is the same) and the marker paragraph style; cached by string. Conf: extracted.

**Headings** (`adjustIndent…shouldHang:YES`), extracted:
```
w = markerWidth("## ")                      // # count + trailing whitespace
firstLineHeadIndent = max(m·E − w, 0)
headIndent = firstLineHeadIndent + w        // only if wrapped-indent-with-markers, and not (Compact && level ≥ 5)
every tab stop shifted left by firstLineHeadIndent (stops ≤ 0 dropped)
```
In Mono, `# ` = 2E, `## ` = 3E … `###### ` = 7E. With m = 7 (Regular, wide window) `# ` starts 2 columns left of the text edge and the heading text is flush with body text; `###### ` uses the whole margin; with m = 6 the 7E marker is clipped (`firstLineHeadIndent` = 0, text pushed 1E right). In Compact (m = 0) nothing hangs and the text is pushed right by w.

**Lists, tasks, blockquotes, comments** (`handleContainer:`, `shouldHang:NO`), extracted:
```
ws = leading whitespace of the (remaining) line
if ws and (indentWithWhitespace or indentWithMarkers): headIndent += markerWidth(ws)
if indentWithMarkers: headIndent += markerWidth(marker)     // "- ", "1. ", "- [ ] ", "> "
firstLineHeadIndent stays m·E
```
So the marker sits in the text column and wrapped lines align with the first character after the marker. Nested containers on one line (`> - x`): each handler starts from the base style and sets it on its own range; TextKit uses the style at the paragraph start, so the outer container's indent wins (inferred).

**Indented lines and code blocks**: `headIndent += markerWidth(leading whitespace)` when the whitespace option is on (code blocks: per line). Extracted.

## 4. Editor behaviours

| Behaviour | Spec | Source | Conf. |
|---|---|---|---|
| Enter in a list / quote | After the newline, looks at the preceding line. If it is a list/quote/task line with content, inserts the same marker text (regex match of the block rule): ordered number replaced by `n+1` (`integerValue` + 1, `%tu`, last number group only), task state reset to `[ ]`, leading whitespace kept. If the preceding line is **only** the marker, the marker is deleted instead (ends the list). | `TC smartInsertNewlineMarkerWithRange:` | extracted |
| Enter on an indented plain line | copies the preceding line's leading whitespace | same (`leadingWhitespaceExpression`) | extracted |
| Enter just before an inline closer | if the caret is right before a closing marker (`IAInlineAttributeMarkerMask` bit 0x100) the newline is swallowed: the caret jumps past the closer and any spaces typed before it are moved after it | `TC _smartSkipInlineAttributeCloserInRange:` + `smartInsertDefaultActionMode…` | extracted |
| Shift+Enter | newline, then `\` appended to the end of the previous line (Markdown hard break) | `TC smartInsertNewlineBreakWithRange:`; cfstring `\` | extracted |
| Tab | `tabKeyBehavior` 0 (default "Indents"): indent every selected line by `textPadding` = one tab (Indent using: Tabs, default) or `indentWidth` spaces (2/4/8, default 4). On a blockquote line Tab adds a `>` level instead. ⌥Tab (`insertTabIgnoringFieldEditor:`) does the opposite of the setting (literal tab). Tab accepts a visible completion. | `Main IAEditorTextView insertTab:`, `TC _shiftTextLeftOrRight…`, `textPadding` | extracted |
| Shift+Tab | outdent: removes up to `indentWidth` leading spaces (U+3000 counts as a space) or one tab; on a quote line removes one `>` level | `TC _transformToOutdentTextInLineRange:` | extracted |
| Backspace at end of leading whitespace | outdents instead of deleting one char | `TC smartDeleteBackwardWithRange:` | extracted |
| Backspace on a marker-only line | deletes the whole block marker (`- `, `> `, `1. `) | same | extracted |
| Backspace on an inline marker char | removes the whole formatting (opener + closer, plus U+200C placeholders) rather than one character | `TC _smartDeleteBackwardInlineAttributeInRange:` | extracted (logic), inferred (exact edge cases) |
| Auto-pairing | **only `(` `[` `{`**. Insert: closer added when the next char is end-of-text, whitespace/newline or one of `(){}[],:;="` and a backtick. Wrap: typing an opener with a selection wraps it. Typing the closer when it was auto-inserted types over it; Backspace between an auto pair deletes both. Disabled inside math (`IATextAttributeDelimiterAutoInsertionDisabled`). Quotes, `*`, `_`, backticks are **not** auto-paired. Options key `Editor Delimiter Auto Insertion Options` default **3** (Insert + Wrap). | `TC _smartInsertAutoDelimiterForCharacter:`, `_IADelimiterAutoInsertion*`, prefs block 19 | extracted |
| Formatting toggles (⌘B, ⌘I, …) with no selection | insert an empty pair with a U+200C placeholder (`IAInlineAttributeDiscardableSingleCharacter`); the next typed char replaces the placeholder | `TC smartInsertString:` (consumption side; `_insertEmptyInlineAttribute:` not read) | inferred |
| Smart quotes / dashes / spelling | Not iA logic: the `Editor Text Checking Types` bitmask is applied as `NSTextView enabledTextCheckingTypes` (standard `NSTextCheckingType` bits: spelling 0x2, grammar 0x4, quote 0x40, dash 0x80, replacement 0x100, correction 0x200; allowed mask 0x3C6). Default at registration = spelling, + correction / quote / replacement if the system has them on. **Dora: 768 = replacement + correction; smart quotes off, spelling off.** Smart insert/delete default on. | prefs block 19, `Main IAEditorTextView textCheckingTypes`, `defaults` | extracted |
| Completed task style | `Editor Completed Task Style` bitmask, default **3**: bit 0 = strikethrough (single) on the item text after the marker; bit 1 = whole item in secondary colour (strike colour secondary) and checking disabled. | `TC handleTaskInRange:` | extracted |
| Soft wrap | always wraps at the text-column width; no hard-wrap setting in the editor. "Single return starts a new paragraph" is an HTML-output preference only. | MarkdownPreferences.nib | extracted |
| Selection highlight | `fillBackgroundRectArray:` override shrinks the selection 1 pt at the top of the first line and 1 pt at the bottom of the last | `LM fillBackgroundRectArray:count:forCharacterRange:color:` | extracted |

Indentation preference defaults (`+[IAEditorPreferences restoreDefaultIndentation]` and IndentationPreferences.nib): indent with Tabs (0; 1 = Spaces), tab width **2** (menu 2/4/8), indent width **4** (2/4/8), Tab key = Indents (0; 1 = Inserts tab), wrapped-line indent = Whitespace + Markdown block markers (3). Dora has none of these stored, so she gets the defaults. Conf: extracted.

## 5. Custom drawing in IALayoutManager

`drawBackgroundForGlyphRange:atPoint:` draws, in this order, before calling super (selection etc.). Constants are extracted from Kit `0x4f76f0…0x4f7d58`. Rect `(x, y, w, h)` is each enclosing rect of the attribute run (one per line fragment; its height is the line-fragment height = h, inferred). `fillBackgroundRect` = `NSBezierPath bezierPathWithRoundedRect:xRadius:yRadius:` fill, then `strokeInside` with the border colour when there is one, lineWidth 1. Integer conversions are C truncations `(long)`.

| # | Attribute | Shape | At M Regular (h = 28.16) | Conf. |
|---|---|---|---|---|
| 1 | `IACodeBlockBackgroundColor` (code blocks) | One rect for the whole run: union of all its line fragments, left = origin.x + `firstLineHeadIndent`, right = container width + `tailIndent`, `CGRectIntegral`, radius **3**, no border. The text column plus the 5 pt `lineFragmentPadding` on each side (inferred). Full line heights, so no extra vertical padding. | colour ≈ #EBEBEB light / #202020 dark over the editor background (inferred blend) | extracted |
| 2 | `IAContentBlockBackgroundColor` | inline: H = (long)(h·1.0); pad = (long)(H·0.15) left and right; y = rect.y + H/25 + (long)((h−H)/2); height = H − 2H/25; radius 3; 1 pt border inside | H = 28, pad 4, y + 1.12, height 25.76 | extracted |
| 3 | `IABackgroundColor` (`==highlight==`) | inline: H = (long)h; no horizontal pad; radius 0 | y + 1.12, height 25.76, square corners | extracted |
| 4 | `IAInlineCodeBackgroundColor` (inline code, math) | inline: H = (long)(h·0.95); pad = (long)(H·0.05); radius 3 | H = 26, ±1 pt, y + 2.04, height 23.92 | extracted |
| 5 | `IAHashtagBackgroundColor` | inline: H = (long)(h·0.9); radius = (long)(H·0.475) (pill) | never set by the editor | extracted |
| 6 | `IATextHighlightUnderlineColor` | style 0: bar of thickness T = (long)(h·0.1) at the bottom of the line fragment: y = rect.y + h − T + T/25, height = T − 2T/25, radius T/2 = (long)(h·0.1)·0.5, same x/width as the glyph rect. Style ≠ 0 (custom style-check underline): dotted, dots of 3.5 pt, 2 pt above the bottom. | T = 2 → 1.84 pt bar, radius 1, at the bottom edge of the 28.16 pt line box | extracted |
| 7 | authorship underline | not covered | — | — |

Pads on the first/last rect of a multi-line run use the "outer" fraction, inner breaks use the "inner" fraction; all registered values have outer = inner. Extracted.

Other LM behaviour, extracted:
- Baseline: `baselineOffset = (h + capHeight)/2` (already in `measurements.md` §4).
- `drawGlyphsForGlyphRange:` → super, then emphasis marks (§6).
- `showCGGlyphs:` only special-cases the AI-authorship text gradient (`IATextGradient`), shadows and inverted kern; no marker recolouring.
- Temporary attributes (focus dimming) are honoured only while drawing glyphs.
- No horizontal-rule, blockquote-bar, list-bullet or heading drawing exists.

## 6. CJK specifics

| Item | Spec | Source | Conf. |
|---|---|---|---|
| Tradition | 0 default (Latin), 1 zh-Hans, 2 zh-Hant, 3 ja, 4 ko. Chosen in settings or "System": first `NSLocale.preferredLanguages` entry matched by prefix against `zh-Hans`, `zh-Hant`, `ja`, `ko`. Dora's first language is `en-TW` → **default tradition** unless she picked one (no override found in her defaults). | TK `IATypographySettings tradition`, `_IATypographyTraditionFromLanguage` | extracted (rule), inferred (her effective value) |
| Emphasis setting | per tradition (`setEmphasis:forTradition:`): 0 Italic, 1 Emphasis Mark. Allowed: default → italic only; zh-Hans/zh-Hant → either; ja/ko → mark only. Default for every CJK tradition = Mark. | TK `_IATypographyTraditionAllowsEmphasis`, `…DefaultEmphasis` | extracted |
| Emphasis mark drawing | When emphasis = Mark and the tradition has a position: every non-whitespace character in an Emphasis/StrongEmphasis run (markers excluded via `_IATextControllerInlineMarkerRangeForExcludingFromEmphasisMark`) gets one `IATextEmphasis`: string U+E000 from the plist `EmphasisMark` font (`iAWriterEmphasis-Regular`, `-Semibold` for StrongEmphasis), size = 0.5 × body size, colour = textColor. Drawn after the glyphs, per glyph: x = glyphRect.minX + (long)((glyphRect.width − markWidth)/2); position 1 (zh-Hans, zh-Hant): y = glyphRect.maxY − markHeight − markHeight/27.5 (bottom of the line box, i.e. **below** the text); position 0 (ja, ko): y = glyphRect.minY + markHeight/35 (**above**). The emphasised text itself stays upright (EmphasisMark face = Regular). Latin characters inside the run get marks too. | `TC setTextEmphasisWithStyle:…`, `IATextEmphasis drawInRect:`, `_IATextEmphasisYWithPositionAndSizeWithinRect` (−27.5, 35.0), position table `0x4f79c0` = [1,1,0,0] | extracted constants; "below/above" reading inferred |
| Italic for CJK | Emphasis/StrongEmphasis CJK fallback = PingFang/Hiragino/Apple SD Gothic with a **9.5° oblique** (Semibold/W6/Bold for StrongEmphasis) | plist `Oblique` | extracted |
| Full-width punctuation | `iAWriterFullSpace{JA,KR,SC,TC}` substitutes full-width punctuation (see `measurements.md` §1). There is no punctuation compression. | plist | extracted |
| Line breaking (kinsoku) | No custom code: no `lineBreakStrategy`, hyphenation or kinsoku tables in Kit, TK or Main; paragraph styles are fresh `NSMutableParagraphStyle` objects. TextKit 1's default Unicode line breaking applies. | strings / decompile | extracted (absence); behaviour inferred |
| CJK–Latin auto-spacing | none (no kern/tracking/spacing code) | strings | extracted (absence) |
| Ideographic space | U+3000 counts as whitespace in every block regex, in outdent and in the non-whitespace set (`\t`, space, U+3000) | regex file, `TC _transformToOutdent…` | extracted |
| Weight | CJK text uses `wght` 400 (Normal) and 650 (Strong) | `measurements.md` §2 | extracted |

## 7. Unknowns

1. Whether iA intends markers to look grey: the code never greys them (§0.1). If the real app shows grey `#`/`**`, the mechanism is outside everything decompiled (Kit IATextController/IALayoutManager/live parser, Main IAEditorTextView, TypographyKit). Checking one screenshot settles it.
2. Inline rules inside Markdown.framework were not decompiled: intraword `_`, nesting of `**` inside `*`, precedence between code spans and emphasis, which bare URLs/emails autolink, math delimiter rules.
3. MDSpan / MDWikilink field meaning is inferred from usage; the exact sub-ranges coloured for `[[Page|Label]]` and for link titles need a visual check.
4. `LM rectArrayForCharacterRange:…`, `enumerateEnclosingRects…` and `getLineFragmentInsertionPointsForCharacterAtIndex:` are overridden but not read; they may change caret positions or selection shapes around hanging heading markers.
5. Exact colour of the per-word gradient for active wikilinks/content blocks (`writerLinkGradientColorSequence`).
6. Strikethrough thickness/offset: AppKit defaults, not measured.
7. Code-block background colour hex values are alpha blends computed here, not measured.
8. The live parser's handling of a container followed by another block element on the same line beyond lists in quotes (e.g. heading inside a quote) — the rule loop continues on the remaining range but paragraph-style precedence was not tested.
9. Dora's effective tradition if she set it in the Typography settings sheet under a key not visible in `defaults read pro.writer.mac`.
