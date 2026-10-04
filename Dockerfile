# Packages the official Hugging Face CLI (`hf`) as a container image.
#
# Upstream is the PyPI package `huggingface_hub` (github.com/huggingface/huggingface_hub).
# Hugging Face does not publish a container image for the CLI, so this repository only
# tracks upstream releases and packages them. It adds no functionality of its own.
# Dependabot tracks both the supported stable Python release and its base digest.
FROM python:3.14.8-slim@sha256:c3e521df8b2b498a7a682e7e18676771cb80c6b75b8699af886b2d554ce40151

# Deliberately no default. The version is NOT stored in this repository: CI resolves the
# latest release from the PyPI JSON API and passes it in. That is why there is nothing here
# for a dependency bot to bump for HF itself — discovery remains in CI.
#
# `:?` makes a missing build-arg a hard build failure, so a build can never silently produce
# an image whose tag would not match the version actually installed inside it.
ARG HF_VERSION
# Recorded in the image so `docker inspect` alone identifies the recipe commit.
# This is what replaces a separate sha-<gitsha> image tag.
ARG GIT_SHA=unknown
RUN pip install --no-cache-dir "huggingface_hub==${HF_VERSION:?HF_VERSION build-arg is required}"

# hf-xet is a default dependency of huggingface_hub on x86_64/arm64, so the Xet
# content-addressed transport is present without requesting an extra.
#
# HF_HUB_DISABLE_UPDATE_CHECK: the CLI otherwise checks PyPI at start-up and, when a newer
# release exists, prints a hint to run `hf update`. In a version-tagged image that is wrong
# advice — following it would desync the installed version from the image tag.
ENV HF_HUB_DISABLE_TELEMETRY=1 \
    HF_HUB_DISABLE_UPDATE_CHECK=1 \
    HOME=/tmp

LABEL org.opencontainers.image.title="hf-cli" \
      org.opencontainers.image.version="${HF_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="https://github.com/huggingface/huggingface_hub" \
      org.opencontainers.image.description="Official huggingface_hub CLI (hf), packaged as a container image"

# Runs as a non-root uid/gid, so downloaded files are not owned by root.
USER 568:568

# No ENTRYPOINT on purpose, so both shapes work:
#   docker run --rm <image> hf download <repo-id> --local-dir /models/<name>
#   docker exec <container> hf download <repo-id> --local-dir /models/<name>
CMD ["sleep", "infinity"]
