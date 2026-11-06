#!/bin/bash
# Tag a version, build, zip, and publish a GitHub release (triggers the in-app update check).
# Usage: ./make-release.sh [patch|minor|major]   (default: patch)
set -euo pipefail
cd "$(dirname "$0")"

BUMP="${1:-patch}"
CUR=$(grep -o 'appVersion = "[^"]*"' Sources/MacVoice/main.swift | cut -d'"' -f2)
IFS='.' read -r MAJ MIN PAT <<<"$CUR"
case "$BUMP" in
  major) MAJ=$((MAJ+1)); MIN=0; PAT=0 ;;
  minor) MIN=$((MIN+1)); PAT=0 ;;
  *)     PAT=$((PAT+1)) ;;
esac
NEW="$MAJ.$MIN.$PAT"
sed -i '' "s/appVersion = \"$CUR\"/appVersion = \"$NEW\"/" Sources/MacVoice/main.swift
sed -i '' "s/<string>$CUR<\/string>/<string>$NEW<\/string>/" make-app.sh
echo "version: $CUR -> $NEW"

./make-app.sh
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent build/MacVoice.app dist/MacVoice.zip
cp dist/MacVoice.zip dist/MacVoice-v$NEW.zip

git add -A
git commit -m "release v$NEW" >/dev/null || true
git tag "v$NEW"

gh release create "v$NEW" dist/MacVoice.zip --title "MacVoice v$NEW" --generate-notes
echo "released v$NEW — apps running v$CUR will now see the update"
