# Library window: values used and where they come from

Draft's library window started as a copy of iA Writer 8.0.6's library window (sidebar | file list | editor in one window). Since 2026-10-15 the sidebar and the file list are one column, a folder tree (Dora's request), and the list's column shows the open document's headings (`#` to `######`, outside code blocks, indented 12 pt per level; a click puts the caret on the heading). The window is tree | outline | editor. Since 2026-10-15 the outline is part of the writing area (Dora's request): same page colour and paper pattern as the editor (lined up with it and moving with its scrolling), no divider line, and its own toggle (« at the right of its 章節 header, » at the page's top left when folded, ⇧⌘O, View → Show Outline); the library button (⌃⌘S, View → Show Library) hides only the tree. First-run widths: tree 240 pt, outline 200 pt. Launch reopens the file shown last (path in the `LastDocumentPath` default, written whenever a saved file is shown; Dora's request, 2026-10-15); if it's gone, launch starts with an empty draft as before. The file-list values below (geometry, list fonts and colours, sort, filter) are kept as the record of iA's list; Draft no longer has that list. Values were taken from two sources:
- **screenshot**: iA running on macOS 27.0.1, dark appearance, window 1512 × 949 pt, captured at 2× with `screencapture -l` and measured pixel by pixel. iA's window was inactive when captured.
- **binary**: the `NSColor(Writer)` category in `Contents/MacOS/iA Writer`. Each method calls `colorWithWhite:alpha:` with one of two doubles picked by `fcsel` (the dark value when the argument is YES). The doubles were read from `__const` at the addresses the method loads.

Draft was captured at the same window size and compared against iA, then adjusted until the positions below matched to within 1–2 pt. Code: `Sources/Draft/Library/LibraryStyle.swift` and the view controllers next to it.

## Geometry

| Item | Value | Source |
|---|---|---|
| Sidebar width | 158 pt | iA prefs (`NSSplitView Subview Frames`), confirmed in the screenshot |
| File list width | 272 pt, editor starts at x = 431 | same |
| Toolbar height | 52 pt | screenshot |
| List header ("Sort by Date Modified") | pill 23 pt tall, 8 pt from the list's left edge, top 0.5 pt below the toolbar; list rows start 31 pt below the toolbar | screenshot |
| File row | 68 pt pitch including a 1 pt separator; three 18 pt lines (title + 2 excerpt lines) centred | screenshot |
| Row icon | x = 19–21 pt; the system plain-text document icon | screenshot |
| Row text | x = 40 pt; the date's right edge sits 30 pt from the list's right edge | screenshot |
| Row separator | from x = 39 to 4 pt past the date's right edge | screenshot |
| Title truncation | in the middle (`作為一個9…個經典.txt`); the extension is shown | screenshot; extension visibility default 1 in storage.md §5 |
| Excerpt | text with Markdown markers removed and lines joined by spaces; the second line is clipped without an ellipsis | screenshot |
| Bottom bars (Filter, format bar) | 39 pt including a 1 pt top separator | screenshot |
| Filter field | 9 pt side margins, 26 pt tall, filter icon (`line.3.horizontal.decrease.circle`) | screenshot |
| Sidebar rows | items 32 pt; section titles 24 pt; the "Drag folders…" placeholder 53 pt (3 lines of 16 pt) | screenshot |
| Format bar items | Body starts 25 pt into the editor pane; 20 pt between items, 17 pt after Body and Heading 1, 16 pt either side of the group dividers; word count ends 25 pt from the right edge | screenshot |
| Default window | 1100 × 720 pt (iA's code default is 720 × 600, but at that size the editor would be 290 pt wide) | deviation |

## Fonts

| Item | Value | Source |
|---|---|---|
| List title, date, excerpt | system 13 pt regular. The ink width of `事實上.txt` (57 pt) and of `2019/8/10` (57.5 pt) both match 13 pt regular | screenshot + width check against `NSFont` |
| Sort pill | system 11 pt medium | ink width 115 pt for "Sort by Date Modified" |
| Format bar | system 13 pt; Bold semibold, Italic italic, Strikethrough struck through | ink widths of "Blockquote" (67 pt) and "Strikethrough" (83 pt) |
| Sidebar section titles | 11 pt semibold | "Locations" ink width 51 pt |
| Sidebar items | 13 pt ("illustration" is 62.5 pt wide in both apps) | screenshot |
| Location / document title in the toolbar | 14 pt semibold ("iCloud" ink width 42.5 pt) | screenshot |

## Colours (white level, light / dark)

| Role | Light | Dark | Source |
|---|---|---|---|
| List background | 0.99 | 0.08 (#141414; measured 20,20,20) | `writerLibraryBackgroundColor…` |
| Title text | 0.10 | 0.725 (measured 185) | `writerLibraryPrimaryTextColor…` |
| Date, excerpt | 0.60 | 0.46 (measured 117) | `writerLibrarySecondaryTextColor…` |
| Row and bar separators | 0.93 | 0.13 (measured 33) | `writerLibrarySeparatorColor…`, Liquid Glass branch |
| Current row | black α 0.05 | white α 0.10 | `writerLibrarySelectedBackgroundColor…` |
| Sort pill text | 0.50 | 0.56 | `writerLibrarySortToolbarTintColor…` |
| Format bar text | editor text colour (0.10 / 0.80; measured 205) | | screenshot |
| Active block (Body / Heading n / List / Blockquote) | writerBlue P3 (0, 0.75, 1) | same | screenshot shows "Body" in blue; colour from measurements.md §5 |
| Sidebar icon tints | folder #00C7FF, smart folder #9887F2, hashtag #8E8E93 | same | InterfaceFoundation asset catalog |

Other library colours found in the binary but not used yet: alternate background 0.96 / 0.09, toolbar background 0.98 / 0.10, selected separator (glass) 0.85 α 0.9 / white α 0.05, filter placeholder 0.60 / white α 0.40.

## Behaviour

| Item | Draft | Source |
|---|---|---|
| Sort | the tree is by name; there is no sort menu and no Filter field | |
| Date format | `yyyy/M/d` | screenshot |
| Word count | each Han, kana or hangul character counts as one word, and every other run of letters and digits counts as one. For 安.txt this gives 2,816, the same number iA shows | count on the file |
| Selecting a file | opens it in the same editor. Up to 10 documents stay loaded without a window | storage.md §4 |
| Switching away from a never-written draft | the draft is written to a file then, so it appears in the tree. Empty drafts are dropped. (iA keeps it in memory, unwritten.) | Dora's choice |
| ⌘W (File → Close) | closes the current document only; the window stays and shows a new empty draft in the browsed folder. ⇧⌘W (Close Window) and the red button close the window | storage.md §4 `_closeDocument:` |
| Rename | click the title in the toolbar (it is an in-place text field; the stem is pre-selected by Library → Rename…, which File → Rename… also reaches). Return or clicking away renames, Escape cancels. Name cleanup per storage.md §3.4; collisions get ` 2`, ` 3`. A never-written draft is written first, then renamed | storage.md §3.4 |
| Favorites | drag folders or text files from the list, the sidebar or Finder onto the Favorites section. Only items inside the library are accepted (the list only knows scanned folders). Paths are stored in the `Favorites` default; right-click → Remove from Favorites. A file favourite opens the file. A favourite whose file or folder no longer exists (deleted, or renamed outside Draft) is dropped from the default when the sidebar rebuilds, except while a Draft rename is still finishing or the library folder itself is missing; moves and renames done in Draft carry the favourite to the new path (2026-10-16, Dora's request) | Dora's request |
| Library tree | Locations is a folder tree: the library root, then each folder's subfolders and then its files, both by name. A click on a folder (or a hashtag) opens or closes it; open folders are remembered in the `SidebarExpanded` default. A hashtag expands to the files containing it. Smart Folders (Recents) was removed 2026-10-15 (Dora's request). File rows are 26 pt. First-run width 260 pt | Dora's request |
| Multiple selection | shift-click selects a range, ⌘-click adds or removes a row (Draft addition, Dora's request). With one row selected a file opens as before; with several nothing opens. Several rows drag into a folder together, and ⌘⌫ or right-click → Move to Trash / Show in Finder / Remove from Favorites act on all of them; Rename and Duplicate only appear for a single file | Dora's request |
| Moving files | drag files or folders in the tree (or items from Finder that are inside the library) onto a folder to move them there; dropping on a file means its folder. The move is coordinated, so an open document follows its file; name clashes get ` 2`, ` 3`. A folder can't go into itself | |
| Library updates | the first scan reads excerpts in parallel off the main thread. After that FSEvents paths are coalesced (0.15 s) and only those paths are re-stat'ed and re-read; a new or renamed folder brings its subtree. Rows redraw in place when the order is unchanged; the sidebar rebuilds only when folders or the hashtag set change. Hidden paths (anything under `.git`) are ignored. Typing in a draft redraws just its row | |
| Back / forward | document history only; the folder back/forward and the location label went with the list | |
| + menu (chevron) | New File, New Folder, both in the selected folder or the open file's folder ("Untitled Folder", "Untitled Folder 2", …) | Kit.strings "Untitled Folder" |

## Not copied

- iA's sidebar is a floating glass panel with an opaque fill (#212121 when inactive). Draft uses the standard source-list sidebar, so its colour follows the system.
- Editor toolbar buttons on the right (Focus, Quick Search, Preview) come from `Preview/PreviewToolbar.swift`; Quick Search has no feature behind it yet.
- Favorites outside the library folder are refused rather than scanned.
