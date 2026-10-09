#!/bin/bash
# Publishes a new version that installed copies of Orée will offer to download.
#   1. edit VERSION (e.g. 1.0.1)  2. ./scripts/release.sh "notes de version"
# Needs GITHUB_TOKEN (a personal access token with the `repo` scope) to create the release and upload the zip.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
NOTES="${1:-Version $VERSION}"
REPO="Gwada33/oree"

./build_app.sh
ZIP="Oree-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent Oree.app "$ZIP"
echo "==> $ZIP ($(du -h "$ZIP" | cut -f1))"

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "GITHUB_TOKEN absent : créez la release « v$VERSION » à la main sur https://github.com/$REPO/releases/new et joignez $ZIP."
  exit 0
fi
API="https://api.github.com/repos/$REPO"
AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json")
BODY=$(python3 -c 'import json,sys; print(json.dumps({"tag_name":"v"+sys.argv[1],"name":"Orée "+sys.argv[1],"body":sys.argv[2]}))' "$VERSION" "$NOTES")
RELEASE=$(curl -fsS "${AUTH[@]}" -X POST "$API/releases" -d "$BODY")
UPLOAD=$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["upload_url"].split("{")[0])' <<< "$RELEASE")
curl -fsS "${AUTH[@]}" -H "Content-Type: application/zip" --data-binary @"$ZIP" "$UPLOAD?name=$ZIP" > /dev/null
echo "==> Release v$VERSION publiée."
