#!/usr/bin/env python3
"""Run one clean LazyVim ecosystem E2E lane and persist resumable evidence."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
import platform
import re
import shutil
import statistics
import struct
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
E2E_LOCKFILE = SCRIPT_DIR / "lazy-lock-e2e.json"
BASE_LOCKFILE = REPO_ROOT / "fixtures" / "lazy-lock.json"
MANIFEST_PATH = REPO_ROOT / "manifest.json"
MANIFEST = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
STARTER_COMMIT = "803bc181d7c0d6d5eeba9274d9be49b287294d99"
STARTER_URL = "https://github.com/LazyVim/starter.git"
UPSTREAM_LAZYVIM_URL = "https://github.com/LazyVim/LazyVim.git"
UPSTREAM_TREESITTER_URL = "https://github.com/nvim-treesitter/nvim-treesitter.git"
FORK_LAZYVIM_URL = (
    f"https://github.com/{MANIFEST['components']['lazyvim']['repository']}.git"
)
FORK_TREESITTER_URL = (
    "https://github.com/"
    f"{MANIFEST['components']['nvim-treesitter']['repository']}.git"
)
MASON_PACKAGES = ("stylua", "shfmt", "lua-language-server", "tree-sitter-cli")
DEFAULT_PARSERS = (
    "bash",
    "c",
    "diff",
    "html",
    "javascript",
    "jsdoc",
    "json",
    "lua",
    "luadoc",
    "luap",
    "markdown",
    "markdown_inline",
    "printf",
    "python",
    "query",
    "regex",
    "toml",
    "tsx",
    "typescript",
    "vim",
    "vimdoc",
    "xml",
    "yaml",
)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def summarize(values: list[float]) -> dict[str, Any]:
    quartiles = statistics.quantiles(values, n=4, method="inclusive")
    return {
        "count": len(values),
        "iqr_seconds": quartiles[2] - quartiles[0],
        "max_seconds": max(values),
        "median_seconds": statistics.median(values),
        "min_seconds": min(values),
        "p95_seconds": percentile(values, 0.95),
        "q1_seconds": quartiles[0],
        "q3_seconds": quartiles[2],
        "samples_seconds": values,
    }


def path_uri(path: Path) -> str:
    return path.resolve().as_uri().rstrip("/") + "/"


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def binary_architecture(path: Path) -> dict[str, Any] | None:
    try:
        with path.open("rb") as stream:
            header = stream.read(64)
            if header[:2] == b"MZ":
                if len(header) < 64:
                    return None
                offset = struct.unpack_from("<I", header, 0x3C)[0]
                stream.seek(offset)
                if stream.read(4) != b"PE\0\0":
                    return None
                machine = struct.unpack("<H", stream.read(2))[0]
                return {
                    "architecture": {
                        0x014C: "x86",
                        0x8664: "x64",
                        0xAA64: "arm64",
                    }.get(machine, f"pe-0x{machine:04x}"),
                    "format": "PE",
                    "machine": f"0x{machine:04X}",
                    "machine_value": machine,
                }
            if header[:4] == b"\x7fELF" and len(header) >= 20:
                byte_order = "little" if header[5] == 1 else "big"
                machine = int.from_bytes(header[18:20], byte_order)
                return {
                    "architecture": {
                        3: "x86",
                        40: "arm",
                        62: "x64",
                        183: "arm64",
                    }.get(machine, f"elf-{machine}"),
                    "format": "ELF",
                    "machine": str(machine),
                    "machine_value": machine,
                }
    except (OSError, PermissionError, struct.error):
        return None
    return None


class LaneError(RuntimeError):
    pass


class Lane:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.lockfile = BASE_LOCKFILE if args.profile == "control" else E2E_LOCKFILE
        self.lock = read_json(self.lockfile)
        self.lazyvim_url = (
            UPSTREAM_LAZYVIM_URL if args.profile == "control" else FORK_LAZYVIM_URL
        )
        self.treesitter_url = (
            UPSTREAM_TREESITTER_URL
            if args.profile == "control"
            else FORK_TREESITTER_URL
        )
        self.work_root = args.work_root.resolve()
        self.evidence = args.evidence_dir.resolve()
        self.logs = self.evidence / "logs"
        self.artifacts = self.evidence / "artifacts"
        self.receipts = self.evidence / "mason-receipts"
        self.config_snapshot = self.evidence / "config-snapshot"
        self.appname = "lazyvim-e2e"
        self.config_home = self.work_root / "xdg" / "config"
        self.data_home = self.work_root / "xdg" / "data"
        self.state_home = self.work_root / "xdg" / "state"
        self.cache_home = self.work_root / "xdg" / "cache"
        self.config_dir = self.config_home / self.appname
        data_app = f"{self.appname}-data" if args.lane == "windows" else self.appname
        self.data_dir = self.data_home / data_app
        self.lazy_root = self.data_dir / "lazy"
        self.mason_root = self.data_dir / "mason"
        self.fixture = self.work_root / "project"
        self.summary_path = self.evidence / "summary.json"
        self.summary: dict[str, Any] = {
            "schema_version": 1,
            "label": args.label,
            "lane": args.lane,
            "profile": args.profile,
            "plugin_source_mode": args.plugin_source_mode,
            "started_at": utc_now(),
            "result": "running",
            "paths": {
                "work_root": str(self.work_root),
                "work_root_length": len(str(self.work_root)),
                "evidence_dir": str(self.evidence),
                "nvim": str(args.nvim),
                "git": str(args.git),
                "git_cache": str(args.git_cache),
                "starter_source": str(args.starter_source),
                "lazyvim_source": str(args.lazyvim_source),
                "treesitter_source": str(args.treesitter_source),
                "mason_registry": args.mason_registry,
                "lockfile": str(self.lockfile),
                "additional_git_trace": (
                    str(args.additional_git_trace.resolve())
                    if args.additional_git_trace
                    else None
                ),
                "mason_artifact_validation": (
                    str(args.mason_artifact_validation.resolve())
                    if args.mason_artifact_validation
                    else None
                ),
            },
            "host": {
                "machine": platform.machine(),
                "platform": platform.platform(),
                "processor": platform.processor(),
                "python": sys.version,
                "python_executable": sys.executable,
            },
            "stages": [],
        }
        self.env = self.make_environment()
        self.setup_started = time.perf_counter()

    def expected_binary(self) -> tuple[str, int, str]:
        if self.args.lane == "windows":
            machine = {"arm64": 0xAA64, "x64": 0x8664}[self.args.expected_architecture]
            return "PE", machine, f"0x{machine:04X}"
        machine = {"arm64": 183, "x64": 62}[self.args.expected_architecture]
        return "ELF", machine, str(machine)

    def compiler_driver(self) -> str:
        return {
            "arm64": "aarch64-w64-mingw32-gcc.exe",
            "x64": "x86_64-w64-mingw32-gcc.exe",
        }[self.args.expected_architecture]

    def make_environment(self) -> dict[str, str]:
        env = os.environ.copy()
        for key in list(env):
            if key.startswith("GIT_"):
                env.pop(key)
        for key in (
            "CC",
            "CRATE_CC_NO_DEFAULTS",
            "NVIM_APPNAME",
            "XDG_CACHE_HOME",
            "XDG_CONFIG_HOME",
            "XDG_DATA_HOME",
            "XDG_STATE_HOME",
        ):
            env.pop(key, None)

        if self.args.lane == "windows":
            path_entries = [
                str(self.args.support_bin),
                str(self.args.compiler_bin),
                str(self.args.nvim.parent),
                str(Path(sys.executable).parent),
                str(self.args.git.parent),
            ]
            for command in ("pwsh", "powershell", "cmd", "curl", "tar"):
                resolved = shutil.which(command)
                if resolved:
                    path_entries.append(str(Path(resolved).parent))
            path_entries.extend(
                (
                    r"C:\Windows\System32",
                    r"C:\Windows",
                    r"C:\Windows\System32\WindowsPowerShell\v1.0",
                )
            )
        else:
            env.pop("WSL_INTEROP", None)
            env.pop("WSLENV", None)
            path_entries = [
                str(self.args.nvim.parent),
                str(self.args.support_bin),
                "/usr/local/sbin",
                "/usr/local/bin",
                "/usr/sbin",
                "/usr/bin",
                "/sbin",
                "/bin",
            ]
        seen: set[str] = set()
        clean_path: list[str] = []
        for entry in path_entries:
            key = entry.lower() if self.args.lane == "windows" else entry
            if entry and key not in seen:
                seen.add(key)
                clean_path.append(entry)
        env["PATH"] = os.pathsep.join(clean_path)
        env["GIT_TRACE2_EVENT"] = str(self.logs / "git-trace.jsonl")
        env.update(
            {
                "NVIM_APPNAME": self.appname,
                "XDG_CACHE_HOME": str(self.cache_home),
                "XDG_CONFIG_HOME": str(self.config_home),
                "XDG_DATA_HOME": str(self.data_home),
                "XDG_STATE_HOME": str(self.state_home),
                "LVB_E2E_MASON_REGISTRY": self.args.mason_registry,
                "LVB_E2E_MASON_TARGET": self.args.mason_target,
                "LVB_E2E_LAZYVIM_URL": (
                    self.lazyvim_url
                    if self.args.lane == "windows"
                    else path_uri(self.args.lazyvim_source)
                ),
                "LVB_E2E_TREESITTER_URL": (
                    self.treesitter_url
                    if self.args.lane == "windows"
                    else path_uri(self.args.treesitter_source)
                ),
                "LVB_E2E_TIMEOUT_MS": str(self.args.timeout * 1000),
            }
        )
        if self.args.lane == "windows":
            env["LVB_E2E_PYTHON"] = sys.executable
            env["LVB_E2E_YQ_SCRIPT"] = str(SCRIPT_DIR / "support" / "yq_compat.py")

        if self.args.lane != "windows":
            rewrites = (
                (
                    path_uri(self.args.starter_source),
                    STARTER_URL,
                ),
                (path_uri(self.args.lazyvim_source), self.lazyvim_url),
                (
                    path_uri(self.args.treesitter_source),
                    self.treesitter_url,
                ),
                (path_uri(self.args.git_cache), "https://github.com/"),
            )
            env["GIT_CONFIG_COUNT"] = str(len(rewrites))
            for index, (replacement, source) in enumerate(rewrites):
                env[f"GIT_CONFIG_KEY_{index}"] = f"url.{replacement}.insteadOf"
                env[f"GIT_CONFIG_VALUE_{index}"] = source
        return env

    def write_summary(self) -> None:
        self.summary["updated_at"] = utc_now()
        atomic_json(self.summary_path, self.summary)

    def prepare(self) -> None:
        if self.work_root.exists() and any(self.work_root.iterdir()):
            raise LaneError(f"Work root must be new and empty: {self.work_root}")
        if self.evidence.exists() and any(self.evidence.iterdir()):
            raise LaneError(f"Evidence directory must be new and empty: {self.evidence}")
        required_paths = (
            self.args.nvim,
            self.args.git,
            self.args.git_cache,
            self.args.starter_source,
            self.args.lazyvim_source,
            self.args.treesitter_source,
            self.lockfile,
            BASE_LOCKFILE,
            E2E_LOCKFILE,
            MANIFEST_PATH,
        )
        if self.args.additional_git_trace:
            required_paths += (self.args.additional_git_trace,)
        if self.args.mason_artifact_validation:
            required_paths += (self.args.mason_artifact_validation,)
        if self.args.support_bin:
            required_paths += (self.args.support_bin,)
        missing = [str(path) for path in required_paths if not path.exists()]
        if missing:
            raise LaneError(f"Required paths are missing: {missing}")
        if not self.args.support_bin or not self.args.support_bin.is_dir():
            raise LaneError("--support-bin must name an existing directory")
        if self.args.lane == "windows":
            if not self.args.compiler_bin.is_dir():
                raise LaneError(f"Compiler bin directory is missing: {self.args.compiler_bin}")
        for directory in (
            self.work_root,
            self.logs,
            self.artifacts,
            self.receipts,
            self.config_snapshot,
            self.config_home,
            self.data_home,
            self.state_home,
            self.cache_home,
            self.fixture,
        ):
            directory.mkdir(parents=True, exist_ok=True)
        self.validate_lock_delta()
        self.summary["initial_environment"] = {
            "CC": self.env.get("CC"),
            "CRATE_CC_NO_DEFAULTS": self.env.get("CRATE_CC_NO_DEFAULTS"),
            "PATH": self.env["PATH"],
        }
        self.summary["inputs"] = {
            "base_lock_sha256": file_sha256(BASE_LOCKFILE),
            "e2e_lock_sha256": file_sha256(E2E_LOCKFILE),
            "selected_lock_sha256": file_sha256(self.lockfile),
            "selected_lock_plugins": len(self.lock),
        }
        self.write_summary()

    def validate_lock_delta(self) -> None:
        base = read_json(BASE_LOCKFILE)
        selected = self.lock
        if set(base) != set(selected) or len(selected) != 32:
            raise LaneError("Selected lock must preserve the exact 32-plugin key set")
        changes = []
        for name in sorted(base):
            if base[name] != selected[name]:
                changes.append(
                    {
                        "plugin": name,
                        "before": base[name],
                        "after": selected[name],
                    }
                )
        if self.args.profile == "control":
            if changes:
                raise LaneError(f"Control lock unexpectedly differs from base: {changes}")
            self.summary["lock_delta"] = []
            return
        expected = {
            "LazyVim": MANIFEST["components"]["lazyvim"]["commit"],
            "nvim-treesitter": MANIFEST["components"]["nvim-treesitter"]["commit"],
        }
        if {item["plugin"] for item in changes} != set(expected):
            raise LaneError(f"Unexpected E2E lock delta: {changes}")
        for item in changes:
            if item["before"]["branch"] != item["after"]["branch"]:
                raise LaneError(f"Lock branch changed for {item['plugin']}")
            if item["after"]["commit"] != expected[item["plugin"]]:
                raise LaneError(f"Unexpected replacement commit for {item['plugin']}")
        self.summary["lock_delta"] = changes

    def run_stage(
        self,
        name: str,
        command: Iterable[str | Path],
        *,
        cwd: Path | None = None,
        timeout: int | None = None,
        env: dict[str, str] | None = None,
        check: bool = True,
    ) -> dict[str, Any]:
        command_strings = [str(item) for item in command]
        log_path = self.logs / f"{len(self.summary['stages']):02d}-{name}.log"
        started = time.perf_counter()
        timed_out = False
        output = ""
        return_code: int | None
        try:
            completed = subprocess.run(
                command_strings,
                cwd=cwd,
                env=env or self.env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout or self.args.timeout,
                check=False,
            )
            return_code = completed.returncode
            output = completed.stdout
        except subprocess.TimeoutExpired as error:
            timed_out = True
            return_code = None
            partial = error.stdout or ""
            if isinstance(partial, bytes):
                partial = partial.decode("utf-8", errors="replace")
            output = partial + f"\nTimed out after {timeout or self.args.timeout} seconds.\n"
        elapsed = time.perf_counter() - started
        log_path.write_text(output, encoding="utf-8")
        result = {
            "command": command_strings,
            "cwd": str(cwd) if cwd else None,
            "log": str(log_path),
            "name": name,
            "return_code": return_code,
            "seconds": elapsed,
            "timed_out": timed_out,
        }
        self.summary["stages"].append(result)
        self.write_summary()
        if check and (return_code != 0 or timed_out):
            raise LaneError(f"Stage {name} failed; see {log_path}")
        return result

    def git_output(self, *arguments: str, cwd: Path | None = None) -> str:
        completed = subprocess.run(
            [str(self.args.git), *arguments],
            cwd=cwd,
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=60,
            check=False,
        )
        if completed.returncode != 0:
            raise LaneError(
                f"Git command failed ({' '.join(arguments)}): {completed.stderr.strip()}"
            )
        return completed.stdout.strip()

    def verify_components(self) -> None:
        expected = (
            (self.args.starter_source, STARTER_COMMIT),
            (self.args.lazyvim_source, self.lock["LazyVim"]["commit"]),
            (
                self.args.treesitter_source,
                self.lock["nvim-treesitter"]["commit"],
            ),
        )
        components = []
        for path, commit in expected:
            head = self.git_output("-C", str(path), "rev-parse", "HEAD")
            status = self.git_output("-C", str(path), "status", "--porcelain")
            if head != commit or status:
                raise LaneError(f"Component source mismatch or dirty worktree: {path}")
            components.append(
                {
                    "path": str(path),
                    "commit": head,
                    "tree": self.git_output("-C", str(path), "rev-parse", "HEAD^{tree}"),
                    "clean": True,
                }
            )
        self.summary["component_sources"] = components
        self.write_summary()

    def compile_yq_bridge(self) -> None:
        if self.args.lane != "windows":
            return
        compiler = self.args.compiler_bin / self.compiler_driver()
        output = self.args.support_bin / "yq.exe"
        self.args.support_bin.mkdir(parents=True, exist_ok=True)
        self.run_stage(
            "compile-native-yq-bridge",
            [
                compiler,
                "-O2",
                "-Wall",
                "-Wextra",
                SCRIPT_DIR / "support" / "yq_wrapper.c",
                "-o",
                output,
            ],
        )
        architecture = binary_architecture(output)
        _, expected_machine, _ = self.expected_binary()
        if not architecture or architecture["machine_value"] != expected_machine:
            raise LaneError(
                f"yq bridge does not match {self.args.expected_architecture}: {architecture}"
            )
        self.summary["yq_bridge"] = {
            **architecture,
            "path": str(output),
            "sha256": file_sha256(output),
            "source_sha256": file_sha256(SCRIPT_DIR / "support" / "yq_wrapper.c"),
            "converter_sha256": file_sha256(SCRIPT_DIR / "support" / "yq_compat.py"),
        }
        self.write_summary()

    def materialize_repository(
        self,
        destination: Path,
        source: Path,
        commit: str,
        origin: str,
    ) -> str:
        destination.parent.mkdir(parents=True, exist_ok=True)
        commands = (
            [str(self.args.git), "init", "--quiet", str(destination)],
            [
                str(self.args.git),
                "-C",
                str(destination),
                "remote",
                "add",
                "origin",
                origin,
            ],
        )
        output = []
        for command in commands:
            completed = subprocess.run(
                command,
                env=self.env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=120,
                check=False,
            )
            output.append(f"$ {' '.join(command)}\n{completed.stdout}")
            if completed.returncode != 0:
                raise LaneError(f"Failed to initialize cached worktree: {destination}")

        source_objects = source / ".git" / "objects" if (source / ".git").is_dir() else source / "objects"
        if not source_objects.is_dir():
            raise LaneError(f"Git object store is missing: {source_objects}")
        alternates = destination / ".git" / "objects" / "info" / "alternates"
        alternates.parent.mkdir(parents=True, exist_ok=True)
        alternates.write_text(
            source_objects.resolve().as_posix() + "\n",
            encoding="utf-8",
            newline="\n",
        )
        checkout = [
            str(self.args.git),
            "-C",
            str(destination),
            "checkout",
            "--detach",
            commit,
        ]
        completed = subprocess.run(
            checkout,
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=120,
            check=False,
        )
        output.append(f"$ {' '.join(checkout)}\n{completed.stdout}")
        if completed.returncode != 0:
            raise LaneError(f"Failed to materialize {commit} from {source}")
        return "\n".join(output)

    def record_internal_stage(
        self,
        name: str,
        started: float,
        output: str,
        command: list[str],
    ) -> None:
        log_path = self.logs / f"{len(self.summary['stages']):02d}-{name}.log"
        log_path.write_text(output, encoding="utf-8")
        self.summary["stages"].append(
            {
                "command": command,
                "cwd": None,
                "log": str(log_path),
                "name": name,
                "return_code": 0,
                "seconds": time.perf_counter() - started,
                "timed_out": False,
            }
        )
        self.write_summary()

    def materialize_starter(self) -> None:
        started = time.perf_counter()
        output = self.materialize_repository(
            self.config_dir,
            self.args.starter_source,
            STARTER_COMMIT,
            "https://github.com/LazyVim/starter.git",
        )
        self.record_internal_stage(
            "materialize-starter-cached",
            started,
            output,
            ["git-init-alternates-checkout", str(self.args.starter_source), STARTER_COMMIT],
        )

    def materialize_plugins(self) -> None:
        lock = self.lock
        manifest = read_json(self.args.git_cache / "manifest.json")
        repositories = {item["name"]: item for item in manifest["repositories"]}
        started = time.perf_counter()
        output = []
        materialized = []
        for name, lock_entry in sorted(lock.items()):
            if name == "LazyVim":
                source = self.args.lazyvim_source
                origin = self.lazyvim_url
            elif name == "nvim-treesitter":
                source = self.args.treesitter_source
                origin = self.treesitter_url
            else:
                item = repositories.get(name)
                if not item:
                    raise LaneError(f"Frozen cache manifest has no source for {name}")
                origin = item["url"]
                relative = origin.split("https://github.com/", 1)[1]
                if relative.endswith(".git"):
                    relative = relative[:-4]
                source = self.args.git_cache / Path(relative)
            destination = self.lazy_root / name
            output.append(
                self.materialize_repository(
                    destination,
                    source,
                    lock_entry["commit"],
                    origin,
                )
            )
            materialized.append(
                {
                    "commit": lock_entry["commit"],
                    "destination": str(destination),
                    "name": name,
                    "origin": origin,
                    "source": str(source),
                }
            )
        self.summary["cached_plugin_materialization"] = materialized
        self.record_internal_stage(
            "materialize-32-plugin-graph",
            started,
            "\n".join(output),
            ["git-init-alternates-checkout", "32 plugins", str(self.args.git_cache)],
        )

    def configure(self) -> None:
        preseeded = self.args.plugin_source_mode == "preseeded"
        if preseeded:
            self.materialize_starter()
        else:
            clone_command = [
                self.args.git,
                "clone",
                "--filter=blob:none",
                "--single-branch",
                "--branch",
                "main",
                "--depth",
                "1",
                "--no-tags",
                "https://github.com/LazyVim/starter.git",
                self.config_dir,
            ]
            clone_attempts = self.args.network_retries + 1 if self.args.plugin_source_mode == "online" else 1
            clone_result = None
            for attempt in range(1, clone_attempts + 1):
                if attempt > 1 and self.config_dir.exists():
                    shutil.rmtree(self.config_dir)
                clone_result = self.run_stage(
                    f"clone-starter-{self.args.plugin_source_mode}-attempt-{attempt}",
                    clone_command,
                    check=False,
                )
                if clone_result["return_code"] == 0 and not clone_result["timed_out"]:
                    break
            if not clone_result or clone_result["return_code"] != 0 or clone_result["timed_out"]:
                raise LaneError("Starter clone exhausted all network retries")
            self.run_stage(
                "checkout-starter",
                [
                    self.args.git,
                    "-C",
                    self.config_dir,
                    "checkout",
                    "--detach",
                    STARTER_COMMIT,
                ],
            )
        shutil.copy2(self.lockfile, self.config_dir / "lazy-lock.json")
        plugin_dir = self.config_dir / "lua" / "plugins"
        plugin_dir.mkdir(parents=True, exist_ok=True)
        fork_overrides = ""
        if self.args.profile == "fork":
            fork_overrides = f"""  {{
    "LazyVim/LazyVim",
    branch = "{MANIFEST['components']['lazyvim']['branch']}",
    url = assert(vim.env.LVB_E2E_LAZYVIM_URL),
  }},
  {{
    "nvim-treesitter/nvim-treesitter",
    branch = "{MANIFEST['components']['nvim-treesitter']['branch']}",
    url = assert(vim.env.LVB_E2E_TREESITTER_URL),
  }},
"""
        (plugin_dir / "arm64-e2e.lua").write_text(
            f"""return {{
{fork_overrides}
  {{
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.registries = {{ assert(vim.env.LVB_E2E_MASON_REGISTRY) }}
    end,
  }},
}}
""",
            encoding="utf-8",
            newline="\n",
        )
        (self.fixture / "sample.lua").write_text(
            'local   message={foo="bar",baz={1,2,3}}\nprint( message )\n',
            encoding="utf-8",
            newline="\n",
        )
        (self.fixture / "sample.sh").write_text(
            "#!/usr/bin/env sh\nif true;then echo  hi;fi\n",
            encoding="utf-8",
            newline="\n",
        )
        self.run_stage("initialize-fixture-git", [self.args.git, "init", "--quiet", self.fixture])
        if preseeded:
            self.materialize_plugins()
        bootstrap_attempts = self.args.network_retries + 1 if self.args.plugin_source_mode == "online" else 1
        bootstrap_result = None
        for attempt in range(1, bootstrap_attempts + 1):
            bootstrap_result = self.run_stage(
                f"bootstrap-plugins-attempt-{attempt}",
                [self.args.nvim, "--headless", "+qa!"],
                timeout=self.args.timeout,
                check=False,
            )
            if bootstrap_result["return_code"] == 0 and not bootstrap_result["timed_out"]:
                break
        if (
            not bootstrap_result
            or bootstrap_result["return_code"] != 0
            or bootstrap_result["timed_out"]
        ):
            raise LaneError("Plugin bootstrap exhausted all network retries")

    def validate_plugins(self) -> None:
        expected = self.lock
        installed_lock = self.config_dir / "lazy-lock.json"
        observed = read_json(installed_lock)
        if set(observed) != set(expected):
            raise LaneError("Lazy bootstrap changed the E2E plugin key set")
        branch_normalization = {
            name: {
                "fixture": expected[name]["branch"],
                "observed": observed[name].get("branch"),
            }
            for name in sorted(expected)
            if expected[name]["branch"] != observed[name].get("branch")
        }
        commit_drift = {
            name: {
                "fixture": expected[name]["commit"],
                "observed": observed[name].get("commit"),
            }
            for name in sorted(expected)
            if expected[name]["commit"].lower()
            != str(observed[name].get("commit", "")).lower()
        }
        if commit_drift:
            raise LaneError(f"Lazy bootstrap changed pinned commits: {commit_drift}")
        self.summary["runtime_lock_observation"] = {
            "branch_normalization": branch_normalization,
            "commit_drift": commit_drift,
            "observed_sha256": file_sha256(installed_lock),
        }
        shutil.copy2(self.lockfile, installed_lock)
        self.summary["runtime_lock_observation"]["fixture_restored_sha256"] = file_sha256(
            installed_lock
        )
        validation: dict[str, Any] = {}
        for name, lock_entry in sorted(expected.items()):
            path = self.lazy_root / name
            if not path.is_dir():
                validation[name] = {"valid": False, "error": "plugin directory missing"}
                continue
            head = self.git_output("-C", str(path), "rev-parse", "HEAD")
            status = self.git_output(
                "-C",
                str(path),
                "status",
                "--porcelain",
                "--untracked-files=no",
            )
            validation[name] = {
                "clean": not bool(status),
                "expected_commit": lock_entry["commit"],
                "head": head,
                "path": str(path),
                "valid": head.lower() == lock_entry["commit"].lower() and not status,
            }
        self.summary["plugin_validation"] = validation
        self.summary["plugin_gate"] = {
            "expected": 32,
            "valid": sum(1 for item in validation.values() if item.get("valid")),
            "passed": len(validation) == 32 and all(
                item.get("valid") is True for item in validation.values()
            ),
        }
        self.write_summary()
        if not self.summary["plugin_gate"]["passed"]:
            raise LaneError("The exact 32-plugin E2E lock gate failed")

    def reconcile_online_lock(self) -> None:
        if self.args.plugin_source_mode != "online":
            return
        expected = self.lock
        runtime_lock = self.config_dir / "lazy-lock.json"
        observed = read_json(runtime_lock)
        drift = {
            name: {
                "expected": expected[name]["commit"],
                "observed": observed.get(name, {}).get("commit"),
            }
            for name in sorted(expected)
            if expected[name]["commit"].lower()
            != str(observed.get(name, {}).get("commit", "")).lower()
        }
        self.summary["online_initial_lock_drift"] = drift
        self.write_summary()
        if not drift:
            return
        shutil.copy2(self.lockfile, runtime_lock)
        attempts = self.args.network_retries + 1
        restore_result = None
        for attempt in range(1, attempts + 1):
            restore_result = self.run_stage(
                f"online-lazy-restore-attempt-{attempt}",
                [self.args.nvim, "--headless", "+Lazy! restore", "+qa!"],
                timeout=self.args.timeout,
                check=False,
            )
            if restore_result["return_code"] == 0 and not restore_result["timed_out"]:
                break
        if not restore_result or restore_result["return_code"] != 0 or restore_result["timed_out"]:
            raise LaneError("Online Lazy restore exhausted all network retries")

    def run_probe(
        self,
        stage: str,
        script: str,
        output_name: str,
        *,
        fixture_file: Path | None = None,
        timeout: int | None = None,
        check: bool = True,
    ) -> dict[str, Any]:
        output = self.artifacts / output_name
        output.unlink(missing_ok=True)
        probe_env = self.env.copy()
        probe_env["LVB_E2E_OUTPUT"] = str(output)
        probe_env["LVB_E2E_PROBE"] = str(SCRIPT_DIR / "probes" / script)
        command: list[str | Path] = [self.args.nvim, "--headless"]
        if fixture_file:
            command.append(fixture_file)
        command.extend(("-c", "lua dofile(vim.env.LVB_E2E_PROBE)"))
        self.run_stage(
            stage,
            command,
            cwd=self.fixture,
            timeout=timeout,
            env=probe_env,
            check=check,
        )
        if not output.is_file():
            raise LaneError(f"Probe {stage} did not produce {output}")
        return read_json(output) if output.suffix == ".json" else {"path": str(output)}

    def install_mason(self) -> dict[str, Any]:
        result = self.run_probe(
            "mason-install",
            "mason_install.lua",
            "mason-install.json",
            timeout=self.args.timeout + 60,
            check=False,
        )
        failures = [
            name
            for name in MASON_PACKAGES
            if result.get("results", {}).get(name, {}).get("success") is not True
        ]
        self.summary["mason"] = result
        self.write_summary()
        if (
            result.get("completed") is not True
            or result.get("fatal") is not None
            or failures
            or result.get("target") != self.args.mason_target
        ):
            if self.args.profile == "control" and self.args.lane == "windows":
                self.audit_git_execution()
            raise LaneError(f"Mason {self.args.mason_target} gate failed for: {failures}")
        for package in MASON_PACKAGES:
            receipt = self.mason_root / "packages" / package / "mason-receipt.json"
            if not receipt.is_file():
                raise LaneError(f"Mason receipt is missing for {package}")
            shutil.copy2(receipt, self.receipts / f"{package}.json")
        self.verify_mason_artifact_integrity()
        self.env["PATH"] = os.pathsep.join((str(self.mason_root / "bin"), self.env["PATH"]))
        return result

    def verify_mason_artifact_integrity(self) -> None:
        validation_path = self.args.mason_artifact_validation
        if not validation_path:
            if (
                self.args.lane == "windows"
                and self.args.profile == "fork"
                and self.args.expected_architecture == "arm64"
            ):
                raise LaneError(
                    "Windows fork runs require hash-verified Mason artifact validation"
                )
            return

        validation = read_json(validation_path)
        if validation.get("passed") is not True:
            raise LaneError("The pinned Mason artifact validation did not pass")
        components = {
            component.get("component"): component
            for component in validation.get("components", [])
        }
        if set(components) != set(MASON_PACKAGES):
            raise LaneError("Mason artifact validation has an unexpected component set")

        package_results = {}
        for package in MASON_PACKAGES:
            component = components[package]
            manifest_component = MANIFEST["components"][package]
            if (
                component.get("asset") != manifest_component["asset"]
                or component.get("archive_sha256", "").lower()
                != manifest_component["sha256"].lower()
            ):
                raise LaneError(f"Mason artifact identity mismatch for {package}")

            expected_files = {}
            for record in component.get("files", []):
                relative = str(record.get("path", "")).replace("\\", "/").casefold()
                if not relative or relative in expected_files:
                    raise LaneError(
                        f"Mason artifact file inventory is invalid for {package}"
                    )
                expected_files[relative] = record
            if not expected_files:
                raise LaneError(f"Mason artifact file inventory is empty for {package}")

            package_root = self.mason_root / "packages" / package
            installed_files = {
                str(path.relative_to(package_root)).replace("\\", "/").casefold(): path
                for path in package_root.rglob("*")
                if path.is_file()
            }
            allowed_additional = {"mason-receipt.json"}
            if package == "lua-language-server":
                allowed_additional.add("mason-schemas/lsp.json")
            missing = sorted(set(expected_files) - set(installed_files))
            additional = sorted(
                set(installed_files) - set(expected_files) - allowed_additional
            )
            changed = sorted(
                relative
                for relative, record in expected_files.items()
                if relative in installed_files
                and (
                    installed_files[relative].stat().st_size != int(record["bytes"])
                    or file_sha256(installed_files[relative])
                    != str(record["sha256"]).lower()
                )
            )
            package_results[package] = {
                "additional_files": additional,
                "archive_sha256": component["archive_sha256"].lower(),
                "changed_files": changed,
                "expected_file_count": len(expected_files),
                "missing_files": missing,
                "passed": not (missing or additional or changed),
            }
            if missing or additional or changed:
                raise LaneError(
                    f"Installed Mason payload differs from the verified {package} asset"
                )

        result = {"passed": True, "packages": package_results}
        atomic_json(self.artifacts / "mason-asset-integrity.json", result)
        self.summary["mason_asset_integrity"] = result
        self.write_summary()

    def find_package_binary(self, package: str) -> Path:
        root = self.mason_root / "packages" / package
        if self.args.lane == "windows":
            patterns = {
                "stylua": ("stylua.exe",),
                "shfmt": ("shfmt*.exe",),
                "lua-language-server": ("lua-language-server.exe",),
                "tree-sitter-cli": ("tree-sitter.exe",),
            }
        else:
            patterns = {
                "stylua": ("stylua",),
                "shfmt": ("shfmt", "shfmt_*"),
                "lua-language-server": ("lua-language-server",),
                "tree-sitter-cli": ("tree-sitter", "tree-sitter-linux-arm64"),
            }
        candidates: list[Path] = []
        for pattern in patterns[package]:
            candidates.extend(path for path in root.rglob(pattern) if path.is_file())
        candidates = sorted(set(candidates), key=lambda path: (len(path.parts), str(path)))
        if not candidates:
            raise LaneError(f"Could not find installed binary for {package}")
        return candidates[0]

    def run_preflight(self) -> dict[str, Any]:
        result = self.run_probe(
            "lazyvim-architecture-preflight", "preflight.lua", "preflight.json"
        )
        banned = {"missing_mason_target", "wrong_architecture"}
        statuses = {check.get("status") for check in result.get("checks", [])}
        if (
            result.get("ok") is not True
            or result.get("before", {}).get("CC") is not None
            or result.get("before", {}).get("CRATE_CC_NO_DEFAULTS") is not None
            or statuses & banned
        ):
            raise LaneError(f"LazyVim preflight gate failed: {result}")
        compiler = result.get("compiler") or {}
        if self.args.lane == "windows":
            kind = compiler.get("kind")
            no_defaults = result.get("after", {}).get("CRATE_CC_NO_DEFAULTS")
            environment_ok = (
                kind == "msvc" and no_defaults is None
            ) or (
                kind == "llvm-mingw" and no_defaults == "1"
            )
            if (
                compiler.get("arch") != self.args.expected_architecture
                or not environment_ok
                or not result.get("after", {}).get("CC")
            ):
                raise LaneError(
                    "LazyVim did not auto-select and configure a native compiler"
                )
        self.summary["preflight"] = result
        self.write_summary()
        return result

    def run_treesitter(self) -> dict[str, Any]:
        result: dict[str, Any] = {}
        passed = False
        attempts = self.args.network_retries + 1
        for attempt in range(1, attempts + 1):
            result = self.run_probe(
                f"treesitter-readiness-attempt-{attempt}",
                "treesitter_readiness.lua",
                "treesitter-readiness.json",
                timeout=self.args.timeout + 60,
                check=False,
            )
            parser_results = result.get("results", {})
            requested_ok = all(
                parser_results.get(parser, {}).get("installed") is True
                and parser_results.get(parser, {}).get("load_ok") is True
                for parser in DEFAULT_PARSERS
            )
            dependencies = result.get("dependencies", {})
            passed = (
                result.get("completed") is True
                and result.get("task_ok") is True
                and requested_ok
                and "dtd" in dependencies
                and dependencies["dtd"].get("load_ok") is True
            )
            if passed:
                break
            if attempt < attempts:
                time.sleep(min(2**attempt, 10))
        if not passed:
            raise LaneError(
                f"The frozen 23-parser readiness contract failed after {attempts} attempts"
            )
        if self.args.lane == "windows":
            preflight = result.get("preflight") or {}
            compiler = preflight.get("compiler") or {}
            kind = compiler.get("kind")
            no_defaults = result.get("after", {}).get("CRATE_CC_NO_DEFAULTS")
            environment_ok = (
                kind == "msvc" and no_defaults is None
            ) or (
                kind == "llvm-mingw" and no_defaults == "1"
            )
            if (
                result.get("before", {}).get("CC") is not None
                or result.get("before", {}).get("CRATE_CC_NO_DEFAULTS") is not None
                or not environment_ok
                or not result.get("after", {}).get("CC")
            ):
                raise LaneError(
                    "Parser install did not use the expected native compiler environment"
                )
        self.summary["treesitter"] = result
        self.write_summary()
        return result

    def exercise_tools(self) -> dict[str, Any]:
        binaries = {package: self.find_package_binary(package) for package in MASON_PACKAGES}
        lua_file = self.fixture / "sample.lua"
        shell_file = self.fixture / "sample.sh"
        before_lua = lua_file.read_text(encoding="utf-8")
        before_shell = shell_file.read_text(encoding="utf-8")
        stages = {}
        stages["stylua_format"] = self.run_stage(
            "stylua-format", [binaries["stylua"], lua_file], cwd=self.fixture
        )
        stages["stylua_check"] = self.run_stage(
            "stylua-check", [binaries["stylua"], "--check", lua_file], cwd=self.fixture
        )
        stages["shfmt_format"] = self.run_stage(
            "shfmt-format", [binaries["shfmt"], "-w", shell_file], cwd=self.fixture
        )
        stages["shfmt_check"] = self.run_stage(
            "shfmt-check", [binaries["shfmt"], "-d", shell_file], cwd=self.fixture
        )
        stages["tree_sitter_version"] = self.run_stage(
            "tree-sitter-version", [binaries["tree-sitter-cli"], "--version"]
        )
        stages["luals_version"] = self.run_stage(
            "luals-version", [binaries["lua-language-server"], "--version"]
        )
        after_lua = lua_file.read_text(encoding="utf-8")
        after_shell = shell_file.read_text(encoding="utf-8")
        if before_lua == after_lua or before_shell == after_shell:
            raise LaneError("A formatter did not modify its deliberately unformatted fixture")
        result = {
            "binaries": {name: str(path) for name, path in binaries.items()},
            "fixtures": {
                "lua": {"before": before_lua, "after": after_lua},
                "shell": {"before": before_shell, "after": after_shell},
            },
            "passed": True,
            "stages": stages,
        }
        atomic_json(self.artifacts / "tool-execution.json", result)
        self.summary["tool_execution"] = result
        self.write_summary()
        return result

    def exercise_lsp(self, luals: Path) -> None:
        protocol_output = self.artifacts / "luals-protocol.json"
        self.run_stage(
            "luals-protocol",
            [
                sys.executable,
                SCRIPT_DIR / "lsp_protocol.py",
                "--server",
                luals,
                "--file",
                self.fixture / "sample.lua",
                "--output",
                protocol_output,
                "--timeout",
                "90",
            ],
            cwd=self.fixture,
            timeout=150,
        )
        protocol = read_json(protocol_output)
        if protocol.get("success") is not True:
            raise LaneError("The explicit LuaLS protocol lifecycle failed")
        attachment = self.run_probe(
            "lazyvim-luals-attachment",
            "lsp_attachment.lua",
            "lsp-attachment.json",
            fixture_file=self.fixture / "sample.lua",
            timeout=150,
        )
        if (
            attachment.get("attached") is not True
            or attachment.get("hover_ok") is not True
            or attachment.get("stop_requested") is not True
        ):
            raise LaneError("LazyVim LuaLS attachment/hover/shutdown gate failed")
        log_path = attachment.get("lsp_log")
        if log_path and Path(log_path).is_file():
            shutil.copy2(log_path, self.artifacts / "lazyvim-lsp.log")
        self.summary["lsp"] = {
            "attachment": attachment,
            "protocol": protocol,
        }
        self.write_summary()

    def capture_health_and_runtime(self) -> None:
        health_path = self.artifacts / "health.txt"
        probe_env = self.env.copy()
        probe_env["LVB_E2E_OUTPUT"] = str(health_path)
        probe_env["LVB_E2E_PROBE"] = str(SCRIPT_DIR / "probes" / "health.lua")
        self.run_stage(
            "lazyvim-health",
            [
                self.args.nvim,
                "--headless",
                "-c",
                "lua dofile(vim.env.LVB_E2E_PROBE)",
            ],
            cwd=self.fixture,
            timeout=120,
            env=probe_env,
        )
        health = health_path.read_text(encoding="utf-8", errors="replace")
        lowered = health.lower()
        banned = ("missing_mason_target", "wrong_architecture", "missing target", "wrong architecture")
        if any(value in lowered for value in banned):
            raise LaneError("Health output contains missing-target or wrong-architecture diagnostics")
        runtime = self.run_probe(
            "runtime-quiescence",
            "runtime_state.lua",
            "runtime-state.json",
            timeout=120,
        )
        if runtime.get("pending_plugin_tasks"):
            raise LaneError("LazyVim still has pending plugin tasks after readiness gates")
        self.summary["health"] = {
            "path": str(health_path),
            "sha256": file_sha256(health_path),
            "forbidden_diagnostics": False,
        }
        self.summary["runtime_state"] = runtime
        self.write_summary()

    def architecture_gate_roots(self) -> dict[str, Path]:
        roots: dict[str, Path] = {
            "plugins": self.lazy_root,
            "mason": self.mason_root,
            "parsers": self.data_dir / "site" / "parser",
        }
        if self.args.lane == "windows":
            roots["support"] = self.args.support_bin
            yaml_spec = importlib.util.find_spec("yaml")
            if yaml_spec and yaml_spec.origin:
                roots["pyyaml"] = Path(yaml_spec.origin).parent
        return roots

    def architecture_diagnostic_roots(self) -> dict[str, Path]:
        if not self.args.distribution_diagnostics:
            return {}
        if self.args.lane == "windows":
            return {
                "python_distribution": Path(sys.executable).parent,
                "neovim_distribution": self.args.nvim.parent.parent,
                "git_distribution": self.args.git.parent.parent,
                "compiler_distribution": self.args.compiler_bin.parent,
            }
        return {"native_tool_bundle": Path("/root/.local/lvb-arm64-tools")}

    def audit_architecture(self) -> dict[str, Any]:
        expected_format, expected_machine, expected_machine_label = self.expected_binary()
        native_suffixes = {".exe", ".dll", ".pyd"} if self.args.lane == "windows" else {".so"}

        def scan_roots(roots: dict[str, Path]) -> tuple[dict[str, Any], list[dict[str, Any]], list[str]]:
            scopes: dict[str, Any] = {}
            wrong: list[dict[str, Any]] = []
            invalid: list[str] = []
            for scope, root in roots.items():
                records = []
                if not root.exists():
                    raise LaneError(f"Architecture audit root is missing: {scope}: {root}")
                files = [root] if root.is_file() else root.rglob("*")
                for path in files:
                    if not path.is_file():
                        continue
                    architecture = binary_architecture(path)
                    if architecture:
                        record = {
                            **architecture,
                            "bytes": path.stat().st_size,
                            "path": str(path),
                            "sha256": file_sha256(path),
                        }
                        records.append(record)
                        if (
                            architecture["format"] != expected_format
                            or architecture["machine_value"] != expected_machine
                        ):
                            wrong.append({"scope": scope, **record})
                    elif path.suffix.lower() in native_suffixes:
                        invalid.append(str(path))
                scopes[scope] = {
                    "format": expected_format,
                    "native_count": len(records),
                    "records": records,
                    "root": str(root),
                }
            return scopes, wrong, invalid

        scopes, wrong, invalid_native_files = scan_roots(self.architecture_gate_roots())
        diagnostic_scopes, diagnostic_foreign, diagnostic_invalid = scan_roots(
            self.architecture_diagnostic_roots()
        )

        resolved_tools = []
        tool_names = [
            ("python", sys.executable),
            ("nvim", str(self.args.nvim)),
            ("git", str(self.args.git)),
            ("cc", shutil.which("cc", path=self.env["PATH"])),
            ("gcc", shutil.which("gcc", path=self.env["PATH"])),
            (
                self.compiler_driver().removesuffix(".exe"),
                shutil.which(self.compiler_driver(), path=self.env["PATH"]),
            ),
            ("curl", shutil.which("curl", path=self.env["PATH"])),
            ("tar", shutil.which("tar", path=self.env["PATH"])),
            ("powershell", shutil.which("powershell", path=self.env["PATH"])),
            ("pwsh", shutil.which("pwsh", path=self.env["PATH"])),
            ("yq", shutil.which("yq", path=self.env["PATH"])),
        ]
        if self.args.lane == "wsl":
            tool_names.extend(
                (
                    ("make", shutil.which("make", path=self.env["PATH"])),
                    ("unzip", shutil.which("unzip", path=self.env["PATH"])),
                )
            )
        for name, value in tool_names:
            if not value:
                continue
            path = Path(value)
            architecture = binary_architecture(path)
            record = {
                "name": name,
                "path": str(path),
                **(architecture or {"architecture": None, "format": None, "machine": None}),
            }
            resolved_tools.append(record)
            if not architecture or (
                architecture["format"] != expected_format
                or architecture["machine_value"] != expected_machine
            ):
                wrong.append({"scope": "resolved_tools", **record})

        parser_records = scopes["parsers"]["records"]
        parser_native = [
            record
            for record in parser_records
            if record["format"] == expected_format and record["machine_value"] == expected_machine
        ]
        result = {
            "expected": {
                "architecture": self.args.expected_architecture,
                "format": expected_format,
                "machine": expected_machine_label,
            },
            "invalid_native_files": invalid_native_files,
            "passed": not wrong and not invalid_native_files and len(parser_native) >= 24,
            "parser_count": len(parser_records),
            "parser_native_count": len(parser_native),
            "resolved_tools": resolved_tools,
            "scopes": scopes,
            "wrong_architecture": wrong,
            "provisioned_distribution_diagnostics": {
                "foreign_binaries": diagnostic_foreign,
                "foreign_count": len(diagnostic_foreign),
                "invalid_native_files": diagnostic_invalid,
                "note": (
                    "Retained diagnostic inventory of dormant multi-architecture payloads in "
                    "the provisioned distributions; only resolved executables and recursively "
                    "installed E2E payloads are eligible for the no-emulation sign-off gate."
                ),
                "scopes": diagnostic_scopes,
            },
        }
        atomic_json(self.artifacts / "architecture-inventory.json", result)
        self.summary["architecture"] = {
            "expected": result["expected"],
            "passed": result["passed"],
            "parser_count": result["parser_count"],
            "parser_native_count": result["parser_native_count"],
            "scope_counts": {
                name: scope["native_count"] for name, scope in scopes.items()
            },
            "wrong_architecture_count": len(wrong),
            "invalid_native_file_count": len(invalid_native_files),
            "provisioned_distribution_foreign_count": len(diagnostic_foreign),
        }
        self.write_summary()
        if not result["passed"]:
            raise LaneError("Native architecture audit failed")
        return result

    def startup_series(self, name: str, extra_args: list[str | Path]) -> dict[str, Any]:
        command = [str(self.args.nvim), "--headless", *map(str, extra_args), "+qa!"]
        warmup_codes = []
        for _ in range(self.args.warmups):
            completed = subprocess.run(
                command,
                env=self.env,
                cwd=self.fixture,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=120,
                check=False,
            )
            warmup_codes.append(completed.returncode)
        samples = []
        return_codes = []
        for _ in range(self.args.runs):
            started = time.perf_counter()
            completed = subprocess.run(
                command,
                env=self.env,
                cwd=self.fixture,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=120,
                check=False,
            )
            samples.append(time.perf_counter() - started)
            return_codes.append(completed.returncode)
        if any(code != 0 for code in warmup_codes + return_codes):
            raise LaneError(f"Startup series {name} returned a nonzero code")
        result = {
            "command": command,
            "name": name,
            "return_codes": return_codes,
            "warmup_return_codes": warmup_codes,
            **summarize(samples),
        }
        atomic_json(self.artifacts / f"{name}.json", result)
        return result

    def benchmark_startup(self) -> None:
        startuptime = self.artifacts / "startuptime.log"
        self.run_stage(
            "startuptime",
            [
                self.args.nvim,
                "--headless",
                "--startuptime",
                startuptime,
                "+qa!",
            ],
            cwd=self.fixture,
            timeout=120,
        )
        series = {
            "empty": self.startup_series("warm-empty-startup", []),
            "file": self.startup_series(
                "warm-file-startup", [self.fixture / "sample.lua"]
            ),
        }
        self.summary["startup"] = series
        self.write_summary()
        maintenance = self.run_stage(
            "lazy-noop-maintenance",
            [self.args.nvim, "--headless", "+Lazy! restore", "+qa!"],
            cwd=self.fixture,
            timeout=self.args.timeout,
        )
        self.summary["maintenance"] = {
            "name": maintenance["name"],
            "return_code": maintenance["return_code"],
            "seconds": maintenance["seconds"],
        }
        self.write_summary()

    def snapshot_config(self) -> None:
        lockfile = self.config_dir / "lazy-lock.json"
        self.summary["final_runtime_lock_sha256"] = file_sha256(lockfile)
        shutil.copy2(self.lockfile, lockfile)
        self.summary["final_fixture_lock_sha256"] = file_sha256(lockfile)
        for source in (
            self.config_dir / "init.lua",
            self.config_dir / "lazy-lock.json",
            self.config_dir / "lua" / "config" / "lazy.lua",
            self.config_dir / "lua" / "plugins" / "arm64-e2e.lua",
        ):
            if source.is_file():
                destination = self.config_snapshot / source.relative_to(self.config_dir)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)

    def collect_runtime_logs(self) -> None:
        candidates = {
            "mason-runtime.log": self.state_home / (
                f"{self.appname}-data" if self.args.lane == "windows" else self.appname
            ) / "mason.log",
            "nvim-runtime.log": self.state_home / (
                f"{self.appname}-data" if self.args.lane == "windows" else self.appname
            ) / "nvim.log",
        }
        for name, source in candidates.items():
            if source.is_file():
                shutil.copy2(source, self.logs / name)

    def git_trace_paths(self) -> list[Path]:
        paths = [self.logs / "git-trace.jsonl"]
        if self.args.additional_git_trace:
            paths.append(self.args.additional_git_trace.resolve())
        return paths

    def read_git_trace_events(self) -> list[dict[str, Any]]:
        events = []
        for trace_path in self.git_trace_paths():
            for line_number, line in enumerate(
                trace_path.read_text(encoding="utf-8").splitlines(), 1
            ):
                if not line.strip():
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError as error:
                    raise LaneError(
                        f"Invalid Git trace JSON in {trace_path} at line "
                        f"{line_number}: {error}"
                    ) from error
                event["_trace"] = str(trace_path)
                events.append(event)
        return events

    def audit_git_execution(self) -> None:
        events = self.read_git_trace_events()
        if self.args.additional_git_trace:
            shutil.copy2(
                self.args.additional_git_trace,
                self.logs / "provisioning-git-trace.jsonl",
            )

        shell_children = []
        shell_ancestry = []
        executables: dict[str, dict[str, Any]] = {}
        git_exec_path_result = subprocess.run(
            [str(self.args.git), "--exec-path"],
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=30,
            check=False,
        )
        git_exec_path = (
            Path(git_exec_path_result.stdout.strip())
            if git_exec_path_result.returncode == 0
            else None
        )
        for event in events:
            event_name = event.get("event")
            ancestry = None
            if event_name == "cmd_ancestry":
                ancestry = [str(item) for item in event.get("ancestry", [])]
            elif (
                event_name == "data_json"
                and event.get("key") == "windows/ancestry"
            ):
                ancestry = [str(item) for item in event.get("value", [])]
            if ancestry is not None:
                if any(
                    Path(item).name.lower() in {"sh.exe", "bash.exe"}
                    for item in ancestry
                ):
                    shell_ancestry.append(event)
            if event_name not in {"start", "child_start"}:
                continue
            argv = event.get("argv") or []
            if isinstance(argv, str):
                argv = [argv]
            if not argv:
                continue
            command = str(argv[0])
            command_name = Path(command.strip('"')).name.lower()
            if event_name == "child_start" and (
                event.get("use_shell") is True
                or command_name in {"sh", "sh.exe", "bash", "bash.exe"}
            ):
                shell_children.append(event)
            resolved = command
            if not Path(command).is_file():
                found = shutil.which(command, path=self.env["PATH"])
                if found:
                    resolved = found
                elif git_exec_path and command.lower().startswith("git-"):
                    executable = (
                        command if command.lower().endswith(".exe") else command + ".exe"
                    )
                    git_root = self.args.git.parent.parent
                    candidates = (
                        git_exec_path / executable,
                        git_root / "clangarm64" / "bin" / executable,
                        git_root / "mingw64" / "bin" / executable,
                    )
                    for candidate in candidates:
                        if candidate.is_file():
                            resolved = str(candidate)
                            break
            path = Path(resolved)
            architecture = binary_architecture(path) if path.is_file() else None
            executables[str(path)] = {
                "architecture": architecture,
                "command": command,
                "path": str(path),
            }

        wrong = [
            record
            for record in executables.values()
            if not record["architecture"]
            or record["architecture"]["format"] != "PE"
            or record["architecture"]["machine_value"] != self.expected_binary()[1]
        ]
        shell_violation = self.args.forbid_shell and bool(shell_children or shell_ancestry)
        result = {
            "event_count": len(events),
            "executables": list(executables.values()),
            "forbid_shell": self.args.forbid_shell,
            "passed": not shell_violation and not wrong,
            "shell_ancestry": shell_ancestry,
            "shell_children": shell_children,
            "traces": [str(path) for path in self.git_trace_paths()],
            "wrong_architecture": wrong,
        }
        atomic_json(self.artifacts / "git-execution-audit.json", result)
        self.summary["git_execution"] = {
            "event_count": result["event_count"],
            "executable_count": len(executables),
            "passed": result["passed"],
            "shell_ancestry_count": len(shell_ancestry),
            "shell_child_count": len(shell_children),
            "wrong_architecture_count": len(wrong),
        }
        self.write_summary()
        if not result["passed"]:
            raise LaneError(
                "Git execution trace detected a forbidden shell or wrong-architecture execution"
            )

    @staticmethod
    def is_windows_contaminated(value: str) -> bool:
        normalized = value.replace("\\", "/")
        lowered = normalized.lower()
        return (
            lowered == "/mnt"
            or lowered.startswith("/mnt/")
            or "/mnt/" in lowered
            or re.search(r"(^|[=\"' ])/[a-z]/", lowered) is not None
            or re.search(r"(^|[=\"' ])/[mnt]/[a-z]/", lowered) is not None
            or re.search(r"(^|[=\"' ])[a-z]:/", lowered) is not None
        )

    def audit_wsl_placement(self) -> None:
        configured_paths: dict[str, Path] = {
            "cache": self.cache_home,
            "config": self.config_home,
            "cwd": Path.cwd(),
            "data": self.data_home,
            "evidence": self.evidence,
            "git": self.args.git,
            "git_cache": self.args.git_cache,
            "harness": REPO_ROOT,
            "lazyvim_source": self.args.lazyvim_source,
            "nvim": self.args.nvim,
            "project": self.fixture,
            "python": Path(sys.executable),
            "starter_source": self.args.starter_source,
            "state": self.state_home,
            "support_bin": self.args.support_bin,
            "treesitter_source": self.args.treesitter_source,
            "work": self.work_root,
        }
        for command in ("cc", "gcc"):
            resolved = shutil.which(command, path=self.env["PATH"])
            if resolved:
                configured_paths[command] = Path(resolved)
        tool_bundle = Path("/root/.local/lvb-arm64-tools")
        if tool_bundle.exists():
            configured_paths["tool_bundle"] = tool_bundle

        complete_environment = dict(os.environ)
        environment = {
            "PATH": os.environ.get("PATH"),
            "WSLENV": os.environ.get("WSLENV"),
            "WSL_INTEROP": os.environ.get("WSL_INTEROP"),
        }
        environment_hits = [
            {"name": name}
            for name, value in complete_environment.items()
            if value
            and (
                name in {"WSLENV", "WSL_INTEROP"}
                or self.is_windows_contaminated(value)
            )
        ]

        active_paths: set[str] = set()
        recursive_hits = []
        for root in configured_paths.values():
            resolved_root = root.resolve()
            candidates = [resolved_root]
            if resolved_root.is_dir():
                candidates.extend(resolved_root.rglob("*"))
            for path in candidates:
                value = str(path)
                active_paths.add(value)
                if self.is_windows_contaminated(value):
                    recursive_hits.append(value)

        trace_hits = []
        trace_event_count = 0
        for event in self.read_git_trace_events():
            trace_event_count += 1
            serialized = json.dumps(event, sort_keys=True)
            if self.is_windows_contaminated(serialized):
                trace_hits.append(event)

        mounts = {}
        invalid_mounts = []
        for name, path in configured_paths.items():
            completed = subprocess.run(
                [
                    "findmnt",
                    "--json",
                    "--output",
                    "SOURCE,TARGET,FSTYPE,OPTIONS",
                    "--target",
                    str(path),
                ],
                env=self.env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=30,
                check=False,
            )
            if completed.returncode != 0:
                raise LaneError(f"findmnt failed for {name}: {completed.stderr.strip()}")
            filesystems = json.loads(completed.stdout).get("filesystems") or []
            if not filesystems:
                raise LaneError(f"findmnt returned no filesystem for {name}: {path}")
            mount = filesystems[0]
            mounts[name] = {"path": str(path.resolve()), **mount}
            if str(mount.get("fstype", "")).lower() in {"9p", "drvfs"}:
                invalid_mounts.append(name)

        result = {
            "accepted": not (
                environment_hits
                or recursive_hits
                or trace_hits
                or invalid_mounts
            ),
            "active_path_count": len(active_paths),
            "environment": environment,
            "environment_hits": environment_hits,
            "environment_variable_count": len(complete_environment),
            "git_trace_event_count": trace_event_count,
            "invalid_mounts": invalid_mounts,
            "mounts": mounts,
            "recursive_forbidden_hits": recursive_hits,
            "trace_forbidden_hits": trace_hits,
        }
        atomic_json(self.artifacts / "wsl-placement.json", result)
        self.summary["placement"] = result
        self.write_summary()
        if not result["accepted"]:
            raise LaneError("WSL placement or Windows interoperability contamination gate failed")

    def run(self) -> None:
        self.prepare()
        self.verify_components()
        self.compile_yq_bridge()
        self.configure()
        self.reconcile_online_lock()
        self.validate_plugins()
        self.install_mason()
        self.run_preflight()
        self.run_treesitter()
        tools = self.exercise_tools()
        self.exercise_lsp(Path(tools["binaries"]["lua-language-server"]))
        self.capture_health_and_runtime()
        functional_readiness = time.perf_counter() - self.setup_started
        architecture_started = time.perf_counter()
        self.audit_architecture()
        self.summary["architecture_audit_seconds"] = time.perf_counter() - architecture_started
        self.summary["setup_to_readiness_seconds"] = functional_readiness
        self.summary["setup_to_signoff_seconds"] = time.perf_counter() - self.setup_started
        self.summary["setup_stage_sum_seconds"] = sum(
            stage["seconds"] for stage in self.summary["stages"]
        )
        self.summary["readiness_gates"] = {
            "architecture": True,
            "formatters": True,
            "health": True,
            "lazyvim_luals_attachment": True,
            "luals_protocol": True,
            "mason": True,
            "plugin_lock": True,
            "preflight": True,
            "treesitter": True,
        }
        self.write_summary()
        self.benchmark_startup()
        if self.args.lane == "windows":
            self.audit_git_execution()
            self.summary["readiness_gates"]["git_no_emulation"] = True
        else:
            self.audit_wsl_placement()
            self.summary["readiness_gates"]["wsl_placement"] = True
        self.snapshot_config()
        self.collect_runtime_logs()
        self.summary["finished_at"] = utc_now()
        self.summary["result"] = "passed"
        self.write_summary()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lane", choices=("windows", "wsl"), required=True)
    parser.add_argument("--profile", choices=("control", "fork"), default="fork")
    parser.add_argument("--label", required=True)
    parser.add_argument("--work-root", required=True, type=Path)
    parser.add_argument("--evidence-dir", required=True, type=Path)
    parser.add_argument("--nvim", required=True, type=Path)
    parser.add_argument("--git", required=True, type=Path)
    parser.add_argument("--git-cache", required=True, type=Path)
    parser.add_argument("--starter-source", required=True, type=Path)
    parser.add_argument("--lazyvim-source", required=True, type=Path)
    parser.add_argument("--treesitter-source", required=True, type=Path)
    parser.add_argument("--mason-registry", required=True)
    parser.add_argument("--mason-target", required=True)
    parser.add_argument(
        "--expected-architecture",
        choices=("arm64", "x64"),
        required=True,
    )
    parser.add_argument("--compiler-bin", type=Path)
    parser.add_argument("--support-bin", type=Path)
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--warmups", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--distribution-diagnostics", action="store_true")
    parser.add_argument("--additional-git-trace", type=Path)
    parser.add_argument("--mason-artifact-validation", type=Path)
    parser.add_argument(
        "--forbid-shell",
        action="store_true",
        help="Reject Git shell execution (required for ARM64 no-emulation sign-off).",
    )
    parser.add_argument(
        "--plugin-source-mode",
        choices=("preseeded", "online"),
        default="preseeded",
    )
    parser.add_argument("--network-retries", type=int, default=2)
    args = parser.parse_args()
    if args.runs < 2 or args.warmups < 0 or args.timeout < 60 or args.network_retries < 0:
        parser.error(
            "runs must be >= 2, warmups >= 0, timeout must be >= 60, "
            "and network-retries must be >= 0"
        )
    if args.lane == "windows" and (args.compiler_bin is None or args.support_bin is None):
        parser.error("Windows requires --compiler-bin and --support-bin")
    return args


def main() -> int:
    args = parse_args()
    lane = Lane(args)
    try:
        lane.run()
    except Exception as error:
        lane.collect_runtime_logs()
        lane.summary["finished_at"] = utc_now()
        lane.summary["result"] = "failed"
        lane.summary["error"] = f"{type(error).__name__}: {error}"
        lane.write_summary()
        print(lane.summary["error"], file=sys.stderr)
        return 1
    print(lane.summary_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
