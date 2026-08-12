[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "out\arm64-artifacts")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-PeMachine {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -lt 64) {
            return $null
        }
        $reader = [System.IO.BinaryReader]::new($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) {
            return $null
        }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadUInt32()
        if ($peOffset + 6 -gt $stream.Length) {
            return $null
        }
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

function Download-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Sha256
    )

    if (-not (Test-Path -LiteralPath $Destination)) {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    }
    $actual = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    if ($actual -ne $Sha256) {
        throw "SHA-256 mismatch for $Destination. Expected $Sha256, got $actual."
    }
}

$manifest = Get-Content (Join-Path $PSScriptRoot "manifest.json") -Raw | ConvertFrom-Json
$cache = Join-Path $PSScriptRoot ".cache\arm64-artifacts"
New-Item -ItemType Directory -Force -Path $cache, $OutputDirectory | Out-Null

$components = @("stylua", "shfmt", "lua-language-server", "tree-sitter-cli")
$records = @()
foreach ($name in $components) {
    $component = $manifest.components.$name
    if (-not $component.asset -or -not $component.sha256) {
        throw "Component $name is missing asset metadata."
    }
    $assetName = [System.IO.Path]::GetFileName(([Uri]$component.asset).AbsolutePath)
    $assetPath = Join-Path $cache $assetName
    Download-Checked -Url $component.asset -Destination $assetPath -Sha256 $component.sha256

    $scanRoot = $assetPath
    if ([System.IO.Path]::GetExtension($assetPath) -eq ".zip") {
        $scanRoot = Join-Path $cache ([System.IO.Path]::GetFileNameWithoutExtension($assetName))
        if (Test-Path -LiteralPath $scanRoot) {
            Remove-Item -LiteralPath $scanRoot -Recurse -Force
        }
        Expand-Archive -LiteralPath $assetPath -DestinationPath $scanRoot
    }

    $files = if ((Get-Item -LiteralPath $scanRoot).PSIsContainer) {
        Get-ChildItem -LiteralPath $scanRoot -Recurse -File
    }
    else {
        @(Get-Item -LiteralPath $scanRoot)
    }
    $peFiles = @()
    foreach ($file in $files) {
        $machine = Get-PeMachine -Path $file.FullName
        if ($null -ne $machine) {
            $peFiles += [ordered]@{
                path = $file.FullName
                bytes = $file.Length
                machine = "0x{0:X4}" -f $machine
                sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    }
    if ($peFiles.Count -eq 0) {
        throw "No PE files found in $assetName."
    }
    $wrong = @($peFiles | Where-Object machine -ne "0xAA64")
    if ($wrong.Count -ne 0) {
        throw "Non-ARM64 PE files found in $assetName."
    }
    $records += [ordered]@{
        component = $name
        asset = $component.asset
        archive = $assetPath
        archive_sha256 = $component.sha256.ToLowerInvariant()
        pe_files = $peFiles
    }
}

$result = [ordered]@{
    schema_version = 1
    validated_at = [DateTimeOffset]::UtcNow.ToString("o")
    host_os_architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    executed_arm64_binaries = $false
    passed = $true
    components = $records
}
$resultPath = Join-Path $OutputDirectory "artifact-validation.json"
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8
Write-Host "ARM64 artifact validation passed: $resultPath"
