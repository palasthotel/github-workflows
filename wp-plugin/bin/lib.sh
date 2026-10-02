#!/usr/bin/env bash
# shellcheck disable=SC2034  # the variables are set for the scripts that source this
# Shared by the wp-plugin scripts: works out where the plugin's files are.
#
# Every value can be set from the environment; what is left empty is detected.
#   ROOT          the plugin project in the repository           (default: .)
#   PLUGIN_DIR    what ships to wordpress.org, relative to ROOT   (default: public)
#   MAIN_FILE     the file with the plugin header, relative to PLUGIN_DIR
#                 (default: the one *.php in PLUGIN_DIR carrying "Plugin Name:")
#   README        readme.txt or README.txt, relative to PLUGIN_DIR (default: detected)
#   VERSION_FILE  version.txt or package.json, relative to ROOT
#                 (default: version.txt if it exists, else package.json)
#   CHANGELOG     relative to ROOT                                (default: CHANGELOG.md)

wp_plugin_die() {
  echo "ERROR: $*" >&2
  exit 1
}

wp_plugin_resolve() {
  ROOT="${ROOT:-.}"
  ROOT="$(cd "$ROOT" && pwd)" || wp_plugin_die "ROOT does not exist"
  PLUGIN_DIR="${PLUGIN_DIR:-public}"
  PLUGIN_PATH="$ROOT/$PLUGIN_DIR"
  [[ -d "$PLUGIN_PATH" ]] || wp_plugin_die "$PLUGIN_PATH does not exist - set PLUGIN_DIR"

  if [[ -z "${MAIN_FILE:-}" ]]; then
    local candidates=()
    local file
    for file in "$PLUGIN_PATH"/*.php; do
      [[ -f "$file" ]] && grep -qE '^[[:space:]]*\*?[[:space:]]*Plugin Name:' "$file" && candidates+=("$(basename "$file")")
    done
    [[ ${#candidates[@]} -eq 1 ]] || wp_plugin_die "found ${#candidates[@]} files with a plugin header in $PLUGIN_DIR (${candidates[*]:-none}) - set MAIN_FILE"
    MAIN_FILE="${candidates[0]}"
  fi
  MAIN_PATH="$PLUGIN_PATH/$MAIN_FILE"
  [[ -f "$MAIN_PATH" ]] || wp_plugin_die "$MAIN_PATH does not exist"

  if [[ -z "${README:-}" ]]; then
    if [[ -f "$PLUGIN_PATH/readme.txt" ]]; then README="readme.txt"
    elif [[ -f "$PLUGIN_PATH/README.txt" ]]; then README="README.txt"
    else wp_plugin_die "no readme.txt in $PLUGIN_DIR - set README"
    fi
  fi
  README_PATH="$PLUGIN_PATH/$README"
  [[ -f "$README_PATH" ]] || wp_plugin_die "$README_PATH does not exist"

  if [[ -z "${VERSION_FILE:-}" ]]; then
    if [[ -f "$ROOT/version.txt" ]]; then VERSION_FILE="version.txt"
    elif [[ -f "$ROOT/package.json" ]]; then VERSION_FILE="package.json"
    else wp_plugin_die "neither version.txt nor package.json in $ROOT - set VERSION_FILE"
    fi
  fi
  VERSION_PATH="$ROOT/$VERSION_FILE"
  [[ -f "$VERSION_PATH" ]] || wp_plugin_die "$VERSION_PATH does not exist"

  CHANGELOG="${CHANGELOG:-CHANGELOG.md}"
  CHANGELOG_PATH="$ROOT/$CHANGELOG"
}

# The version release-please maintains: package.json's "version", or the first
# line of version.txt.
wp_plugin_read_version() {
  case "$VERSION_FILE" in
    *.json) python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$VERSION_PATH" ;;
    *) head -n1 "$VERSION_PATH" | tr -d '[:space:]' ;;
  esac
}

wp_plugin_read_header_version() {
  grep -m1 -E '^[[:space:]]*\*?[[:space:]]*Version:[[:space:]]*[0-9]' "$MAIN_PATH" \
    | sed -E 's/.*Version:[[:space:]]*([^[:space:]]+).*/\1/'
}

wp_plugin_read_stable_tag() {
  grep -m1 -E '^Stable tag:' "$README_PATH" | sed -E 's/^Stable tag:[[:space:]]*//' | tr -d '[:space:]'
}

# sed -i.bak keeps the scripts usable with both GNU and BSD/macOS sed
wp_plugin_sed_inplace() {
  sed -i.bak "$1" "$2"
  rm -f "$2.bak"
}
