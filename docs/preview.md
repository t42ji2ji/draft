# Preview: iA Writer 8.0.6 behaviour and Draft's implementation

Sources:
- **binary**: strings and the compiled `Base.lproj/Menu.nib` (NIBArchive parsed) of `/Applications/iA Writer.app` 8.0.6; `Kit.framework` strings.
- **resource**: file names, class names and JavaScript entry points seen in the app bundle (`Contents/Resources/Templates`, `Kit.framework/Resources`). Draft's templates, page scripts and stylesheets are its own (rewritten 2026-10-16); nothing is copied from the bundle.
- **screenshot / AX**: iA running hidden on macOS 27.0.1, dark appearance, window 1492 × 929 pt, driven only through the accessibility tree (bg-drive), sample `scratchpad/compare/sample.md`.

Confidence: **extracted** = read from a file, string or the AX tree; **measured** = from screenshots; **inferred** = reasoned from the above, not observed directly.

Code: `Sources/Draft/Preview/`. Resources: `Resources/Preview/` (`Style/` shared CSS, `Templates/`, `Kit/` page scripts, `Fonts/`). Third-party pieces and their licences: `THIRD_PARTY_LICENSES.md`.

## 1. Toggling and the right-hand toolbar items

The editor toolbar ends with three items. Identifiers are from the binary; roles from the AX tree.

| Item | Identifier | What it does | Conf. |
|---|---|---|---|
| ≡ with chevron | `IAToolbarFocusSegmentedControlItemIdentifier` | An `AXRadioGroup` of two parts. The left part toggles Focus Mode (same as Focus > Enable Focus Mode, ⌘D). The chevron opens the focus menu (`makeFocusMenu`): Sentence, Paragraph, Typewriter. Not a preview control. | extracted (strings `focusSegmentedControl`, `focusSegmentedControlClicked:`, `makeFocusMenu`; AX) |
| Syntax ⌄, Style Check ⌄ | `syntax`, `styleCheck` | Draft additions (2026-10-15, Dora's request), right of ≡. Shaped like ≡ ⌄ (2026-10-16): clicking the icon toggles Syntax / Style Check and the icon segment stays selected while on; the chevron opens the Focus menu's Syntax section (Show/Hide Syntax, then the parts of speech) and Style Check section (Enable/Disable Style Check, then Fillers, Clichés, Redundancies). Symbols `highlighter` and `checkmark.seal`. | – |
| 🔍 | `IAToolbarQuickSearchItemIdentifier` | Quick Search (⇧⌘O, `showQuickSearch:`). Not in Draft's toolbar: no Quick Search yet. | extracted |
| ▶ | `IAToolbarPreviewItemIdentifier` | `AXCheckBox "Preview"`, symbol `play`. Toggles the preview (`togglePreview:`, ⌘R). Its image changes with visibility (`previewButtonImageForPreviewVisible:`). | extracted; filled image when on is inferred |

The ≡ icon is iA's own image asset `focus-3.0`; Draft uses the SF Symbol `text.alignleft` (deviation).

Menu items (Menu.nib):

| Menu item | Shortcut | Action | Tag |
|---|---|---|---|
| Show Preview | ⌘R | `togglePreview:` | |
| Reload Preview | ⇧⌘R | `reloadPreview:` | |
| Web / PDF | – | `changePreviewDisplayModeTo:` | 0 / 1 |
| Full / Split | – | `changePreviewWidthTo:` | 0 / 1 |
| Fit Width / Fit Page (PDF mode) | – | `zoomPDFToFitWidth:` / `zoomPDFToFitPage:` | |
| Preview > Template ▸ | – | template list | |
| Export… | ⇧⌘E | `exportDocument:` | |
| Print… | ⌘P | `printFormatted:` | |
| Print Plain Text… | ⌥⌘P | `printPlainText:` | |
| Copy HTML | ⇧⌘C | `copyHTML:` | |
| Copy Formatted | ⌥⌘C | `copyFormatted:` | |
| Quick Search | ⇧⌘O | `showQuickSearch:` | |

State is saved in `Library Window State` (`IALibraryWindowState.editorPreviewState`): `IAEditorPreviewSize` (Full/Split), `IAEditorPreviewVisibleFull`, `IAEditorPreviewVisibleSplit` (extracted, see storage.md). Visibility is remembered separately for each size (inferred from the key names).

## 2. Layouts

| Layout | Behaviour | Conf. |
|---|---|---|
| Full | The preview replaces the editor in the editor pane (431 → 1492 pt in the test window). The editor's format bar is replaced by the preview bar. | screenshot |
| Split | Editor and preview side by side, each half of the editor pane (≈ 530 pt each), each with its own bottom bar. | screenshot |

The preview bar (`IAPreviewToolbarViewController`) is the same height as the format bar (39 pt with its separator): **Web** **PDF** at the left, the template pop-up (e.g. "Modern (Sans) ⌃⌄") centred, **Split** **Full** at the right. The selected item in each pair is blue (screenshot). PDF mode shows the document as light paginated pages with a page number in the footer, on a grey background, regardless of appearance (screenshot).

## 3. Rendering pipeline

iA's page is the template's `document.html` (body `<body data-document>`). Kit.framework drives it with JavaScript (format strings extracted from Kit):

```
Template.insertStylesheets("<urlencoded JSON [{id, style}]>")
Template.updateClass("<urlencoded JSON [classes]>")
Template.updateLang("…")
Template.updateInset("%fpx")          // html padding-top and padding-bottom
Template.updateContent("<urlencoded {document: html}>", "<urlencoded {useDiffHTML: true}>")
Template.updateMath();  Template.updateSmartTables();
```

Page scripts in `Resources/Preview/Kit`: Draft's own `Template.js` (the seven calls above, nothing else), `SmartTables.js` (table formulas on top of math.js and Numeral) and `mark.css` (highlight colours, alphas from `Settings.Highlight.backgroundAlpha`); the open-source `diffHTML.js` (DOM diffing for live updates), `KaTeX.js` + `mhchem.js` + `copy-tex.js` + `KaTeX.css` (math), `Math.js`, `Numeral.js`.

`<html>` classes Kit knows (extracted): `night-mode`, `center-headings`, `number-headings`, `indent-paragraphs`, `macos-device`, `content-size-4xs … 10xl`. Draft sets `mac macos-device center-headings emphasis-italic content-size-m green-mark` plus `night-mode` in dark appearance; its CSS keys on `mac`, `center-headings`, `emphasis-italic` / `emphasis-mark`, `content-size-*`, `*-mark` and `night-mode`. These match iA's screenshot: centred headings, italic blockquote, green highlight (Dora's highlight colour), text #cccccc on #101010 (measured pixels).

CSS layout: `Style/base.css` holds every rule and reads custom properties; `serif.css`, `sans.css` and `writer.css` (Mono, Duo, Quattro) are profiles that set the numbers (line grid, sizes, spacing, weights); each template's `template.css` imports one profile and names its faces. `document.html` links `../../../../Style/base.css` and `template.css`; HTML export inlines both. `fonts.css` declares the faces as "Draft Sans", "Draft Mono" etc., each `local()` first, then the app's URL.

`html lang`: the templates choose fonts by `:lang(x-default-zh-Hant)` etc. iA's preview shows Latin in IBM Plex Sans and Han in PingFang TC, which is the `x-default-zh-Hant` rule. Draft derives the tag from the first CJK language in the user's preferred languages (inferred mapping).

Fonts: `fonts.css` loads `url("ia-writer-font://Name.ttf")`; Draft registers that scheme (`PreviewSchemeHandler`) and serves `Resources/Preview/Fonts` (IBM Plex Sans/Serif, KaTeX) and `Resources/Fonts` (iA Writer Mono/Duo/Quattro, Emphasis; all OFL — Mono and Quattro are the public variable builds, PostScript names `iAWriterMonoV-*` / `iAWriterQuattroV-*`).

Inset: measured so the first line sits where iA's does — 24 px when the pane starts below the 52 pt toolbar. With that inset every text row of the sample lands within 1 pt of iA's, horizontally and vertically (row-by-row ink comparison, `scratchpad/preview/tools/rows`).

Templates (`Resources/Preview/Templates`, same set as iA): Sans — the default —, Serif, Mono, Duo, Quattro, GitHub (github-markdown-css 5.8.1, MIT, dark file scoped to `html.night-mode`). Names come from each bundle's `en.lproj/InfoPlist.strings`; `IATemplateHeaderHeight` / `IATemplateFooterHeight` (90) from `Info.plist`; bundle ids are `app.dorara.draft.template.<name>`, so a template saved before 2026-10-16 falls back to Sans once.

## 4. Markdown → HTML

iA's HTML comes from a modified **MultiMarkdown 6** inside Kit (extracted: MMD6's HTML/LaTeX/ODT/OPML/LyX writers and its footnote, glossary and citation strings are all present). Kit also contains cmark (`data-sourcepos="%d:%d-%d:%d"`), used elsewhere (inferred). The AX tree of iA's preview confirms MMD list semantics on the sample: the block

```
- item / - item / ··- nested item / 1. ordered one / 2. ordered two / - [ ] task item
```

renders as **one flat `<ul>` of six items**: a two-space indent does not nest, and `1.` continues the bullet list. CommonMark would give a nested list, an `<ol>` and a third list.

So Draft uses a small in-repo renderer (`PreviewRenderer.swift`) that follows MultiMarkdown's block rules and emits iA's strings:

| Feature | Output | Conf. |
|---|---|---|
| Headings (ATX, setext) | `<h2 id="secondheading">`; id = lower-cased text without spaces/punctuation (MMD label) | strings extracted; id rule inferred |
| Lists | MMD rules: nesting needs 4 spaces; later items keep the first list's type; loose if blank lines separate items | AX-confirmed on the sample |
| Task lists | `<li class="task-list-item"><input type="checkbox" class="task-list-item-checkbox" disabled[ checked]>` | extracted |
| Footnotes | `<sup><a href="#fnN" id="fnrN" title="see footnote" class="footnote">N</a></sup>`; `<div class="footnotes"><hr /><ol><li id="fnN">… <a href="#fnrN" title="return to article" class="reversefootnote">&#8617;&#xFE0E;</a>`; inline `^[…]` too | extracted (`fn%s`/`fnr%s`; the exact id text is inferred) |
| Highlight / strike | `<mark>`, `<del>` | extracted |
| Math | `<span class="math">\(…\)</span>`, `\[…\]` for `$$`; rendered by `Template.updateMath()` (KaTeX) | extracted |
| Tables | MMD form with `<colgroup>` and `style="text-align:…;"`; SmartTables runs after | extracted |
| Images | `![alt](src)` alone in a paragraph → `<figure><img … /><figcaption>alt</figcaption></figure>`; inline otherwise | extracted (`<figure>`, `<figcaption>`) |
| Content blocks | a line `/file.png "Title"` → figure; `/file.csv` → table; `/file.md` → rendered in place; other text files → `<pre><code>` | output shape inferred |
| Wikilinks | `<a class="wikilink" title="X" href="X">X</a>` (also `[[X|label]]`) | extracted |
| Autolinks | `<url>` → `<a href>`; bare URLs → `<a class="autolink" href>` | extracted (`class="autolink"`) |
| TOC | `{{TOC}}` → `<div class="TOC"><ul>…` nested by level | extracted (`<div class="TOC">`) |
| Code | fenced (`<pre><code class="lang">`) and indented | extracted |
| Mermaid (Draft addition, 2026-10-20, Dora's request) | ```` ```mermaid ```` stays `<pre><code class="mermaid">`; `Template.updateMermaid()` draws it with Pele (`Kit/Pele.js`, obsidianmd/pele 1.7.0) into a `div.mermaid-diagram` after the `<code>`, which the CSS then hides. Colours come from `--page` / `--text` (a palette overrides both). A source with an error shows Pele's error instead of the diagram. HTML/PDF export not yet checked | — |
| Front matter | a leading YAML block is not rendered | inferred |

Not implemented: MMD metadata, smart quotes, CriticMarkup, citations/glossary, abbreviations, definition lists, sub/superscript, hashtag links (iA has `hashtagPreviewOutput` settings; default unknown).

Why in-repo: an SPM dependency (swift-cmark) would need Package.swift and gives CommonMark lists, which do not match iA; a JS renderer in the page would also be CommonMark and would need the same MMD patches. The renderer is ~900 lines, runs on a background queue, and renders the sample in ~2 ms.

## 5. Live update and scroll sync

| Item | Value | Conf. |
|---|---|---|
| Live update | Every text change restarts a timer (iA: `_previewUpdateTimer`); Draft waits 0.15 s, renders off the main thread, and patches the DOM with diffHTML (`useDiffHTML`). Measured in the harness: preview updated 160 ms after the last keystroke. | timer extracted; interval inferred |
| Scroll sync | iA has `IAScrollViewPositionSyncAgent` and a "Scroll Position Sync Enabled" preference; the mechanism was not observed. Draft maps source lines: top-level blocks carry `data-line`; the preview scrolls so a given (fractional) source line is at the top, interpolating between blocks, and reports its own top line back while the user scrolls it. | inferred |

## 6. WebKit is loaded on first use

Linking WebKit and PDFKit costs launch time even when no web view is made: `dlopen` of WebKit after AppKit is up took ~8 ms (7 of 8 runs), PDFKit ~1 ms. Draft does not link either: `WebKitRuntime.swift` dlopens them when the preview is first shown and talks to WKWebView / PDFView through the Objective-C runtime. `otool -L` on a release build shows neither framework. A cleaner alternative is a separate dynamic target loaded with `dlopen`, which needs Package.swift and build.sh changes.

## 7. Export and print

iA's formats (strings): HTML, PDF, Word (`word/document.xml`, `Word.preprocessImages()`), and from MultiMarkdown ODT, LaTeX, OPML, LyX; iA reads HTML for export with `document.documentElement.outerHTML`. Draft implements:

| | How | Notes |
|---|---|---|
| Export HTML | the live page's `outerHTML`, template `<link>`s replaced by their CSS with `@import`s inlined, `data-line`, `night-mode` and the inset removed, image paths made relative to the document | fonts fall back to `local()` / system fonts (the app-only `ia-writer-font://` URLs are dropped) |
| Export PDF | WKWebView's print operation saved to a file; the template's `@media print` rules apply; light classes; top/bottom margins = template header/footer height (90 pt) | iA's header (title, date) and footer (page number) pages are not drawn |
| Print… | same print operation with the print panel | |
| Copy HTML | the body HTML (no template) to the pasteboard | |
| PDF display mode | the same PDF in a PDFView in place of the web view | |

Known gaps: Word export; header/footer pages; `printPlainText:`. While printing, the page switches to light classes through JavaScript just before WebKit captures it; the order has held in testing but is not guaranteed by WebKit. WKWebView paginates only through `runModal`; `NSPrintOperation.run()` loops forever.
