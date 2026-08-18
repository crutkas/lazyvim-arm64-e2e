[CmdletBinding()]
param(
    [ValidateSet("Fork", "Control")]
    [string]$Profile = "Fork",
    [string]$RunId,
    [int]$Runs = 10,
    [int]$Warmups = 3,
    [string]$WorkRoot = "C:\lvb-a64",
    [string]$ToolRoot = "C:\lvb-a64-tools"
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

function Assert-Arm64Pe {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Name is missing: $Path"
    }
    $machine = Get-PeMachine -Path $Path
    if ($machine -ne 0xAA64) {
        throw "$Name must be a native ARM64 PE (0xAA64); got $('0x{0:X4}' -f $machine): $Path"
    }
}

function Assert-FileHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "$Name SHA-256 mismatch. Expected $ExpectedSha256, got $actual."
    }
}

function Test-CheckedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][pscustomobject]$Spec
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $file = Get-Item -LiteralPath $Path
    if ($file.Length -ne [int64]$Spec.bytes) {
        throw "Size mismatch for cached download $Path."
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Spec.sha256.ToLowerInvariant()) {
        throw "SHA-256 mismatch for cached download $Path. Expected $($Spec.sha256), got $actual."
    }
    return $true
}

function Download-Checked {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Spec,
        [Parameter(Mandatory = $true)][string]$Directory
    )
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $path = Join-Path $Directory $Spec.archive
    if (-not (Test-CheckedFile -Path $path -Spec $Spec)) {
        $temporary = "$path.$([guid]::NewGuid().ToString('N')).partial"
        try {
            Write-Host "Downloading $($Spec.url)"
            try {
                Invoke-WebRequest -Uri $Spec.url -OutFile $temporary -UseBasicParsing
            }
            catch {
                $curl = Join-Path $env:SystemRoot "System32\curl.exe"
                Assert-Arm64Pe -Path $curl -Name "Windows curl"
                & $curl --fail --location --retry 3 --output $temporary $Spec.url
                if ($LASTEXITCODE -ne 0) {
                    throw "Both PowerShell and native curl failed to download $($Spec.url)"
                }
            }
            if (-not (Test-CheckedFile -Path $temporary -Spec $Spec)) {
                throw "Downloaded file did not pass validation: $temporary"
            }
            Move-Item -LiteralPath $temporary -Destination $path
        }
        finally {
            if (Test-Path -LiteralPath $temporary) {
                Remove-Item -LiteralPath $temporary -Force
            }
        }
    }
    return $path
}

function Expand-ZipChecked {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Sentinel
    )
    if (-not (Test-Path -LiteralPath $Sentinel -PathType Leaf)) {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
        Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force
    }
    if (-not (Test-Path -LiteralPath $Sentinel -PathType Leaf)) {
        throw "Archive extraction did not produce $Sentinel"
    }
}

function Get-FileRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    Assert-Arm64Pe -Path $Path -Name $Name
    $file = Get-Item -LiteralPath $Path
    return [ordered]@{
        name = $Name
        path = $file.FullName
        bytes = $file.Length
        pe_machine = "0xAA64"
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$processArch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
if ($osArch -ne "Arm64" -or $processArch -ne "Arm64") {
    throw "This suite requires native ARM64 Windows. OS=$osArch Process=$processArch"
}
if ($Runs -lt 2 -or $Warmups -lt 0) {
    throw "Runs must be >= 2 and Warmups must be >= 0."
}
if (-not $RunId) {
    $RunId = "win-a64-$($Profile.ToLowerInvariant())-" + (Get-Date -Format "yyyyMMdd-HHmmss")
}
if ($RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,47}$') {
    throw "RunId must be 1-48 safe filename characters."
}

$repo = $PSScriptRoot
$tools = Get-Content (Join-Path $repo "tools.json") -Raw | ConvertFrom-Json
$manifest = Get-Content (Join-Path $repo "manifest.json") -Raw | ConvertFrom-Json
$arm64 = $tools.windows_arm64
$downloads = Join-Path $ToolRoot "downloads"
$expanded = Join-Path (Join-Path $ToolRoot "runs") $RunId
$sources = Join-Path $ToolRoot "sources"
$gitCache = Join-Path $ToolRoot "git-cache"
$runRoot = Join-Path (Join-Path $WorkRoot "r") $RunId
$evidence = Join-Path (Join-Path $repo "out") $RunId
$provisioning = Join-Path (Join-Path $repo "out") "$RunId-provisioning"
$support = Join-Path $runRoot "support"

foreach ($path in ($runRoot, $evidence, $provisioning, $expanded)) {
    if (Test-Path -LiteralPath $path) {
        throw "Run path already exists: $path"
    }
}
New-Item -ItemType Directory -Force -Path $downloads, $expanded, $sources, $gitCache, $provisioning | Out-Null

$gitArchive = Download-Checked -Spec $arm64.git -Directory $downloads
$gitRoot = Join-Path $expanded "mingit-$($arm64.git.version)-arm64"
$git = Join-Path $gitRoot "cmd\git.exe"
Expand-ZipChecked -Archive $gitArchive -Destination $gitRoot -Sentinel $git
Assert-Arm64Pe -Path $git -Name "Git"
Assert-FileHash -Path $git -ExpectedSha256 $arm64.git.binary_sha256 -Name "Git"
$gitBuild = (& $git --version --build-options) -join "`n"
if ($LASTEXITCODE -ne 0 -or $gitBuild -notmatch 'cpu:\s*aarch64') {
    throw "Provisioned Git did not report an aarch64 build."
}
$trace = Join-Path $provisioning "git-trace.jsonl"

$pythonArchive = Download-Checked -Spec $arm64.python -Directory $downloads
$pythonRoot = Join-Path $expanded "python-$($arm64.python.version)-arm64"
$python = Join-Path $pythonRoot "python.exe"
Expand-ZipChecked -Archive $pythonArchive -Destination $pythonRoot -Sentinel $python
Assert-Arm64Pe -Path $python -Name "Python"
Assert-FileHash -Path $python -ExpectedSha256 $arm64.python.binary_sha256 -Name "Python"

$sitePackages = Join-Path $pythonRoot "Lib\site-packages"
$pyyamlSource = Join-Path $sources "support\PyYAML-$($arm64.pyyaml.version)"
$previousTrace = $env:GIT_TRACE2_EVENT
try {
    $env:GIT_TRACE2_EVENT = $trace
    if (-not (Test-Path -LiteralPath (Join-Path $pyyamlSource ".git"))) {
        if (Test-Path -LiteralPath $pyyamlSource) {
            throw "PyYAML source path exists but is not a Git checkout: $pyyamlSource"
        }
        New-Item -ItemType Directory -Force -Path $pyyamlSource | Out-Null
        & $git -C $pyyamlSource init --quiet
        & $git -C $pyyamlSource remote add origin $arm64.pyyaml.repository
    }
    $origin = (& $git -C $pyyamlSource remote get-url origin).Trim()
    if ($origin -ne $arm64.pyyaml.repository) {
        throw "PyYAML source has an unexpected origin: $origin"
    }
    & $git -C $pyyamlSource cat-file -e "$($arm64.pyyaml.commit)^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) {
        & $git -C $pyyamlSource fetch --force --no-tags --depth 1 origin $arm64.pyyaml.commit
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to fetch the pinned PyYAML commit."
        }
    }
    & $git -C $pyyamlSource checkout --force --detach $arm64.pyyaml.commit
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to check out the pinned PyYAML commit."
    }
    $pyyamlHead = (& $git -C $pyyamlSource rev-parse HEAD).Trim()
    $pyyamlStatus = (& $git -C $pyyamlSource status --porcelain --untracked-files=all) -join "`n"
    if ($pyyamlHead -ne $arm64.pyyaml.commit -or $pyyamlStatus) {
        throw "PyYAML source is not the exact clean pinned checkout."
    }
}
finally {
    if ($null -eq $previousTrace) {
        Remove-Item Env:GIT_TRACE2_EVENT -ErrorAction SilentlyContinue
    }
    else {
        $env:GIT_TRACE2_EVENT = $previousTrace
    }
}
New-Item -ItemType Directory -Force -Path $sitePackages | Out-Null
$installedYaml = Join-Path $sitePackages "yaml"
if (Test-Path -LiteralPath $installedYaml) {
    Remove-Item -LiteralPath $installedYaml -Recurse -Force
}
$trackedYamlFiles = @(& $git -C $pyyamlSource ls-files -- "lib/yaml")
if ($LASTEXITCODE -ne 0 -or $trackedYamlFiles.Count -eq 0) {
    throw "Could not enumerate the pinned PyYAML package files."
}
foreach ($relativePath in $trackedYamlFiles) {
    $windowsRelativePath = $relativePath.Replace("/", "\")
    $sourceFile = Join-Path $pyyamlSource $windowsRelativePath
    $siteRelativePath = $windowsRelativePath.Substring("lib\".Length)
    $destinationFile = Join-Path $sitePackages $siteRelativePath
    New-Item -ItemType Directory -Force -Path (Split-Path $destinationFile -Parent) | Out-Null
    Copy-Item -LiteralPath $sourceFile -Destination $destinationFile
}
$pth = Get-ChildItem -LiteralPath $pythonRoot -File -Filter "python*._pth" | Select-Object -First 1
if (-not $pth) {
    throw "Embedded Python path configuration is missing."
}
$pthLines = @(Get-Content -LiteralPath $pth.FullName)
$pthLines = @($pthLines | ForEach-Object { if ($_ -eq "#import site") { "import site" } else { $_ } })
if ($pthLines -notcontains "Lib\site-packages") {
    $pthLines += "Lib\site-packages"
}
$pthLines | Set-Content -LiteralPath $pth.FullName -Encoding ascii
$pythonIdentity = (& $python -c "import platform, yaml; print(platform.machine()); print(yaml.__version__)") -join "`n"
if ($LASTEXITCODE -ne 0 -or $pythonIdentity -notmatch '(?im)^ARM64$' -or $pythonIdentity -notmatch '(?im)^6\.0\.3$') {
    throw "Provisioned Python/PyYAML support failed its native execution check."
}

$nvimArchive = Download-Checked -Spec $arm64.neovim -Directory $downloads
$nvimRoot = Join-Path $expanded "neovim-$($arm64.neovim.version)-arm64"
$nvim = Join-Path $nvimRoot "nvim-win-arm64\bin\nvim.exe"
Expand-ZipChecked -Archive $nvimArchive -Destination $nvimRoot -Sentinel $nvim
Assert-Arm64Pe -Path $nvim -Name "Neovim"
Assert-FileHash -Path $nvim -ExpectedSha256 $arm64.neovim.binary_sha256 -Name "Neovim"

$llvmArchive = Download-Checked -Spec $arm64.llvm_mingw -Directory $downloads
$llvmRoot = Join-Path $expanded "llvm-mingw-$($arm64.llvm_mingw.version)-arm64"
$compilerBin = Get-ChildItem -LiteralPath $llvmRoot -Recurse -File -Filter "aarch64-w64-mingw32-gcc.exe" -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty DirectoryName
if (-not $compilerBin) {
    New-Item -ItemType Directory -Force -Path $llvmRoot | Out-Null
    Expand-Archive -LiteralPath $llvmArchive -DestinationPath $llvmRoot -Force
    $compilerBin = Get-ChildItem -LiteralPath $llvmRoot -Recurse -File -Filter "aarch64-w64-mingw32-gcc.exe" |
        Select-Object -First 1 -ExpandProperty DirectoryName
}
$compiler = Join-Path $compilerBin "aarch64-w64-mingw32-gcc.exe"
Assert-Arm64Pe -Path $compiler -Name "LLVM-MinGW compiler"
Assert-FileHash -Path $compiler -ExpectedSha256 $arm64.llvm_mingw.binary_sha256 -Name "LLVM-MinGW compiler"

$inputsPath = Join-Path $provisioning "inputs.json"
$registryKind = if ($Profile -eq "Fork") { "fork" } else { "upstream" }
$previousTrace = $env:GIT_TRACE2_EVENT
try {
    $env:GIT_TRACE2_EVENT = $trace
    & $python (Join-Path $repo "harness\prepare_inputs.py") `
        --profile $Profile.ToLowerInvariant() `
        --registry $registryKind `
        --git $git `
        --source-root $sources `
        --git-cache $gitCache `
        --output $inputsPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to prepare exact component sources and frozen Git objects."
    }
}
finally {
    if ($null -eq $previousTrace) {
        Remove-Item Env:GIT_TRACE2_EVENT -ErrorAction SilentlyContinue
    }
    else {
        $env:GIT_TRACE2_EVENT = $previousTrace
    }
}

$inputs = Get-Content -LiteralPath $inputsPath -Raw | ConvertFrom-Json
$registryPath = $inputs.checkouts.registry.path.Replace("\", "/")
$registry = "file:$registryPath"
$toolchain = [ordered]@{
    schema_version = 1
    run_id = $RunId
    host = [ordered]@{
        os_architecture = $osArch
        process_architecture = $processArch
        powershell = $PSVersionTable.PSVersion.ToString()
        powershell_path = (Get-Process -Id $PID).Path
    }
    pins = [ordered]@{
        lazyvim = $inputs.checkouts.lazyvim.commit
        nvim_treesitter = $inputs.checkouts.treesitter.commit
        mason_registry = if ($Profile -eq "Fork") {
            $manifest.components."mason-registry".e2e_commit
        }
        else {
            $tools.mason_registry_commit
        }
    }
    archives = [ordered]@{
        git = $arm64.git
        llvm_mingw = $arm64.llvm_mingw
        neovim = $arm64.neovim
        python = $arm64.python
        pyyaml = $arm64.pyyaml
    }
    binaries = @(
        (Get-FileRecord -Path $git -Name "Git"),
        (Get-FileRecord -Path $python -Name "Python"),
        (Get-FileRecord -Path $nvim -Name "Neovim"),
        (Get-FileRecord -Path $compiler -Name "LLVM-MinGW compiler")
    )
    git_build = $gitBuild
    python_identity = $pythonIdentity
}
$toolchain | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $provisioning "toolchain.json") -Encoding utf8

$masonArtifactValidation = $null
if ($Profile -eq "Fork") {
    $artifactDirectory = Join-Path $provisioning "arm64-artifacts"
    & (Join-Path $repo "verify-arm64-artifacts.ps1") -OutputDirectory $artifactDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "Pinned ARM64 Mason artifact validation failed."
    }
    $masonArtifactValidation = Join-Path $artifactDirectory "artifact-validation.json"
    if (-not (Test-Path -LiteralPath $masonArtifactValidation -PathType Leaf)) {
        throw "ARM64 Mason artifact validation did not produce its receipt."
    }
}

$arguments = @(
    (Join-Path $repo "harness\run_lane.py"),
    "--lane", "windows",
    "--profile", $Profile.ToLowerInvariant(),
    "--label", $RunId,
    "--plugin-source-mode", "preseeded",
    "--network-retries", "2",
    "--expected-architecture", "arm64",
    "--work-root", $runRoot,
    "--evidence-dir", $evidence,
    "--nvim", $nvim,
    "--git", $git,
    "--git-cache", $gitCache,
    "--starter-source", $inputs.checkouts.starter.path,
    "--lazyvim-source", $inputs.checkouts.lazyvim.path,
    "--treesitter-source", $inputs.checkouts.treesitter.path,
    "--mason-registry", $registry,
    "--mason-target", "win_arm64",
    "--compiler-bin", $compilerBin,
    "--support-bin", $support,
    "--runs", $Runs,
    "--warmups", $Warmups,
    "--timeout", "900",
    "--distribution-diagnostics",
    "--additional-git-trace", $trace,
    "--forbid-shell"
)
if ($masonArtifactValidation) {
    $arguments += @("--mason-artifact-validation", $masonArtifactValidation)
}

& $python @arguments *> (Join-Path $provisioning "runner.log")
$laneExit = $LASTEXITCODE
if (-not (Test-Path -LiteralPath (Join-Path $evidence "summary.json"))) {
    throw "The lane did not produce a summary. See $provisioning."
}
$summary = Get-Content (Join-Path $evidence "summary.json") -Raw | ConvertFrom-Json

if ($Profile -eq "Control") {
    $masonProperty = $summary.PSObject.Properties["mason"]
    $masonResults = if ($masonProperty -and $null -ne $masonProperty.Value) {
        @($masonProperty.Value.results.PSObject.Properties | ForEach-Object { $_ })
    }
    else {
        @()
    }
    $failedPackages = @($masonResults | Where-Object { $_.Value.success -ne $true })
    $expectedPackages = @("lua-language-server", "shfmt", "stylua", "tree-sitter-cli")
    $failedNames = @($failedPackages.Name | Sort-Object)
    $fatalProperty = $summary.mason.PSObject.Properties["fatal"]
    $fatal = if ($fatalProperty) { $fatalProperty.Value } else { $null }
    $expected = (
        $laneExit -ne 0 -and
        $summary.result -eq "failed" -and
        $summary.plugin_gate.passed -eq $true -and
        $summary.mason.completed -eq $true -and
        $null -eq $fatal -and
        $summary.mason.target -eq "win_arm64" -and
        $masonResults.Count -eq 4 -and
        $failedPackages.Count -eq 4 -and
        ($failedNames -join "`n") -eq (($expectedPackages | Sort-Object) -join "`n") -and
        @($failedPackages | Where-Object {
            $_.Value.installed -ne $false -or
            $_.Value.error -ne 'Platform "win_arm64" is unsupported.'
        }).Count -eq 0 -and
        $summary.git_execution.passed -eq $true -and
        $summary.git_execution.shell_ancestry_count -eq 0 -and
        $summary.git_execution.shell_child_count -eq 0 -and
        $summary.git_execution.wrong_architecture_count -eq 0 -and
        $summary.error -match 'Mason win_arm64 gate failed'
    )
    $controlResult = [ordered]@{
        schema_version = 1
        run_id = $RunId
        expected_failure = $expected
        profile = "control"
        exact_plugins = $summary.plugin_gate.valid
        mason_target = $summary.mason.target
        failed_packages = @($failedPackages | ForEach-Object {
            [ordered]@{
                name = $_.Name
                error = $_.Value.error
                installed = $_.Value.installed
            }
        })
        git_execution = $summary.git_execution
        summary = $summary.paths.evidence_dir
    }
    $controlResult | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $evidence "control-result.json") -Encoding utf8
    if (-not $expected) {
        throw "The supported-default control did not fail in the expected four Mason targets."
    }
    Write-Host "Supported-default Windows ARM64 control preserved its expected failure: $evidence"
    exit 0
}

if ($laneExit -ne 0 -or $summary.result -ne "passed") {
    throw "LazyVim Windows ARM64 fork E2E failed. See $evidence."
}
$masonPassed = @($summary.mason.results.PSObject.Properties | Where-Object { $_.Value.success -eq $true }).Count
$accepted = (
    $summary.plugin_gate.valid -eq 32 -and
    $masonPassed -eq 4 -and
    $summary.architecture.passed -eq $true -and
    $summary.architecture.parser_count -eq 24 -and
    $summary.architecture.parser_native_count -eq 24 -and
    $summary.git_execution.passed -eq $true -and
    $summary.git_execution.shell_ancestry_count -eq 0 -and
    $summary.git_execution.shell_child_count -eq 0 -and
    $summary.git_execution.wrong_architecture_count -eq 0 -and
    $summary.lsp.protocol.success -eq $true -and
    $summary.lsp.attachment.attached -eq $true -and
    $summary.tool_execution.passed -eq $true
)
if (-not $accepted) {
    throw "The summary did not satisfy every Windows ARM64 acceptance gate."
}
$result = [ordered]@{
    schema_version = 1
    run_id = $RunId
    passed = $true
    profile = "fork"
    result_class = "preseeded-frozen-object-correctness"
    normal_online_plugin_install_timing = $null
    exact_plugins = $summary.plugin_gate.valid
    mason_packages = $masonPassed
    native_parsers = $summary.architecture.parser_native_count
    setup_to_readiness_seconds = $summary.setup_to_readiness_seconds
    empty_startup = $summary.startup.empty
    file_startup = $summary.startup.file
    maintenance = $summary.maintenance
    evidence = $evidence
    provisioning_evidence = $provisioning
}
$result | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $evidence "windows-arm64-result.json") -Encoding utf8

Write-Host "LazyVim Windows ARM64 fork E2E passed: $evidence"
