#!/bin/zsh
# 上線一個新版本：改版號、commit、tag、push，從 tag 的乾淨副本做公證過的 DMG（release.sh），發 GitHub Release，
# 官網改版號並部署。
#   ./publish.sh 0.2 notes.md
# notes.md 是 release 說明（中英文）。只發已經 commit 的東西：工作目錄裡沒 commit 的改動不會進 DMG。
# 官網在另一個 repo ~/me/draft-site（只在本機，沒有 remote），下載鈕連 releases/latest，只有版號要更新。
set -e
cd "${0:A:h}"
VERSION=$1 NOTES=${2:A} SITE=${0:A:h}/../draft-site
[ -n "$VERSION" ] && [ -f "$NOTES" ] || { echo "usage: ./publish.sh <version> <notes.md>"; exit 1 }
git fetch -q && [ "$(git rev-parse HEAD)" = "$(git rev-parse @{u})" ] || { echo "main 跟 origin 不同步，先 pull／push"; exit 1 }
[ -z "$(git status --porcelain)" ] || { echo "工作目錄有沒 commit 的改動"; exit 1 }

BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" -c "Set CFBundleVersion $BUILD" Info.plist
git add Info.plist
git commit -q -m "Draft $VERSION

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git tag v$VERSION
git push -q origin main v$VERSION

./release.sh   # builds the tag (HEAD) in a clean worktree
gh release create v$VERSION build/Draft.dmg --title "Draft $VERSION" --notes-file $NOTES

sed -i '' -E "s|<span class=\"ver\">v[^<]*<|<span class=\"ver\">v$VERSION<|g" $SITE/index.html
git -C $SITE commit -q -m "v$VERSION" index.html
$SITE/deploy.sh
