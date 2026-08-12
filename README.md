# LazyVim Windows ARM64 ecosystem E2E

This repository is the transferable validation point for the Windows ARM64
LazyVim fixes and their ecosystem dependencies. Clone it on an **x64 Windows
machine**, run one command, and get an end-to-end regression result plus ARM64
release-artifact inspection.

## Quick start on x64 Windows

Prerequisites:

- Native x64 Windows 11.
- Native x64 Git for Windows on `PATH`.
- Native x64 Python 3.12 or newer on `PATH`.
- PowerShell 7 or Windows PowerShell 5.1.
- At least 4 CPU cores, 12 GB free disk space, and internet access.

```powershell
git clone https://github.com/crutkas/lazyvim-arm64-e2e.git
cd lazyvim-arm64-e2e
Set-ExecutionPolicy -Scope Process Bypass
.\test.ps1
```

The script downloads and hash-verifies pinned Neovim 0.12.4 and LLVM-MinGW,
creates an isolated Python environment, checks out immutable component commits,
then runs the complete flow. It does not modify your normal Neovim profile.

For the full 10-sample benchmark:

```powershell
.\test.ps1 -RunId x64-full -Runs 10 -Warmups 3 -DistributionDiagnostics
```

Each `RunId` must be unique. Evidence is written to `out/<RunId>/`.

## What the x64 run validates

| Surface | Validation |
|---|---|
| LazyVim | `crutkas/LazyVim@975e73f9455faa7960fba5e14b4c81e20fbf2716` |
| nvim-treesitter | `crutkas/nvim-treesitter@61c17a841e9295716e441a42d88c93431a100890` |
| Frozen graph | All 32 exact plugin commits, clean worktrees |
| Mason | Pinned upstream registry, x64 StyLua, shfmt, LuaLS, and tree-sitter |
| Formatting | Real StyLua and shfmt rewrites and clean checks |
| LuaLS | JSON-RPC initialize, didOpen, hover, shutdown, exit; LazyVim attachment |
| Parsers | 23 LazyVim defaults plus dependencies; install, load, and parse |
| Compiler/preflight | LazyVim selects native x64 MSVC when available, otherwise pinned x64 LLVM-MinGW, with no preset `CC` |
| Architecture | All resolved tools, installed Mason payloads, and parsers are PE x64 |
| Maintenance/startup | No-op maintenance and warm empty/file startup samples |
| Git | Complete trace; shell use is allowed only when the shell is native x64 |

The x64 lane intentionally uses the pinned upstream Mason registry because the
fork registry in PR #2 redirects packages to ARM64-only prereleases. This tests
that the LazyVim and nvim-treesitter fixes preserve the established x64
ecosystem while the artifact gate validates the ARM64 producer changes.

## ARM64 artifacts checked on x64

`test.ps1` also runs `verify-arm64-artifacts.ps1`. It downloads the public
fork-only releases, checks archive SHA-256 values, extracts them, and verifies
every shipped PE file is `0xAA64`:

- StyLua `stylua-windows-aarch64.zip`
- shfmt `shfmt_v3.13.1_windows_arm64.exe`
- LuaLS `lua-language-server-3.19.0-win32-arm64.zip`
- tree-sitter CLI 0.26.12 Windows ARM64

The artifact gate **does not execute ARM64 binaries on x64**. Native ARM64
runtime and performance sign-off remains in `reference/ARM64_RESULTS.md`.

To run only this portable artifact check:

```powershell
.\verify-arm64-artifacts.ps1
```

## Expected success output

The command exits zero and prints:

```text
LazyVim x64 ecosystem validation passed.
  Plugins: 32/32
  Mason tools: 4/4
  Parsers: 24/24 native x64
  LuaLS protocol and LazyVim attachment: passed
```

Inspect:

- `out/<RunId>/summary.json` for stages, timings, gates, and raw samples.
- `out/<RunId>/artifacts/` for health, architecture, Mason, parser, and LSP evidence.
- `out/<RunId>/mason-receipts/` for the four exact package receipts.
- `out/<RunId>-arm64-artifacts/artifact-validation.json` for ARM64 release inspection.

## Fix and retest workflow

1. Make the ecosystem change in its dedicated `crutkas` fork.
2. Push the branch and update the immutable commit or asset in `manifest.json`.
3. If LazyVim or nvim-treesitter changed, update only those entries in
   `harness/lazy-lock-e2e.json`.
4. Run `.\test.ps1 -RunId <new-name>`.
5. Require both the x64 consumer flow and ARM64 artifact inspection to pass.
6. Run native ARM64 CI/device validation before claiming ARM64 runtime or
   performance sign-off.

The component PRs and prereleases are enumerated in `manifest.json`. Historical
native ARM64 results are retained under `reference/`.

## CI

`.github/workflows/x64-e2e.yml` runs the same command on `windows-latest` and
uploads its evidence. Local and CI validation therefore use the same entry
point.

## Scope limitation

The validated Windows ARM64 E2E uses shell-free preseeded Git objects for its
native-only correctness lane. Normal online Windows plugin-install performance
is still unsigned because the current Git for Windows ARM64 package executes
bundled x64 `sh.exe`. The x64 regression run is unaffected because that shell is
native on an x64 host.
