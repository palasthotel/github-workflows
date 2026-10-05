#!/usr/bin/env bash
# Checks out what a release touches: trunk, assets and tags/VERSION if that tag
# already exists (a re-deploy of a published version). The other tags stay empty
# directories - a release never changes them, and with many of them a full checkout
# takes minutes (grid: 25 tags with up to 3000 files each).
#
# Usage: VERSION=1.2.3 SVN_URL=https://plugins.svn.wordpress.org/my-plugin/ \
#          SVN_DIR=svn svn-checkout.sh [svn options, e.g. --username ...]
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ -n "${VERSION:-}" ]] || wp_plugin_die "VERSION is not set"
[[ -n "${SVN_URL:-}" ]] || wp_plugin_die "SVN_URL is not set"
[[ -n "${SVN_DIR:-}" ]] || wp_plugin_die "SVN_DIR is not set"

svn checkout -q --depth immediates "$SVN_URL" "$SVN_DIR" "$@"
cd "$SVN_DIR"

for dir in trunk assets; do
  if [[ -d "$dir" ]]; then
    svn update -q --set-depth infinity "$dir" "$@"
  fi
done

if [[ -d tags ]]; then
  # lists the tags as empty directories, so tags/VERSION shows up if it exists
  svn update -q --set-depth immediates tags "$@"
  if [[ -d "tags/$VERSION" ]]; then
    svn update -q --set-depth infinity "tags/$VERSION" "$@"
  fi
fi
