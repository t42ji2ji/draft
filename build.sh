#!/bin/zsh
# Build Draft.app into ./build
set -e
cd "$(dirname "$0")"
# SwiftPM records sdk 14.0 in LC_BUILD_VERSION, which keeps AppKit in pre-Liquid-Glass compatibility mode; record the real SDK.
swift build -c release -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$(xcrun --show-sdk-version)"
APP=build/Draft.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/Draft $APP/Contents/MacOS/
cp Info.plist $APP/Contents/
cp -R Resources/Fonts Resources/StyleRules Resources/Preview $APP/Contents/Resources/
cp Resources/Icon/AppIcon.icns $APP/Contents/Resources/
cp Resources/Brand/*.pdf $APP/Contents/Resources/
# A stable identity keeps macOS privacy grants (e.g. Documents folder access) across rebuilds; ad-hoc changes every build.
codesign -s "Developer ID Application" --force $APP >/dev/null 2>&1 || codesign -s - --force $APP >/dev/null 2>&1
echo "built $APP"
