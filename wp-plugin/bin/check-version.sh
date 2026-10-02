#!/usr/bin/env bash
# Fails unless every version carrier agrees with VERSION (without the leading v):
# the version file, the "Version:" header of the main plugin file and the readme's
# "Stable tag:". Runs before anything is deployed, and in pull requests.
#
# Usage: VERSION=1.2.3 check-version.sh      (paths: see lib.sh)
#        check-version.sh                    (checks against the version file)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
wp_plugin_resolve

FILE_VERSION="$(wp_plugin_read_version || true)"
VERSION="${VERSION:-$FILE_VERSION}"
[[ -n "$VERSION" ]] || wp_plugin_die "VERSION is not set and $VERSION_FILE has none"

fail=0
check() {
  local label="$1" got="$2"
  if [[ -z "$got" ]]; then
    echo "ERROR: could not read $label" >&2; fail=1
  elif [[ "$got" != "$VERSION" ]]; then
    echo "ERROR: $label is $got, expected $VERSION" >&2; fail=1
  else
    echo "OK: $label == $VERSION"
  fi
}

check "$VERSION_FILE" "$FILE_VERSION"
check "$PLUGIN_DIR/$MAIN_FILE Version" "$(wp_plugin_read_header_version || true)"
check "$PLUGIN_DIR/$README Stable tag" "$(wp_plugin_read_stable_tag || true)"

[[ "$fail" -eq 0 ]] || { echo "Version check failed." >&2; exit 1; }
echo "All versions match ✅"
