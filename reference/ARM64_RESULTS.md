# LazyVim Windows ARM64 E2E

> Historical native ARM64 evidence captured before the x64 `vcvarsall.bat`
> quoting follow-up. Use the current immutable pins in `../manifest.json` for
> new runs. The follow-up commit preserves the validated ARM64 behavior.

## Outcome

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

Machine-readable results are in [`results.json`](results.json).

## Immutable inputs

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

## Accepted gates

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

## Timings

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

## WSL placement

Only `runs/wsl-arm64-e2e-regression/repetition-3` is accepted. Its harness,
fixtures, component clones, Git cache, Neovim, config, data, state, cache,
project, compiler, and tools were all under `/root` or `/usr` on `/dev/sdd`
ext4. `WSL_INTEROP` and `WSLENV` were unset. The runner's `/proc/<pid>/cwd` was
`/root/lazyvim-arm64-e2e-src-20260812-final`.

Repetitions 1 and 2 are preserved under `runs/wsl-arm64-e2e-regression/excluded/`
because their parent shell inherited a `/mnt/c` working directory.

## Evidence

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
