# hf-cli-image

Tracks upstream [`huggingface_hub`](https://github.com/huggingface/huggingface_hub) releases
and publishes the official `hf` CLI as a container image.

```text
ghcr.io/sky-zhang01/hf-cli
```

This repository adds no functionality of its own. It exists because Hugging Face does not
publish a container image for the CLI.

## Why the official CLI

`huggingface_hub` pulls in `hf-xet` as a **default** dependency on x86_64 and arm64 — not as an
extra — so the Xet content-addressed transport is active out of the box. Xet is Hugging Face's
current transport layer and replaces the older `hf_transfer` acceleration path.

## Tags and releases

| Tag | Meaning |
| --- | --- |
| `<upstream-version>` e.g. `1.26.0` | Exactly one upstream `huggingface_hub` release |
| `latest` | The most recent successfully published version |

Every published version also gets a git tag and a GitHub Release of the same name. The image
tag is the delivery artifact; the git tag and Release are audit refs — the authoritative
recipe pointer for any published image is its `org.opencontainers.image.revision` label.

The version tag is immutable in normal operation: the workflow refuses to build a version whose
tag already resolves in the registry. The only way to overwrite one is a manual
`workflow_dispatch` with `force=true`, which is deliberate and logged as a warning.

## How upstream tracking works

There is no dependency bot here, and none is needed — **the version is not stored in this
repository at all**. `ARG HF_VERSION` has no default, and `${HF_VERSION:?}` makes a missing
build-arg a hard build failure. CI resolves the current release from the PyPI JSON API and
passes it in, so there is nothing for Renovate or Dependabot to bump.

```text
scheduled run (every 6h)
  → resolve version from PyPI
  → probe registry by HTTP status: version tag + latest digest
  → published AND latest/git-tag/Release all in sync?  →  exit
  → build locally, prove it, publish the version tag   (build only if the tag is absent)
  → gate: the tag must be anonymously pullable
  → re-point `latest` (registry-side copy), assert latest digest == version digest
  → ensure git tag + GitHub Release
  → keepalive commit if the default branch has been quiet ~40 days
```

The registry is the state store, and every step after the probe is a reconcile: a run that
dies halfway is healed by the next run, not by the next upstream release. Registry probes
branch on the HTTP status code and hard-fail on anything but 200/404 — "assume unpublished"
is indistinguishable from a registry outage and would silently overwrite an immutable tag.

## The three ways this pipeline can rot silently

**1. The GHCR package must be public.** A newly created package defaults to private. Until it
is made public the consumer's anonymous check keeps failing in a way that looks exactly like a
code bug. The gate before `latest` moves turns that into a loud build failure rather than a
silent one.

**2. `latest` must actually equal the newest version.** The consumer watches the `latest`
digest, so "the version tag exists" is not the invariant that matters. The workflow asserts
`latest digest == version digest` after every move and reconciles on every run.

**3. GitHub disables the cron after 60 quiet days — and tag pushes do not count.** In a public
repository, scheduled workflows are auto-disabled after 60 days without repository activity.
Verified against this repo's own `/activity` API: a real tag push leaves no activity record,
while branch pushes do — so a tag-only repo dies on schedule regardless of upstream cadence.
The workflow therefore makes an unconditional, age-gated keepalive commit (at most one per ~40
days). One historical false belief is documented here so it does not come back: the image
manifest does **not** need to be Docker schema2 — TrueNAS 25.10.5's updater compares the
`Docker-Content-Digest` response header and never parses the manifest body, so OCI manifests
are detected just as well. The `--load`-then-push build path is kept because the local smoke
test needs the image in the local store, not for its media type.

Known accepted edge: the pipeline publishes whatever PyPI reports as the current release. If
upstream yanks its newest release, PyPI reports the previous one, which is already published —
`latest` keeps serving the yanked version until the next upstream release.

## Using it

```bash
# one-shot
docker run --rm -v "$MODELS_DIR:/models" -e HF_TOKEN \
  ghcr.io/sky-zhang01/hf-cli \
  hf download <repo-id> --local-dir /models/<repo-name>

# resident service, driven by exec
docker exec <container> hf download <repo-id> --local-dir /models/<repo-name>
```

The image has no `ENTRYPOINT` and its default command is `sleep infinity`, so it works both as
a one-shot and as a long-running container.

Notes:

- Runs as `568:568`, a non-root uid/gid, so downloaded files are not owned by root.
- Mount the directory your serving stack already reads models from, so a finished download
  needs no copy or move step.
- Point `HF_HOME` inside that same mount to keep the cache and partial blobs on the same
  filesystem as the final files.
- Supply `HF_TOKEN` through an `env_file`, never in a compose file.
- `HF_XET_HIGH_PERFORMANCE=1` enables Xet's high-throughput mode.
- ⚠️ `--include` takes **one** pattern per flag. `--include "a" "b"` makes the second string a
  positional filename and the CLI then ignores `--include` entirely. Repeat the flag instead.

## License

MIT — see [LICENSE](LICENSE). This applies to the packaging in this repository only;
`huggingface_hub` itself is licensed by Hugging Face.
