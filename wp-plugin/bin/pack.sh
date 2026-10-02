#!/usr/bin/env bash
# Stages PLUGIN_DIR in build/<slug>/ - exactly what is deployed to wordpress.org -
# and zips it to <slug>.zip next to it, in ROOT.
#
# build/<slug>/ is left in place on purpose: the deploy rsyncs from it into the SVN
# checkout, so the release zip and the SVN trunk are byte-identical.
#
# Usage: SLUG=my-plugin pack.sh          (paths: see lib.sh)
#   EXCLUDE   newline-separated rsync patterns to leave out of the payload
#
# A build step (npm run build and the like) runs before this, not in it.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ -n "${SLUG:-}" ]] || wp_plugin_die "SLUG is not set - it has to be the wordpress.org slug"
wp_plugin_resolve

BUILD_PATH="$ROOT/build"
DEST_PATH="$BUILD_PATH/$SLUG"
ZIP_PATH="$ROOT/$SLUG.zip"

echo "Staging $PLUGIN_DIR in build/$SLUG/ ..."
rm -rf "$BUILD_PATH" "$ZIP_PATH"
mkdir -p "$DEST_PATH"

RSYNC_EXCLUDES=()
while IFS= read -r pattern; do
  [[ -n "${pattern//[[:space:]]/}" ]] && RSYNC_EXCLUDES+=("--exclude=$pattern")
done <<< "${EXCLUDE:-}"

# -L resolves symlinks into real files: wordpress.org discards symlinks when it builds
# the download, and SVN refuses a commit that puts a symlink where it versions a file.
rsync -rL ${RSYNC_EXCLUDES[@]+"${RSYNC_EXCLUDES[@]}"} "$PLUGIN_PATH/" "$DEST_PATH/"

# A composer.json in the payload: install without dev dependencies, write an
# optimized autoloader, and drop composer.json/composer.lock - nothing reads them at
# runtime, and the provenance stays in vendor/composer/installed.json.
if [[ -f "$DEST_PATH/composer.json" ]]; then
  command -v composer >/dev/null || wp_plugin_die "the payload has a composer.json, but composer is not installed"
  echo "Installing composer dependencies without dev ..."
  (cd "$DEST_PATH" \
    && composer install --no-dev --no-interaction --quiet \
    && composer dump-autoload --no-dev --optimize --quiet \
    && rm -f composer.json composer.lock)
fi

echo "Zipping $SLUG.zip ..."
(cd "$BUILD_PATH" && zip -q -r "$ZIP_PATH" "$SLUG/")

echo "$SLUG.zip: $(find "$DEST_PATH" -type f | wc -l | tr -d ' ') files"
