#requires -Version 5.1
<#
.SYNOPSIS
    Lint all addon Lua with luacheck and run the pure-Lua unit tests under LuaJIT.
.EXAMPLE
    .\scripts\check.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    $luacheck = Join-Path $root '.tools\luacheck.exe'
    if (-not (Test-Path $luacheck)) { throw "Missing $luacheck - download luacheck.exe v1.2.0 from github.com/lunarmodules/luacheck/releases into .tools\" }

    $luajit = (Get-Command luajit -ErrorAction SilentlyContinue).Source
    if (-not $luajit) { $luajit = Join-Path $env:LOCALAPPDATA 'Programs\LuaJIT\bin\luajit.exe' }
    if (-not (Test-Path $luajit)) { throw "LuaJIT not found - winget install DEVCOM.LuaJIT" }

    $targets = @(@('src', 'prototypes', 'tests') | Where-Object { Test-Path $_ })
    Write-Host "== luacheck $($targets -join ' ')"
    & $luacheck @targets
    $lintCode = $LASTEXITCODE

    Write-Host "== unit tests"
    & $luajit tests/run.lua
    $testCode = $LASTEXITCODE

    if ($lintCode -gt 1 -or $testCode -ne 0) { exit 1 }  # luacheck: 1 = warnings only
} finally {
    Pop-Location
}
