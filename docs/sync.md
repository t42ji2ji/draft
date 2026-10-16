# Git sync

Git replaces iCloud for the library. The library folder (`LibraryPath`) is the repository. Code: `Sources/Draft/Sync/`.

## Settings

| Key | Default | Effect |
|---|---|---|
| `SyncEnabled` | off | Off: nothing runs and no `.git` is created. On: `git init -b main` if the folder is not a repository, then local commits. |
| `SyncRemote` | none | Any URL git accepts. Empty: local commits only. Set: fetch, rebase and push to `origin`. The URL is written to `origin` on the next cycle. |

There is no settings UI yet: `defaults write app.dorara.draft SyncEnabled -bool YES` and `defaults write app.dorara.draft SyncRemote <url>`. Draft never creates a remote.

## When it runs

- **Commit:** 30 s after the last `noteSaved(url:)` (the URL is not checked; it may be NSDocument's temporary file), and at the start of every sync cycle. Stages everything (`git add -A`). Message: `Update <up to 3 file names>`. `.DS_Store` and `*.icloud` are excluded through `.git/info/exclude`, so no file is added to the library.
- **Sync cycle:** 3 s after launch, 5 s after wake from sleep, every 5 min, and when the status item is clicked. Order: commit, `fetch origin`, rebase local commits onto `origin/<branch>`, `push -u origin HEAD:<branch>`.
- An empty library on a new machine checks out the remote branch instead of rebasing.
- All git work runs on one serial background queue. Launch does no git or file work on the main thread.

## Git binary and environment

The first of `/opt/homebrew/bin/git`, the Command Line Tools git and the Xcode git that runs `--version` successfully. `/usr/bin/git` is never used, because without developer tools it opens the install dialog. `/usr/local/bin` is skipped because on this Mac it holds an Intel Homebrew that cannot run. Without git the status shows "Sync error".

Every call: `GIT_TERMINAL_PROMPT=0`, `ssh -oBatchMode=yes -oConnectTimeout=10`, `commit.gpgsign=false`, `core.quotepath=false`, and a 30 s timeout (60 s for fetch and push), so a hung network or a credential prompt cannot stall the queue. When `user.email` is not configured, commits are made as `Draft <draft@localhost>`.

## Conflicts

Text is never dropped:

| Case | Result |
|---|---|
| Same file edited on both machines | The file keeps this machine's text. The other machine's text is written next to it as `Name (conflict YYYY-MM-DD).ext` and committed. An identical existing copy is reused; a different one gets ` 2`, ` 3`. |
| Deleted here, edited there (or the reverse) | The edited file is kept and reported as the conflict. No copy. |
| Both machines added a file with the same name (two libraries joined) | Same as an edit on both sides. |

If the push is rejected because the remote moved after the fetch, the cycle runs once more right away.

After a conflict the rebase is finished and the tree is clean, but sync pauses: local commits continue, pull and push stop, and the status reads "Conflict: <copy name>". Clicking it calls `resume()`, which pushes the resolved history. Relaunching also resumes.

A failure the rules above cannot resolve aborts the rebase (`rebase --abort`), so the repository returns to the local commits; uncommitted edits made during the rebase are written back after the abort.

## Open documents

- Before rebasing, sync takes a coordinated write on every file that differs from the remote. Open documents (NSFilePresenter) hold their saves until git finishes. A save that landed just before is committed first; if the tree is still dirty the cycle is skipped.
- An open document that is itself in conflict never sees conflict markers: the presenter is notified once, after the local text is back in place (measured).
- The coordinated write has no timeout: a presenter that never relinquishes stalls sync until relaunch.
- git writes the files directly. macOS still delivers `presentedItemDidChange` to presenters for uncoordinated writes, including `git checkout` and rebase (measured), so `TextDocument.presentedItemDidChange` runs: an unedited document reverts silently, an edited one shows the "changed externally" alert.
- A pulled file gets a new modification date, so it moves up in a Date-Modified list. git does not carry the `app.dorara.draft.selectedRange` xattr, so the caret of a pulled file goes to the end.

## Startup cleanup

Each cycle, before any git command: a `.git/index.lock` is removed when no `git` process is running (`pgrep -x git`), and a rebase left by a crash (`.git/rebase-merge` or `rebase-apply`) is aborted.

## Status

`SyncStatusView` (an NSButton, or `SyncStatusView.makeToolbarItem()`) shows Syncing…, Synced 14:02, Committed 14:02, Local, Offline, Conflict, or Sync error, with details in the tooltip. Conflict and error are orange. It is hidden while sync is off. No sounds or notifications.

## Library location

The `.git` folder must not be inside iCloud Drive: iCloud can evict or duplicate files inside it. `~/Documents/Draft` is safe only while Desktop & Documents iCloud sync is off. Since 2026-10-16 the default library (`LibraryPath` unset) is `iCloud Drive/Draft` when iCloud Drive is on, so iCloud and git sync are alternatives: turning git sync on needs a library outside iCloud Drive. Nothing checks this yet.

## Test harness

`swiftc LibrarySync.swift testing.swift main.swift` against a local bare repository and three working copies: first push to an empty remote, debounced commit, clean rebase of edits to different files, same-file conflict (with an NSFilePresenter watching), paused push and resume, modify/delete, offline remote, stale `index.lock`, interrupted rebase, and joining an unrelated library. All 46 checks pass. Not exercised: a push rejected by a race, and a real `TextDocument` (checked with plain NSFilePresenters).
