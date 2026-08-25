[CmdletBinding()]
param(
    [switch]$ResetProfile,
    [switch]$InstallCompiler,
    [switch]$SkipFont,
    [switch]$SkipPackages,
    [switch]$NoLaunch
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
        throw "$Name must be native ARM64 PE 0xAA64; got $('0x{0:X4}' -f $machine): $Path"
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$Capture
    )
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& $FilePath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "$FilePath failed with exit code $exitCode`n$($output -join "`n")"
    }
    if ($Capture) {
        return ($output -join "`n").Trim()
    }
}

function Download-Checked {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Spec,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $parent = Split-Path $Destination -Parent
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $valid = Test-Path -LiteralPath $Destination -PathType Leaf
    if ($valid) {
        $file = Get-Item -LiteralPath $Destination
        $hash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
        $valid = (
            $file.Length -eq [int64]$Spec.bytes -and
            $hash -eq $Spec.sha256
        )
    }
    if (-not $valid) {
        $temporary = "$Destination.$([guid]::NewGuid().ToString('N')).partial"
        try {
            Write-Host "Downloading native ARM64 yq"
            Invoke-WebRequest -Uri $Spec.url -OutFile $temporary -UseBasicParsing
            $file = Get-Item -LiteralPath $temporary
            $hash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash
            if (
                $file.Length -ne [int64]$Spec.bytes -or
                $hash -ne $Spec.sha256
            ) {
                throw "Downloaded yq did not match its pinned size and SHA-256."
            }
            Move-Item -LiteralPath $temporary -Destination $Destination -Force
        }
        finally {
            if (Test-Path -LiteralPath $temporary) {
                Remove-Item -LiteralPath $temporary -Force
            }
        }
    }
    Assert-Arm64Pe -Path $Destination -Name "yq"
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Version,
        [string]$Architecture
    )
    $arguments = @(
        "install",
        "--id", $Id,
        "--exact",
        "--source", "winget",
        "--accept-package-agreements",
        "--accept-source-agreements"
    )
    if ($Version) {
        $arguments += @("--version", $Version)
    }
    if ($Architecture) {
        $arguments += @("--architecture", $Architecture)
    }
    Write-Host "Installing $Id$(if ($Version) { " $Version" }) with Winget"
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & winget.exe @arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "Winget failed to install $Id with exit code $exitCode."
    }
}

function Test-WingetPackageInstalled {
    param([Parameter(Mandatory = $true)][string]$Id)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & winget.exe list --id $Id --exact --source winget `
            --accept-source-agreements *> $null
        return $LASTEXITCODE -eq 0
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Test-NvimMinimumVersion {
    param([Parameter(Mandatory = $true)][string]$Path)
    $version = Invoke-Native -FilePath $Path -Arguments @("--version") -Capture
    if ($version -notmatch '(?m)^NVIM v(\d+)\.(\d+)\.(\d+)') {
        return $false
    }
    $observed = [Version]::new(
        [int]$Matches[1],
        [int]$Matches[2],
        [int]$Matches[3]
    )
    return $observed -ge [Version]::new(0, 12, 4)
}

function Update-ProcessPath {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = @($machine, $user) -join ";"
}

function Find-NativeTool {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Candidates,
        [switch]$Optional
    )
    foreach ($candidate in $Candidates) {
        if (-not $candidate) {
            continue
        }
        $resolved = $candidate
        if (-not [System.IO.Path]::IsPathRooted($candidate)) {
            $command = Get-Command $candidate -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $command) {
                continue
            }
            $resolved = $command.Source
        }
        if (Test-Path -LiteralPath $resolved -PathType Leaf) {
            if ((Get-PeMachine -Path $resolved) -eq 0xAA64) {
                return [System.IO.Path]::GetFullPath($resolved)
            }
        }
    }
    if ($Optional) {
        return $null
    }
    throw "Could not find native ARM64 $Name."
}

function Read-ManagedMarker {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-Utf8Json {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )
    $json = $Value | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText(
        $Path,
        $json + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Invoke-IsolatedGit {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$EmptyConfig
    )
    $saved = @{}
    Get-ChildItem Env: | Where-Object { $_.Name -like "GIT_*" } |
        ForEach-Object { $saved[$_.Name] = $_.Value }
    try {
        Get-ChildItem Env: | Where-Object { $_.Name -like "GIT_*" } |
            ForEach-Object {
                Remove-Item -Path "Env:$($_.Name)" -ErrorAction SilentlyContinue
            }
        $env:GIT_CONFIG_GLOBAL = $EmptyConfig
        $env:GIT_CONFIG_NOSYSTEM = "1"
        $env:GIT_TERMINAL_PROMPT = "0"
        & $Action
    }
    finally {
        Get-ChildItem Env: | Where-Object { $_.Name -like "GIT_*" } |
            ForEach-Object {
                Remove-Item -Path "Env:$($_.Name)" -ErrorAction SilentlyContinue
            }
        foreach ($name in $saved.Keys) {
            Set-Item -Path "Env:$name" -Value $saved[$name]
        }
    }
}

$osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$processArch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
if ($osArch -ne "Arm64" -or $processArch -ne "Arm64") {
    throw "This setup requires native ARM64 Windows PowerShell. OS=$osArch Process=$processArch"
}

$repo = $PSScriptRoot
$manifest = Get-Content (Join-Path $repo "manifest.json") -Raw | ConvertFrom-Json
$tools = Get-Content (Join-Path $repo "tools.json") -Raw | ConvertFrom-Json
$configDirectory = Join-Path $env:LOCALAPPDATA "nvim"
$dataDirectory = Join-Path $env:LOCALAPPDATA "nvim-data"
$supportRoot = Join-Path $env:LOCALAPPDATA "Programs\LazyVimARM64"
$supportBin = Join-Path $supportRoot "bin"
$yq = Join-Path $supportBin "yq.exe"
$registryDirectory = Join-Path $supportRoot "mason-registry"
$marker = Join-Path $configDirectory ".lazyvim-arm64-managed.json"
$emptyGitConfig = Join-Path $env:TEMP "lazyvim-arm64-empty-gitconfig"
[System.IO.File]::WriteAllText($emptyGitConfig, "", [System.Text.ASCIIEncoding]::new())
$programFiles = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::ProgramFiles
)

$managed = Read-ManagedMarker -Path $marker
if ($ResetProfile) {
    if (-not $managed) {
        throw "Refusing to reset an unmanaged Neovim profile: $configDirectory"
    }
    Remove-Item -LiteralPath $configDirectory -Recurse -Force
    if (Test-Path -LiteralPath $dataDirectory) {
        Remove-Item -LiteralPath $dataDirectory -Recurse -Force
    }
    $managed = $null
}
if ((Test-Path -LiteralPath $configDirectory) -and -not $managed) {
    $entries = @(Get-ChildItem -LiteralPath $configDirectory -Force)
    if ($entries.Count -ne 0) {
        throw @"
An existing unmanaged Neovim profile is present at:
  $configDirectory
Back it up or remove it before running this setup. Nothing was changed.
"@
    }
    Remove-Item -LiteralPath $configDirectory -Force
}
if ((Test-Path -LiteralPath $dataDirectory) -and -not $managed) {
    $entries = @(Get-ChildItem -LiteralPath $dataDirectory -Force)
    if ($entries.Count -ne 0) {
        throw @"
Existing unmanaged Neovim data is present at:
  $dataDirectory
Back it up or remove it before running this setup. Nothing was changed.
"@
    }
}

if (-not $SkipPackages) {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw "Winget is required to install native ARM64 prerequisites."
    }
    Update-ProcessPath
    $installedNvim = Find-NativeTool -Name "Neovim" -Optional -Candidates @(
        (Join-Path $programFiles "Neovim\bin\nvim.exe"),
        "nvim.exe"
    )
    if (-not $installedNvim -or -not (Test-NvimMinimumVersion -Path $installedNvim)) {
        Install-WingetPackage -Id "Neovim.Neovim" -Version "0.12.4" -Architecture "arm64"
    }
    $installedGit = Find-NativeTool -Name "Git" -Optional -Candidates @(
        (Join-Path $programFiles "Git\cmd\git.exe"),
        "git.exe"
    )
    if (-not $installedGit) {
        Install-WingetPackage -Id "Git.Git" -Architecture "arm64"
    }
    if (-not $SkipFont -and -not (Test-WingetPackageInstalled -Id "DEVCOM.JetBrainsMonoNerdFont")) {
        Install-WingetPackage -Id "DEVCOM.JetBrainsMonoNerdFont"
    }
    if ($InstallCompiler) {
        $installedCompiler = Find-NativeTool -Name "Clang" -Optional -Candidates @(
            (Join-Path $programFiles "LLVM\bin\clang.exe"),
            "clang.exe"
        )
        if (-not $installedCompiler) {
            Install-WingetPackage -Id "LLVM.LLVM" -Architecture "arm64"
        }
    }
    Update-ProcessPath
}

$nvim = Find-NativeTool -Name "Neovim" -Candidates @(
    (Join-Path $programFiles "Neovim\bin\nvim.exe"),
    "nvim.exe"
)
$git = Find-NativeTool -Name "Git" -Candidates @(
    (Join-Path $programFiles "Git\cmd\git.exe"),
    "git.exe"
)
$compiler = Find-NativeTool -Name "Clang" -Optional -Candidates @(
    (Join-Path $programFiles "LLVM\bin\clang.exe"),
    "clang.exe"
)
Assert-Arm64Pe -Path $nvim -Name "Neovim"
Assert-Arm64Pe -Path $git -Name "Git"
Download-Checked -Spec $tools.windows_arm64.yq -Destination $yq

if (-not (Test-NvimMinimumVersion -Path $nvim)) {
    $nvimVersion = Invoke-Native -FilePath $nvim -Arguments @("--version") -Capture
    throw "LazyVim ARM64 requires Neovim 0.12.4 or newer; found:`n$nvimVersion"
}
$gitBuild = Invoke-Native -FilePath $git -Arguments @("--version", "--build-options") -Capture
if ($gitBuild -notmatch '(?im)^cpu:\s*aarch64$') {
    throw "Git did not report a native aarch64 build."
}

$freshProfile = -not (Test-Path -LiteralPath $configDirectory)
if ($freshProfile) {
    Write-Host "Creating the standard LazyVim starter profile"
    $staging = "$configDirectory.installing-$([guid]::NewGuid().ToString('N'))"
    try {
        Invoke-IsolatedGit -EmptyConfig $emptyGitConfig -Action {
            Invoke-Native -FilePath $git -Arguments @(
                "clone",
                "--filter=blob:none",
                "--single-branch",
                "--branch", "main",
                "https://github.com/LazyVim/starter.git",
                $staging
            )
        }
        Remove-Item -LiteralPath (Join-Path $staging ".git") -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $repo "harness\lazy-lock-e2e.json") `
            -Destination (Join-Path $staging "lazy-lock.json")
        Move-Item -LiteralPath $staging -Destination $configDirectory
        Write-Utf8Json -Path $marker -Value ([ordered]@{
            schema_version = 2
            state = "installing"
            config = $configDirectory
            data = $dataDirectory
        })
    }
    finally {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force
        }
    }
}

$registryUrl = "https://github.com/$($manifest.components.'mason-registry'.repository).git"
$registryCommit = $manifest.components."mason-registry".e2e_commit
Write-Host "Preparing the native ARM64 Mason registry"
Invoke-IsolatedGit -EmptyConfig $emptyGitConfig -Action {
    if (-not (Test-Path -LiteralPath (Join-Path $registryDirectory ".git"))) {
        if (Test-Path -LiteralPath $registryDirectory) {
            Remove-Item -LiteralPath $registryDirectory -Recurse -Force
        }
        $registryStaging = "$registryDirectory.installing-$([guid]::NewGuid().ToString('N'))"
        try {
            Invoke-Native -FilePath $git -Arguments @(
                "clone",
                "--filter=blob:none",
                "--no-checkout",
                $registryUrl,
                $registryStaging
            )
            Invoke-Native -FilePath $git -Arguments @(
                "-C", $registryStaging,
                "checkout", "--quiet", "--force", "--detach", $registryCommit
            )
            Move-Item -LiteralPath $registryStaging -Destination $registryDirectory
        }
        finally {
            if (Test-Path -LiteralPath $registryStaging) {
                Remove-Item -LiteralPath $registryStaging -Recurse -Force
            }
        }
    }
    $origin = Invoke-Native -FilePath $git -Arguments @(
        "-C", $registryDirectory,
        "config", "--local", "--get", "remote.origin.url"
    ) -Capture
    if ($origin.TrimEnd("/") -ne $registryUrl.TrimEnd("/")) {
        throw "The local Mason registry has an unexpected origin: $origin"
    }
    Invoke-Native -FilePath $git -Arguments @(
        "-C", $registryDirectory,
        "fetch", "--quiet", "--force", "--no-tags", "origin", $registryCommit
    )
    Invoke-Native -FilePath $git -Arguments @(
        "-C", $registryDirectory,
        "checkout", "--quiet", "--force", "--detach", $registryCommit
    )
    Invoke-Native -FilePath $git -Arguments @(
        "-C", $registryDirectory,
        "clean", "-ffdx"
    )
}

$pluginDirectory = Join-Path $configDirectory "lua\plugins"
Write-Host "Applying the Windows ARM64 LazyVim overrides"
New-Item -ItemType Directory -Force -Path $pluginDirectory | Out-Null
$overridePath = Join-Path $pluginDirectory "windows-arm64.lua"
$override = @"
return {
  {
    "LazyVim/LazyVim",
    branch = "$($manifest.components.lazyvim.branch)",
    commit = "$($manifest.components.lazyvim.commit)",
    url = "https://github.com/$($manifest.components.lazyvim.repository).git",
  },
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "$($manifest.components.'nvim-treesitter'.branch)",
    commit = "$($manifest.components.'nvim-treesitter'.commit)",
    url = "https://github.com/$($manifest.components.'nvim-treesitter'.repository).git",
  },
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.registries = {
        "file:`$LOCALAPPDATA/Programs/LazyVimARM64/mason-registry",
      }
    end,
  },
}
"@
[System.IO.File]::WriteAllText(
    $overridePath,
    $override,
    [System.Text.UTF8Encoding]::new($false)
)

$optionsPath = Join-Path $configDirectory "lua\config\options.lua"
$options = Get-Content -LiteralPath $optionsPath -Raw
if ($options -notmatch '(?m)^vim\.g\.have_nerd_font\s*=') {
    $options += "`nvim.g.have_nerd_font = true`n"
}
if ($options -notmatch 'LazyVimARM64/bin') {
    $options += @"

local arm64_bin = vim.fn.expand("`$LOCALAPPDATA/Programs/LazyVimARM64/bin")
vim.env.PATH = arm64_bin .. ";" .. vim.env.PATH
"@
}
if ($compiler -and $options -notmatch '(?m)^local arm64_compiler_bin\s*=') {
    $compilerBinJson = (Split-Path $compiler -Parent) | ConvertTo-Json -Compress
    $options += @"

local arm64_compiler_bin = $compilerBinJson
vim.env.PATH = arm64_compiler_bin .. ";" .. vim.env.PATH
"@
}
[System.IO.File]::WriteAllText(
    $optionsPath,
    $options,
    [System.Text.UTF8Encoding]::new($false)
)

$receipt = [ordered]@{
    schema_version = 2
    installed_at = [DateTimeOffset]::UtcNow.ToString("o")
    config = $configDirectory
    data = $dataDirectory
    command = "nvim"
    architecture = "arm64"
    components = [ordered]@{
        lazyvim_branch = $manifest.components.lazyvim.branch
        lazyvim_commit = $manifest.components.lazyvim.commit
        mason_registry = $manifest.components."mason-registry".e2e_commit
        nvim_treesitter_branch = $manifest.components."nvim-treesitter".branch
        nvim_treesitter_commit = $manifest.components."nvim-treesitter".commit
    }
    tools = [ordered]@{
        compiler = $compiler
        git = $git
        neovim = $nvim
        yq = $yq
    }
    registry = $registryDirectory
}
Write-Utf8Json -Path $marker -Value $receipt
Write-Utf8Json -Path (Join-Path $configDirectory "lazyvim-arm64-receipt.json") `
    -Value $receipt

Write-Host ""
Write-Host "LazyVim ARM64 is configured in the standard Windows profile."
Write-Host "  Command: nvim"
Write-Host "  Config:  $configDirectory"
Write-Host ""
if (-not $SkipFont) {
    Write-Host "Set Windows Terminal's font face to 'JetBrainsMono Nerd Font'."
}
if (-not $InstallCompiler) {
    Write-Host "If no native compiler is already installed, rerun with -InstallCompiler before adding parsers."
}

if (-not $NoLaunch) {
    & $nvim
}
