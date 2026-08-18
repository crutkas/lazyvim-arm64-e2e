#!/usr/bin/env bash
set -euo pipefail

run_id="${1:-}"
runs="${2:-10}"
warmups="${3:-3}"

if [[ ! "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,47}$ ]]; then
  echo "RunId must be 1-48 safe filename characters." >&2
  exit 2
fi
if ((runs < 2 || warmups < 0)); then
  echo "Runs must be >= 2 and Warmups must be >= 0." >&2
  exit 2
fi

unset WSL_INTEROP WSLENV
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

contaminated_variables=()
while IFS='=' read -r name value; do
  normalized="${value//\\//}"
  if [[ "$normalized" == "/mnt" ||
        "$normalized" == /mnt/* ||
        "$normalized" == *"/mnt/"* ||
        "$normalized" =~ (^|[=:[:space:]])[A-Za-z]:/ ||
        "$normalized" =~ (^|[=:[:space:]])/[A-Za-z]/ ]]; then
    contaminated_variables+=("$name")
  fi
done < <(env)
if ((${#contaminated_variables[@]} > 0)); then
  printf 'Windows-contaminated environment variables: %s\n' \
    "${contaminated_variables[*]}" >&2
  exit 2
fi

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
case "$repo" in
  /mnt | /mnt/*)
    echo "The WSL lane must run from a Linux-filesystem copy, not $repo." >&2
    exit 2
    ;;
esac
if [[ "$(uname -m)" != "aarch64" ]]; then
  echo "The WSL lane requires native Linux ARM64; got $(uname -m)." >&2
  exit 2
fi
if [[ -n "${WSL_INTEROP-}" || -n "${WSLENV-}" || "$PATH" == *"/mnt/"* ]]; then
  echo "Windows interoperability or PATH contamination is present." >&2
  exit 2
fi

tools_root="/root/.local/lvb-arm64-tools"
downloads="$tools_root/downloads"
sources="$tools_root/sources"
git_cache="/root/.cache/lvb-arm64-git-cache"
work_root="/root/lvb-a64/r/$run_id"
run_tools="$tools_root/runs/$run_id"
expanded="$run_tools/expanded"
tools_bin="$run_tools/bin"
evidence="$repo/out/$run_id"
provisioning="$repo/out/$run_id-provisioning"
mkdir -p "$downloads" "$sources" "$git_cache"
for path in "$work_root" "$run_tools" "$evidence" "$provisioning"; do
  if [[ -e "$path" ]]; then
    echo "Run path already exists: $path" >&2
    exit 2
  fi
done
mkdir -p "$expanded" "$tools_bin" "$provisioning"
export PATH="$tools_bin:$PATH"

apt_packages=()
if ! dpkg-query -W -f='${Status}\n' build-essential 2>/dev/null | grep -qx "install ok installed"; then
  apt_packages+=(build-essential)
fi
command -v unzip >/dev/null 2>&1 || apt_packages+=(unzip)
if ((${#apt_packages[@]} > 0)); then
  {
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${apt_packages[@]}"
  } >"$provisioning/apt-packages.log" 2>&1
fi
{
  printf 'required packages: build-essential unzip\n'
  dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\t${Status}\n' \
    build-essential unzip
} >>"$provisioning/apt-packages.log"
for command in python3 git gcc cc make curl tar unzip findmnt file sha256sum; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required native Linux command is missing: $command" >&2
    exit 2
  fi
done

mapfile -t nvim_spec < <(
  python3 - "$repo/tools.json" <<'PY'
import json
import sys

spec = json.load(open(sys.argv[1], encoding="utf-8"))["linux_arm64"]["neovim"]
for key in ("archive", "bytes", "sha256", "url", "version", "binary_sha256"):
    print(spec[key])
PY
)
nvim_archive_name="${nvim_spec[0]}"
nvim_bytes="${nvim_spec[1]}"
nvim_sha="${nvim_spec[2]}"
nvim_url="${nvim_spec[3]}"
nvim_version="${nvim_spec[4]}"
nvim_binary_sha="${nvim_spec[5]}"
nvim_archive="$downloads/$nvim_archive_name"
mapfile -t yq_spec < <(
  python3 - "$repo/tools.json" <<'PY'
import json
import sys

spec = json.load(open(sys.argv[1], encoding="utf-8"))["linux_arm64"]["yq"]
for key in ("archive", "bytes", "sha256", "url", "version"):
    print(spec[key])
PY
)
yq_archive_name="${yq_spec[0]}"
yq_bytes="${yq_spec[1]}"
yq_sha="${yq_spec[2]}"
yq_url="${yq_spec[3]}"
yq_archive="$downloads/$yq_archive_name"

download_checked() {
  local url="$1"
  local destination="$2"
  local bytes="$3"
  local sha="$4"
  if [[ ! -f "$destination" ]]; then
    local temporary="$destination.$$.partial"
    curl --fail --location --retry 3 --output "$temporary" "$url"
    mv "$temporary" "$destination"
  fi
  [[ "$(stat -c %s "$destination")" == "$bytes" ]] || {
    echo "Size mismatch for $destination" >&2
    exit 3
  }
  [[ "$(sha256sum "$destination" | awk '{print $1}')" == "$sha" ]] || {
    echo "SHA-256 mismatch for $destination" >&2
    exit 3
  }
}

download_checked "$nvim_url" "$nvim_archive" "$nvim_bytes" "$nvim_sha"
download_checked "$yq_url" "$yq_archive" "$yq_bytes" "$yq_sha"
yq="$tools_bin/yq"
if [[ ! -x "$yq" ]]; then
  cp "$yq_archive" "$yq"
  chmod 0755 "$yq"
fi
nvim_root="$expanded/neovim-$nvim_version-arm64"
nvim="$nvim_root/nvim-linux-arm64/bin/nvim"
if [[ ! -x "$nvim" ]]; then
  mkdir -p "$nvim_root"
  tar -xzf "$nvim_archive" -C "$nvim_root"
fi
[[ -x "$nvim" ]] || {
  echo "Neovim extraction failed: $nvim" >&2
  exit 3
}
[[ "$(sha256sum "$nvim" | awk '{print $1}')" == "$nvim_binary_sha" ]] || {
  echo "Neovim binary SHA-256 mismatch: $nvim" >&2
  exit 3
}

python3 - "$repo" "$nvim" "$(command -v git)" "$(command -v python3)" "$(command -v gcc)" "$(command -v make)" "$(command -v unzip)" "$yq" >"$provisioning/native-tool-architecture.json" <<'PY'
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / "harness"))
from run_lane import binary_architecture

records = {}
for name, value in zip(("nvim", "git", "python", "gcc", "make", "unzip", "yq"), sys.argv[2:]):
    path = pathlib.Path(value).resolve()
    architecture = binary_architecture(path)
    if not architecture or architecture["format"] != "ELF" or architecture["machine_value"] != 183:
        raise SystemExit(f"{name} is not native Linux ARM64: {path}: {architecture}")
    records[name] = {"path": str(path), **architecture}
print(json.dumps(records, indent=2, sort_keys=True))
PY

trace="$provisioning/git-trace.jsonl"
inputs="$provisioning/inputs.json"
GIT_TRACE2_EVENT="$trace" python3 "$repo/harness/prepare_inputs.py" \
  --profile fork \
  --registry upstream \
  --git "$(command -v git)" \
  --source-root "$sources" \
  --git-cache "$git_cache" \
  --output "$inputs"

registry_path="$(
  python3 - "$inputs" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["checkouts"]["registry"]["path"])
PY
)"
starter_path="$(
  python3 - "$inputs" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["checkouts"]["starter"]["path"])
PY
)"
lazyvim_path="$(
  python3 - "$inputs" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["checkouts"]["lazyvim"]["path"])
PY
)"
treesitter_path="$(
  python3 - "$inputs" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["checkouts"]["treesitter"]["path"])
PY
)"

python3 - "$provisioning/toolchain.json" "$nvim_archive" "$nvim_sha" "$nvim_bytes" "$nvim" <<'PY'
import hashlib
import json
import pathlib
import platform
import sys

output = pathlib.Path(sys.argv[1])
archive_path = pathlib.Path(sys.argv[2])
nvim_path = pathlib.Path(sys.argv[5])
value = {
    "schema_version": 1,
    "host": {"machine": platform.machine(), "platform": platform.platform()},
    "neovim_archive": {
        "path": str(archive_path),
        "bytes": archive_path.stat().st_size,
        "sha256": hashlib.sha256(archive_path.read_bytes()).hexdigest(),
        "expected_bytes": int(sys.argv[4]),
        "expected_sha256": sys.argv[3],
    },
    "nvim": {
        "path": str(nvim_path),
        "sha256": hashlib.sha256(nvim_path.read_bytes()).hexdigest(),
    },
    "commands": {
        name: str(pathlib.Path(value).resolve())
        for name in ("python3", "git", "gcc", "cc", "make", "curl", "tar", "unzip", "yq")
        if (value := __import__("shutil").which(name))
    },
}
output.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

set +e
python3 "$repo/harness/run_lane.py" \
  --lane wsl \
  --profile fork \
  --label "$run_id" \
  --plugin-source-mode preseeded \
  --network-retries 2 \
  --expected-architecture arm64 \
  --work-root "$work_root" \
  --evidence-dir "$evidence" \
  --nvim "$nvim" \
  --git "$(command -v git)" \
  --git-cache "$git_cache" \
  --starter-source "$starter_path" \
  --lazyvim-source "$lazyvim_path" \
  --treesitter-source "$treesitter_path" \
  --mason-registry "file:$registry_path" \
  --mason-target auto \
  --support-bin "$tools_bin" \
  --runs "$runs" \
  --warmups "$warmups" \
  --timeout 900 \
  --distribution-diagnostics \
  --additional-git-trace "$trace" \
  >"$provisioning/runner.log" 2>&1
lane_exit=$?
set -e

if ((lane_exit != 0)); then
  echo "WSL ARM64 regression failed. See $evidence." >&2
  exit "$lane_exit"
fi

python3 - "$evidence/summary.json" "$evidence/wsl-arm64-result.json" <<'PY'
import json
import sys

summary = json.load(open(sys.argv[1], encoding="utf-8"))
checks = (
    summary["result"] == "passed",
    summary["plugin_gate"]["valid"] == 32,
    summary["architecture"]["passed"] is True,
    summary["architecture"]["parser_count"] == 24,
    summary["architecture"]["parser_native_count"] == 24,
    summary["placement"]["accepted"] is True,
    summary["placement"]["environment_hits"] == [],
    summary["placement"]["recursive_forbidden_hits"] == [],
    summary["placement"]["trace_forbidden_hits"] == [],
    summary["lsp"]["protocol"]["success"] is True,
    summary["lsp"]["attachment"]["attached"] is True,
    summary["tool_execution"]["passed"] is True,
    sum(result["success"] is True for result in summary["mason"]["results"].values()) == 4,
)
if not all(checks):
    raise SystemExit("WSL summary did not satisfy every acceptance gate")
result = {
    "schema_version": 1,
    "run_id": summary["label"],
    "passed": True,
    "exact_plugins": summary["plugin_gate"]["valid"],
    "mason_packages": 4,
    "native_parsers": summary["architecture"]["parser_native_count"],
    "setup_to_readiness_seconds": summary["setup_to_readiness_seconds"],
    "empty_startup": summary["startup"]["empty"],
    "file_startup": summary["startup"]["file"],
    "maintenance": summary["maintenance"],
    "placement": summary["placement"],
}
open(sys.argv[2], "w", encoding="utf-8").write(
    json.dumps(result, indent=2, sort_keys=True) + "\n"
)
PY

echo "LazyVim WSL2 ARM64 regression passed: $evidence"
