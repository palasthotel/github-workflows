#!/usr/bin/env bash
# Runs on the release-please PR: release-please has bumped the version file and
# written CHANGELOG.md, this writes the same version into the plugin header and the
# readme's "Stable tag:", and the CHANGELOG.md entry into the readme's changelog.
#
# Prints the two files it touched, relative to the repository root, on its last line
# as "changed: <main file> <readme>", for the workflow that commits them.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
wp_plugin_resolve

VERSION="$(wp_plugin_read_version)"
[[ -n "$VERSION" ]] || wp_plugin_die "could not read the version from $VERSION_FILE"
echo "🤖 Updating plugin files for version $VERSION …"

# 1. The Version header, keeping its alignment
wp_plugin_sed_inplace "s/^\([[:space:]]*\*[[:space:]]*Version:[[:space:]]*\).*/\1$VERSION/" "$MAIN_PATH"

# 2. The readme's Stable tag
wp_plugin_sed_inplace "s/^Stable tag:.*/Stable tag: $VERSION/" "$README_PATH"

report() {
  local root_rel
  root_rel="$(cd "$ROOT" && pwd)"
  root_rel="${root_rel#"$(pwd)"}"; root_rel="${root_rel#/}"
  echo "changed: ${root_rel:+$root_rel/}$PLUGIN_DIR/$MAIN_FILE ${root_rel:+$root_rel/}$PLUGIN_DIR/$README"
}

# 3. Nothing more to do if the readme's changelog already has this version. Only
# "== Changelog ==" counts - "== Upgrade Notice ==" uses the same "= x.y.z =".
ALREADY_LOGGED=$(awk -v heading="= $VERSION =" '
  /^== Changelog ==/ { in_changelog = 1; next }
  in_changelog && /^== / { in_changelog = 0 }
  in_changelog && $0 == heading { found = 1 }
  END { print found ? "yes" : "no" }
' "$README_PATH")
if [[ "$ALREADY_LOGGED" == "yes" ]]; then
  echo "🤖 $README already has a changelog entry for $VERSION"
  report; exit 0
fi

# 4. The CHANGELOG.md section: from "## [X.Y.Z]" to the next "# " or "## " heading,
# so whatever release-please parks below the entries stays out of the readme while
# the "### Bug Fixes" subheadings inside the entry are kept.
SECTION=""
[[ -f "$CHANGELOG_PATH" ]] && SECTION=$(awk -v version="$VERSION" '
  !found && index( $0, "## [" version "]" ) == 1 { found = 1; next }
  found && ( /^# / || /^## / ) { exit }
  found && /^[[:space:]]*<!--/ { next }
  found { print }
' "$CHANGELOG_PATH")
if [[ -z "$SECTION" ]]; then
  echo "🤖 No $CHANGELOG entry for $VERSION - the readme changelog stays as it is"
  report; exit 0
fi

# Markdown to readme.txt:
#   "### Bug Fixes"                 -> "**Bug Fixes**", preceded by one blank line
#   "* item ([abc1234](https://…))" -> "* item (abc1234)"
#   "&gt;" "&lt;" "&quot;" "&#39;" "&amp;" -> the characters - release-please
#   HTML-escapes commit subjects, and readme.txt would show the entities as written
#   blank line runs collapsed
WP_LINES=""
while IFS= read -r line; do
  if [[ "$line" =~ ^###+[[:space:]]+(.*)$ ]]; then
    [[ -n "$WP_LINES" ]] && WP_LINES+=$'\n'
    WP_LINES+="**${BASH_REMATCH[1]}**"$'\n'
    continue
  fi
  [[ -z "${line//[[:space:]]/}" ]] && continue
  line=$(printf '%s' "$line" | sed 's/\[\([^]]*\)\]([^)]*)/\1/g')
  line=$(printf '%s' "$line" | sed -e 's/&gt;/>/g' -e 's/&lt;/</g' -e 's/&quot;/"/g' -e "s/&#39;/'/g" -e 's/&amp;/\&/g')
  WP_LINES+="$line"$'\n'
done <<< "$SECTION"
WP_ENTRY="= $VERSION ="$'\n'"${WP_LINES%$'\n'}"

# 5. Prepend the entry right after "== Changelog =="
ENTRY_FILE=$(mktemp)
printf '%s\n' "$WP_ENTRY" > "$ENTRY_FILE"
TMPFILE=$(mktemp)
awk -v entry_file="$ENTRY_FILE" '
  /^== Changelog ==/ && !injected {
    print
    print ""
    while ((getline line < entry_file) > 0) print line
    print ""
    injected = 1
    skip_blank = 1
    next
  }
  skip_blank && /^[[:space:]]*$/ { skip_blank = 0; next }
  { skip_blank = 0; print }
' "$README_PATH" > "$TMPFILE"
cat "$TMPFILE" > "$README_PATH"
rm -f "$ENTRY_FILE" "$TMPFILE"

echo "🤖 $README updated."
report
