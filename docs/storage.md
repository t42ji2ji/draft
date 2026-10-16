# iA Writer 8.0.6: document storage, naming and saving

Read-only reverse engineering of `/Applications/iA Writer.app` (8.0.6, arm64 slice) together with Dora's preferences, index database and iCloud library. The app was not launched. Document contents were not read, except to compute statistics: encoding, line endings, how the first line compares with the filename, and whether frontmatter or authorship blocks are present.

Confidence levels follow `measurements.md`:
- **extracted**: read literally from a resource, a plist, a disassembled constant or a method body.
- **inferred**: derived from code flow, from AppKit semantics or from on-disk evidence.

Abbreviations:
- `Main` = `Contents/MacOS/iA Writer`
- `Kit` = `Frameworks/Kit.framework`
- `FA` = `Frameworks/FoundationAdditions.framework`
- `MD` = `Frameworks/Markdown.framework`
- Prefs = `~/Library/Containers/pro.writer.mac/Data/Library/Preferences/pro.writer.mac.plist`

The app is sandboxed, so `defaults read pro.writer.mac` returns this container plist. `Last Launched Version` still reads `5.6.16`, but `index.db` and the plist were both modified on 2026-10-07, which means 8.x has run and simply no longer updates that key.

## 1. Library model

### 1.1 Locations

| Item | Value | Source | Conf. |
|---|---|---|---|
| Default location, iCloud | ubiquity container `27N4MQEA55.pro.writer`, folder `Documents`. On disk: `~/Library/Mobile Documents/27N4MQEA55~pro~writer/Documents`. Display name "iCloud" | entitlements, `Info.plist NSUbiquitousContainers`, `FA Cloud_Location` | extracted |
| Default location, no iCloud | `NSSearchPathForDirectoriesInDomains(NSDocumentDirectory)`. In the sandbox this is `~/Library/Containers/pro.writer.mac/Data/Documents`. Display name "Local" | `Kit -[IALibraryController _updateLocalDocumentsObserver]`, `FA On_My_Device_Location` | extracted |
| Which location is the default | `documentsURL` returns the ubiquitous URL when one exists, otherwise the local one. The iCloud URL and the identity token are cached in `index.db` `KeyValueStore` (`Ubiquitous Documents URL`, `Ubiquitous Documents Identity Token`). If the token changes (sign-out or a different account), the default location is removed from the index and re-resolved | `Kit -[IALibraryController documentsURL]`, `_updateUbiquitousDocumentsObserver` | extracted |
| Custom locations | Any folder the user adds. Each one is stored as a security-scoped bookmark in `Library Locations Bookmarks` (an NSKeyedArchiver `NSMutableArray` of `IAFileBookmark`). A folder that sits inside an existing location, or contains one, is refused with "Cannot Add an Existing Library Location" | `FA IAFileBookmarkStore`, Kit.strings | extracted |
| `<Store> Options` bit 0 | Enables that nested-location check, through `_validateForNestedItemsWithURL:` | `FA -[IAFileBookmarkStore _reallyValidateURL:…]` | extracted |
| Dropbox and Google Drive | Recognised by the path regexes `/Users/\w+/Dropbox` and `/Users/\w+/Google Drive`, and by paths under `Library/CloudStorage/`. Toggled by `Library Locations Include Dropbox` and `Library Locations Include Google Drive` | Main strings, prefs | extracted |
| "Open Files" pseudo-location | Identifier `External` (`IALibraryLocationIdentifierExternal`). It indexes documents that are open from outside the library. Bookmarks for these are in `External Files Bookmarks` | `Kit -[IALibraryController externalFilesLocation]`, `index.db Location` | extracted |
| Favorites | `Favorites Bookmarks` and `Favorites Manual Order`. Items reach Favorites only by being dragged into the sidebar | Main Localizable `Library_Root_Favorites_Empty_Message` | extracted |
| Index | `~/Library/Containers/pro.writer.mac/Data/Library/Application Support/iA Writer/index.db`, a SQLite database. Tables: `Location`, `Item`, `Reference`, `Symbol`, `KeyValueStore`, plus an FTS5 table `Content(path, body)` with the custom tokenizer `ia`. Library paths look like `iCloud:/name.txt` | sqlite `.schema` | extracted |

### 1.2 Dora's values

| Key | Decoded value | Conf. |
|---|---|---|
| `Library Locations Bookmarks`, `Favorites Bookmarks`, `External Files Bookmarks` | All three are empty `NSMutableArray`s. She has no custom locations, favorites or external files | extracted |
| `Library Locations Options` | 1 (nested check on). `Favorites Options` and `External Files Options` are 0 | extracted |
| `Library Locations Include Dropbox` / `Include Google Drive` | 0 / 0 | extracted |
| `Library Navigation History Records` | One `IANavigationHistoryRecord`: category `libraryLocation`, destination `iCloud:/`, `treeState` = {moves: [], expanded: [], actions: []} | extracted |
| `Library Window State` | `IALibraryWindowState`: `sidebarVisible` YES, `organizerVisible` YES, `IAEditorPreviewSize` Full, `IAEditorPreviewVisibleFull` NO, `IAEditorPreviewVisibleSplit` NO | extracted |
| `Library Window Frame` | `{{0, 20}, {1492, 929}}` | extracted |
| Split views | Library split: sidebar 158 pt, file list 272 pt. Main split: library 430 pt, then a 1 pt divider, then the editor 1061 pt | extracted |
| `index.db Location` | 1 = `Default`, path `…/27N4MQEA55~pro~writer/Documents`, name `iCloud`, 31 items, all indexed. 2 = `External`, name `Open Files`, empty | extracted |
| `Document Path Extension` | `txt` | extracted |

### 1.3 Her library on disk

`~/Library/Mobile Documents/27N4MQEA55~pro~writer/Documents` contains no subfolders: 31 `.txt` files and one `.DS_Store`. Example names: `How to Do Great Work.txt`, `回聲.txt`, `貼圖.txt`, `安.txt`.

Four of the files are dataless, meaning iCloud has evicted their contents. Even `ls -l` blocked on that folder until it timed out. The clone must not assume it can read the bytes of every file in an iCloud folder, and directory scans need a timeout.

| Property (27 readable files) | Value | Conf. |
|---|---|---|
| Encoding | 27/27 UTF-8 with no BOM | extracted |
| Line endings | 27/27 LF only. No CR anywhere | extracted |
| Trailing newline | Mixed: 14 have one, 13 do not. Not enforced | extracted |
| Frontmatter or authorship block | None present | extracted |
| Filename vs first line | 10 identical, 4 are a prefix of the first line (cut at sentence punctuation), and 13 differ. The differing cases are explained by Markdown markers being stripped (`# `, `## `), by `，` becoming `,` (NFKD), by trailing `」？：。` being trimmed, and by first lines that were edited after the first save (see §3.4) | extracted |
| Unicode form of names | NFC as stored. NFKD leaves CJK unchanged and only folds compatibility characters such as full-width punctuation | extracted |
| xattrs | Every file has `net.ia.writer.selectedRange` and `net.ia.writer.visibleRange`: a bplist wrapping NSData of an `NSStringFromRange` string, e.g. `{9223372036854775807, 0}`. `com.apple.FinderInfo` has finder flag `0x0010` (kExtensionHidden) set | extracted |

## 2. File format

| Item | Value | Source | Conf. |
|---|---|---|---|
| Default extension, fresh install | `txt`. `_defaultPathExtension` returns `@"txt"`. The preferences class registers no other default | `Kit -[IADocumentPreferences _defaultPathExtension]` | extracted |
| Defaults key | `Document Path Extension` (identifier `Document` + property `pathExtension`) | `Kit IADocumentPreferences` init block | extracted |
| Validation | Lowercased, then must fully match `[a-z0-9]{1,25}` and conform to plain text. Otherwise it falls back to `txt`. Preferences UI text: "New files will have this extension. Only plain text extensions are allowed." | `Kit +[IATextNormalization normalizedPathExtension:]`, `FilesPreferences.nib` | extracted |
| Extension of a document | The existing file's extension if it has one. Otherwise the display name's extension if it has one. Otherwise the default | `Kit -[IADocument pathExtension]`, `fileNameExtensionForType:saveOperation:` | extracted |
| `md` vs `txt` | Content is the same either way. Authorship annotations are only allowed when the extension is Markdown ("Authorship is supported only in Markdown files.") | Kit.strings, `-[IADocument readFromURL:error:]` (`annotationsAllowed` depends on the extension) | extracted / inferred |
| New document encoding | `NSUTF8StringEncoding` (ivar set to 4) | `Kit -[IADocument commonInit]` | extracted |
| New document line breaks | `lineBreakType` = 0. LF is the most likely meaning, because every file on disk uses LF | `Kit -[IADocument commonInit]` | 0 extracted / LF inferred |
| Existing files | Encoding and line-break type are detected on read (`detectedEncodingType`, `detectedLineBreakType`) and written back unchanged. If the encoding cannot be detected the error is "The text encoding of the contents could not be determined." | `Kit -[IADocument readFromURL:error:]`, Kit.strings | extracted |
| Trailing newline | Not added or removed. The text is written as it is | `dataOfType:` → `MDSerializationWritingRequest` (no newline step); disk evidence | inferred |
| Authorship | Kept in the file as a block at the end: `---` followed by `Annotations: <start>,<len> SHA-256 <hex>` and per-author lines. Hidden in iA Writer's editor but visible in other apps | `MD` regexes `\b([0-9]+,[0-9]+) SHA-256 ([a-fA-F0-9]{20,64})\b`, Kit.strings `Authorship_Prompt` | extracted (exact block grammar not decoded) |
| File attributes on write | `NSFileExtensionHidden = YES` on every write | `Kit -[IADocument fileAttributesToWriteToURL:error:]` | extracted |
| xattrs on write | After each successful `writeToURL:` the app writes `net.ia.writer.template` (template identifier, if any), `net.ia.writer.visibleRange` and `net.ia.writer.selectedRange` (archived range data). They are read back on open. If `selectedRange` is missing, the caret goes to the end of the text | `Main -[IALibraryDocument write/readExtendedAttributes…]` | extracted |
| Word files (.docx) | Opened as "Viewer": converted to an untitled plain-text document with automatic naming turned off, and the display name set to the .docx name without its extension | `Main -[IALibraryDocumentController makeDocumentWithContentsOfURL:ofType:error:]` | extracted |

## 3. New document flow

### 3.1 Entry points

| Action | Behaviour | Source | Conf. |
|---|---|---|---|
| ⌘N, Dock click, or launch with nothing open | Calls `_newDocument:`. If `newInLibraryByDefault` (default YES) it creates a new document in the library; otherwise it uses the plain NSDocument "New" (untitled, outside the library, save panel on close). Preferences labels: "Files will be automatically created in Library." and "Files will ask whether you want to save them when closed." | `Main -[IAAppDelegate _newDocument:]`, `Kit IAInterfacePreferences` defaults block, `FilesPreferences.nib` | extracted |
| New in Library | Finds a library window, brings it to the front, and calls `newDocumentInLibraryInWindow:`. If there is no such window, it opens one | `Main -[IAAppDelegate newDocumentInLibraryInWindow:]` | extracted |
| Target folder | The library view's `contextMenuDestinationFolderURL`. That is the folder currently navigated to in the library list. For a Smart Folder it is the first destination that is a directory. Otherwise it is the default location root | `Main -[IALibraryViewController _updateFolderURL]`, `-[IALibraryWindowController newDocumentInLibraryInWindow:]` | extracted |
| Save panel | None. The document is created untitled with `folderURL` set. A save panel appears only for "New" outside the library, or for Save As. In that panel the allowed types are the default extension plus `public.text`, and the default directory is `folderURL` | `Main -[IALibraryDocument prepareSavePanel:]`, `_defaultDirectoryURLForSaveOperation:` | extracted |
| Reusing an empty draft | If the window already shows a document that has never been saved and whose text is empty, that document is retargeted to the new folder instead of creating another one | `Main -[IALibraryWindowController _reuseOpenDocumentForNewWithFolderURL:…]` | extracted |
| Initial state | `text = ""`, `shouldNameAutomatically = YES`, `remainsOpen = YES`, and the template identifier comes from the template preferences | `Main -[IALibraryDocument initWithType:error:]`, `init` | extracted |

### 3.2 When the file is first written

The title-bar name updates live while the user types. The file itself is created at the first of the following events (all extracted from `Main IALibraryDocument`):

1. **The name becomes final** (§3.3), for example when Return is pressed after the first non-empty line. `setText:` calls `updateDisplayNameAndSaveIfNecessary`. If the document has no `fileURL` and has a `folderURL`, and the name is final, and `didNameAutomatically` is still NO, the method sets that flag and calls `saveDocument:`.
2. **⌘S, close, quit, or any autosave that is not implicitly cancellable.** For an untitled document with a folder, `saveDocumentWithDelegate:` writes non-empty text to `folderURL/<current name>.<ext>`, whether or not the name is final. Empty text calls the didSave callback with success and writes nothing.
3. **Periodic autosave is suppressed until then.** `shouldPreventAutosaveForBetterAutomaticName` returns YES while the document is untitled, has a folder, is set to name automatically, and the name is not yet final. `autosaveWithImplicitCancellability:YES` then does nothing at all, so no copy is made in `Autosave Information` either.

Closing an empty new document never creates a file, so there is nothing to clean up. A file that was saved and later emptied stays on disk as an empty file, shown in the library with the snippet "Empty Document" (inferred: no deletion path was found).

Write sequence (`_prepareToSaveDocumentToFolderWithHandler:`):
1. `createDirectoryAtURL:folderURL withIntermediateDirectories:YES`.
2. Build `name + "." + ext`.
3. Pass it through `autoIncrementedURLWithURL:suffix:` (§3.5).
4. Call `saveToURL:ofType:forSaveOperation:`.

### 3.3 Filename from the text

Source: `Kit +[IATextNormalization nameWithText:final:]`, `nameRangeWithText:final:`, `normalizedNameLineWithLine:keepPlainTextContentBlocks:` and `normalizedNameWithUserInput:`. All extracted.

1. **Choose a line.** Enumerate lines and take the first one that is non-empty after steps 2 and 3. For the document's very first line, plain-text content-block references are kept; on later lines they are dropped.
2. **Strip Markdown.** Using the Markdown parser, delete these ranges:
   - inline delimiters (emphasis, code, strike and so on; inline mask `0x7f`)
   - metadata
   - HTML tags
   - wikilink brackets
   - link and image syntax: the brackets and URL are removed, the link text is kept
   - the `http`/`https` scheme of autolinks
   - ordered and unordered list markers
   - heading markers (`#`)
   - comment delimiters
   - content-block paths

   Then collapse `[\t ]{2,}` to a single space and trim characters from the set `| : \t space U+3000`.
3. **Sanitise.**
   - Cut to 255 UTF-16 units if longer.
   - Remove leading dots.
   - Replace `([0-9]+)/(?=[0-9])` with `$1.` (so `10/14` becomes `10.14`).
   - Replace `[:/ ]+` with a single space.
   - Trim tab, space and U+3000.
   - Apply NFKD (`decomposedStringWithCompatibilityMapping`).

   There are no other illegal characters to handle: `/` and `:` are the only characters that cannot appear in a macOS filename.
4. **Cut to the first sentence.** Enumerate sentences (`NSStringEnumerationBySentences`). Each candidate range runs from the start of the line to the end of a sentence. Trim trailing characters that belong to (punctuation ∪ {space, U+3000}) minus `(` and `)`. Accept the candidate if it is at least 5 UTF-16 units long and does not end in an ASCII digit; otherwise extend to the next sentence. As a result, `Hi. How are you?` becomes `Hi. How are you`, and `1. Intro` is not cut after `1`.
5. **Length cap: 64 UTF-16 units.** If the result is empty or longer than 64, cut at the last word boundary that ends at or before 64 (`ByWords | Localized`). If no word fits, cut at the last composed-character boundary at or before 64.
6. **Final NFKD.** If the result is empty, use `Default_Document_Name`, which is "Untitled" (localised).

**The name is final when** the chosen line ends with a line terminator, meaning the user has pressed Return after it. It is also final when the line is longer than 64 units and had to be cut, or when a sentence that is already longer than 64 is followed by more text.

**Before the first save**, `preferredName` (if set) overrides the computed display name. It is set by Duplicate and by programmatic creation.

### 3.4 Renaming

| Item | Value | Source | Conf. |
|---|---|---|---|
| Rename when the first line changes | Never, once the file exists. `updateDisplayNameAndSaveIfNecessary` returns immediately when `fileURL` is set. Her library confirms this: several files no longer match their first line | `Main`, disk | extracted |
| Manual rename | Through the title-bar rename (`renameDocument:`; for a never-saved document this saves into the folder first) or Library → Rename. The new name goes through `normalizedNameToRenameItemWithName:toName:`: the existing extension is kept unless the user typed a valid plain-text extension, and the stem is sanitised as in §3.3 step 3 | `Main -[IALibraryDocument renameDocument:]`, `Kit +[IATextNormalization normalizedNameToRenameItem…]` | extracted |

Draft: `DocumentName.renamedFileName` (extension rule and §3.3 step 3 sanitising), then `uniqueFileName` against the folder minus the file itself, then `NSDocument.move(to:)`.

### 3.5 Name collisions

Source: `FA _IAUniquePathComponentWithSuffixAndDirectoryContents`, called by `Kit -[IADocument autoIncrementedURLWithURL:suffix:]`. Extracted.

1. List the destination directory.
2. Strip the suffix and any trailing ` N` (N from 1 to 999) from the requested stem using `(<suffix>)?(?: +([1-9][0-9]{0,2}))?$`. Base = the remaining stem + the suffix.
3. For each directory entry, strip ` N` the same way. If its base matches case-insensitively and its extension matches case-insensitively, record N as taken (an entry with no number counts as "no-number").
4. If the plain name is free, use it. Otherwise try ` 2`, ` 3`, and so on. This gives `Name.txt`, `Name 2.txt`, `Name 3.txt`.
5. Duplicate uses the suffix `Duplicate_Item_Suffix` = " copy", so a duplicate of `Name.txt` is `Name copy.txt`, then `Name copy 2.txt`. The duplicate is saved straight away into the source document's folder.

## 4. Saving after creation

| Item | Value | Source | Conf. |
|---|---|---|---|
| `autosavesInPlace` | YES | `Kit +[IADocument autosavesInPlace]` | extracted |
| `autosavingDelay` | 30 s, set on the document controller | `Kit -[IADocumentController commonInit]` | extracted |
| Effective timing | AppKit's in-place autosave: the document is written a few seconds after editing pauses and also when the app is deactivated, closed or quits. The 30 s value is the controller setting; the exact interval for in-place autosave is decided by AppKit | AppKit behaviour | inferred |
| Asynchronous writes | `canAsynchronouslyWriteToURL:…` returns YES | Kit | extracted |
| Before each save | `commitChanges`: the window controller pushes the pending selection and visible ranges into the document so they go into the xattrs | `Main -[IALibraryDocument saveToURL:…]` | extracted |
| "Ask to keep changes when closed" | Maps to the system `NSCloseAlwaysConfirmsChanges`. Default off ("Files are always automatically saved."). Dora: 0 | `FilesPreferences.nib`, prefs | extracted |
| "Close when quitting" | Inverse of `NSQuitAlwaysKeepsWindows`. Dora: keeps windows, so open documents are restored at launch. A draft that was never saved restores its folder from `IADocumentRestorableFolderURLKey` | nib, `Main encodeRestorableStateWithCoder:` | extracted |
| Changes made outside the app | `IADocument` is an `NSFilePresenter`. On `presentedItemDidChange` it does a coordinated read. If the modification date is unchanged, nothing happens. If the SHA-256 of the file equals the SHA-256 of the in-memory data, only the date is refreshed. Otherwise: if the document has no unsaved edits it reverts silently (`revertToContentsOfURL:`); if it has edits it shows "The file “%@” was changed externally." with the buttons **Keep iA Writer Version** (saves), **Revert** and **Save As…** | `Kit IADocument presentedItemDidChange` blocks, `_fileHashIsEqualToDataHash` | extracted (branch order) / inferred (button mapping) |
| File deleted outside the app | `accommodatePresentedItemDeletion…` posts a document-deleted notification, and the controller removes the document | Kit | extracted |
| Versions | Standard NSDocument versions (Revert To / Browse All Versions) through `NSFileVersion`. The presenter callbacks `presentedItemDidGainVersion` and `presentedItemDidResolveConflictVersion` and the class `IAFileVersionBrowser` exist. There is no custom revision store | `FA`, Kit symbols | inferred |
| Inactive documents | Up to 10 documents with no window stay in memory (`maximumInactiveDocumentCount = 10`). This makes switching files in the library fast. The oldest ones are closed (and saved) once there are more than 10 | `Main -[IALibraryDocumentController commonInit]`, `processInactiveDocuments:` | extracted |
| Closing the current document in a library window | The window immediately gets a new empty draft for the same library (`newDocumentInLibraryInWindow:`) | `Main -[IALibraryDocumentController _closeDocument:]` | extracted |
| Draft's implementation of the two rows above | Switching to another document detaches the current one without writing it, including a never-written draft (it keeps a row at the top of its folder's list). `DocumentController.trimInactiveDocuments` closes the oldest beyond 10, which writes a non-empty draft through `canClose`. ⌘W runs `LibraryWindowController.closeDocument:`: detach, open a new draft in the window, then close (and so write) the old document. On quit AppKit closes every document itself; the library window's own close-on-window-close is skipped while that is under way, because closing documents from both sides left quit hanging | Draft | — |
| External (non-library) document | `folderURL` is `fileURL`'s parent when the file has been saved, and the ivar while it is untitled. The import prompt reads: "You’re editing a document outside iA Writer Library. You can continue editing, or you can move it to the Library." Buttons: Move / Move to “%@” / Copy to “%@” | `Main -[IALibraryDocument folderURL]`, Localizable | extracted |

## 5. Library list behaviour relevant to storage

| Item | Value | Source | Conf. |
|---|---|---|---|
| Default view options | `sortBy` 0, `sortOptions` 0 (folders not pinned), `visibleDate` 0, `visibleExcerpt` YES | `Kit -[IALibraryViewOptions init]` | extracted |
| Ascending defaults | `sortBy` 0 and 1 descending, 2 and 3 ascending (`ascending = index > 1`) | `Kit _IAAscendingSortByDefaultDictionary` | extracted |
| `sortBy` enum | 0 = Date Modified, 1 = Date Created, 2 = Name, 3 = Extension. This is consistent with dates defaulting to "Newest on Top" and with the order of the Preferences popup | Kit.strings, `LibraryPreferences.nib` | inferred |
| Sort descriptor order | Secondary items last, then folders first (only if "Pin folders to top", `sortOptions` bit 0), then the `sortBy` key | `Kit -[IALibraryViewOptions sortDescriptors]` | extracted |
| Preference keys | `Library Sort Order`, `Library Search Sort Order`, `Library Pin Folders To Top`, `Library Show Text Snippet`, `Library Show Extension` (migrated into `fileExtensionVisibility`, default 1 = show) | Kit cfstrings, `IAInterfacePreferences` defaults block | extracted |
| Displayed name | Draft (no file yet): the live name from §3.3. Saved file: the filename without its extension, unless extensions are shown. Untitled document with a folder: its would-be URL is `folder/displayName` (`backreferenceURL`) | `Main -[IALibraryDocument displayNameShowingFileExtension:]` | extracted |
| Snippet | A text excerpt, or "Empty Document" for zero-length files, or "Updating…" | Localizable | extracted |
| New folder name | "Untitled Folder" | Kit.strings | extracted |
| "Loading" text | "Loading documents… This may take a few minutes if you have a large library." | Localizable | extracted |

## 6. Frontmatter, images and content blocks

| Item | Value | Source | Conf. |
|---|---|---|---|
| Frontmatter | No frontmatter is generated. The parser recognises it (`MDMetadata`), and it is excluded when the name is derived | `normalizedNameLineWithLine` metadata handler | extracted |
| Dropped or pasted files | Handled by `IALibraryImportOperation`. The destination is the document's `folderURL`, which is the directory of the saved file or the draft's target folder. A drag that copies, copies the file; otherwise it moves it. A content-block line is then inserted. There is no `assets/` folder | `Main -[IAEditorViewController textView:insertContentBlocksFromPasteboard:copy:inRange:]` | extracted (destination) / inferred (no subfolder) |
| Content-block path form | A preference with the options Shortest / Relative / Absolute (`Library_Destination_*`). "Shortest" is the bare filename when that is unambiguous. A leading `/` is deprecated | Kit.strings | extracted |
| Outside the library | Error "Content blocks are supported only by files in Library." | Kit.strings, error code 7 | extracted |
| Allowed content-block types | Plain-text files (Markdown, CSV and so on) and images | Kit.strings | extracted |
