#!/usr/bin/env bash
# Release check for this repository's image. It runs inside the image with no host token or cache.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 IMAGE_REF EXPECTED_HF_VERSION" >&2
  exit 2
fi

image_ref="$1"
hf_version="$2"

docker image inspect --format 'Verifying image {{.Id}} ({{.Os}}/{{.Architecture}})' "$image_ref"
docker run --rm --pull=never -i "$image_ref" python - "$hf_version" <<'PY'
import hashlib
import importlib.metadata
import json
import os
import platform
import subprocess
import sys
import tempfile
from pathlib import Path


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def check_file(path, size, sha256):
    require(path.is_file(), f"Missing downloaded file: {path}")
    require(path.stat().st_size == size, f"Unexpected size: {path}")
    require(hashlib.sha256(path.read_bytes()).hexdigest() == sha256, f"SHA256 mismatch: {path}")
    print(json.dumps({"file": str(path), "size": size, "sha256": sha256}), flush=True)


expected_hf = sys.argv[1]
require(os.getuid() == 568, f"Image UID {os.getuid()} != 568")
installed_hf = importlib.metadata.version("huggingface_hub")
require(installed_hf == expected_hf, f"huggingface_hub {installed_hf} != {expected_hf}")
print(json.dumps({"python": platform.python_version(), "huggingface_hub": installed_hf,
                  "hf-xet": importlib.metadata.version("hf-xet"), "uid": os.getuid()}), flush=True)
packages = sorted(({"name": dist.metadata["Name"], "version": dist.version}
                   for dist in importlib.metadata.distributions()), key=lambda item: item["name"].lower())
print(json.dumps({"installedPackages": packages}), flush=True)
subprocess.run([sys.executable, "-m", "pip", "check"], check=True)

with tempfile.TemporaryDirectory(prefix="hf-image-verify-") as temporary:
    workspace = Path(temporary)
    (workspace / "home").mkdir()
    os.environ.update({
        "HOME": str(workspace / "home"), "XDG_CACHE_HOME": str(workspace / "cache"),
        "HF_HOME": str(workspace / "hf"), "HF_TOKEN_PATH": str(workspace / "absent-token"),
        "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
    })
    cli_version = subprocess.check_output(["hf", "--version"], text=True).strip()
    require(cli_version == expected_hf, f"hf --version {cli_version!r} != {expected_hf}")
    import hf_xet  # noqa: F401

    http_dir = workspace / "http"
    subprocess.run(["hf", "download", "openai-community/gpt2", "README.md", "--revision",
                    "607a30d783dfa663caf39e06633721c8d4cfcd7e", "--local-dir", str(http_dir)], check=True)
    check_file(http_dir / "README.md", 8092,
               "0fcd631078093c2aa1d93438b898320b8a1167784e2a1ab37b8016e9de8b3c2e")

    xet_dir = workspace / "xet"
    subprocess.run(["hf", "download", "hf-internal-testing/tiny-random-gpt2", "model.safetensors", "--revision",
                    "71034c5d8bde858ff824298bdedc65515b97d2b9", "--local-dir", str(xet_dir)], check=True)
    check_file(xet_dir / "model.safetensors", 453864,
               "8111d5afb0715dbf5a31396d31432cb56370ba23f6650a035ea0fc8a20b4e500")

print("Image verification: PASS", flush=True)
PY
