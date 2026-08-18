# LazyVim Windows ARM64 E2E

## Current physical-device result (2026-08-18)

The current immutable fork stack passed end to end on native Windows ARM64 and
in WSL2 Linux ARM64. The supported-default Windows control reproduced its
expected upstream Mason limitation separately. These results use the current
pins in `../manifest.json`; the older evidence later in this file is historical
and must not be used to select inputs for a new run.

### Exact commands

These are the commands used for the accepted evidence:

```powershell
.\run-windows.ps1 -Profile Control -RunId win-a64-control-20260818-09 -Runs 10 -Warmups 3
.\run-windows.ps1 -Profile Fork -RunId win-a64-fork-20260818-04 -Runs 10 -Warmups 3
.\run-wsl-arm64.ps1 -Distribution Ubuntu -RunId wsl-a64-fork-20260818-10 -Runs 10 -Warmups 3
```

Run IDs are immutable output identities and cannot be reused. Substitute new
unique IDs to reproduce the lanes. `run-wsl-arm64.ps1` copies the repository to
`/root/lazyvim-arm64-e2e-<RunId>` and invokes the Linux runner there; it never
executes the lane from `/mnt/c`.

### Current immutable inputs

| Input | Current identity |
|---|---|
| Base/control lock | 32 plugins, SHA-256 `2afde58236bdfeda9efbe4936a6a8f295066362e7c9e8c1d542fd052d0aa4134` |
| Fork/E2E lock | 32 plugins, SHA-256 `187204912c46110001e9768a1cc91a3552bc94ec84a08f5fb9e455476d55b2fc` |
| LazyVim | `crutkas/LazyVim@975e73f9455faa7960fba5e14b4c81e20fbf2716` |
| nvim-treesitter | `crutkas/nvim-treesitter@61c17a841e9295716e441a42d88c93431a100890` |
| Fork/E2E Mason registry | `crutkas/mason-registry@75a6e0ebca221321cf154f169f56873749dd0d17` |
| WSL/control upstream registry | `mason-org/mason-registry@132d86ea3a73b9d76eeb6f9ee5a4d3a70f9a523b` |
| StyLua | `crutkas/StyLua@1aedf8bbaac4b1fb5a4bd51e9e93c52548b32f31`, asset SHA-256 `a69da76852134633197aae03d17bf05abab1e4cb16824e44b3fc3b1ad133f104` |
| shfmt | `crutkas/sh@8297faffcb1bb7e7b332d44fb96afe1a88e19e99`, asset SHA-256 `1b6e6cd8e1142951e72412e527a6ed97de3908b9b212fdd147cbd93399f2d355` |
| LuaLS | `crutkas/lua-language-server@11db71d7763570e6ae33218e99dbd957865bfe98`, asset SHA-256 `e79fe25dc91e049b4406a26bfd35716dec8434eb141411d71848105223f1b624` |
| bee.lua in LuaLS | `crutkas/bee.lua@5cdaaea78b7f44c01d8cf0f772e8479afd616a80` |
| tree-sitter CLI | `v0.26.12`, Windows ARM64 archive SHA-256 `5ecc7ff2e0ac60be9f93ce20927f3767fd6187f972bff8fada5540979d6abc3c` |
| Windows Neovim | `v0.12.4`, SHA-256 `49906085a3c473ee87a28319942c62216fb365a1a1a4f83dbc4ac41365f5e609` |
| Windows MinGit | `2.53.0.windows.4`, SHA-256 `e1898dbb750804e13472a0e4170ade581516df3ff47ddb5b5503cbfa574b3624` |
| Windows Python | `3.14.6` ARM64, SHA-256 `0a7e80914709a9f3ebfccdb9d1d02a37e4ddb69bb7f80d6df1a7e95d54af9e58` |
| Windows LLVM-MinGW | `20260616`, SHA-256 `312593669435bd0bfc1a43ac3fba23c8b27e0610bade88b2738e5a01702a99ba` |
| Linux Neovim | `v0.12.4`, SHA-256 `ceb7e88c6b681f0515d135dcdfad54f5eb4373b25ce6172197cd9a69c758063f` |
| Linux yq | `v4.53.3`, SHA-256 `578648e463a11c1b6db6010cbf41eafed6bee79466fcffa1bb446672cf7945ea` |

The E2E lock differs from the control lock only at LazyVim and
nvim-treesitter. All other 30 plugin names and commits are identical.

### Accepted gates

| Gate | Windows control | Windows fork E2E | WSL2 ARM64 regression |
|---|---|---|---|
| Exact clean plugins | 32/32 | 32/32 | 32/32 |
| Mason packages | Exact four expected unsupported `win_arm64` targets | StyLua, shfmt, LuaLS, and tree-sitter installed and executed; all 1,200 files matched the four hash-verified release assets before execution | Same four upstream Linux ARM64 tools installed and executed |
| Formatting | Not reached by design | Real StyLua and shfmt rewrites, then clean checks | Real StyLua and shfmt rewrites, then clean checks |
| LuaLS | Not reached by design | JSON-RPC lifecycle and hover passed; LazyVim attached `lua_ls` and completed hover | Same protocol and LazyVim attachment gates passed |
| Parsers | Not reached by design | 24/24 loaded and parsed; every parser is PE `0xAA64` | 24/24 loaded and parsed; every parser is ELF ARM64 (machine 183) |
| Compiler | Not reached by design | Initial `CC` unset; LazyVim selected native LLVM-MinGW `aarch64-w64-mingw32-gcc` | Initial `CC` unset; LazyVim selected native `/usr/bin/cc`, target `aarch64-linux-gnu` |
| Architecture | Native runner/tool provisioning passed before expected Mason failure | Active gate payloads passed with zero wrong-architecture files | Active gate payloads passed with zero wrong-architecture files |
| Process/placement | 4,853 Git Trace2 events; zero shell children, shell ancestry, or wrong-architecture executables | 5,133 Git Trace2 events; zero shell children, shell ancestry, or wrong-architecture executables | Empty allowlisted launch environment; 23,967 active paths and 4,827 Git events; zero environment, recursive-path, trace, or mount violations |

The Windows distribution inventory records 178 dormant foreign payloads from
the provisioned archives, including x64 MSYS utilities and `win32yank.exe`.
They are diagnostic-only and are not resolved or executed by an accepted gate.
The combined provisioning/runtime Git audit observed only native ARM64 Git and
resolved helpers.

### Timings

Each startup result contains 10 measured samples after 3 warmups.

| Metric | Windows preseeded fork E2E | WSL2 ext4 fork E2E |
|---|---:|---:|
| Setup to functional readiness | 295.625224 s | 11.212060 s |
| Warm empty startup median | 0.087961 s | 0.032446 s |
| Warm empty startup p95 | 0.092878 s | 0.033513 s |
| Warm file startup median | 0.356387 s | 0.114678 s |
| Warm file startup p95 | 0.389532 s | 0.264757 s |
| No-op maintenance | 0.123648 s | 0.065061 s |

The Windows setup sample measures the shell-free, preseeded frozen-object
correctness/readiness workflow plus Mason and parser setup. It is not a normal
clean online plugin-install result. Git for Windows ARM64 can invoke bundled
x64 MSYS shell components during HTTPS transport; any run that does so is
excluded rather than weakening the zero-emulation gate.

Setup-to-readiness follows the existing harness methodology and starts after
outer runner provisioning. Archive downloads, fresh native tool extraction,
and Windows Mason release-asset verification are recorded in the sibling
`-provisioning` directory but are not included in this metric.

The final Windows sample includes a long online Mason/parser transfer interval;
the preceding hardened run completed the same readiness stages in 75.632588
seconds. Neither value measures normal online plugin installation because the
32-plugin graph is materialized from preseeded frozen objects.

### Current evidence

- `../out/win-a64-control-20260818-09/`: expected-failure summary,
  `control-result.json`, plugin audit, Mason receipts, logs, and config snapshot.
- `../out/win-a64-control-20260818-09-provisioning/`: native toolchain
  identities, exact input checkouts, full provisioning Git trace, and runner log.
- `../out/win-a64-fork-20260818-04/`: accepted `summary.json`,
  `windows-arm64-result.json`, all raw timing samples, functional artifacts,
  Mason receipts, full archive-to-installed-payload integrity receipt,
  architecture inventory, and runtime logs.
- `../out/win-a64-fork-20260818-04-provisioning/`: archive/tool identities,
  verified Mason release inventories, exact input checkouts, combined-audit
  provisioning trace, and runner log.
- `../out/wsl-a64-fork-20260818-10/`: accepted `summary.json`,
  `wsl-arm64-result.json`, raw samples, functional artifacts, native architecture
  inventory, placement audit, receipts, and logs.
- `../out/wsl-a64-fork-20260818-10-provisioning/`: apt, native tool,
  hash-verified archive, input checkout, Git trace, and runner receipts.
- `../out/wsl-a64-fork-20260818-10-wsl-wrapper.log`: Windows-side wrapper log.

`out/` is intentionally ignored by Git. The unique local directories above
remain the authoritative raw evidence and were not copied over historical
reference artifacts.

### Exclusions and limitations

- `win-a64-fork-20260818-01` functionally passed but was rejected because the
  first Trace2 parser left `git-remote-https` unresolved. Its receipt shows no
  shell child or ancestry; the audit was fixed to resolve MinGit's
  `clangarm64/bin` helper before accepting `-02`.
- `win-a64-fork-20260818-02` was the first complete Windows pass. The cited
  `-03` run added fresh run-scoped tool extraction, pinned executable hashes,
  complete Mason payload hash matching, and `child_start` architecture
  auditing. The cited `-04` run repeats every gate after tracked-only PyYAML
  restoration and Windows PowerShell 5.1 receipt compatibility.
- `wsl-a64-fork-20260818-02` exhausted starter-clone retries.
- `wsl-a64-fork-20260818-03` did not expose the four packages from the local
  upstream registry.
- `wsl-a64-fork-20260818-04` forced `linux_arm64`; LuaLS and StyLua require the
  distinct `linux_arm64_gnu` target, so the accepted lane uses Mason `auto`.
- `wsl-a64-fork-20260818-05` passed three Mason tools but lacked native
  `unzip`, preventing StyLua extraction.
- `wsl-a64-fork-20260818-06` installed all Mason tools but lacked the C library
  development headers required to compile parsers.
- `wsl-a64-fork-20260818-07` was the first complete pass; `-08` repeated it
  after explicit root execution and expanded native receipts. Run `-09` added
  the empty allowlisted environment and fresh run-scoped tools, but its harness
  PATH could still resolve a legacy shared yq. The cited `-10` run explicitly
  passes, mounts, resolves, hash-verifies, and architecture-audits the
  run-scoped yq path.
- All failed setup and lane attempts remain under their unique `../out/`
  directories. None contributes accepted timing or correctness claims.
- `../test.ps1` is x64-only. Its artifact inspection cannot establish native
  ARM64 execution.
- Normal online Windows ARM64 plugin-install performance remains unmeasured
  under the zero-x64-ancestry policy.

## Historical evidence (2026-08-12; not current pins)

> Historical native ARM64 evidence captured before the x64 `vcvarsall.bat`
> quoting follow-up. Use the current immutable pins in `../manifest.json` for
> new runs. The follow-up commit preserves the validated ARM64 behavior.

### Outcome

The immutable fork stack completes native Windows ARM64 correctness and
readiness. Three clean, short-root repetitions passed with 32/32 exact plugin
commits, four native Mason tools, a real LuaLS protocol and LazyVim attachment,
24/24 native parsers, ARM64-aware LazyVim health, and ten startup samples after
three warmups.

The accepted Windows runs use **preseeded frozen Git objects**. This avoids Git
for Windows invoking its bundled x64 `sh.exe`; it is a correctness/readiness
fixture, not a normal plugin-install performance result. A true HTTPS attempt
reached all 32 commits after `:Lazy restore`, but its trace contained 341 x64
shell ancestries. It is excluded, so normal clean online plugin-install timing
remains unmeasured.

Machine-readable results are in
[`arm64-results.json`](arm64-results.json).

### Immutable inputs

| Input | Identity |
|---|---|
| Base lock | 32 plugins, `2afde58236bdfeda9efbe4936a6a8f295066362e7c9e8c1d542fd052d0aa4134` |
| E2E lock | 32 plugins, `41525e97d86a539a817295973026fabf9d38eb2e7b82baaad15e47499220ac3d` |
| LazyVim | `crutkas/LazyVim@0d773f3cb86706e101733f5ff2ef5c36d821ddd2` |
| nvim-treesitter | `crutkas/nvim-treesitter@61c17a841e9295716e441a42d88c93431a100890` |
| E2E Mason registry | `crutkas/mason-registry@75a6e0ebca221321cf154f169f56873749dd0d17`, `file:C:/lvb-a64/mr-e2e` |
| Registry base | tree-sitter fix `32cfcb4d16a4a3942ac2daa703479ef261b0f023` |
| StyLua asset | SHA-256 `a69da76852134633197aae03d17bf05abab1e4cb16824e44b3fc3b1ad133f104` |
| shfmt asset | SHA-256 `1b6e6cd8e1142951e72412e527a6ed97de3908b9b212fdd147cbd93399f2d355` |
| LuaLS asset | SHA-256 `e79fe25dc91e049b4406a26bfd35716dec8434eb141411d71848105223f1b624` |
| bee.lua fix in LuaLS | `5cdaaea78b7f44c01d8cf0f772e8479afd616a80` |

Only the LazyVim and nvim-treesitter commits differ between the two lock
fixtures. Branch labels and all other 30 commits are unchanged; see
[`lock-delta.json`](lock-delta.json).

### Accepted gates

| Gate | Windows ARM64 | WSL ARM64 regression |
|---|---|---|
| Exact clean plugins | 32/32 in all three runs | 32/32 |
| Mason tools | StyLua, shfmt, LuaLS, tree-sitter all pass | Same four upstream Linux ARM64 packages pass |
| Formatting | Real StyLua and shfmt rewrites plus clean checks | Passed |
| LuaLS | initialize, initialized, didOpen, hover, shutdown, exit; LazyVim attaches | Passed |
| Parsers | 23 defaults plus `dtd`; 24/24 PE `0xAA64` | 24/24 ELF ARM64 |
| Preflight | Auto-selected `aarch64-w64-mingw32-gcc`; initial `CC` and `CRATE_CC_NO_DEFAULTS` unset | Native GCC |
| Health | No missing-target or wrong-architecture diagnostics | Passed |
| Git execution | 0 shell children, 0 x64 ancestry, 0 wrong-architecture executables | Native Linux tools |
| WSL placement | n/a | 7,111 active paths and 10,884 trace events; zero Windows-path/interop hits |

The Windows recursive E2E inventory contains four Mason PE files, 24 parser PE
files, the ARM64 yq bridge, and the ARM64 PyYAML extension; every one is
`0xAA64`. Eleven resolved core/support executables are also `0xAA64`.

The provisioned tool distributions contain 560 dormant multi-architecture
payloads, including Git's x64 MSYS utilities and Neovim's x64 `win32yank.exe`.
They are retained in the diagnostic inventory. Any run that executed the x64
Git shell was rejected; accepted traces execute only native ARM64 Git.

### Timings

Windows values pool 30 startup samples from the three accepted runs.

| Metric | Windows preseeded E2E | WSL ext4 E2E |
|---|---:|---:|
| Setup to functional readiness | 42.593986 s median, 2.448327 s IQR, 46.595126 s p95 | 14.057939 s |
| Empty startup | 0.090931 s median, 0.005065 s IQR, 0.103671 s p95 | 0.032234 s median |
| File startup | 0.373022 s median, 0.017273 s IQR, 0.415801 s p95 | 0.114694 s median |
| No-op maintenance | 0.130301 s median | 0.208606 s |

The Windows setup samples are `46.595126`, `42.593986`, and `41.698472`
seconds. They include shell-free frozen plugin materialization plus online Mason
assets and parser grammars. They must not be compared with a normal clean online
plugin install.

The supported-default Windows control remains an expected failure: four
`win_arm64` Mason targets were missing. The earlier tree-sitter-only lane was a
partial pass. The complete E2E lane resolves those correctness blockers through
the immutable forks and E2E-only registry.

Plugin-bootstrap performance was not targeted by this blocker-first scope.

### WSL placement

Only `runs/wsl-arm64-e2e-regression/repetition-3` is accepted. Its harness,
fixtures, component clones, Git cache, Neovim, config, data, state, cache,
project, compiler, and tools were all under `/root` or `/usr` on `/dev/sdd`
ext4. `WSL_INTEROP` and `WSLENV` were unset. The runner's `/proc/<pid>/cwd` was
`/root/lazyvim-arm64-e2e-src-20260812-final`.

Repetitions 1 and 2 are preserved under `runs/wsl-arm64-e2e-regression/excluded/`
because their parent shell inherited a `/mnt/c` working directory.

### Evidence

- `runs/win-arm64-e2e-final/preseeded-repetition-{2,3,4}/`: accepted Windows
  summaries, raw samples, logs, receipts, traces, and architecture inventories.
- `runs/win-arm64-e2e-final/excluded/`: all rejected Windows attempts, including
  the traced online HTTPS attempt.
- `runs/wsl-arm64-e2e-regression/repetition-3/`: accepted WSL regression and
  placement validation.
- `runs/wsl-arm64-e2e-regression/excluded/`: contaminated WSL attempts.
- `integrity.json`: frozen harness, old controls, components, assets, and new
  evidence hashes.

Use `run_lane.py` directly or `run-windows.ps1` for a new uniquely named Windows
run. A WSL run must first copy the hash-verified harness under `/root`; never run
it from `/mnt/c`.
