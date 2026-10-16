#!/bin/zsh
# build/Draft.dmg for download: Developer ID with hardened runtime, notarized and stapled.
# Built from a clean checkout of HEAD, so uncommitted changes are left out.
# Notarization uses the keychain profile away-blur (shared by the developer account).
set -e
cd "${0:A:h}"
IDENTITY=40EE56946432E9A272F0B129ED83D5E843B5EAE8
OUT=$PWD/build
W=$(mktemp -d)/draft
git worktree add -q --detach $W HEAD
trap "git worktree remove --force $W" EXIT
(cd $W && ./build.sh)
APP=$W/build/Draft.app
codesign --force --options runtime --timestamp -s $IDENTITY $APP
ditto -c -k --keepParent $APP $W/build/Draft.zip
xcrun notarytool submit $W/build/Draft.zip --keychain-profile away-blur --wait
xcrun stapler staple $APP
STAGE=$W/build/dmg && mkdir -p $STAGE
cp -R $APP $STAGE/ && ln -s /Applications $STAGE/Applications
mkdir -p $OUT && rm -f $OUT/Draft.dmg
hdiutil create -volname Draft -srcfolder $STAGE -format UDZO -quiet $OUT/Draft.dmg
codesign --force --timestamp -s $IDENTITY $OUT/Draft.dmg
xcrun notarytool submit $OUT/Draft.dmg --keychain-profile away-blur --wait
xcrun stapler staple $OUT/Draft.dmg
spctl --assess --type open --context context:primary-signature -v $OUT/Draft.dmg
echo "done: $OUT/Draft.dmg"
