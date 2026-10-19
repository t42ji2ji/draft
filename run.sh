#!/bin/zsh
# Build, quit the running Draft, install the fresh build in /Applications and open it, so what's on screen is always the latest code.
set -e
cd "$(dirname "$0")"
./build.sh
# A normal quit, not kill: never-written drafts are saved on quit.
osascript -e "tell application id \"$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' Info.plist)\" to quit" 2>/dev/null || true
while pgrep -x Draft >/dev/null; do sleep 0.2; done
rm -rf /Applications/Draft.app
ditto build/Draft.app /Applications/Draft.app
open /Applications/Draft.app
