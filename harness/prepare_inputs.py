#!/usr/bin/env python3
"""Prepare exact component checkouts and frozen Git object stores without a shell."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parent.parent
STARTER_COMMIT = "803bc181d7c0d6d5eeba9274d9be49b287294d99"
STARTER_URL = "https://github.com/LazyVim/starter.git"
UPSTREAM_LAZYVIM_URL = "https://github.com/LazyVim/LazyVim.git"
UPSTREAM_TREESITTER_URL = "https://github.com/nvim-treesitter/nvim-treesitter.git"


class InputError(RuntimeError):
    pass


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def run(git: Path, *arguments: str, capture: bool = False) -> str:
    completed = subprocess.run(
        [str(git), *arguments],
        env=os.environ.copy(),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=600,
        check=False,
    )
    if completed.returncode != 0:
        raise InputError(
            f"Git command failed ({' '.join(arguments)}):\n{completed.stdout}"
        )
    return completed.stdout.strip() if capture else ""


def ensure_remote(git: Path, repository: Path, url: str) -> None:
    observed = run(git, "-C", str(repository), "remote", "get-url", "origin", capture=True)
    if observed.rstrip("/") != url.rstrip("/"):
        raise InputError(
            f"Existing source has the wrong origin: {repository}: {observed} != {url}"
        )


def ensure_checkout(git: Path, destination: Path, url: str, commit: str) -> dict[str, str]:
    if (destination / ".git").is_dir():
        ensure_remote(git, destination, url)
        dirty = run(git, "-C", str(destination), "status", "--porcelain", capture=True)
        if dirty:
            raise InputError(f"Existing source checkout is dirty: {destination}")
    elif destination.exists():
        raise InputError(f"Source path exists but is not a Git checkout: {destination}")
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        run(git, "init", "--quiet", str(destination))
        run(git, "-C", str(destination), "remote", "add", "origin", url)

    has_commit = subprocess.run(
        [str(git), "-C", str(destination), "cat-file", "-e", f"{commit}^{{commit}}"],
        env=os.environ.copy(),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=60,
        check=False,
    ).returncode == 0
    if not has_commit:
        run(
            git,
            "-C",
            str(destination),
            "fetch",
            "--force",
            "--no-tags",
            "--depth",
            "1",
            "origin",
            commit,
        )
    run(git, "-C", str(destination), "checkout", "--force", "--detach", commit)
    head = run(git, "-C", str(destination), "rev-parse", "HEAD", capture=True)
    dirty = run(git, "-C", str(destination), "status", "--porcelain", capture=True)
    if head.lower() != commit.lower() or dirty:
        raise InputError(f"Could not establish exact clean checkout: {destination}")
    return {"commit": head, "path": str(destination), "url": url}


def cache_path(cache_root: Path, url: str) -> Path:
    prefix = "https://github.com/"
    if not url.startswith(prefix):
        raise InputError(f"Only GitHub HTTPS sources are supported: {url}")
    relative = url[len(prefix) :]
    if relative.endswith(".git"):
        relative = relative[:-4]
    return cache_root / Path(relative)


def ensure_bare_repository(
    git: Path,
    destination: Path,
    url: str,
    commits: set[str],
) -> dict[str, Any]:
    if (destination / "objects").is_dir():
        remote = subprocess.run(
            [str(git), "--git-dir", str(destination), "remote", "get-url", "origin"],
            env=os.environ.copy(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=60,
            check=False,
        )
        if remote.returncode == 0:
            observed = remote.stdout.strip()
            if observed.rstrip("/") != url.rstrip("/"):
                raise InputError(
                    f"Existing cache has the wrong origin: {destination}: "
                    f"{observed} != {url}"
                )
        else:
            run(git, "--git-dir", str(destination), "remote", "add", "origin", url)
    elif destination.exists():
        raise InputError(f"Cache path exists but is not a bare repository: {destination}")
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        run(git, "init", "--bare", "--quiet", str(destination))
        run(git, "--git-dir", str(destination), "remote", "add", "origin", url)

    fetched = []
    for commit in sorted(commits):
        present = subprocess.run(
            [
                str(git),
                "--git-dir",
                str(destination),
                "cat-file",
                "-e",
                f"{commit}^{{commit}}",
            ],
            env=os.environ.copy(),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=60,
            check=False,
        ).returncode == 0
        if not present:
            run(
                git,
                "--git-dir",
                str(destination),
                "fetch",
                "--force",
                "--no-tags",
                "--depth",
                "1",
                "origin",
                commit,
            )
            fetched.append(commit)
        run(
            git,
            "--git-dir",
            str(destination),
            "cat-file",
            "-e",
            f"{commit}^{{commit}}",
        )
    return {
        "commits": sorted(commits),
        "fetched": fetched,
        "path": str(destination),
        "url": url,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("control", "fork"), required=True)
    parser.add_argument("--registry", choices=("fork", "upstream"), required=True)
    parser.add_argument("--git", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--git-cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    manifest = read_json(REPO_ROOT / "manifest.json")
    tools = read_json(REPO_ROOT / "tools.json")
    lock_path = (
        REPO_ROOT / "fixtures" / "lazy-lock.json"
        if args.profile == "control"
        else REPO_ROOT / "harness" / "lazy-lock-e2e.json"
    )
    lock = read_json(lock_path)
    plugin_sources = read_json(REPO_ROOT / "fixtures" / "plugin-sources.json")
    expected_names = set(lock) - {"LazyVim", "nvim-treesitter"}
    if set(plugin_sources) != expected_names:
        raise InputError(
            "plugin-sources.json must describe the exact non-fork plugin key set"
        )

    if args.profile == "control":
        lazyvim_url = UPSTREAM_LAZYVIM_URL
        treesitter_url = UPSTREAM_TREESITTER_URL
    else:
        lazyvim_url = f"https://github.com/{manifest['components']['lazyvim']['repository']}.git"
        treesitter_url = (
            "https://github.com/"
            f"{manifest['components']['nvim-treesitter']['repository']}.git"
        )

    profile_root = args.source_root.resolve() / args.profile
    checkouts = {
        "starter": ensure_checkout(
            args.git, profile_root / "starter", STARTER_URL, STARTER_COMMIT
        ),
        "lazyvim": ensure_checkout(
            args.git,
            profile_root / "LazyVim",
            lazyvim_url,
            lock["LazyVim"]["commit"],
        ),
        "treesitter": ensure_checkout(
            args.git,
            profile_root / "nvim-treesitter",
            treesitter_url,
            lock["nvim-treesitter"]["commit"],
        ),
    }

    if args.registry == "fork":
        registry_url = (
            "https://github.com/"
            f"{manifest['components']['mason-registry']['repository']}.git"
        )
        registry_commit = manifest["components"]["mason-registry"]["e2e_commit"]
        registry_name = "mason-registry-fork"
    else:
        registry_url = "https://github.com/mason-org/mason-registry.git"
        registry_commit = tools["mason_registry_commit"]
        registry_name = "mason-registry-upstream"
    checkouts["registry"] = ensure_checkout(
        args.git,
        args.source_root.resolve() / registry_name,
        registry_url,
        registry_commit,
    )

    grouped: dict[str, set[str]] = {}
    for name, url in plugin_sources.items():
        grouped.setdefault(url, set()).add(lock[name]["commit"])
    repositories = [
        ensure_bare_repository(
            args.git,
            cache_path(args.git_cache.resolve(), url),
            url,
            commits,
        )
        for url, commits in sorted(grouped.items())
    ]
    cache_manifest = {
        "repositories": [
            {"name": name, "url": plugin_sources[name]} for name in sorted(plugin_sources)
        ],
        "schema_version": 1,
    }
    write_json(args.git_cache.resolve() / "manifest.json", cache_manifest)

    write_json(
        args.output.resolve(),
        {
            "cache_manifest": str(args.git_cache.resolve() / "manifest.json"),
            "checkouts": checkouts,
            "git": str(args.git.resolve()),
            "lock": str(lock_path),
            "profile": args.profile,
            "registry": args.registry,
            "repositories": repositories,
            "schema_version": 1,
        },
    )
    print(args.output.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
