#!/usr/bin/env bash
# Shared release check for the Gitea and GitHub container builds.
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 IMAGE_REF EXPECTED_HF_VERSION [EXPECTED_PYTHON_VERSION]" >&2
  exit 2
fi

image_ref="$1"
hf_version="$2"
python_version="${3:-}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$python_version" ]; then
  python_version="$(sed -nE 's/^FROM[[:space:]]+python:([0-9]+\.[0-9]+\.[0-9]+)([-@][^[:space:]]*)?[[:space:]]*$/\1/p' "$script_dir/../Dockerfile")"
fi
if [[ ! "$image_ref" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/@-]*$ ]] ||
   [[ ! "$hf_version" =~ ^[0-9]+(\.[0-9]+)+([.]post[0-9]+)?$ ]] ||
   [[ ! "$python_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid image reference or expected version; Python must have an exact three-part pin." >&2
  exit 2
fi

run_dir="$(mktemp -d)"
cleanup() {
  status=$?
  trap - EXIT
  if [ -s "$run_dir/container.cid" ]; then
    docker rm -f "$(cat "$run_dir/container.cid")" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$run_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker image inspect --format 'Verifying image {{.Id}} ({{.Os}}/{{.Architecture}})' "$image_ref"
docker run --rm --pull=never --cidfile "$run_dir/container.cid" -i "$image_ref" \
  python - "$hf_version" "$python_version" <<'PY'
import contextlib
import hashlib
import importlib.metadata
import json
import os
import platform
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlsplit


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def check_file(path, size, sha256):
    require(path.is_file(), f"Missing downloaded file: {path}")
    require(path.stat().st_size == size, f"Unexpected size: {path}")
    require(hashlib.sha256(path.read_bytes()).hexdigest() == sha256, f"SHA256 mismatch: {path}")
    print(json.dumps({"file": str(path), "size": size, "sha256": sha256}), flush=True)


expected_hf, expected_python = sys.argv[1:]
require(os.getuid() == 568, f"Image UID {os.getuid()} != 568")
require(platform.python_version() == expected_python, f"Python {platform.python_version()} != {expected_python}")
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
    # Every check uses a fresh container-local home and cache; no host token or cache is mounted.
    for key in list(os.environ):
        if key.startswith(("HF_", "HUGGING_FACE_", "HUGGINGFACE_", "XET_")):
            del os.environ[key]
    home = workspace / "home"
    home.mkdir()
    hf_home = workspace / "hf"
    os.environ.update({
        "HOME": str(home), "XDG_CACHE_HOME": str(workspace / "cache"),
        "HF_HOME": str(hf_home), "HF_TOKEN_PATH": str(workspace / "absent-token"),
        "HF_ENDPOINT": "https://huggingface.co", "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
        "HF_HUB_DISABLE_TELEMETRY": "1", "HF_HUB_DISABLE_UPDATE_CHECK": "1",
        "HF_HUB_DISABLE_PROGRESS_BARS": "1", "HF_XET_HIGH_PERFORMANCE": "0", "NO_COLOR": "1",
    })
    cli_version = subprocess.check_output(["hf", "--version"], text=True).strip()
    require(cli_version == expected_hf, f"hf --version {cli_version!r} != {expected_hf}")
    subprocess.run(["hf", "version"], check=True)
    subprocess.run(["hf", "download", "--help"], check=True, stdout=subprocess.DEVNULL)

    http_dir = workspace / "http"
    http_command = ["hf", "download", "openai-community/gpt2", "README.md", "--revision",
                    "607a30d783dfa663caf39e06633721c8d4cfcd7e", "--local-dir", str(http_dir)]
    subprocess.run(http_command, check=True)
    check_file(http_dir / "README.md", 8092,
               "0fcd631078093c2aa1d93438b898320b8a1167784e2a1ab37b8016e9de8b3c2e")
    offline_env = {**os.environ, "HF_HUB_OFFLINE": "1"}
    subprocess.run(http_command, check=True, env=offline_env)
    check_file(http_dir / "README.md", 8092,
               "0fcd631078093c2aa1d93438b898320b8a1167784e2a1ab37b8016e9de8b3c2e")
    print("HTTP download and HF_HUB_OFFLINE local reuse: OK", flush=True)

    import hf_xet
    from huggingface_hub import file_download
    from huggingface_hub.cli.hf import main
    from huggingface_hub.utils import _xet

    original_session = _xet.get_xet_session
    original_http_get = file_download.http_get
    completed_endpoints = []

    class XetSessionSpy:
        def __init__(self, session):
            require(isinstance(session, hf_xet.XetSession), "Expected the native hf_xet session")
            self.session = session

        @contextlib.contextmanager
        def new_file_download_group(self, *args, **kwargs):
            endpoint = urlsplit(kwargs.get("endpoint", ""))
            require(endpoint.scheme == "https" and endpoint.hostname, "Missing HTTPS CAS endpoint")
            # Delegate to the real native group; only record a group after its downloads finish.
            with self.session.new_file_download_group(*args, **kwargs) as group:
                yield group
            completed_endpoints.append(endpoint.hostname)

    def reject_http_fallback(*args, **kwargs):
        raise RuntimeError("Xet fixture attempted an HTTP download fallback")

    repo = "hf-internal-testing/tiny-random-gpt2"
    revision = "71034c5d8bde858ff824298bdedc65515b97d2b9"
    xet_command = ["hf", "download", repo, "model.safetensors", "--revision", revision]
    _xet.get_xet_session = lambda: XetSessionSpy(original_session())
    file_download.http_get = reject_http_fallback
    try:
        # Call the installed hf entry function in this process so the native spy observes it.
        for phase in ("download", "online cache reuse"):
            sys.argv = xet_command
            try:
                main()
            except SystemExit as error:
                if error.code not in (None, 0):
                    raise
            require(len(completed_endpoints) == 1, f"Xet {phase} did not use exactly one completed native group overall")
    finally:
        _xet.get_xet_session = original_session
        file_download.http_get = original_http_get
    require(len(completed_endpoints) == 1, "Xet fixture did not complete exactly one native download group")
    print(json.dumps({"xetDownloadGroupsCompleted": len(completed_endpoints),
                      "casEndpointHosts": completed_endpoints, "httpFallbackAllowed": False}), flush=True)
    xet_file = hf_home / "hub" / "models--hf-internal-testing--tiny-random-gpt2" / "snapshots" / revision / "model.safetensors"
    check_file(xet_file, 453864, "8111d5afb0715dbf5a31396d31432cb56370ba23f6650a035ea0fc8a20b4e500")
    subprocess.run(xet_command, check=True, env=offline_env)
    check_file(xet_file, 453864, "8111d5afb0715dbf5a31396d31432cb56370ba23f6650a035ea0fc8a20b4e500")
    print("Native Xet download, online cache reuse, and HF_HUB_OFFLINE cache reuse: OK", flush=True)

print("Image verification: PASS", flush=True)
PY
