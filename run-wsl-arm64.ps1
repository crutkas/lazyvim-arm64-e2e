[CmdletBinding()]
param(
    [string]$RunId = ("wsl-a64-fork-" + (Get-Date -Format "yyyyMMdd-HHmmss")),
    [int]$Runs = 10,
    [int]$Warmups = 3,
    [string]$Distribution = "Ubuntu"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,47}$') {
    throw "RunId must be 1-48 safe filename characters."
}
if ($Runs -lt 2 -or $Warmups -lt 0) {
    throw "Runs must be >= 2 and Warmups must be >= 0."
}

$repo = $PSScriptRoot
$localEvidence = Join-Path (Join-Path $repo "out") $RunId
$localProvisioning = Join-Path (Join-Path $repo "out") "$RunId-provisioning"
$wrapperLog = Join-Path (Join-Path $repo "out") "$RunId-wsl-wrapper.log"
foreach ($path in ($localEvidence, $localProvisioning, $wrapperLog)) {
    if (Test-Path -LiteralPath $path) {
        throw "Output path already exists: $path"
    }
}
New-Item -ItemType Directory -Force -Path (Join-Path $repo "out") | Out-Null

$resolvedRepo = [System.IO.Path]::GetFullPath($repo)
if ($resolvedRepo -notmatch '^([A-Za-z]):\\(.*)$') {
    throw "The repository must be on a Windows drive for WSL copying: $resolvedRepo"
}
$linuxSource = "/mnt/$($Matches[1].ToLowerInvariant())/" + $Matches[2].Replace("\", "/")
$linuxCopy = "/root/lazyvim-arm64-e2e-$RunId"
$copyCommand = @(
    "set -e",
    "test ! -e '$linuxCopy'",
    "mkdir -p '$linuxCopy'",
    "cd '$linuxSource'",
    "tar --exclude=.git --exclude=out -cf - . | tar -C '$linuxCopy' -xf -"
) -join "; "
& wsl.exe -d $Distribution -u root --cd /root -- bash -lc $copyCommand
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create the Linux-filesystem source copy."
}

$runCommand = @(
    "cd '$linuxCopy'",
    "exec env -i HOME=/root USER=root LOGNAME=root SHELL=/bin/bash LANG=C.UTF-8 PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash ./run-wsl-arm64.sh '$RunId' '$Runs' '$Warmups'"
) -join "; "
& wsl.exe -d $Distribution -u root --cd $linuxCopy -- bash -lc $runCommand 2>&1 |
    Tee-Object -FilePath $wrapperLog
$laneExit = $LASTEXITCODE

$uncRoot = "\\wsl.localhost\$Distribution" + ($linuxCopy.Replace("/", "\"))
foreach ($name in ($RunId, "$RunId-provisioning")) {
    $source = Join-Path (Join-Path $uncRoot "out") $name
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination (Join-Path (Join-Path $repo "out") $name) -Recurse
    }
}

if ($laneExit -ne 0) {
    throw "WSL ARM64 regression failed. Linux source and evidence remain at $linuxCopy."
}
$summaryPath = Join-Path $localEvidence "summary.json"
if (-not (Test-Path -LiteralPath $summaryPath)) {
    throw "WSL passed without producing copied evidence: $summaryPath"
}
$summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
if ($summary.result -ne "passed" -or $summary.placement.accepted -ne $true) {
    throw "Copied WSL evidence does not contain an accepted result."
}

Write-Host "LazyVim WSL2 ARM64 regression passed: $localEvidence"
