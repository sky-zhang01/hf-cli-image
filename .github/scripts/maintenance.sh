#!/usr/bin/env bash
# Shared boundary checks for the verification and publishing jobs.

resolve_version() {
  jq --slurp -er '
    if length != 1 then error("expected one PyPI JSON response") else .[0].info.version end
    | if type == "string" and test("\\A[0-9]+(\\.[0-9]+)+(\\.post[0-9]+)?\\z")
      then . else error("expected a final/post release version string") end
  ' || return 1
}

registry_token() {
  local token
  token="$(curl -fsS --retry 3 --connect-timeout 10 \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:${REGISTRY_REPO:?}:pull" \
    | jq --slurp -er '
      if length != 1 then error("expected one registry token response") else .[0].token end
      | if type == "string" and test("\\A[A-Za-z0-9._~-]+\\z")
        then . else error("invalid registry token") end
    ')" || return 1
  printf '%s\n' "$token"
}

registry_probe() {
  local tag="$1" token="$2" header code digest
  header="$(mktemp)" || return 1
  if ! code="$(curl -sS --retry 3 --connect-timeout 10 -I -D "$header" -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer ${token}" -H "Accept: ${MANIFEST_ACCEPT:?}" \
      "https://ghcr.io/v2/${REGISTRY_REPO:?}/manifests/${tag}")"; then
    rm -f -- "$header"
    echo "::error::registry request for ${tag} failed" >&2
    return 1
  fi
  case "$code" in
    404) rm -f -- "$header"; printf '404 none\n'; return 0 ;;
    200) ;;
    *) rm -f -- "$header"; echo "::error::registry request for ${tag} returned HTTP ${code}" >&2; return 1 ;;
  esac
  # curl can record a proxy CONNECT or earlier retry response. Inspect only
  # the final response block, and reject missing or duplicate digest headers.
  if ! digest="$(awk '
      /^HTTP\// { count=0; invalid=0; value="" }
      tolower($1)=="docker-content-digest:" { count++; value=$2; if (NF!=2) invalid=1 }
      END { if (count==1 && !invalid) printf "%s", value; else exit 1 }
    ' "$header" | tr -d '\r')"; then
    rm -f -- "$header"
    echo "::error::registry response for ${tag} lacks one digest header" >&2
    return 1
  fi
  rm -f -- "$header"
  if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "::error::registry response for ${tag} has an invalid digest" >&2
    return 1
  fi
  printf '200 %s\n' "$digest"
}

registry_config() {
  local digest="$1" token="$2" body code actual config
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  body="$(mktemp)" || return 1
  if ! code="$(curl -sS --retry 3 --connect-timeout 10 -o "$body" -w '%{http_code}' \
      -H "Authorization: Bearer ${token}" -H "Accept: ${MANIFEST_ACCEPT:?}" \
      "https://ghcr.io/v2/${REGISTRY_REPO:?}/manifests/${digest}")"; then
    rm -f -- "$body"
    echo '::error::published manifest request failed' >&2
    return 1
  fi
  if ! actual="sha256:$(sha256sum "$body" | awk '{print $1}')"; then
    rm -f -- "$body"
    echo '::error::published manifest hash failed' >&2
    return 1
  fi
  if [ "$code" != 200 ] || [ "$actual" != "$digest" ]; then
    rm -f -- "$body"
    echo '::error::published manifest status or content digest differs' >&2
    return 1
  fi
  if ! config="$(jq --slurp -er '
      if length != 1 then error("expected one manifest") else .[0].config.digest end
      | if type == "string" and test("\\Asha256:[0-9a-f]{64}\\z")
        then . else error("invalid manifest config digest") end
    ' "$body")"; then
    rm -f -- "$body"
    return 1
  fi
  rm -f -- "$body"
  printf '%s\n' "$config"
}

git_tag_exists() {
  local status
  if git ls-remote --exit-code --tags origin "refs/tags/${1}" >/dev/null; then
    return 0
  else
    status=$?
    [ "$status" != 2 ] || return 1
    echo "::error::git tag query failed (exit ${status})" >&2
    return 2
  fi
}

assert_current_main() {
  local remote
  remote="$(git ls-remote --exit-code origin refs/heads/main)" || return 1
  if [[ ! "$remote" =~ ^([0-9a-f]{40})[[:space:]]refs/heads/main$ ]] ||
     [ "${BASH_REMATCH[1]}" != "${SOURCE_SHA:?}" ]; then
    echo '::error::remote main differs from this recipe; refusing a stale publication' >&2
    return 1
  fi
}

release_exists() {
  local code
  if ! code="$(curl -sS --retry 3 --connect-timeout 10 -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer ${GH_TOKEN:?}" -H 'Accept: application/vnd.github+json' \
      "${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY:?}/releases/tags/${1}")"; then
    echo '::error::GitHub Release request failed' >&2
    return 2
  fi
  case "$code" in
    200) return 0 ;;
    404) return 1 ;;
    *) echo "::error::GitHub Release request returned HTTP ${code}" >&2; return 2 ;;
  esac
}

needs_build() {
  local version_status="$1" force="$2" event="$3" schedule="$4"
  case "$version_status" in 200|404) ;; *) return 1 ;; esac
  case "$force" in true|false) ;; *) return 1 ;; esac
  if [ "$version_status" = 404 ] || [ "$force" = true ] || [ "$event" = push ] ||
     { [ "$event" = schedule ] && [ "$schedule" = '47 3 * * 0' ]; }; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

needs_sync() {
  if [ "$1" = true ] || [ "$2" = 404 ] || [ "$3" != "$4" ] || [ "$5" = true ] || [ "$6" = true ]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

build_image() {
  local ref="$1" version="$2" base recipe config manifest loaded
  recipe="${SOURCE_SHA:-${GITHUB_SHA:?}}"
  base="$(sed -n 's/^FROM[[:space:]]\{1,\}\([^[:space:]]*\)[[:space:]]*$/\1/p' Dockerfile)" || return 1
  if [[ ! "$base" =~ ^python:[0-9]+\.[0-9]+\.[0-9]+-slim@sha256:[0-9a-f]{64}$ ]]; then
    echo '::error::Dockerfile must pin one stable Python slim tag and digest' >&2
    return 1
  fi
  echo "Recipe base: ${base}; recipe SHA: ${recipe}"
  docker buildx build --pull --no-cache --platform linux/amd64 --provenance=false --progress=plain --load \
    --metadata-file "${BUILD_METADATA:?}" --build-arg "HF_VERSION=${version}" \
    --build-arg "GIT_SHA=${recipe}" --tag "$ref" . || return 1
  cat "$BUILD_METADATA" || return 1
  config="$(jq -er '."containerimage.config.digest"' "$BUILD_METADATA")" || return 1
  manifest="$(jq -er '."containerimage.digest"' "$BUILD_METADATA")" || return 1
  [[ "$config" =~ ^sha256:[0-9a-f]{64}$ ]] && [[ "$manifest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  loaded="$(docker image inspect "$ref" --format '{{.Id}}')" || return 1
  # Classic and containerd image stores expose different .Id values.
  if [ "$loaded" != "$config" ] && [ "$loaded" != "$manifest" ]; then
    echo '::error::loaded image does not match build metadata' >&2
    return 1
  fi
  echo "Built config ${config}; build manifest ${manifest}; loaded image ${loaded}"
}
