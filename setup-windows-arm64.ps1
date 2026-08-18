[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA "Programs\LazyVimARM64"),
    [string]$AppName = "lazyvim-arm64",
    [switch]$NoLaunch,
    [switch]$NoPath,
    [switch]$ResetProfile
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

function Send-EnvironmentChanged {
    if (-not ([System.Management.Automation.PSTypeName]"LazyVimArm64.NativeMethods").Type) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace LazyVimArm64
{
    public static class NativeMethods
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd,
            uint message,
            UIntPtr wParam,
            string lParam,
            uint flags,
            uint timeout,
            out UIntPtr result);
    }
}
"@
    }
    $result = [UIntPtr]::Zero
    [LazyVimArm64.NativeMethods]::SendMessageTimeout(
        [IntPtr]0xffff,
        0x001A,
        [UIntPtr]::Zero,
        "Environment",
        0x0002,
        5000,
        [ref]$result
    ) | Out-Null
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
    Assert-FileHash -Path $Path -ExpectedSha256 $Spec.sha256 -Name $Spec.archive
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

function Expand-VerifiedZip {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Sentinel,
        [Parameter(Mandatory = $true)][string]$ExpectedArchiveSha256,
        [Parameter(Mandatory = $true)][string]$ExpectedBinarySha256,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $destinationFull = [System.IO.Path]::GetFullPath($Destination).TrimEnd("\")
    $sentinelFull = [System.IO.Path]::GetFullPath($Sentinel)
    if (-not $sentinelFull.StartsWith(
        $destinationFull + "\",
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "$Name sentinel is outside its extraction directory."
    }
    $relativeSentinel = $sentinelFull.Substring($destinationFull.Length + 1)
    $completionMarker = Join-Path $destinationFull ".archive-sha256"
    $valid = (
        (Test-Path -LiteralPath $sentinelFull -PathType Leaf) -and
        (Test-Path -LiteralPath $completionMarker -PathType Leaf) -and
        ((Get-Content -LiteralPath $completionMarker -Raw).Trim() -eq
            $ExpectedArchiveSha256.ToLowerInvariant())
    )
    if ($valid) {
        $actual = (Get-FileHash -LiteralPath $sentinelFull -Algorithm SHA256).Hash.ToLowerInvariant()
        $valid = $actual -eq $ExpectedBinarySha256.ToLowerInvariant()
    }
    if (-not $valid) {
        $staging = "$destinationFull.installing-$([guid]::NewGuid().ToString('N'))"
        try {
            New-Item -ItemType Directory -Force -Path $staging | Out-Null
            Expand-Archive -LiteralPath $Archive -DestinationPath $staging -Force
            $stagingSentinel = Join-Path $staging $relativeSentinel
            Assert-Arm64Pe -Path $stagingSentinel -Name $Name
            Assert-FileHash -Path $stagingSentinel `
                -ExpectedSha256 $ExpectedBinarySha256 -Name $Name
            [System.IO.File]::WriteAllText(
                (Join-Path $staging ".archive-sha256"),
                $ExpectedArchiveSha256.ToLowerInvariant() + [Environment]::NewLine,
                [System.Text.ASCIIEncoding]::new()
            )
            if (Test-Path -LiteralPath $destinationFull) {
                Remove-Item -LiteralPath $destinationFull -Recurse -Force
            }
            Move-Item -LiteralPath $staging -Destination $destinationFull
        }
        finally {
            if (Test-Path -LiteralPath $staging) {
                Remove-Item -LiteralPath $staging -Recurse -Force
            }
        }
    }
    Assert-Arm64Pe -Path $sentinelFull -Name $Name
    Assert-FileHash -Path $sentinelFull -ExpectedSha256 $ExpectedBinarySha256 -Name $Name
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string]$Git,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$Capture
    )
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& $Git @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "Git failed: git $($Arguments -join ' ')`n$($output -join "`n")"
    }
    if ($Capture) {
        return ($output -join "`n").Trim()
    }
}

function Set-ExactCheckout {
    param(
        [Parameter(Mandatory = $true)][string]$Git,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Commit
    )
    $gitDirectory = Join-Path $Destination ".git"
    if (-not (Test-Path -LiteralPath $gitDirectory -PathType Container)) {
        if (Test-Path -LiteralPath $Destination) {
            $items = @(Get-ChildItem -LiteralPath $Destination -Force)
            if ($items.Count -ne 0) {
                throw "Checkout destination is not empty: $Destination"
            }
        }
        else {
            New-Item -ItemType Directory -Force -Path $Destination | Out-Null
        }
        Invoke-Git -Git $Git -Arguments @("init", "--quiet", $Destination)
        Invoke-Git -Git $Git -Arguments @("-C", $Destination, "remote", "add", "origin", $Url)
    }
    $localKeys = @(
        (Invoke-Git -Git $Git -Arguments @(
            "-C", $Destination, "config", "--local", "--name-only", "--list"
        ) -Capture) -split "\r?\n" |
        Where-Object { $_ }
    )
    $unsafeKeys = @($localKeys | Where-Object {
        $_ -match '^(?i:include\.|includeif\.|url\.)' -or
        $_ -eq "remote.origin.pushurl"
    })
    if ($unsafeKeys.Count -ne 0) {
        throw "Unsafe local Git URL configuration in $Destination`: $($unsafeKeys -join ', ')"
    }
    $origins = @(
        (Invoke-Git -Git $Git -Arguments @(
            "-C", $Destination, "config", "--local", "--get-all", "remote.origin.url"
        ) -Capture) -split "\r?\n" |
        Where-Object { $_ }
    )
    if ($origins.Count -ne 1 -or $origins[0].TrimEnd("/") -ne $Url.TrimEnd("/")) {
        throw "Unexpected raw origin for $Destination`: $($origins -join ', ')"
    }
    $effectiveOrigins = @(
        (Invoke-Git -Git $Git -Arguments @(
            "-C", $Destination, "remote", "get-url", "--all", "origin"
        ) -Capture) -split "\r?\n" |
        Where-Object { $_ }
    )
    if (
        $effectiveOrigins.Count -ne 1 -or
        $effectiveOrigins[0].TrimEnd("/") -ne $Url.TrimEnd("/")
    ) {
        throw "Unexpected effective origin for $Destination`: $($effectiveOrigins -join ', ')"
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $Git -C $Destination cat-file -e "$Commit^{commit}" *> $null
        $commitPresent = $LASTEXITCODE -eq 0
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if (-not $commitPresent) {
        Write-Host "Fetching $([System.IO.Path]::GetFileName($Destination))@$Commit"
        Invoke-Git -Git $Git -Arguments @(
            "-C", $Destination, "fetch", "--force", "--no-tags", "--depth", "1", "origin", $Commit
        )
    }
    Invoke-Git -Git $Git -Arguments @("-C", $Destination, "checkout", "--quiet", "--force", "--detach", $Commit)
    Invoke-Git -Git $Git -Arguments @("-C", $Destination, "clean", "-ffdx")
    $head = Invoke-Git -Git $Git -Arguments @("-C", $Destination, "rev-parse", "HEAD") -Capture
    $status = Invoke-Git -Git $Git -Arguments @("-C", $Destination, "status", "--porcelain") -Capture
    if ($head -ne $Commit -or $status) {
        throw "Checkout is not exact and clean: $Destination"
    }
}

function Copy-GitTrackedTree {
    param(
        [Parameter(Mandatory = $true)][string]$Git,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $files = @(& $Git -C $Source ls-files)
    if ($LASTEXITCODE -ne 0 -or $files.Count -eq 0) {
        throw "Could not enumerate starter files."
    }
    foreach ($relative in $files) {
        $windowsRelative = $relative.Replace("/", "\")
        $sourceFile = Join-Path $Source $windowsRelative
        $destinationFile = Join-Path $Destination $windowsRelative
        New-Item -ItemType Directory -Force -Path (Split-Path $destinationFile -Parent) | Out-Null
        Copy-Item -LiteralPath $sourceFile -Destination $destinationFile -Force
    }
}

$osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$processArch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
if ($osArch -ne "Arm64" -or $processArch -ne "Arm64") {
    throw "This setup requires native ARM64 Windows PowerShell. OS=$osArch Process=$processArch"
}
if ($AppName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,47}$') {
    throw "AppName must be 1-48 safe filename characters."
}

$repo = $PSScriptRoot
$resolvedInstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
$tools = Get-Content (Join-Path $repo "tools.json") -Raw | ConvertFrom-Json
$manifest = Get-Content (Join-Path $repo "manifest.json") -Raw | ConvertFrom-Json
$lock = Get-Content (Join-Path $repo "harness\lazy-lock-e2e.json") -Raw | ConvertFrom-Json
$pluginSources = Get-Content (Join-Path $repo "fixtures\plugin-sources.json") -Raw | ConvertFrom-Json
$arm64 = $tools.windows_arm64

$downloads = Join-Path $resolvedInstallRoot "downloads"
$toolRoot = Join-Path $resolvedInstallRoot "tools"
$sourceRoot = Join-Path $resolvedInstallRoot "sources"
$profileRoot = Join-Path $resolvedInstallRoot "profile"
$configHome = Join-Path $profileRoot "xdg\config"
$dataHome = Join-Path $profileRoot "xdg\data"
$stateHome = Join-Path $profileRoot "xdg\state"
$cacheHome = Join-Path $profileRoot "xdg\cache"
$configDirectory = Join-Path $configHome $AppName
$dataDirectory = Join-Path $dataHome "$AppName-data"
$lazyRoot = Join-Path $dataDirectory "lazy"
$marker = Join-Path $configDirectory ".lazyvim-arm64-managed.json"
$ownerMarker = Join-Path $resolvedInstallRoot ".lazyvim-arm64-owned.json"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

$ownedInstall = Test-Path -LiteralPath $ownerMarker -PathType Leaf
if ($ownedInstall) {
    $owner = Get-Content -LiteralPath $ownerMarker -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($owner.app_name -ne $AppName -or $owner.install_root -ne $resolvedInstallRoot) {
        throw "The install root is managed by a different LazyVim ARM64 profile."
    }
}
$managedProfile = Test-Path -LiteralPath $marker -PathType Leaf
if ($managedProfile) {
    $profileOwner = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json
    if (
        $profileOwner.app_name -ne $AppName -or
        $profileOwner.install_root -ne $resolvedInstallRoot
    ) {
        throw "The profile marker does not match this setup request."
    }
}
if ($ResetProfile -and (Test-Path -LiteralPath $profileRoot)) {
    if (-not ($ownedInstall -or $managedProfile)) {
        throw "Refusing to reset an unmanaged profile: $profileRoot"
    }
    Remove-Item -LiteralPath $profileRoot -Recurse -Force
}
if (
    (Test-Path -LiteralPath $configDirectory) -and
    -not (Test-Path -LiteralPath $marker -PathType Leaf)
) {
    $items = @(Get-ChildItem -LiteralPath $configDirectory -Force)
    if ($items.Count -ne 0 -and -not $ownedInstall) {
        throw "Refusing to modify an unmanaged profile: $configDirectory"
    }
    if ($ownedInstall) {
        Remove-Item -LiteralPath $configDirectory -Recurse -Force
    }
}
New-Item -ItemType Directory -Force -Path (
    $downloads, $toolRoot, $sourceRoot, $configHome, $dataHome, $stateHome, $cacheHome, $lazyRoot
) | Out-Null
if (-not $ownedInstall) {
    $ownerJson = [ordered]@{
        schema_version = 1
        app_name = $AppName
        install_root = $resolvedInstallRoot
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText(
        $ownerMarker,
        $ownerJson + [Environment]::NewLine,
        $utf8NoBom
    )
}

$gitArchive = Download-Checked -Spec $arm64.git -Directory $downloads
$gitRoot = Join-Path $toolRoot "mingit-$($arm64.git.version)"
$git = Join-Path $gitRoot "cmd\git.exe"
Expand-VerifiedZip -Archive $gitArchive -Destination $gitRoot -Sentinel $git `
    -ExpectedArchiveSha256 $arm64.git.sha256 `
    -ExpectedBinarySha256 $arm64.git.binary_sha256 -Name "Git"
$gitBuild = (& $git --version --build-options) -join "`n"
if ($LASTEXITCODE -ne 0 -or $gitBuild -notmatch 'cpu:\s*aarch64') {
    throw "Provisioned Git did not report an aarch64 build."
}

$nvimArchive = Download-Checked -Spec $arm64.neovim -Directory $downloads
$nvimRoot = Join-Path $toolRoot "neovim-$($arm64.neovim.version)"
$nvim = Join-Path $nvimRoot "nvim-win-arm64\bin\nvim.exe"
Expand-VerifiedZip -Archive $nvimArchive -Destination $nvimRoot -Sentinel $nvim `
    -ExpectedArchiveSha256 $arm64.neovim.sha256 `
    -ExpectedBinarySha256 $arm64.neovim.binary_sha256 -Name "Neovim"
$foreignYank = Join-Path $nvimRoot "nvim-win-arm64\bin\win32yank.exe"
if (Test-Path -LiteralPath $foreignYank) {
    Remove-Item -LiteralPath $foreignYank -Force
}

$llvmArchive = Download-Checked -Spec $arm64.llvm_mingw -Directory $downloads
$llvmRoot = Join-Path $toolRoot "llvm-mingw-$($arm64.llvm_mingw.version)"
$compilerRelative = (
    "llvm-mingw-$($arm64.llvm_mingw.version)-ucrt-aarch64" +
    "\bin\aarch64-w64-mingw32-gcc.exe"
)
$compiler = Join-Path $llvmRoot $compilerRelative
Expand-VerifiedZip -Archive $llvmArchive -Destination $llvmRoot -Sentinel $compiler `
    -ExpectedArchiveSha256 $arm64.llvm_mingw.sha256 `
    -ExpectedBinarySha256 $arm64.llvm_mingw.binary_sha256 -Name "LLVM-MinGW compiler"
$compilerBin = Split-Path $compiler -Parent

$yqDownload = Download-Checked -Spec $arm64.yq -Directory $downloads
$supportRoot = Join-Path $toolRoot "yq-$($arm64.yq.version)"
$yq = Join-Path $supportRoot "yq.exe"
New-Item -ItemType Directory -Force -Path $supportRoot | Out-Null
Copy-Item -LiteralPath $yqDownload -Destination $yq -Force
Assert-Arm64Pe -Path $yq -Name "yq"
Assert-FileHash -Path $yq -ExpectedSha256 $arm64.yq.sha256 -Name "yq"

$gitEnvironment = @{}
Get-ChildItem Env: | Where-Object { $_.Name -like "GIT_*" } | ForEach-Object {
    $gitEnvironment[$_.Name] = $_.Value
}
$emptyGitConfig = Join-Path $resolvedInstallRoot ".empty-gitconfig"
[System.IO.File]::WriteAllText($emptyGitConfig, "", [System.Text.ASCIIEncoding]::new())
try {
    Get-ChildItem Env: | Where-Object { $_.Name -like "GIT_*" } | ForEach-Object {
        Remove-Item -Path "Env:$($_.Name)" -ErrorAction SilentlyContinue
    }
    $env:GIT_CONFIG_GLOBAL = $emptyGitConfig
    $env:GIT_CONFIG_NOSYSTEM = "1"
    $env:GIT_TERMINAL_PROMPT = "0"
    $starterCommit = "803bc181d7c0d6d5eeba9274d9be49b287294d99"
    $starterSource = Join-Path $sourceRoot "starter"
    Set-ExactCheckout -Git $git -Destination $starterSource `
        -Url "https://github.com/LazyVim/starter.git" -Commit $starterCommit

    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        Copy-GitTrackedTree -Git $git -Source $starterSource -Destination $configDirectory
    }
    Copy-Item -LiteralPath (Join-Path $repo "harness\lazy-lock-e2e.json") `
        -Destination (Join-Path $configDirectory "lazy-lock.json") -Force

    $lazyConfig = Join-Path $configDirectory "lua\config\lazy.lua"
    $lazyText = Get-Content -LiteralPath $lazyConfig -Raw
    $checkerLine = "enabled = true, -- check for plugin updates periodically"
    if ($lazyText.Contains($checkerLine)) {
        $lazyText = $lazyText.Replace(
            $checkerLine,
            "enabled = false, -- pinned ARM64 profile; update manually"
        )
        [System.IO.File]::WriteAllText($lazyConfig, $lazyText, $utf8NoBom)
    }

    $arm64Plugin = Join-Path $configDirectory "lua\plugins\windows-arm64.lua"
    $pluginText = @"
return {
  {
    "LazyVim/LazyVim",
    branch = "$($manifest.components.lazyvim.branch)",
    url = "https://github.com/$($manifest.components.lazyvim.repository).git",
  },
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "$($manifest.components.'nvim-treesitter'.branch)",
    url = "https://github.com/$($manifest.components.'nvim-treesitter'.repository).git",
  },
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.registries = {
        "github:$($manifest.components.'mason-registry'.repository)@$($manifest.components.'mason-registry'.e2e_commit)",
      }
    end,
  },
}
"@
    [System.IO.File]::WriteAllText($arm64Plugin, $pluginText, $utf8NoBom)

    $sourceMap = @{}
    $pluginSources.PSObject.Properties | ForEach-Object {
        $sourceMap[$_.Name] = [string]$_.Value
    }
    $sourceMap["LazyVim"] = "https://github.com/$($manifest.components.lazyvim.repository).git"
    $sourceMap["nvim-treesitter"] = "https://github.com/$($manifest.components.'nvim-treesitter'.repository).git"
    foreach ($property in $lock.PSObject.Properties | Sort-Object Name) {
        $name = $property.Name
        $entry = $property.Value
        if (-not $sourceMap.ContainsKey($name)) {
            throw "No repository mapping exists for $name."
        }
        Set-ExactCheckout -Git $git -Destination (Join-Path $lazyRoot $name) `
            -Url $sourceMap[$name] -Commit $entry.commit
    }
}
finally {
    Get-ChildItem Env: | Where-Object { $_.Name -like "GIT_*" } | ForEach-Object {
        Remove-Item -Path "Env:$($_.Name)" -ErrorAction SilentlyContinue
    }
    foreach ($name in $gitEnvironment.Keys) {
        Set-Item -Path "Env:$name" -Value $gitEnvironment[$name]
    }
}

$rootPrefix = $resolvedInstallRoot.TrimEnd("\") + "\"
$relativePaths = @{}
$managedPaths = [ordered]@{
    nvim = $nvim
    nvim_bin = (Split-Path $nvim -Parent)
    git_bin = (Split-Path $git -Parent)
    git_helpers = (Join-Path $gitRoot "clangarm64\bin")
    compiler_bin = $compilerBin
    support = $supportRoot
}
foreach ($item in $managedPaths.GetEnumerator()) {
    if (-not $item.Value.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Managed path is outside the install root: $($item.Value)"
    }
    $relative = $item.Value.Substring($rootPrefix.Length)
    if ($relative -match '[^\x00-\x7F]') {
        throw "Managed launcher path must be ASCII relative to the install root: $relative"
    }
    $relativePaths[$item.Key] = $relative
}
$launcher = Join-Path $resolvedInstallRoot "lazyvim-arm64.cmd"
$launcherText = @"
@ECHO off
SETLOCAL
SET "LVB_ROOT=%~dp0"
SET "NVIM_APPNAME=$AppName"
SET "XDG_CONFIG_HOME=%LVB_ROOT%profile\xdg\config"
SET "XDG_DATA_HOME=%LVB_ROOT%profile\xdg\data"
SET "XDG_STATE_HOME=%LVB_ROOT%profile\xdg\state"
SET "XDG_CACHE_HOME=%LVB_ROOT%profile\xdg\cache"
SET "PATH=%LVB_ROOT%$($relativePaths.nvim_bin);%LVB_ROOT%$($relativePaths.git_bin);%LVB_ROOT%$($relativePaths.git_helpers);%LVB_ROOT%$($relativePaths.compiler_bin);%LVB_ROOT%$($relativePaths.support);%PATH%"
"%LVB_ROOT%$($relativePaths.nvim)" %*
EXIT /b %ERRORLEVEL%
"@
[System.IO.File]::WriteAllText($launcher, $launcherText, [System.Text.ASCIIEncoding]::new())

$receipt = [ordered]@{
    schema_version = 1
    app_name = $AppName
    installed_at = [DateTimeOffset]::UtcNow.ToString("o")
    install_root = $resolvedInstallRoot
    launcher = $launcher
    profile = [ordered]@{
        config = $configDirectory
        data = $dataDirectory
    }
    components = [ordered]@{
        lazyvim = $manifest.components.lazyvim.commit
        mason_registry = $manifest.components."mason-registry".e2e_commit
        neovim = $arm64.neovim.version
        nvim_treesitter = $manifest.components."nvim-treesitter".commit
        plugins = @($lock.PSObject.Properties).Count
        yq = $arm64.yq.version
    }
    native_tools = @(
        [ordered]@{ name = "nvim"; path = $nvim; sha256 = $arm64.neovim.binary_sha256 },
        [ordered]@{ name = "git"; path = $git; sha256 = $arm64.git.binary_sha256 },
        [ordered]@{ name = "compiler"; path = $compiler; sha256 = $arm64.llvm_mingw.binary_sha256 },
        [ordered]@{ name = "yq"; path = $yq; sha256 = $arm64.yq.sha256 }
    )
}
$receiptPath = Join-Path $resolvedInstallRoot "setup-receipt.json"
$receiptJson = $receipt | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText(
    $receiptPath,
    $receiptJson + [Environment]::NewLine,
    $utf8NoBom
)
[System.IO.File]::WriteAllText(
    $marker,
    $receiptJson + [Environment]::NewLine,
    $utf8NoBom
)

if (-not $NoPath) {
    $environmentKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        "Environment",
        $true
    )
    if (-not $environmentKey) {
        throw "Could not open the user environment registry key."
    }
    try {
        $pathExists = @($environmentKey.GetValueNames()) -contains "Path"
        if ($pathExists) {
            $rawUserPath = [string]$environmentKey.GetValue(
                "Path",
                "",
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            )
            $pathKind = $environmentKey.GetValueKind("Path")
            if ($pathKind -notin @(
                [Microsoft.Win32.RegistryValueKind]::String,
                [Microsoft.Win32.RegistryValueKind]::ExpandString
            )) {
                throw "The user PATH has an unsupported registry value type: $pathKind"
            }
        }
        else {
            $rawUserPath = ""
            $pathKind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        }
        $segments = @($rawUserPath -split ";" | Where-Object { $_ })
        if (-not ($segments | Where-Object {
            $_.TrimEnd("\") -ieq $resolvedInstallRoot.TrimEnd("\")
        })) {
            $updatedPath = (@($resolvedInstallRoot) + $segments) -join ";"
            $environmentKey.SetValue("Path", $updatedPath, $pathKind)
        }
    }
    finally {
        $environmentKey.Dispose()
    }
    Send-EnvironmentChanged
    $env:Path = "$resolvedInstallRoot;$env:Path"
}

Write-Host ""
Write-Host "LazyVim ARM64 is ready."
Write-Host "  Command: lazyvim-arm64"
Write-Host "  Profile: $configDirectory"
Write-Host "  Receipt: $receiptPath"
Write-Host ""
if (-not $NoPath) {
    Write-Host "Open a new terminal to use the command from PATH."
}

if (-not $NoLaunch) {
    & $launcher
}
