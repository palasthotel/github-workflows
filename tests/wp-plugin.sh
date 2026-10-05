#!/usr/bin/env bash
# Tests for wp-plugin/bin against a throwaway fixture plugin and a local SVN
# repository. Needs bash, rsync, zip, python3 and subversion (svn, svnadmin).
#
# Every case here is something that went wrong in a real release at least once.
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../wp-plugin/bin" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0
ok() { echo "  ok   $1"; passed=$((passed + 1)); }
no() { echo "  FAIL $1"; failed=$((failed + 1)); }
expect() { # description, command...
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$description"; else no "$description"; fi
}
expect_not() {
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then no "$description"; else ok "$description"; fi
}

# A plugin as the repositories lay it out: public/ ships, the version lives in
# package.json, two translations are symlinks to a third.
fixture() {
  local dir="$WORK/$1"
  rm -rf "$dir"; mkdir -p "$dir/public/languages" "$dir/public/inc"
  cat > "$dir/public/my-plugin.php" <<'PHP'
<?php
/**
 * Plugin Name:       My Plugin
 * Version:           1.2.3
 */
PHP
  echo '<?php // not the main file' > "$dir/public/inc/helper.php"
  cat > "$dir/public/readme.txt" <<'TXT'
=== My Plugin ===
Stable tag: 1.2.3

== Changelog ==

= 1.2.3 =
* Older entry

== Upgrade Notice ==

= 1.2.3 =
Upgrade.
TXT
  echo "licence" > "$dir/public/LICENSE"
  echo "de" > "$dir/public/languages/my-plugin-de_DE.po"
  ln -s my-plugin-de_DE.po "$dir/public/languages/my-plugin-de_CH.po"
  ln -s my-plugin-de_DE.po "$dir/public/languages/my-plugin-ch_CH.po"
  echo '{ "name": "my-plugin", "version": "1.2.3" }' > "$dir/package.json"
  echo "$dir"
}

echo "check-version.sh"
P="$(fixture check)"
expect "detects the main file, readme and package.json and passes" bash -c "cd '$P' && bash '$BIN/check-version.sh'"
expect "passes against an explicit VERSION" bash -c "cd '$P' && VERSION=1.2.3 bash '$BIN/check-version.sh'"
expect_not "fails when the tag is another version" bash -c "cd '$P' && VERSION=1.2.4 bash '$BIN/check-version.sh'"
sed -i.bak 's/Stable tag: 1.2.3/Stable tag: 1.2.2/' "$P/public/readme.txt" && rm "$P/public/readme.txt.bak"
expect_not "fails when the Stable tag disagrees" bash -c "cd '$P' && bash '$BIN/check-version.sh'"
P="$(fixture check-version-txt)"
echo "1.2.3" > "$P/version.txt"
echo '{ "version": "0.9.0" }' > "$P/package.json"
expect "prefers version.txt over a stale package.json" bash -c "cd '$P' && bash '$BIN/check-version.sh'"
expect_not "fails when VERSION_FILE points at the stale package.json" bash -c "cd '$P' && VERSION_FILE=package.json bash '$BIN/check-version.sh'"
P="$(fixture check-two-headers)"
printf '<?php\n/**\n * Plugin Name: Other\n */\n' > "$P/public/other.php"
expect_not "refuses to guess between two plugin headers" bash -c "cd '$P' && bash '$BIN/check-version.sh'"
expect "accepts MAIN_FILE when there are two" bash -c "cd '$P' && MAIN_FILE=my-plugin.php bash '$BIN/check-version.sh'"

echo "sync-version.sh"
P="$(fixture sync)"
echo '{ "name": "my-plugin", "version": "1.3.0" }' > "$P/package.json"
cat > "$P/CHANGELOG.md" <<'MD'
# Changelog

## [1.3.0](https://github.com/x/y/compare/v1.2.3...v1.3.0) (2026-10-02)


### Features

* rebuild Tools &gt; Logs ([abc1234](https://github.com/x/y/commit/abc1234))


### Bug Fixes

* keep &quot;quotes&quot; &amp; ampersands ([def5678](https://github.com/x/y/commit/def5678))

## 1.2.3

* Older entry
MD
out="$(cd "$P" && bash "$BIN/sync-version.sh")"
expect "sets the header version and keeps its alignment" grep -qx ' \* Version:           1.3.0' "$P/public/my-plugin.php"
expect "sets the Stable tag" grep -qx 'Stable tag: 1.3.0' "$P/public/readme.txt"
expect "adds the changelog entry" grep -qx '= 1.3.0 =' "$P/public/readme.txt"
expect "turns ### headings into bold lines" grep -qx '\*\*Bug Fixes\*\*' "$P/public/readme.txt"
expect "strips the commit links" grep -qx '\* rebuild Tools > Logs (abc1234)' "$P/public/readme.txt"
expect "decodes the entities release-please writes" grep -qx '\* keep "quotes" & ampersands (def5678)' "$P/public/readme.txt"
expect_not "keeps the next CHANGELOG section out" bash -c "sed -n '/= 1.3.0 =/,/= 1.2.3 =/p' '$P/public/readme.txt' | grep -q 'Older entry'"
expect "reports the files it changed" bash -c "[[ '$out' == *'changed: public/my-plugin.php public/readme.txt' ]]"
expect "leaves the readme consistent for check-version" bash -c "cd '$P' && bash '$BIN/check-version.sh'"
before="$(cat "$P/public/readme.txt")"
(cd "$P" && bash "$BIN/sync-version.sh" >/dev/null)
expect "is idempotent on a second push to the release PR" test "$before" == "$(cat "$P/public/readme.txt")"
expect "does not touch the Upgrade Notice" bash -c "sed -n '/== Upgrade Notice ==/,\$p' '$P/public/readme.txt' | grep -qx '= 1.2.3 ='"

echo "pack.sh"
P="$(fixture pack)"
expect_not "refuses to pack without SLUG" bash -c "cd '$P' && bash '$BIN/pack.sh'"
(cd "$P" && SLUG=my-plugin EXCLUDE=$'inc/helper.php\n' bash "$BIN/pack.sh" >/dev/null 2>&1)
expect "stages build/<slug>/" test -f "$P/build/my-plugin/my-plugin.php"
expect "writes <slug>.zip next to it" test -f "$P/my-plugin.zip"
expect "resolves symlinks into files" bash -c "[[ -z \"\$(find '$P/build/my-plugin' -type l)\" ]] && test -f '$P/build/my-plugin/languages/my-plugin-de_CH.po'"
expect "applies EXCLUDE" test ! -e "$P/build/my-plugin/inc/helper.php"
expect "ships nothing from outside the plugin dir" test ! -e "$P/build/my-plugin/package.json"
mkdir -p "$WORK/unzipped" && (cd "$WORK/unzipped" && unzip -q "$P/my-plugin.zip")
expect "zip and build/<slug>/ are identical" diff -r "$WORK/unzipped/my-plugin" "$P/build/my-plugin"

echo "svn-prepare.sh"
# Seed an SVN repository the way wordpress.org has it for an old release: the Swiss
# translations committed as symlinks (svn:special), page media in assets/.
P="$(fixture svn)"
(cd "$P" && SLUG=my-plugin bash "$BIN/pack.sh" >/dev/null 2>&1)
SEED="$WORK/seed"; mkdir -p "$SEED/tags" "$SEED/branches" "$SEED/assets"
cp -R "$P/public" "$SEED/trunk"   # cp -R keeps the symlinks
echo "png" > "$SEED/assets/icon-128x128.png"
echo "stale" > "$SEED/trunk/removed-in-this-release.php"
# a whole directory that the release drops, as grid's lib/ in 3.0.0, with names that
# a status parser has to keep intact
mkdir -p "$SEED/trunk/lib/old/nested"
echo "stale" > "$SEED/trunk/lib/old/nested/with space.php"
echo "stale" > "$SEED/trunk/lib/old/icon@2x.png"
svnadmin create "$WORK/repo"
svn import -q -m seed "$SEED" "file://$WORK/repo"
svn co -q "file://$WORK/repo" "$WORK/wc"
expect "the seed really holds symlinks" bash -c "svn proplist -R '$WORK/wc/trunk' | grep -q svn:special"
(cd "$P" && VERSION=1.2.4 SLUG=my-plugin SVN_DIR="$WORK/wc" bash "$BIN/svn-prepare.sh" >/dev/null 2>&1)
expect "schedules the removed file for deletion" bash -c "svn status '$WORK/wc' | grep -E '^D' | grep -q removed-in-this-release.php"
expect "leaves nothing missing" bash -c "! svn status '$WORK/wc' | grep -q '^!'"
expect "commits without E145001" svn commit -q -m release --non-interactive "$WORK/wc"
expect "removes a dropped directory from trunk" bash -c "! svn ls 'file://$WORK/repo/trunk/lib' >/dev/null 2>&1"
expect "leaves no svn:special behind" bash -c "! svn proplist -R 'file://$WORK/repo/trunk' | grep -q svn:special"
svn export -q "file://$WORK/repo/trunk" "$WORK/trunk"
svn export -q "file://$WORK/repo/tags/1.2.4" "$WORK/tag"
expect "trunk == build/<slug>/" diff -r "$WORK/trunk" "$P/build/my-plugin"
expect "tags/1.2.4 == trunk" diff -r "$WORK/tag" "$WORK/trunk"
expect "keeps assets/ when the repository has none" bash -c "svn ls 'file://$WORK/repo/assets' | grep -q icon-128x128.png"
mkdir -p "$P/assets" && echo "banner" > "$P/assets/banner-772x250.png"
svn up -q "$WORK/wc"
(cd "$P" && VERSION=1.2.5 SLUG=my-plugin SVN_DIR="$WORK/wc" bash "$BIN/svn-prepare.sh" >/dev/null 2>&1)
svn commit -q -m release --non-interactive "$WORK/wc" >/dev/null 2>&1
expect "mirrors assets/ when the repository has it" bash -c "svn ls 'file://$WORK/repo/assets' | grep -q banner-772x250.png && ! svn ls 'file://$WORK/repo/assets' | grep -q icon-128x128.png"

echo
echo "$passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
