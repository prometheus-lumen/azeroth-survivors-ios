#!/usr/bin/env bash
# Fetch game resources separately; they are intentionally excluded from Git.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
test -f www/bundle-manifest.json || python3 tools/fetch_assets.py www
python3 -c 'import json; m=json.load(open("www/bundle-manifest.json")); assert not m["partial"] and not m["failures"], "Incomplete game resources"'
python3 tools/prepare_icons.py
xcodegen generate
mkdir -p artifacts
xcodebuild -project AzerothSurvivors.xcodeproj -scheme AzerothSurvivors \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ROOT/build/AzerothSurvivors.xcarchive" \
  -derivedDataPath "$ROOT/build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive
APP="$ROOT/build/AzerothSurvivors.xcarchive/Products/Applications/AzerothSurvivors.app"
test -f "$APP/Assets.car"
test -f "$APP/www/index.html"
STAGE="$(mktemp -d "$ROOT/build/ipa-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/Payload"
ditto "$APP" "$STAGE/Payload/AzerothSurvivors.app"
find "$STAGE" -name '.DS_Store' -delete
OUT="$ROOT/artifacts/AzerothSurvivors-unsigned.ipa"
rm -f "$OUT.new"
(cd "$STAGE" && zip -qry "$OUT.new" Payload)
mv "$OUT.new" "$OUT"
python3 tools/verify_ipa.py "$OUT"
printf '\nUnsigned IPA: %s\n' "$OUT"
