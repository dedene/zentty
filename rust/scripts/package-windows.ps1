#Requires -Version 5.1
# Builds the portable Windows release package: rust/dist/zentty-windows-x64.zip
# (release exe + icon + install/uninstall scripts). Use -SkipBuild to package
# an existing target/release build.
param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot   # rust/
if (-not $SkipBuild) {
    Push-Location $root
    try {
        cargo build --release --workspace
        if ($LASTEXITCODE -ne 0) { throw 'cargo build --release failed' }
    }
    finally { Pop-Location }
}

$exe = Join-Path $root 'target\release\zentty-win-desktop.exe'
if (-not (Test-Path $exe)) { throw "missing $exe — run without -SkipBuild" }

$dist = Join-Path $root 'dist'
$stage = Join-Path $dist 'zentty-windows-x64'
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item $exe (Join-Path $stage 'Zentty.exe')
Copy-Item (Join-Path $root 'crates\zentty-win\assets\zentty.ico') $stage
Copy-Item (Join-Path $PSScriptRoot 'install-windows.ps1') (Join-Path $stage 'install.ps1')
Copy-Item (Join-Path $PSScriptRoot 'uninstall-windows.ps1') (Join-Path $stage 'uninstall.ps1')

$zip = Join-Path $dist 'zentty-windows-x64.zip'
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path "$stage\*" -DestinationPath $zip
Write-Host "Packaged: $zip ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB)"
