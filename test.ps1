[CmdletBinding()]
param(
    [string]$RunId = ("x64-" + (Get-Date -Format "yyyyMMdd-HHmmss")),
    [int]$Runs = 3,
    [int]$Warmups = 1,
    [string]$WorkRoot = "C:\lvb-x64-e2e",
    [switch]$SkipArm64Artifacts,
    [switch]$DistributionDiagnostics
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-PeMachine {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $reader = [System.IO.BinaryReader]::new($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) {
            return $null
        }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadUInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            return $null
        }
        return $reader.ReadUInt16()
    }
    finally {
        $stream.Dispose()
    }
}

function Assert-X64Pe {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $machine = Get-PeMachine -Path $Path
    if ($machine -ne 0x8664) {
        throw "$Name must be a native x64 PE (0x8664); got $('0x{0:X4}' -f $machine): $Path"
    }
}

function Download-Checked {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Spec,
        [Parameter(Mandatory = $true)][string]$Directory
    )
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $path = Join-Path $Directory $Spec.archive
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "Downloading $($Spec.url)"
        Invoke-WebRequest -Uri $Spec.url -OutFile $path -UseBasicParsing
    }
    $file = Get-Item -LiteralPath $path
    if ($file.Length -ne [int64]$Spec.bytes) {
        throw "Size mismatch for $path."
    }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Spec.sha256) {
        throw "SHA-256 mismatch for $path. Expected $($Spec.sha256), got $actual."
    }
    return $path
}

function Checkout-Commit {
    param(
        [Parameter(Mandatory = $true)][string]$Git,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath (Join-Path $Destination ".git"))) {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
        & $Git -C $Destination init --quiet
        & $Git -C $Destination remote add origin $Url
    }
    & $Git -C $Destination fetch --force --no-tags --depth 1 origin $Commit
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to fetch $Url@$Commit"
    }
    & $Git -C $Destination checkout --force --detach $Commit
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to check out $Url@$Commit"
    }
    $head = (& $Git -C $Destination rev-parse HEAD).Trim()
    $dirty = (& $Git -C $Destination status --porcelain)
    if ($head -ne $Commit -or $dirty) {
        throw "Source checkout is not exact and clean: $Destination"
    }
}

$osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$processArch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
if ($osArch -ne "X64" -or $processArch -ne "X64") {
    throw "This suite requires native x64 Windows. OS=$osArch Process=$processArch"
}
if ($Runs -lt 2 -or $Warmups -lt 0) {
    throw "Runs must be >= 2 and Warmups must be >= 0."
}

$repo = $PSScriptRoot
$tools = Get-Content (Join-Path $repo "tools.json") -Raw | ConvertFrom-Json
$manifest = Get-Content (Join-Path $repo "manifest.json") -Raw | ConvertFrom-Json
$downloads = Join-Path $WorkRoot "downloads"
$expanded = Join-Path $WorkRoot "tools"
$sources = Join-Path $WorkRoot "sources"
$runRoot = Join-Path $WorkRoot "runs\$RunId"
$evidence = Join-Path $repo "out\$RunId"
$support = Join-Path $runRoot "support"
$emptyCache = Join-Path $WorkRoot "empty-git-cache"

foreach ($path in ($runRoot, $evidence)) {
    if (Test-Path -LiteralPath $path) {
        throw "Run path already exists: $path"
    }
}
New-Item -ItemType Directory -Force -Path $downloads, $expanded, $sources, $emptyCache | Out-Null

$git = (Get-Command git.exe -ErrorAction Stop).Source
Assert-X64Pe -Path $git -Name "Git"

$python = (Get-Command python.exe -ErrorAction Stop).Source
Assert-X64Pe -Path $python -Name "Python"
$pythonMachine = (& $python -c "import platform; print(platform.machine())").Trim().ToLowerInvariant()
if ($pythonMachine -notin @("amd64", "x86_64")) {
    throw "Python reports unexpected architecture: $pythonMachine"
}

$venv = Join-Path $WorkRoot ".venv"
$venvPython = Join-Path $venv "Scripts\python.exe"
if (-not (Test-Path -LiteralPath $venvPython)) {
    & $python -m venv $venv
}
& $venvPython -m pip install --disable-pip-version-check --quiet -r (Join-Path $repo "requirements.txt")
if ($LASTEXITCODE -ne 0) {
    throw "Failed to install Python requirements."
}

$nvimArchive = Download-Checked -Spec $tools.neovim -Directory $downloads
$nvimRoot = Join-Path $expanded "neovim-$($tools.neovim.version)"
$nvim = Join-Path $nvimRoot "nvim-win64\bin\nvim.exe"
if (-not (Test-Path -LiteralPath $nvim)) {
    New-Item -ItemType Directory -Force -Path $nvimRoot | Out-Null
    Expand-Archive -LiteralPath $nvimArchive -DestinationPath $nvimRoot
}
Assert-X64Pe -Path $nvim -Name "Neovim"

$llvmArchive = Download-Checked -Spec $tools.llvm_mingw -Directory $downloads
$llvmRoot = Join-Path $expanded "llvm-mingw-$($tools.llvm_mingw.version)"
$compilerBin = Get-ChildItem -LiteralPath $llvmRoot -Recurse -File -Filter "x86_64-w64-mingw32-gcc.exe" -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty DirectoryName
if (-not $compilerBin) {
    New-Item -ItemType Directory -Force -Path $llvmRoot | Out-Null
    Expand-Archive -LiteralPath $llvmArchive -DestinationPath $llvmRoot
    $compilerBin = Get-ChildItem -LiteralPath $llvmRoot -Recurse -File -Filter "x86_64-w64-mingw32-gcc.exe" |
        Select-Object -First 1 -ExpandProperty DirectoryName
}
$compiler = Join-Path $compilerBin "x86_64-w64-mingw32-gcc.exe"
Assert-X64Pe -Path $compiler -Name "LLVM-MinGW compiler"

$starter = Join-Path $sources "starter"
$lazyvim = Join-Path $sources "LazyVim"
$treesitter = Join-Path $sources "nvim-treesitter"
Checkout-Commit -Git $git -Url "https://github.com/LazyVim/starter.git" -Commit "803bc181d7c0d6d5eeba9274d9be49b287294d99" -Destination $starter
Checkout-Commit -Git $git -Url "https://github.com/crutkas/LazyVim.git" -Commit $manifest.components.lazyvim.commit -Destination $lazyvim
Checkout-Commit -Git $git -Url "https://github.com/crutkas/nvim-treesitter.git" -Commit $manifest.components."nvim-treesitter".commit -Destination $treesitter

if (-not $SkipArm64Artifacts) {
    & (Join-Path $repo "verify-arm64-artifacts.ps1") -OutputDirectory (Join-Path $repo "out\$RunId-arm64-artifacts")
}

$arguments = @(
    (Join-Path $repo "harness\run_lane.py"),
    "--lane", "windows",
    "--label", $RunId,
    "--plugin-source-mode", "online",
    "--network-retries", "2",
    "--expected-architecture", "x64",
    "--work-root", $runRoot,
    "--evidence-dir", $evidence,
    "--nvim", $nvim,
    "--git", $git,
    "--git-cache", $emptyCache,
    "--starter-source", $starter,
    "--lazyvim-source", $lazyvim,
    "--treesitter-source", $treesitter,
    "--mason-registry", $tools.mason_registry,
    "--mason-target", "win_x64",
    "--compiler-bin", $compilerBin,
    "--support-bin", $support,
    "--runs", $Runs,
    "--warmups", $Warmups,
    "--timeout", "900"
)
if ($DistributionDiagnostics) {
    $arguments += "--distribution-diagnostics"
}

& $venvPython @arguments
if ($LASTEXITCODE -ne 0) {
    throw "LazyVim x64 ecosystem validation failed. See $evidence."
}

$summary = Get-Content (Join-Path $evidence "summary.json") -Raw | ConvertFrom-Json
if ($summary.result -ne "passed") {
    throw "The runner did not produce a passing summary."
}

$result = [ordered]@{
    schema_version = 1
    run_id = $RunId
    passed = $true
    host = [ordered]@{ os = $osArch; process = $processArch }
    exact_plugins = $summary.plugin_gate.valid
    mason_packages = @($summary.mason.results.PSObject.Properties.Name)
    parser_count = $summary.architecture.parser_count
    native_parser_count = $summary.architecture.parser_native_count
    setup_to_readiness_seconds = $summary.setup_to_readiness_seconds
    empty_startup = $summary.startup.empty
    file_startup = $summary.startup.file
    evidence = $evidence
}
$result | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $evidence "x64-result.json") -Encoding utf8

Write-Host ""
Write-Host "LazyVim x64 ecosystem validation passed."
Write-Host "  Plugins: $($summary.plugin_gate.valid)/32"
Write-Host "  Mason tools: 4/4"
Write-Host "  Parsers: $($summary.architecture.parser_native_count)/$($summary.architecture.parser_count) native x64"
Write-Host "  LuaLS protocol and LazyVim attachment: passed"
Write-Host "  Evidence: $evidence"
