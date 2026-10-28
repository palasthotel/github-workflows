#!/usr/bin/env bash
# Sends every sbom-<kind>.cdx.json in SBOM_DIR to Dependency-Track, one project per
# SBOM: "<PROJECT> (<kind>)", e.g. "palasthotel/wp-postqueue (npm)", created on the
# first upload and marked as the latest version. The names match the SBOMs that the
# GitLab component palasthotel/devops/ci-components/sbom sends.
#
# In Dependency-Track every version is a project of its own with its own parent, and a
# new version is created without one. So the latest version is looked up first and the
# new one created under the same parent: move the latest version once, and the following
# releases land there as well.
#
# Authentication is workload identity federation: the GitHub OIDC token of the job is
# exchanged for a session of the service account, no stored secret. The bindings of the
# service account in Dependency-Track decide which runs may do that. The service account
# needs BOM_UPLOAD, PROJECT_CREATION_UPLOAD and VIEW_PORTFOLIO.
#
# Usage: upload.sh, in a job with id-token: write
#   DT_URL                      the Dependency-Track API, e.g. https://api.example.org
#   DT_PROVIDER                 name of the workload identity provider in Dependency-Track
#   DT_ACCOUNT                  name of the service account
#   DT_AUDIENCE                 audience of the OIDC token, as the provider expects it
#   PROJECT, VERSION            project name prefix (owner/repository) and version
#   SBOM_DIR                    (default: sbom)
#
# Credentials go to curl in files, never on the command line or into the log.
set -euo pipefail

die() {
  echo "ERROR: $*" >&2
  exit 1
}

for name in DT_URL DT_PROVIDER DT_ACCOUNT DT_AUDIENCE PROJECT VERSION; do
  [[ -n "${!name:-}" ]] || die "$name is not set"
done
command -v jq >/dev/null || die "jq is not installed"
DT_URL="${DT_URL%/}"
SBOM_DIR="${SBOM_DIR:-sbom}"

shopt -s nullglob
SBOMS=("$SBOM_DIR"/sbom-*.cdx.json)
[[ ${#SBOMS[@]} -gt 0 ]] || die "no sbom-*.cdx.json in $SBOM_DIR"

WORK="$(mktemp -d)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

# The claims of the OIDC token that the bindings match against - none of them is a
# secret, the signature that makes the token one is left out.
claims() {
  local payload
  payload="$(cut -d. -f2 "$WORK/subject" | tr '_-' '/+')"
  while (( ${#payload} % 4 )); do payload="$payload="; done
  printf '%s' "$payload" | base64 -d 2>/dev/null \
    | jq '{sub, aud, ref, ref_type, event_name, repository_owner_id, job_workflow_ref}' >&2 || true
}

# dt_call METHOD URL [curl options]: prints the answer; on an error it prints the reason
# given by Dependency-Track (never a credential), a hint for the usual causes, and fails.
dt_call() {
  local method="$1" endpoint="$2" status reason
  shift 2
  status="$(curl --silent --show-error --request "$method" --output "$WORK/response" \
    --write-out '%{http_code}' "$@" "$endpoint")" || status=000
  if [[ "$status" == 2?? ]]; then
    cat "$WORK/response"
    return 0
  fi
  echo "::error::$method $endpoint: HTTP $status" >&2
  cat "$WORK/response" >&2 && echo >&2
  # The reason Dependency-Track gives (RFC 6749 error_description, or problem details).
  # A token that matches no binding is refused without one, by design.
  reason="$(jq -r '.error_description // .detail // empty' "$WORK/response" 2>/dev/null || true)"
  case "$status:$endpoint:$reason" in
    000:*) echo "   Not reachable from the runner." >&2 ;;
    400:*/oauth/token:*workload_identity_provider*)
      echo "   The workload identity provider is \"$DT_PROVIDER\": its name in Dependency-Track," >&2
      echo "   not its description." >&2 ;;
    400:*/oauth/token:*service_account*)
      echo "   The service account is \"$DT_ACCOUNT\": its name in Dependency-Track, not its" >&2
      echo "   description." >&2 ;;
    400:*/oauth/token:*)
      echo "   No binding of service account \"$DT_ACCOUNT\" matches this run, or the audience" >&2
      echo "   \"$DT_AUDIENCE\" is not the one provider \"$DT_PROVIDER\" expects. The claims:" >&2
      claims ;;
    401:*) echo "   Credentials refused: the session ended." >&2 ;;
    403:*) echo "   The service account lacks a permission: BOM_UPLOAD, PROJECT_CREATION_UPLOAD" >&2
           echo "   (upload) or VIEW_PORTFOLIO (lookup of the latest version)." >&2 ;;
  esac
  return 1
}

[[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]] || die "no OIDC token available - the job needs permissions: id-token: write"
curl --silent --show-error --fail --get --header "@-" \
  --data-urlencode "audience=$DT_AUDIENCE" "$ACTIONS_ID_TOKEN_REQUEST_URL" \
  <<< "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  | jq -j '.value' > "$WORK/subject"
[[ -s "$WORK/subject" ]] || die "GitHub returned no OIDC token"

session="$(dt_call POST "$DT_URL/api/v2/oauth/token" \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  --data-urlencode "subject_token@$WORK/subject" \
  --data-urlencode "subject_token_type=urn:ietf:params:oauth:token-type:jwt" \
  --data-urlencode "workload_identity_provider=$DT_PROVIDER" \
  --data-urlencode "service_account=$DT_ACCOUNT")"
access_token="$(printf '%s' "$session" | jq -r '.access_token')"
echo "::add-mask::$access_token"
printf 'Authorization: Bearer %s\n' "$access_token" > "$WORK/headers"

failed=0
for sbom in "${SBOMS[@]}"; do
  kind="${sbom##*/sbom-}"
  kind="${kind%.cdx.json}"
  name="$PROJECT ($kind)"
  echo "$sbom → $DT_URL: $name $VERSION"

  # Parent of the latest version, by name as a query parameter: the names contain
  # slashes, which many servers refuse encoded in a path.
  parent=()
  if versions="$(dt_call GET "$DT_URL/api/v1/project" --header "@$WORK/headers" --get \
    --data-urlencode "name=$name" --data-urlencode "pageSize=500")"; then
    latest="$(printf '%s' "$versions" \
      | jq -r --arg name "$name" 'first(.[] | select(.name == $name and .isLatest == true) | .uuid) // empty')"
    if [[ -n "$latest" ]] && latest_project="$(dt_call GET "$DT_URL/api/v1/project/$latest" --header "@$WORK/headers")"; then
      parent_uuid="$(printf '%s' "$latest_project" | jq -r '.parent.uuid // empty')"
      if [[ -n "$parent_uuid" ]]; then
        parent=(--form "parentUUID=$parent_uuid")
        echo "   under $(printf '%s' "$latest_project" | jq -r '.parent.name // "?"'), like the latest version"
      fi
    fi
  else
    echo "::warning::Latest version of $name not readable, uploading without a parent."
  fi

  if ! answer="$(dt_call POST "$DT_URL/api/v1/bom" --header "@$WORK/headers" \
    --form "autoCreate=true" --form "isLatest=true" \
    --form "projectName=$name" --form "projectVersion=$VERSION" \
    ${parent[@]+"${parent[@]}"} --form "bom=@$sbom")"; then
    failed=1
    continue
  fi
  echo "✅ $name $VERSION, project $(printf '%s' "$answer" | jq -r '.projectUuid // "?"')"
done
exit "$failed"
