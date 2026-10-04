#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=maintenance.sh
source "$script_dir/maintenance.sh"

temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
passed=0
failed=0
check() {
  local name="$1" expected_status="$2" expected_output="$3" result status
  shift 3
  if result="$("$@" 2>"$temporary/stderr")"; then status=0; else status=$?; fi
  if [ "$status" = "$expected_status" ] && [ "$result" = "$expected_output" ]; then
    passed=$((passed + 1))
  else
    printf 'FAIL %s: status=%s output=%q\n' "$name" "$status" "$result" >&2
    cat "$temporary/stderr" >&2
    failed=$((failed + 1))
  fi
}
version() { printf '%s' "$1" | resolve_version; }
check final 0 2.1.1 version '{"info":{"version":"2.1.1"}}'
check post 0 2.1.1.post1 version '{"info":{"version":"2.1.1.post1"}}'
for value in '2.1.1rc1' '2.1.1a1' '2.1.1.dev1' '2.1.1+local' '2' '' '2.1.1\nversion=2.2.0rc1' '2.1.1\n' '2.1.1\r'; do
  check "reject-version-$value" 1 '' version "{\"info\":{\"version\":\"$value\"}}"
done
for value in 2 true null '[]' '{}'; do
  check "reject-type-$value" 1 '' version "{\"info\":{\"version\":$value}}"
done
check multiple-json 1 '' version '{"info":{"version":"2.1.1"}} {"info":{"version":"2.1.1"}}'
check absent-version 1 '' version '{"info":{}}'

digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
other_digest="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
export REGISTRY_REPO=example/hf-cli MANIFEST_ACCEPT=application/vnd.docker.distribution.manifest.v2+json
export GH_TOKEN=fixture GITHUB_REPOSITORY=example/hf-cli-image GITHUB_API_URL=https://api.github.com
response_code=200
response_headers="HTTP/2 200\r\ndocker-content-digest: $digest\r\n\r\n"
response_body=''
token_json='{"token":"fixture.token"}'
curl_status=0
curl() {
  local header='' output='' previous='' argument url=''
  for argument in "$@"; do
    [ "$previous" != '-D' ] || header="$argument"
    [ "$previous" != '-o' ] || output="$argument"
    url="$argument"
    previous="$argument"
  done
  if [[ "$url" == 'https://ghcr.io/token?'* ]]; then
    printf '%s' "$token_json"
    return "$curl_status"
  fi
  [ -z "$header" ] || printf '%b' "$response_headers" > "$header"
  if [ -n "$output" ] && [ "$output" != /dev/null ]; then printf '%s' "$response_body" > "$output"; fi
  if [ "$curl_status" != 0 ]; then return "$curl_status"; fi
  if [[ "$url" == */manifests/latest ]] && [ -n "${latest_code:-}" ]; then
    printf '%b' "$latest_headers" > "$header"
    printf '%s' "$latest_code"
    return
  fi
  printf '%s' "$response_code"
}
check token-ok 0 fixture.token registry_token
token_json='{"token":"fixture+/=="}'
check token-base64-padding 0 fixture+/== registry_token
token_json='{"token":"fixture=middle"}'
check token-misplaced-padding 1 '' registry_token
token_json='{"token":"fixture\nsecond"}'
check token-newline 1 '' registry_token
token_json='{"token":true}'
check token-type 1 '' registry_token
# JSON fixture data, never command text.
# shellcheck disable=SC2089
token_json='{"token":"fixture.token"}'
curl_status=7
check valid-token-json-but-network-failed 1 '' registry_token
curl_status=0
check manifest-ok 0 "200 $digest" registry_probe 2.1.1 fixture
response_headers="HTTP/1.1 200 Connection established\r\n\r\nHTTP/2 200\r\nDocker-Content-Digest: $digest\r\n\r\n"
check final-response 0 "200 $digest" registry_probe 2.1.1 fixture
response_headers="HTTP/2 503\r\ndocker-content-digest: $other_digest\r\n\r\nHTTP/2 200\r\ndocker-content-digest: $digest\r\n\r\n"
check retry-final-response 0 "200 $digest" registry_probe 2.1.1 fixture
response_headers='HTTP/2 200\r\n\r\n'
check missing-digest 1 '' registry_probe 2.1.1 fixture
response_headers="HTTP/2 200\r\ndocker-content-digest: $digest\r\ndocker-content-digest: $digest\r\n\r\n"
check duplicate-digest 1 '' registry_probe 2.1.1 fixture
response_headers='HTTP/2 200\r\ndocker-content-digest: sha256:bad\r\n\r\n'
check invalid-digest 1 '' registry_probe 2.1.1 fixture
response_headers="HTTP/2 200\r\ndocker-content-digest: $digest unexpected\r\n\r\n"
check extra-digest-field 1 '' registry_probe 2.1.1 fixture
response_code=404
check missing-tag 0 '404 none' registry_probe latest fixture
response_code=503
check registry-error 1 '' registry_probe 2.1.1 fixture
response_code=200
curl_status=7
check registry-network-error 1 '' registry_probe 2.1.1 fixture
curl_status=0

# JSON fixture data, never command text.
# shellcheck disable=SC2089
response_body="{\"schemaVersion\":2,\"config\":{\"digest\":\"$other_digest\"}}"
manifest_digest="sha256:$(printf '%s' "$response_body" | sha256sum | awk '{print $1}')"
check manifest-config 0 "$other_digest" registry_config "$manifest_digest" fixture
check manifest-body-digest-mismatch 1 '' registry_config "$digest" fixture
hash_status=0
sha256sum() { command sha256sum "$@"; return "$hash_status"; }
hash_status=1
check valid-hash-output-but-hash-failed 1 '' registry_config "$manifest_digest" fixture
hash_status=0
response_code=404
check manifest-body404 1 '' registry_config "$manifest_digest" fixture
response_code=200
curl_status=7
check manifest-body-network-failed 1 '' registry_config "$manifest_digest" fixture
curl_status=0
response_body='{"schemaVersion":2,"config":{"digest":true}}'
invalid_config_digest="sha256:$(printf '%s' "$response_body" | sha256sum | awk '{print $1}')"
check manifest-config-type 1 '' registry_config "$invalid_config_digest" fixture
# JSON fixture data, never command text.
# shellcheck disable=SC2089
response_body="{\"schemaVersion\":2,\"config\":{\"digest\":\"$other_digest\"}}"

git_status=0
remote_main=''
git() { printf '%s' "$remote_main"; return "$git_status"; }
check git-tag-exists 0 '' git_tag_exists 2.1.1
git_status=2
check git-tag-absent 1 '' git_tag_exists 2.1.1
git_status=128
check git-network-error 2 '' git_tag_exists 2.1.1
export SOURCE_SHA=1111111111111111111111111111111111111111
git_status=0
remote_main="$SOURCE_SHA"$'\trefs/heads/main'
check current-main 0 '' assert_current_main
remote_main='2222222222222222222222222222222222222222'$'\trefs/heads/main'
check stale-main 1 '' assert_current_main
remote_main="$SOURCE_SHA"$'\trefs/heads/main\n'$SOURCE_SHA$'\trefs/heads/main'
check duplicate-main-response 1 '' assert_current_main
remote_main="$SOURCE_SHA"$'\trefs/heads/main'
git_status=128
check valid-main-output-but-git-failed 1 '' assert_current_main
git_status=0
response_code=200
check release-exists 0 '' release_exists 2.1.1
response_code=404
check release-absent 1 '' release_exists 2.1.1
response_code=403
check release-api-error 2 '' release_exists 2.1.1
curl_status=7
check release-network-error 2 '' release_exists 2.1.1
curl_status=0

check already-published 0 false needs_build 200 false schedule '23 */6 * * *'
check new-upstream 0 true needs_build 404 false schedule '23 */6 * * *'
check force 0 true needs_build 200 true workflow_dispatch ''
check manual-without-force 0 false needs_build 200 false workflow_dispatch ''
check recipe-push 0 true needs_build 200 false push ''
check weekly-refresh 0 true needs_build 200 false schedule '47 3 * * 0'
check invalid-force 1 '' needs_build 200 unexpected workflow_dispatch ''
check unexpected-registry-status 1 '' needs_build 503 false schedule '23 */6 * * *'
check fully-synced 0 false needs_sync false 200 "$digest" "$digest" false false
check latest404 0 true needs_sync false 404 "$digest" none false false
check diverged-latest 0 true needs_sync false 200 "$digest" "$other_digest" false false
check missing-git-tag 0 true needs_sync false 200 "$digest" "$digest" true false
check missing-release 0 true needs_sync false 200 "$digest" "$digest" false true
check built-image 0 true needs_sync true 200 "$digest" "$digest" false false

# Run the production build helper with both image-store conventions and failures
# that still produce plausible output; no fixture contacts a real registry.
export BUILD_METADATA="$temporary/build.json"
build_status=0
inspect_status=0
loaded_id="$other_digest"
build_manifest="$manifest_digest"
build_config="$other_digest"
export DOCKER_CALLS="$temporary/docker-calls"
docker() {
  printf '%s\n' "$*" >> "$DOCKER_CALLS"
  case "$1 $2" in
    'buildx build')
      if [ -n "${metadata_override:-}" ]; then
        printf '%s' "$metadata_override" > "$BUILD_METADATA"
      else
        printf '{"containerimage.config.digest":"%s","containerimage.digest":"%s"}\n' "$build_config" "$build_manifest" > "$BUILD_METADATA"
      fi
      return "$build_status" ;;
    'image inspect') printf '%s\n' "$loaded_id"; return "$inspect_status" ;;
    *) return "${docker_status:-0}" ;;
  esac
}
build_quiet() { build_image hf-fixture:2.1.1 2.1.1 >/dev/null; }
check classic-image-store 0 '' build_quiet
loaded_id="$manifest_digest"
check containerd-image-store 0 '' build_quiet
loaded_id="$digest"
check loaded-image-mismatch 1 '' build_quiet
loaded_id="$other_digest"
build_status=1
check metadata-written-but-build-failed 1 '' build_quiet
build_status=0
inspect_status=1
check valid-id-output-but-inspect-failed 1 '' build_quiet
inspect_status=0
build_config=invalid
check invalid-build-config 1 '' build_quiet
build_config="$other_digest\\n"
check build-config-trailing-newline 1 '' build_quiet
build_config="$other_digest\\r"
check build-config-trailing-CR 1 '' build_quiet
build_config="$other_digest"
build_manifest="$manifest_digest\\n"
check build-manifest-trailing-newline 1 '' build_quiet
build_manifest="$manifest_digest"
metadata_override="{\"containerimage.config.digest\":\"$build_config\",\"containerimage.digest\":\"$build_manifest\"} {\"containerimage.config.digest\":\"$build_config\",\"containerimage.digest\":\"$build_manifest\"}"
check build-multiple-metadata-json 1 '' build_quiet
metadata_override=''
check fresh-build-flags 0 '' test -n "$(grep -F -- '--pull --no-cache --platform linux/amd64 --provenance=false --progress=plain --load' "$DOCKER_CALLS")"

# Extract and execute the actual workflow run blocks, instead of a test copy of
# their orchestration. Exported mock CLIs keep these tests offline and read-only.
workflow_step() {
  local name="$1" output="$temporary/workflow-step.sh"
  awk -v name="$name" '
    $0=="      - name: " name { found=1; next }
    found && $0=="        run: |" { run=1; next }
    run && /^          / { print substr($0,11); next }
    run && /^[[:space:]]*$/ { print ""; next }
    run { exit }
  ' "$script_dir/../workflows/publish.yml" > "$output"
  [ -s "$output" ] || return 1
  : > "$GITHUB_OUTPUT"
  : > "$DOCKER_CALLS"
  bash "$output" > "$temporary/workflow-stdout"
}
export -f curl git docker sha256sum
# Pass JSON data to the mocked CLI functions in the child Bash process.
# shellcheck disable=SC2090
export response_code response_headers response_body token_json curl_status latest_code latest_headers
export git_status remote_main hash_status build_status inspect_status loaded_id build_config build_manifest docker_status metadata_override
export V=2.1.1 FORCE=false EVENT_NAME=schedule EVENT_SCHEDULE='23 */6 * * *'
export IMAGE=ghcr.io/example/hf-cli GITHUB_OUTPUT="$temporary/github-output"
export BUILT=false PREVIOUS_DIGEST="$manifest_digest" DIGEST="$manifest_digest" VERIFIED_CONFIG="$other_digest"
response_code=200
response_headers="HTTP/2 200\r\ndocker-content-digest: $manifest_digest\r\n\r\n"
remote_main="$SOURCE_SHA"$'\trefs/heads/main'
check workflow-fully-synced 0 '' workflow_step 'Decide what needs doing'
check workflow-skip-output 0 '' grep -q '^build=false$' "$GITHUB_OUTPUT"
check workflow-synced-output 0 '' grep -q '^sync=false$' "$GITHUB_OUTPUT"
EVENT_NAME=push
check workflow-recipe-push 0 '' workflow_step 'Decide what needs doing'
check workflow-recipe-push-rebuild-output 0 '' grep -q '^build=true$' "$GITHUB_OUTPUT"
EVENT_NAME=schedule
EVENT_SCHEDULE='47 3 * * 0'
check workflow-weekly-refresh 0 '' workflow_step 'Decide what needs doing'
check workflow-weekly-refresh-rebuild-output 0 '' grep -q '^build=true$' "$GITHUB_OUTPUT"
EVENT_SCHEDULE='23 */6 * * *'
latest_code=404
latest_headers='HTTP/2 404\r\n\r\n'
check workflow-latest404 0 '' workflow_step 'Decide what needs doing'
check workflow-latest404-sync-output 0 '' grep -q '^sync=true$' "$GITHUB_OUTPUT"
latest_code=''
response_headers='HTTP/2 200\r\n\r\n'
check workflow-malformed200 1 '' workflow_step 'Decide what needs doing'
response_headers="HTTP/2 200\r\ndocker-content-digest: $manifest_digest\r\n\r\n"
git_status=128
check workflow-git-query-error 2 '' workflow_step 'Decide what needs doing'
git_status=0
curl_status=7
check workflow-token-network-error 1 '' workflow_step 'Decide what needs doing'
curl_status=0
check workflow-artifact-gate 0 '' workflow_step 'Gate — the published tag must be anonymously pullable'
PREVIOUS_DIGEST="$digest"
check workflow-reconcile-changed-tag 1 '' workflow_step 'Gate — the published tag must be anonymously pullable'
PREVIOUS_DIGEST="$manifest_digest"
response_code=404
check workflow-published-version404 1 '' workflow_step 'Gate — the published tag must be anonymously pullable'
response_code=200
check workflow-move-latest 0 '' workflow_step 'Move latest'
check workflow-latest-pushed 0 '' grep -q '^push ghcr.io/example/hf-cli:latest$' "$DOCKER_CALLS"
VERIFIED_CONFIG="$digest"
check workflow-config-mismatch 1 '' workflow_step 'Move latest'
check workflow-config-mismatch-no-push 1 '' grep -q '^push ' "$DOCKER_CALLS"
VERIFIED_CONFIG="$other_digest"
remote_main='2222222222222222222222222222222222222222'$'\trefs/heads/main'
check workflow-stale-main 1 '' workflow_step 'Move latest'
check workflow-stale-main-no-push 1 '' grep -q '^push ' "$DOCKER_CALLS"
check workflow-stale-version-no-push 1 '' workflow_step 'Push the verified version tag'
check workflow-stale-version-push-absent 1 '' grep -q '^push ' "$DOCKER_CALLS"
remote_main="$SOURCE_SHA"$'\trefs/heads/main'
latest_code=404
latest_headers='HTTP/2 404\r\n\r\n'
check workflow-latest-readback404 1 '' workflow_step 'Move latest'
latest_code=200
latest_headers="HTTP/2 200\r\ndocker-content-digest: $digest\r\n\r\n"
check workflow-latest-readback-different 1 '' workflow_step 'Move latest'
latest_headers='HTTP/2 200\r\n\r\n'
check workflow-latest-readback-missing-digest 1 '' workflow_step 'Move latest'
latest_code=''
hash_status=1
check workflow-manifest-hash-failed 1 '' workflow_step 'Move latest'
check workflow-manifest-hash-failed-no-push 1 '' grep -q '^push ' "$DOCKER_CALLS"

printf 'Maintenance tests: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" = 0 ]
