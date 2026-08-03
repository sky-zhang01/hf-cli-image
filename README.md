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

## Tags

| Tag | Meaning |
| --- | --- |
| `<upstream-version>` e.g. `1.26.0` | Exactly one upstream `huggingface_hub` release |
| `latest` | The most recent successfully published version |

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
  → already published?  →  exit
  → build locally, prove it, publish the version tag
  → replay the consumer's manifest request
  → move `latest`, tag the release in git
```

The registry is the state store. "Is this version already published" is one manifest request;
a separate state file could only disagree with it.

## The two things that make or break this pipeline

**1. The image manifest must be Docker schema2.** The intended consumer's image-update check
sends a fixed `Accept` list and its digest parser handles only
`application/vnd.docker.distribution.manifest.v2+json` and
`...manifest.list.v2+json`. An OCI image manifest — which a bare
`docker buildx build --push` produces by default — falls through to an empty result **with no
error and no log**, leaving new versions permanently undetectable. The workflow therefore
builds with `--load` and pushes from the local image store, and a gate replays the consumer's
exact anonymous request before `latest` is allowed to move.

**2. The GHCR package must be public.** A newly created package defaults to private. Until it
is made public the consumer's anonymous check keeps failing in a way that looks exactly like a
code bug. The gate above turns that into a loud build failure rather than a silent one.

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
