# iA Writer 8.0.6: hiding the interface while typing

Read-only reverse engineering of `/Applications/iA Writer.app` (8.0.6, arm64 slice). The app was not launched. Conventions are the same as `measurements.md`:
- **extracted**: the literal value was read from a resource file or a disassembled constant.
- **inferred**: derived from code flow, or depends on AppKit behaviour that was not disassembled.

Abbreviations:
- `Main` = `Contents/MacOS/iA Writer`
- `WK` = `Frameworks/WindowKit.framework`
- `AKA` = `Frameworks/AppKitAdditions.framework`

Two independent systems are involved:
- **Bottom bar ("Toolbar" in the UI).** This is the format/stats bar under the editor. It is managed by `IABarVisibilityAgent` (Main, a singleton).
- **Title bar.** This is managed by `IATitlebarWindow` (WK). The agent forwards typing and scrolling events to it.

## 1. Settings

| Item | Value | Source | Conf. |
|---|---|---|---|
| Title bar key | `titlebar-visibility` (integer) | `-[IABarVisibilityAgent titlebarVisibilityFromUserDefaults]` | extracted |
| Title bar enum | 0 = Fade In/Out, 1 = Always Show. Any stored value > 0 is read as 1. | popup `titlebarVisibilityButton` tags; `return value > 0` | extracted |
| Bottom bar key | `toolbar-visibility` (integer) | `-[IABarVisibilityAgent toolbarVisibilityFromUserDefaults]` | extracted |
| Bottom bar enum | 0 = Fade In/Out, 1 = Always Show, 2 = Hide. Values are clamped to 0…2. | popup `toolbarVisibilityButton` tags 0/1/2 | extracted |
| Fresh-install default | 0 (Fade In/Out) for both. Neither key is in any `registerDefaults:` call, so `integerForKey:` returns 0. | no other reference to either key in Main | extracted |
| Dora's values | Neither key is stored in `pro.writer.mac.plist`, so both are **Fade In/Out**. | plist | extracted |
| UI | Settings › General: "Title bar:" and "Toolbar:" popups. They are also in the menu bar under View › Title Bar and View › Toolbar (`-[IAAppDelegate changeTitlebarVisibility:/changeToolbarVisibility:]` use the item tag). There is no key equivalent. | `GeneralPreferences.nib`, `MainMenu.nib` | extracted |
| Applying a change | Bottom bar: the setter saves the value and then immediately runs `setHidden:(v==2) animated:YES` on every bar. Title bar: the setter saves the value and posts KVO. Each `IALibraryWindowController` observes `barVisibilityAgent.titlebarVisibility` (KVOController block registered in `-init`). When the new value is 1 (Always Show), the block calls `[window showTitlebar]`, which reveals it animated. Switching to Fade hides nothing until the next key press. | setters; `IALibraryWindowController -init` block at `0x100070b88` | extracted |

The View › Toolbar menu also has "Default / Stats Only". These items set `IAEditorToolbarPreferences.visibleBar`, which chooses the bar's content (format buttons or stats). This setting is separate from visibility.

## 2. What triggers hiding

**Typing.** The agent observes `NSTextDidChangeNotification` for all objects.
- It acts only when `[NSApp currentEvent].type == NSEventTypeKeyDown` (10).
- So the trigger is "a key press changed the text". Moving the caret does not count because the text is unchanged. Pasting from the menu with the mouse does not count either. ⌘V does count. Extracted.
- The notification's object must have `affectsToolbarVisibilityInWindow` and/or `affectsTitlebarVisibilityInWindow` set. These are associated-object flags on NSView.
- Views that set both flags: the editor `IAEditorTextView`, the editor `IAEditorScrollView`, and the legacy web preview. The PDF preview sets only the toolbar flag. Extracted from `-loadView` calls.

**Scrolling.** The agent observes `NSScrollViewWillStartLiveScrollNotification`. This fires at the start of a trackpad or wheel gesture on the flagged scroll view.
- Live scroll alone is enough. The key-down check does not apply. Extracted.
- Typing compared with scrolling: on a keyDown, `mouseDistance…` returns 0 (type mask `0xC00`), so typing hides the bottom bar wherever the pointer is. Only scrolling uses the pointer-zone exceptions below.
- Exceptions: the title bar is not hidden if the mouse is in the title-bar zone (§4). The bottom bar is not hidden if the mouse is inside the bar's zone (`distance == 2`, §4).

**Timing.** There is no delay or timer. Hiding starts on the first qualifying key press or scroll. Extracted: there is no `NSTimer` or `performSelector:afterDelay:` in the agent or the WK hide path.

Flow on a key press, as `-[IABarVisibilityAgent textDidChange:]` does it:
1. If the view has the toolbar flag:
   - `setToolbarsHiddenIfPossible:YES animated:YES withEvent:keyDown window:w`
   - `setTitlebarHiddenIfPossible:YES forOtherTabsInWindow:w`. Despite its name, this hides the *bottom bars* of the other windows in the same native tab group, and only when `w` is the selected tab.
2. If `w` is an `IATitlebarWindow`, the view has the titlebar flag, and `titlebarVisibility == 0`, it calls `-[IATitlebarWindow textDidChange:]`. That method checks keyDown again and that the window is the text view's window, then calls `consultDelegateIfNeededWithEvent:toSetTitlebarElementsHidden:YES animated:YES`.

## 3. What hides

### 3a. Bottom bar (`IAEditorToolbarViewController`)

- **Position.** `initWithToolbarPosition:0`, where 0 = bottom and 1 = top. The find bar is created with position 1. Extracted from `-[IAEditorScrollView commonInit]` and the `-[IAToolbarViewController loadView]` constraints.
- **Height.** `defaultContentHeight` is **32 pt**, or **40 pt** when `_NSGlassEnabled()` (Liquid Glass, macOS 26+). There is also a 1 pt separator. Extracted.
- **Animation.** `-[IAToolbarViewController setHidden:animated:]` sets `_hidden` and tells the delegate, then runs `NSAnimationContext runAnimationGroup:` with:
  - `duration = animated ? 0.15 : 0` (constant `0x100184930` = 0.15). Extracted.
  - `timingFunction = hidden ? kCAMediaTimingFunctionEaseIn : kCAMediaTimingFunctionEaseOut`. So fading out eases in, and fading in eases out. Extracted.
  - `[view.animator setHidden:hidden]`. The view is a plain `_IAToolbarView` (an NSView subclass that adds only `viewDidMoveToWindow`). A hidden change sent through the animator becomes an opacity fade. Inferred: this is AppKit behaviour.
- **Layout effect.** The delegate (`IAEditorViewController`) re-runs `updateScrollerInsets`. The bottom scroller inset and the text view's `visibleRectInsets.bottom` become `contentHeight` (32/40) while the bar is visible and **0** while it is hidden. So the scroller and the visible-rect math extend to the window bottom. Extracted.
- **Always Show.** Hide requests are refused. **Hide** (2): show requests are refused, and the bar starts hidden (`defaultHiddenForToolbarVisibility: = (v == 2)`). Extracted.
- **Tracking areas.** These exist only when visibility is 0 (Fade). Each tracking area is added to the bar's **superview** with options `0x282` = MouseMoved | ActiveAlways | InVisibleRect, so mouse-move events arrive even when the window is not key. Extracted.

### 3b. Title bar (`IATitlebarWindow`, WK)

The window uses the full-size content view (`styleMask |= 0x8000`), `titlebarAppearsTransparent = YES`, and toolbar style 1 (Expanded). The title bar is split into component groups, and each group is hidden separately (`_viewsForTitlebarComponent:`):

| # | Component | Views | Animated via |
|---|---|---|---|
| 0 | title bar | AppKit's private `titlebarViewController.view`, which holds the traffic lights and toolbar (inferred) | alpha |
| 1 | title views | document icon button (4), versions button (6), the title `NSTextField`/`NSClipView`, a private title class (obfuscated name), plus the delegate's `windowViewsToHideWithContentTitlebar:` | alpha |
| 2 | content views | delegate `windowViewsToHideWithContentTitlebar:` | alpha |
| 3 | title-bar background | `titlebarBackgroundView` | `animator.hidden` |
| 4 | tab-bar background | `tabBarBackgroundView` | `animator.hidden` |
| 5 | tab-bar content | `tabBarViewController.view` | `animator.hidden` |
| 6 | badge | `titleBadgeView` | alpha |

`IALibraryWindowController windowViewsToHideWithContentTitlebar:` returns:
- the Preview button
- the Focus segmented control
- the Quick Search button (the toolbar items `IAToolbarPreviewItemIdentifier` / `…FocusSegmentedControlItemIdentifier` / `…QuickSearchItemIdentifier` on Glass)
- `navigationButtonView`
- `progressIndicator`

All extracted.

**Which set hides depends on the Library sidebar** (`consultDelegateIfNeeded…`). Here the window's `sidebarSplitViewItem` is `IALibraryWindowController.sidebarItem`, the Library column in the main split view.
- **Library collapsed (or no sidebar):** `setTitlebarHidden:` hides components **0, 4, 3**, which is the whole title bar including the traffic lights. The delegate `shouldSetTitlebarHidden:` allows this only if the Library is collapsed.
- **Library visible:** `setContentTitlebarHidden:` hides components **1, 2, 3, 4, 5**. The traffic lights stay. The title, document icon and the editor-side toolbar buttons fade. The delegate `shouldSetContentTitlebarHidden:` allows this only if the Library is *not* collapsed.

So hiding does **not** require the sidebar to be collapsed. Collapsing it only changes which parts fade. Extracted.

**Hiding is refused** in these cases. Showing is always allowed unless noted.
- Delegate checks:
  - `titlebarVisibility == 1` (Always Show)
  - the organizer or Library collapse animation is in progress
  - the find bar is visible
- `canSetHidden:forTitlebarComponent:` checks:
  - the left mouse button is held (`pressedMouseButtons == 1`) while not in live resize. This blocks both hiding and showing.
  - a sheet is attached
  - the tab overview is visible
  - a native tab bar is visible: content components 1/2/3 are not hidden while the Library is visible
  - **full screen / entering:** only components 3, 4, 6 may be hidden (mask `0x58`), so the title bar itself never fades in full screen.
  - **while exiting full screen:** every change is refused. The will-enter/will-exit handlers pass `validation:1`, which skips this check.
- Live resize:
  - The agent ignores all bottom-bar changes while the window is in live resize.
  - For the title bar, live resize only waives the mouse-button refusal above.
  - `showTitlebarAnimated:` drops the animation during live resize.
  - WK `scrollViewDidScroll:` skips hiding when the scroll view is in live resize.

All extracted.

**Animation.** The window calls `_setHidden:animated:animatedProperty:onViews:token:completionHandler:`:
- **Duration 0.15 s** both ways (`WK 0x2dd98` = 0.15). Extracted.
- No timing function is set, so the NSAnimationContext default applies. Inferred.
- Alpha components fade out as `animator.alphaValue → 0` and then `hidden = YES` on completion. A random token guards this, so a show that arrives mid-fade wins.
- Showing: `hidden = NO` first, then `animator.alphaValue → 1`.
- Components 3–5 use `animator.setHidden:`.
- While the title bar is hidden, the badge view is removed.

**Layout effect** (`-[IALibraryWindowController _updateForWindowTitlebar:]`, called on `windowDidChangeTitlebarVisibility:`):
- The editor's top scroller inset becomes `currentTitlebarHeight` while the title bar is visible (or while the find bar is visible), and **0** while it is hidden. So the scroller grows into the title-bar area.
- `textView.minimumInsetHeight` stays at the title-bar height, so the text does not move.
- `titlebarVisiblity` returns:
  - 0 = visible
  - 1 = hidden (component 0 hidden, or full screen)
  - 2 = only the background (component 3) hidden, which is the content-titlebar case

All extracted.

## 4. What brings bars back

**Bottom bar: mouse movement into its zone.** The flow is `-[IABarVisibilityAgent mouseMoved:]` → `setToolbarsHiddenIfPossible:NO`. `mouseDistanceToToolbarViewController:withEvent:` works in the bar's superview coordinates, with bar frame height `h`:
- It returns **0** if the event is nil or a keyDown/keyUp (type mask `0xC00`).
- It returns **2 ("inside")** if the pointer is within the bar's rect extended **h × 0.5 toward the content** (upward for a bottom bar). With h = 32 this is about the bottom **48 pt** of the editor (60 pt on Glass).
- It returns **1 ("close")** if the pointer is within the rect extended **h × 4.0** toward the content, about the bottom **160 pt** (200 pt on Glass).

All extracted. Note that `mouseDistanceToToolbarViewControllers:` returns the *first* non-zero result over all bars in the window.

What the agent does with the result:
- The bar is shown only when the distance is 2 (`hidden == (distance != 2)`). Any movement outside the zone leaves it hidden.
- In the "close" zone (distance > 0 and not hiding), `mouseCloseEnoughToPrepareToChangeVisibility = YES`. The first time this happens while the bar is hidden, the delegate calls `updateStats`, so the word-count stats are already current when the bar fades in. Nothing visual happens at this stage.

**Title bar: mouse near the top edge.** `-[IATitlebarWindow mouseMoved:]` uses the window's own tracking area on the theme frame (`0x282`, so it works even when the window is not key). If `mouseNearTitlebarWithEvent:` is true, it calls `consultDelegate…Hidden:NO animated:YES`.
- The zone is a full-width band at the top of `titlebarBackgroundView` with height `currentTitlebarHeight + 20`.
- `currentTitlebarHeight` is `titlebarHeight` (**38 pt**, or **52 pt** on Glass) plus the tab-bar height when native tabs are shown. So the zone is **58 pt** (72 pt on Glass) from the window top.
- In full screen the zone always returns NO, because the system handles the title bar there.

All extracted.

**Other ways the title bar is revealed** (`showTitlebar`, animated unless in live resize):
- window init
- Rename Document
- export progress starting
- a sheet beginning (`windowWillBeginSheet:`)
- the Library sidebar starting to collapse or expand, when no tab-bar split is configured. With a tab-bar split, the component-specific logic in `sidebarSplitViewItemWillChangeCollapsed:` applies instead.

All extracted.

**These do NOT bring anything back**, extracted by absence (no handler in the agent or the WK window):
- the window losing focus (resign key)
- any keyboard combination
- caret movement
- mouse clicks in the text
- scrolling
- general mouse movement over the text, away from the two zones

The only code observing key/resign-key is the bottom bar's stats refresh (`updateStats` on `NSWindowDidBecomeKey/ResignKey`), and it does not touch visibility.

## 5. Cursor, scroller, focus mode, title text

**Mouse cursor.** iA does not call `+[NSCursor setHiddenUntilMouseMoves:]` itself. AKA swizzles it (`+[NSCursor(IAAdditions) load]` exchanges it with `ia_setHiddenUntilMouseMoves:`) only to track the state, posting `IACursorDidHide/ShowNotification`. Extracted. The cursor hiding while typing is NSTextView's standard behaviour. Inferred.

**Scroller.** It is never hidden by this system. Only its insets change (§3a, §3b). Whether it shows follows the system overlay-scroller behaviour. Inferred.

**Focus mode / typewriter mode.** Neither the agent nor the WK window reads them, so bar hiding works the same with Focus on or off. Extracted by absence. (Dora has `Editor Focus Mode = true`.)

**Title text.** The document title, document icon and versions button belong to component 1. They fade with the rest of the bar when the title bar fades with the Library visible, and as part of the AppKit title bar view when the Library is collapsed. WK also has a separate "title views hidden" switch:
- `setTitleViewsHidden:animated:`
- `overrideTitleVisibilityForButtons`, which makes `titleVisibility` report hidden

Main never calls these, so they are inactive in 8.0.6. Extracted.

## 6. Clone recipe (inferred summary)

1. Store two integers: `titlebar` (0 fade, 1 always) and `bottomBar` (0 fade, 1 always, 2 hide). Both default to 0.
2. Observe `NSText.didChangeNotification` from the editor text view. If `NSApp.currentEvent?.type == .keyDown`:
   - Hide the bottom bar wherever the pointer is. On a keyDown the distance is forced to 0, so the pointer zone does not matter.
   - Hide the title bar if the setting is 0, the window is not in full screen, the find bar is closed, no sheet is attached, the left button is not down, and no split view is animating.
   - Do the same on `NSScrollView.willStartLiveScrollNotification`, with two exceptions: keep the bottom bar if the pointer is in its 1.5×h band, and keep the title bar if the pointer is in its top zone.
3. Title bar with the Library collapsed: fade the whole AppKit title bar view (traffic lights included) and the title bar background. With the Library visible: the title bar stays (Draft decision; iA fades the editor-side items). Draft addition (2026-10-16, Dora's request): behind the transparent title bar the page area has a band in the page colour at 85 % opacity, fading out over 12 pt below the title bar, so text scrolled up under the toolbar doesn't run into its buttons; it fades together with the title bar (`TitlebarBand`).
4. Fade: alpha 1↔0 over 0.15 s, then set `isHidden` at the end of a fade-out. Use a generation token so a show cancels a pending hide. Bottom bar curves: easeIn when hiding, easeOut when showing.
5. Show the bottom bar on `mouseMoved` inside the bar frame extended 0.5×h upward (32 pt bar → 48 pt from the bottom). Show the title bar on `mouseMoved` within `titlebarHeight + 20` of the top (38 → 58 pt). Use tracking areas with `.mouseMoved, .activeAlways, .inVisibleRect`. There is no timer and no distance threshold beyond these zones.
6. When a bar is hidden, set its scroller inset to 0. Leave text insets unchanged so the text never moves.

## 7. Unknowns

- **Timing curve for the title-bar fade.** WK does not set one, and the NSAnimationContext default was not verified.
- **Traffic lights in component 0.** That the private `titlebarViewController.view` holds the traffic lights is inferred from AppKit structure, not disassembled. AppKit internals were not examined.
- **Bar frame height h.** It is `contentHeight` (32/40) plus possibly the 1 pt separator. The exact constraint constant was not decoded, so the zone sizes could be off by about 1.5 pt.
- **Glass on Dora's machine.** It depends on `_NSGlassEnabled()` at runtime, which is likely on Darwin 27 but was not verified. This decides between 32 and 40 pt for the bar and between 38 and 52 pt for the title bar.
- **Opacity fade from `animator.setHidden:`.** That AppKit animates this as an opacity fade (bottom bar, components 3–5) is assumed and was not verified by running the app.
- **Input-method (marked text) input.** The keyDown check suggests it hides the bars like normal typing, but this was not tested.
