#!/usr/bin/env bash
# Prepares an SVN checkout of the plugin for a release: trunk and tags/VERSION
# become a copy of build/<slug>/, added and removed files are scheduled. Committing
# is left to the caller, so the same script runs against a local rehearsal
# repository.
#
# Usage: VERSION=1.2.3 SLUG=my-plugin SVN_DIR=svn svn-prepare.sh
#   BUILD_DIR   the staged payload        (default: ROOT/build/SLUG)
#   ASSETS_DIR  wordpress.org page media  (default: ROOT/assets, if it exists)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ -n "${VERSION:-}" ]] || wp_plugin_die "VERSION is not set"
[[ -n "${SLUG:-}" ]] || wp_plugin_die "SLUG is not set"
[[ -n "${SVN_DIR:-}" && -d "$SVN_DIR/.svn" ]] || wp_plugin_die "SVN_DIR is not an SVN checkout"

ROOT="$(cd "${ROOT:-.}" && pwd)"
BUILD_DIR="$(cd "${BUILD_DIR:-$ROOT/build/$SLUG}" && pwd)" || wp_plugin_die "no staged payload - run pack.sh first"
ASSETS_DIR="${ASSETS_DIR:-$ROOT/assets}"

cd "$SVN_DIR"
rm -rf trunk/* "tags/$VERSION"
mkdir -p trunk "tags/$VERSION"

# -L as in pack.sh: GNU cp keeps symlinks while descending, BSD cp resolves them, so
# only rsync behaves the same in a macOS rehearsal and on the Ubuntu runner.
rsync -rL "$BUILD_DIR/" trunk/
rsync -rL trunk/ "tags/$VERSION/"

# A file that was a symlink in SVN keeps svn:special, and committing a regular file
# in its place fails with "E145001 ... has unexpectedly changed kind". Only trunk is
# versioned at this point; tags/VERSION is new. propdel stops at the first missing
# node of a removed directory and can leave the working copy locked, so clean up.
svn propdel svn:special -R trunk >/dev/null 2>&1 || true
svn cleanup

# assets/ holds the plugin page's banner, icon and screenshots and is not part of the
# download. It is only mirrored when the repository carries the directory - otherwise
# --delete would empty the plugin page's media.
if [[ -d "$ASSETS_DIR" ]]; then
  mkdir -p assets
  rsync -rL --delete "$ASSETS_DIR/" assets/
fi

svn add --force . >/dev/null
# The path starts in column 9, after seven status columns and a space; a lock (L) or
# a tree conflict (C) in those columns, or a space in the path, must not change it.
svn status | sed -n 's/^!.......//p' | while IFS= read -r file; do
  # the trailing @ keeps a path like icon@2x.png from being read as a peg revision
  [[ -n "$file" ]] && svn rm -q --force "$file@"
done

svn status
