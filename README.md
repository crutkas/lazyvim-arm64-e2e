# LazyVim Windows ARM64 ecosystem E2E

This repository validates the Windows ARM64 LazyVim fixes and their ecosystem
dependencies on native Windows ARM64, WSL2 Linux ARM64, and x64 Windows. The
native runners provision immutable, hash-verified tools and use isolated
Neovim state; they do not modify the user's normal Neovim profile.

## Native Windows ARM64 quick start

Prerequisites:

- A physical Windows 11 ARM64 device running native ARM64 PowerShell.
- PowerShell 7 or Windows PowerShell 5.1.
- Internet access and at least 12 GB of free disk space.
- No host Git, Python, Neovim, or compiler installation is required.

Run the complete fork lane with a new, unique ID:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\run-windows.ps1 -Profile Fork -RunId win-a64-fork-<unique> -Runs 10 -Warmups 3
```

`run-windows.ps1` downloads and hash-verifies native ARM64 MinGit 2.53.0.4,
Python 3.14.6 plus pinned PyYAML, Neovim 0.12.4, and LLVM-MinGW 20260616.
Every run extracts these tools into a new run-scoped directory and verifies the
expected executable hashes. The fork profile also verifies every file in the
four pinned Mason release assets and requires the installed payloads to match
before any tool executes. It prepares exact source checkouts and shell-free
frozen Git object stores, then invokes `harness/run_lane.py` with `--lane windows`,
`--expected-architecture arm64`, `--mason-target win_arm64`, a short work
root, an isolated XDG tree, the provisioning Git trace, and `--forbid-shell`.
The immutable archive identities are in `tools.json`; ecosystem pins are in
`manifest.json`.

Run the supported-default control separately:

```powershell
.\run-windows.ps1 -Profile Control -RunId win-a64-control-<unique> -Runs 10 -Warmups 3
```

The control uses the frozen base lock and pinned upstream Mason registry. It
exits zero only when all 32 plugin commits are exact and clean and the expected
current limitation is reproduced: StyLua, shfmt, LuaLS, and tree-sitter have
no upstream `win_arm64` targets. The details are written to
`out/<RunId>/control-result.json`; this expected failure is never mixed with
fork-lane success.

Every ID must be unique. A run refuses to overwrite an existing work or
evidence directory. Functional evidence is written to `out/<RunId>/`, while
download/source/toolchain identities and provisioning traces are written to
`out/<RunId>-provisioning/`.

## Use LazyVim normally on Windows ARM64

The E2E runner above is for validation. To install a dedicated daily-use
profile instead, run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\setup-windows-arm64.ps1
```

This is a one-time setup, not a benchmark. It hash-verifies and installs native
ARM64 Neovim, MinGit, yq, and LLVM-MinGW beneath
`%LOCALAPPDATA%\Programs\LazyVimARM64`, seeds the exact 32-plugin fork graph,
configures the pinned ARM64 Mason registry, adds `lazyvim-arm64` to the user
`PATH`, and opens the editor. Later, launch it from a new terminal with:

```powershell
lazyvim-arm64
```

The dedicated profile does not replace `%LOCALAPPDATA%\nvim`. Its config lives
under `%LOCALAPPDATA%\Programs\LazyVimARM64\profile`. Automatic plugin update
checks are disabled so the validated pins do not drift. Manual online Git
updates remain outside the native-only sign-off because Git for Windows can
invoke bundled x64 MSYS components during HTTPS operations.

## WSL2 Linux ARM64 regression

The wrapper requires an ARM64 Ubuntu WSL2 distribution. It copies the working
tree through `/mnt/c` into a unique directory under `/root`, then runs only
from the Linux ext4 filesystem as root:

```powershell
.\run-wsl-arm64.ps1 -Distribution Ubuntu -RunId wsl-a64-fork-<unique> -Runs 10 -Warmups 3
```

The Linux runner starts from an empty allowlisted environment, provisions
`build-essential` and `unzip`, and creates fresh run-scoped copies of
hash-verified Linux ARM64 Neovim and yq. It audits every retained environment
value and rejects any active `/mnt` path, Windows interoperability variable,
Windows-mounted gate path, trace contamination, or non-ARM64 executable.
Linux evidence is retained under `/root/.../out/` and copied back to the
repository's `out/` directory.

## Current native result

The 2026-08-18 physical-device run passed the complete Windows fork lane and
the WSL2 ARM64 regression. The supported-default Windows control reproduced
the four expected missing-target failures. Exact commands, pins, metrics,
exclusions, and evidence paths are in
[`reference/ARM64_RESULTS.md`](reference/ARM64_RESULTS.md).

## x64-only portable regression

`test.ps1` is x64-only. It must not be used as evidence that ARM64 binaries
executed natively.

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
Network-backed plugin and parser stages use bounded retries; every failed
attempt remains in the evidence logs.

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

## Performance scope limitation

The validated Windows ARM64 E2E uses shell-free preseeded Git objects for its
native-only correctness lane. Its setup/readiness samples are valid for that
frozen-object workflow, but they are not normal clean online plugin-install
measurements. Current Git for Windows ARM64 HTTPS operations can execute
bundled x64 MSYS shell components, so any such trace is excluded from native
sign-off. The x64 regression is unaffected because those components are native
to its x64 host.
