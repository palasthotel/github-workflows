#!/usr/bin/env bash
# Tests for dependabot/bin/generate.sh against throwaway repositories. Needs bash and jq.
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../dependabot/bin" && pwd)"
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

# The entries of a generated file as "ecosystem dir dir ...", one per line
entries() {
  awk '
    /^  - package-ecosystem:/ { if (line) print line; gsub(/"/, "", $3); line = $3 }
    /^    directory:/ { gsub(/"/, "", $2); line = line " " $2 }
    /^      - "\// { gsub(/"/, "", $2); line = line " " $2 }
    END { if (line) print line }
  ' "$1"
}

repo() {
  local dir="$WORK/$1"
  mkdir -p "$dir"
  echo "$dir"
}

echo "generate.sh"
R="$(repo plain)"
bash "$BIN/generate.sh" "$R" >/dev/null 2>&1
expect "writes .github/dependabot.yml" test -f "$R/.github/dependabot.yml"
expect "always checks the GitHub Actions in /" test "$(entries "$R/.github/dependabot.yml")" = "github-actions /"
expect "never uses /.github/ as directory" bash -c "! grep -q '\"/.github/\"' '$R/.github/dependabot.yml'"

R="$(repo npm)"
echo '{}' > "$R/package.json"; echo '{}' > "$R/package-lock.json"
mkdir -p "$R/node_modules/x" "$R/build/y"
echo '{}' > "$R/node_modules/x/package-lock.json"; echo '{}' > "$R/build/y/package-lock.json"
bash "$BIN/generate.sh" "$R" >/dev/null 2>&1
expect "finds npm in the root, not in node_modules/ or build/" test "$(entries "$R/.github/dependabot.yml" | head -n1)" = "npm /"
expect "groups the @wordpress packages, major versions included" bash -c "sed -n '/wordpress:/,/npm:/p' '$R/.github/dependabot.yml' | grep -q '@wordpress/\*' && ! sed -n '/wordpress:/,/npm:/p' '$R/.github/dependabot.yml' | grep -q update-types"
expect "waits 7 days, but not for our own packages" bash -c "grep -q 'default-days: 7' '$R/.github/dependabot.yml' && grep -q '\"@palasthotel/\*\"' '$R/.github/dependabot.yml'"

R="$(repo monorepo)"
mkdir -p "$R/npm-package" "$R/wp-plugin"
echo '{}' > "$R/npm-package/package-lock.json"; echo '{}' > "$R/wp-plugin/package-lock.json"
echo '{}' > "$R/wp-plugin/package.json"
bash "$BIN/generate.sh" "$R" >/dev/null 2>&1
expect "lists every npm directory of a monorepo" test "$(entries "$R/.github/dependabot.yml" | head -n1)" = "npm /npm-package /wp-plugin"

R="$(repo composer)"
mkdir -p "$R/public" "$R/lib"
echo '{ "require": { "php": ">=8.1", "ext-json": "*" }, "autoload": {} }' > "$R/public/composer.json"
bash "$BIN/generate.sh" "$R" >/dev/null 2>&1
expect "skips a composer.json without packages" test "$(entries "$R/.github/dependabot.yml")" = "github-actions /"
echo '{ "require": { "php": ">=8.1" }, "require-dev": { "kreait/firebase-php": "^7.24" } }' > "$R/public/composer.json"
bash "$BIN/generate.sh" "$R" >/dev/null 2>&1
expect "takes a composer.json with require-dev packages" test "$(entries "$R/.github/dependabot.yml" | head -n1)" = "composer /public"

expect "writes to stdout with -" bash -c "bash '$BIN/generate.sh' '$R' - | grep -q '^version: 2'"
expect "is reproducible" bash -c "diff <(bash '$BIN/generate.sh' '$R' -) '$R/.github/dependabot.yml'"
expect_not "fails for a missing directory" bash "$BIN/generate.sh" "$WORK/missing" -

echo
echo "$passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
