#!/usr/bin/env bash
# Writes the CycloneDX SBOMs of a release to SBOM_DIR - only what ships, not what
# builds it:
#
#   sbom-npm.cdx.json       the npm packages webpack bundled: every cyclonedx/bom.json
#                           that @cyclonedx/webpack-plugin wrote into PLUGIN_DIR during
#                           the build, merged. The @wordpress/* packages and React are
#                           externals that WordPress provides, so they are not in it.
#   sbom-composer.cdx.json  the composer packages of the payload, from the composer.lock
#                           pack.sh installed in build/<slug>/, without require-dev.
#
# An SBOM without components is not written: a plugin that bundles nothing has nothing
# to report. package-lock.json is no source on purpose - every npm package of a plugin
# is a devDependency, so it would list either nothing or the whole toolchain.
#
# Usage: SLUG=my-plugin VERSION=1.2.3 sbom.sh      after pack.sh (paths: see lib.sh)
#   SBOM_DIR              where the SBOMs go               (default: ROOT/sbom)
#   COMPOSER_INCLUDE_DEV  true: keep require-dev, for a plugin that ships a dev
#                         dependency in another form, e.g. prefixed by Strauss
#
# Needs jq, and for a payload with composer.json the composer plugin
# cyclonedx/cyclonedx-php-composer.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ -n "${SLUG:-}" ]] || wp_plugin_die "SLUG is not set - it has to be the wordpress.org slug"
[[ -n "${VERSION:-}" ]] || wp_plugin_die "VERSION is not set - the released version without the leading v"
command -v jq >/dev/null || wp_plugin_die "jq is not installed"
wp_plugin_resolve

PAYLOAD="$ROOT/build/$SLUG"
[[ -d "$PAYLOAD" ]] || wp_plugin_die "$PAYLOAD does not exist - run pack.sh first"
SBOM_DIR="${SBOM_DIR:-$ROOT/sbom}"
rm -rf "$SBOM_DIR"
mkdir -p "$SBOM_DIR"

# keep FILE KIND: writes FILE to SBOM_DIR as sbom-KIND.cdx.json with the released
# version, or reports that it is empty.
keep() {
  local count
  count="$(jq '.components // [] | length' "$1")"
  if [[ "$count" -eq 0 ]]; then
    echo "$2: no components, no SBOM"
    return
  fi
  jq --arg version "$VERSION" '.metadata.component.version = $version' "$1" > "$SBOM_DIR/sbom-$2.cdx.json"
  echo "$2: sbom-$2.cdx.json, $count components"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# One bom.json per webpack run (wp-scripts build runs once per output directory).
# Components are the same package when their bom-ref is, dependencies are joined.
#
# css-loader is dropped: wp-scripts extracts the CSS into .css files, so its runtime
# modules only run during the build - the plugin still counts them as bundled.
WEBPACK_SBOMS=()
while IFS= read -r -d '' file; do
  WEBPACK_SBOMS+=("$file")
done < <(find "$PLUGIN_PATH" -path '*/node_modules' -prune -o -path '*/cyclonedx/bom.json' -print0 | sort -z)
if [[ ${#WEBPACK_SBOMS[@]} -gt 0 ]]; then
  echo "Merging ${#WEBPACK_SBOMS[@]} webpack SBOM(s): ${WEBPACK_SBOMS[*]#"$PLUGIN_PATH/"}"
  jq -s '
    def ref: .["bom-ref"] // .purl // "\(.name)@\(.version)";
    ([.[].components // [] | .[]]
      | map(select((.purl // "") | startswith("pkg:npm/css-loader@") | not))
      | unique_by(ref)
      | sort_by(.purl // .name)) as $components
    | ([$components[] | ref] + [.[0].metadata.component | select(.) | ref]) as $refs
    | .[0] + {
      components: $components,
      dependencies: ([.[].dependencies // [] | .[]]
        | map(select(.ref as $r | $refs | index($r)))
        | group_by(.ref)
        | map({ref: .[0].ref, dependsOn: ([.[].dependsOn // [] | .[]] | unique
          | map(select(. as $d | $refs | index($d))))}))
    }' "${WEBPACK_SBOMS[@]}" > "$WORK/npm.json"
  keep "$WORK/npm.json" npm
else
  echo "npm: no cyclonedx/bom.json in $PLUGIN_DIR - no webpack build with @cyclonedx/webpack-plugin"
fi

# The payload's composer.lock is the one that was installed, also when the repository
# has none. With COMPOSER_INCLUDE_DEV it has to be the repository's: in the payload,
# installed with --no-dev, the plugin leaves require-dev out even without --omit=dev.
if [[ -f "$PAYLOAD/composer.json" ]]; then
  COMPOSER_DIR="$PAYLOAD"
  OMIT=(--omit=dev)
  if [[ "${COMPOSER_INCLUDE_DEV:-false}" == "true" ]]; then
    COMPOSER_DIR="$PLUGIN_PATH"
    OMIT=()
    [[ -f "$COMPOSER_DIR/composer.lock" ]] || wp_plugin_die "COMPOSER_INCLUDE_DEV needs $PLUGIN_DIR/composer.lock"
  fi
  echo "Composer SBOM of ${COMPOSER_DIR#"$ROOT/"}/composer.lock ..."
  composer --working-dir="$COMPOSER_DIR" CycloneDX:make-sbom --no-interaction --quiet \
    --output-format=JSON --spec-version=1.6 --mc-version="$VERSION" \
    ${OMIT[@]+"${OMIT[@]}"} --output-file="$WORK/composer.json"
  keep "$WORK/composer.json" composer
else
  echo "composer: no composer.json in the payload"
fi
