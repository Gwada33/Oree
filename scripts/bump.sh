#!/bin/bash
# Publie une nouvelle version en une commande :   ./scripts/bump.sh 1.0.2
# Met à jour VERSION, commit, crée le tag v1.0.2 et pousse. GitHub Actions (release.yml) construit alors Oree.app
# et publie la release ; les copies installées d'Orée proposeront la mise à jour au prochain contrôle.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 X.Y.Z (ex. 1.0.2)"; exit 2; }
CURRENT="$(tr -d '[:space:]' < VERSION)"
[ "$VERSION" != "$CURRENT" ] || { echo "La version est déjà $CURRENT."; exit 2; }
[ -z "$(git status --porcelain)" ] || { echo "Des changements ne sont pas commités : commitez-les d'abord."; git status --short; exit 2; }
[ "$(git branch --show-current)" = "main" ] || { echo "Placez-vous sur la branche main."; exit 2; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "Le tag v$VERSION existe déjà."; exit 2; }

git fetch origin --tags --quiet
git pull --rebase --quiet origin main

echo "$VERSION" > VERSION
git commit -qam "Version $VERSION"
git tag -a "v$VERSION" -m "Orée $VERSION"
git push origin main "v$VERSION"

echo "==> v$VERSION poussée. La construction tourne ici : https://github.com/Gwada33/oree/actions"
echo "    La release apparaît dans quelques minutes : https://github.com/Gwada33/oree/releases"
