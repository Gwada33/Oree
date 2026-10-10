#!/bin/bash
# Publie une version de bout en bout :
#   ./scripts/release.sh patch|minor|major|X.Y.Z [--dry-run] [--skip-tests] [--no-push]
# Calcule le numéro, vérifie (tests), écrit VERSION + CHANGELOG.md, commit, crée le tag annoté (les notes sont
# les commits depuis la dernière version) et pousse. GitHub Actions (release.yml) construit alors Oree.app,
# fabrique le zip (mise à jour intégrée) et le DMG (premier téléchargement), puis publie la release.
# Le site sert toujours le dernier DMG ; les copies installées proposent la mise à jour d'elles-mêmes.
# `--no-push` : prépare tout (tests, VERSION, CHANGELOG, commit, tag) et s'arrête avant de pousser : vous poussez vous-même.
# `--ci` : utilisé par la publication planifiée (pas de tests ici, la CI les a déjà passés).
set -euo pipefail
cd "$(dirname "$0")/.."

BUMP="${1:-}"; shift || true
DRY=0; SKIP_TESTS=0; CI=0; PUSH=1
for a in "$@"; do case "$a" in --dry-run) DRY=1;; --skip-tests) SKIP_TESTS=1;; --no-push) PUSH=0;; --ci) CI=1; SKIP_TESTS=1;; *) echo "option inconnue : $a"; exit 2;; esac; done
[ -n "$BUMP" ] || { sed -n '2,3p' "$0" | sed 's/^# //'; exit 2; }

CURRENT="$(tr -d '[:space:]' < VERSION)"
IFS=. read -r MA MI PA <<< "$CURRENT"
case "$BUMP" in
  patch) NEXT="$MA.$MI.$((PA + 1))";;
  minor) NEXT="$MA.$((MI + 1)).0";;
  major) NEXT="$((MA + 1)).0.0";;
  *) [[ "$BUMP" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && NEXT="$BUMP" || { echo "Version invalide : $BUMP"; exit 2; };;
esac
TAG="v$NEXT"
NOTES="$(./scripts/release-notes.sh)"

echo "Version : $CURRENT → $NEXT   (tag $TAG)"
echo "Notes :"; echo "$NOTES"
[ "$DRY" = 1 ] && { echo "(essai à blanc : rien n'a été modifié)"; exit 0; }

[ "$CI" = 1 ] || {
  [ -z "$(git status --porcelain)" ] || { echo "Des changements ne sont pas commités : commitez-les d'abord."; git status --short; exit 2; }
  [ "$(git branch --show-current)" = "main" ] || { echo "Placez-vous sur la branche main."; exit 2; }
  git fetch origin --tags --quiet
  git pull --rebase --quiet origin main
}
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "Le tag $TAG existe déjà."; exit 2; }
[ "$SKIP_TESTS" = 1 ] || { echo "==> Tests…"; ./scripts/test.sh >/dev/null 2>&1 || { echo "Les tests échouent : version non publiée (lancez ./scripts/test.sh pour voir)."; exit 1; }; }

echo "$NEXT" > VERSION
{ echo "## $NEXT — $(date +%Y-%m-%d)"; echo; echo "$NOTES"; echo; [ -f CHANGELOG.md ] && cat CHANGELOG.md; } > CHANGELOG.md.new
mv CHANGELOG.md.new CHANGELOG.md
git add VERSION CHANGELOG.md
git commit -qm "Version $NEXT"
git tag -a "$TAG" -m "Orée $NEXT

$NOTES"
if [ "$PUSH" = 1 ]; then
  git push origin main "$TAG"
else
  echo "==> $TAG prête en local. Pour publier :  git push origin main $TAG"
  exit 0
fi

echo "==> $TAG poussée. Construction : https://github.com/Gwada33/oree/actions"
echo "    Release (zip + dmg) dans quelques minutes : https://github.com/Gwada33/oree/releases/tag/$TAG"
