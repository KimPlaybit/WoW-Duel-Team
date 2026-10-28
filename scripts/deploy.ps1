#requires -Version 5.1
<#
.SYNOPSIS
    Junction-link (or copy) every addon under src/ into the WoW: Forever AddOns folder(s).
    Adapted from .ref/WoW-Addons/scripts/deploy.ps1. Targets come from wow-dev.config.json.
.EXAMPLE
    .\scripts\deploy.ps1                 # link all addons into every target
    .\scripts\deploy.ps1 -Target live    # only the live client
    .\scripts\deploy.ps1 -Copy           # copy instead of link
    .\scripts\deploy.ps1 -Clean          # remove deployments
#>
[CmdletBinding()]
param(
    [string[]]$Name,
    [string[]]$Target,
    [switch]$Copy,
    [switch]$Clean
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $root 'src'

$config = Get-Content (Join-Path $root 'wow-dev.config.json') -Raw | ConvertFrom-Json
$localPath = Join-Path $root 'wow-dev.config.local.json'
if (Test-Path $localPath) {
    $local = Get-Content $localPath -Raw | ConvertFrom-Json
    if ($local.targets) { $config.targets = $local.targets }
}
$targets = $config.targets.PSObject.Properties | Where-Object { -not $Target -or $Target -contains $_.Name }
if (-not $targets) { throw "No matching targets in wow-dev.config.json" }

$addons = Get-ChildItem $srcDir -Directory
if ($Name) { $addons = $addons | Where-Object { $Name -contains $_.Name } }
if (-not $addons) { Write-Warning "No matching addons under src/."; return }

foreach ($t in $targets) {
    $addonsDir = Join-Path $t.Value 'Interface\AddOns'
    if (-not (Test-Path $addonsDir)) { Write-Warning "[$($t.Name)] AddOns folder not found: $addonsDir"; continue }
    foreach ($addon in $addons) {
        $link = Join-Path $addonsDir $addon.Name
        if (Test-Path $link) {
            $item = Get-Item $link -Force
            # A junction is removed as a link only, never recursing into the repo.
            if ($item.LinkType) { [System.IO.Directory]::Delete($link, $false) } else { Remove-Item $link -Recurse -Force }
        }
        if ($Clean) {
            Write-Host "[$($t.Name)] clean $($addon.Name)" -ForegroundColor Yellow
        } elseif ($Copy) {
            Copy-Item $addon.FullName $link -Recurse -Force
            Write-Host "[$($t.Name)] copy  $($addon.Name) -> $link" -ForegroundColor Cyan
        } else {
            New-Item -ItemType Junction -Path $link -Target $addon.FullName | Out-Null
            Write-Host "[$($t.Name)] link  $($addon.Name) -> $link" -ForegroundColor Green
        }
    }
}
