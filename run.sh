#!/bin/zsh
# Build, quit the running Draft and open the fresh build, so what's on screen is always the latest code.
set -e
cd "$(dirname "$0")"
./build.sh
# A normal quit, not kill: never-written drafts are saved on quit.
osascript -e "tell application id \"$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' Info.plist)\" to quit" 2>/dev/null || true
while pgrep -f "build/Draft.app/Contents/MacOS/Draft" >/dev/null; do sleep 0.2; done
open build/Draft.app
