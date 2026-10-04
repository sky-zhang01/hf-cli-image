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
| `<upstream-version>` e.g. `2.1.1` | The verified build of that upstream `huggingface_hub` release |
| `latest` | The current upstream version selected by CI |

Every published version also gets a git tag and a GitHub Release of the same name. The image
tag is the delivery artifact; the git tag and Release are audit refs — the authoritative
recipe pointer for any published image is its `org.opencontainers.image.revision` label.

Version tags are refreshed when the recipe changes on `main`, during the weekly dependency
refresh, or with manual `workflow_dispatch` and `force=true`. The HF version can stay the same
while Python, base packages or upstream-allowed dependencies change. Each refresh uses
`--pull --no-cache`, verifies the image before publishing, and moves `latest` last.

Use the image digest for an exact rollback, including rebuilds from the same recipe commit:

```bash
docker pull ghcr.io/sky-zhang01/hf-cli@sha256:<recorded-digest>
```

CI logs record the installed package list and build metadata. The run summary records the
pinned base reference, recipe SHA, previous tag digests and published digest.
Git version tags remain create-only audit refs;
the image's revision label identifies the recipe, while its digest identifies the built artifact.

## How upstream tracking works

The HF version is not stored in this repository. `ARG HF_VERSION` has no default, and
`${HF_VERSION:?}` makes a missing build-arg a hard build failure. CI resolves the current final
or post release from the PyPI JSON API and validates the complete string before using it.
Dependabot independently opens weekly PRs for the literal Python base tag/digest and the
SHA-pinned workflow actions; it does not duplicate HF discovery. Runtime upgrades use the
newest supported stable release compatible with HF, without prereleases.

```text
scheduled run (every 6h)
  → resolve version from PyPI
  → probe registry by HTTP status: version tag + latest digest
  → published AND latest/git-tag/Release all in sync?  →  exit
  → build locally, prove it, publish the version tag   (if absent or refresh requested)
  → gate: the tag must be anonymously pullable
  → pull the exact published digest, move `latest`, assert both tags equal that digest
  → ensure git tag + GitHub Release
  → keepalive commit if the default branch has been quiet ~40 days
```

The same workflow refreshes the current version every Sunday and when recipe changes reach
`main`. PRs and recipe pushes run a separate job with read-only permissions: it builds the
image, verifies exact Python/HF metadata and `pip check`, downloads a pinned public README
over HTTPS, and downloads a 454 KB Xet fixture through the real native `hf-xet` CAS transport.
The Xet check rejects HTTP fallback, checks size/SHA256, then verifies online cache reuse and
offline reuse. PR jobs never publish or receive publishing credentials. The publishing job
performs the same verification on its own build before pushing.
Immediately before publishing either tag, CI checks that remote `main` still equals the
recipe SHA, so a queued run cannot publish an outdated recipe over a newer commit.

The registry is the state store, and every step after the probe is a reconcile: a run that
dies halfway is healed by the next run, not by the next upstream release. Registry probes
branch on the HTTP status code and hard-fail on anything but 200/404. A 200 response must
contain exactly one valid SHA256 digest; a missing `latest` always requires reconciliation.
Git tag and Release queries also distinguish a missing object from a network or API failure.

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
days). The `--load`-then-push build path keeps the image in the local store for verification.
Release behavior does not depend on a particular host's model serving or update mechanism.

The pipeline follows the stable version PyPI currently reports. If PyPI reports an older
already-published version, reconciliation moves `latest` back to that version's digest. This
also applies if upstream withdraws a release; CI does not silently keep a newer version in
preference to the current upstream report.

GitHub and Gitea are independently maintained. Their changes are synchronized only when the
owner explicitly requests synchronization.

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
- Mount the directory where you want downloaded files to persist.
- Point `HF_HOME` inside that same mount to keep the cache and partial blobs on the same
  filesystem as the final files.
- Supply `HF_TOKEN` through an `env_file`, never in a compose file.
- `HF_XET_HIGH_PERFORMANCE=1` enables Xet's high-throughput mode.
- ⚠️ `--include` takes **one** pattern per flag. `--include "a" "b"` makes the second string a
  positional filename and the CLI then ignores `--include` entirely. Repeat the flag instead.

## License

MIT — see [LICENSE](LICENSE). This applies to the packaging in this repository only;
`huggingface_hub` itself is licensed by Hugging Face.
