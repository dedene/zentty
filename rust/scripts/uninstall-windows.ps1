#Requires -Version 5.1
# Removes the per-user Zentty install (%LOCALAPPDATA%\Zentty) and its
# Start-menu shortcut.
$ErrorActionPreference = 'Stop'

$shortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Zentty.lnk'
if (Test-Path $shortcutPath) { Remove-Item -Force $shortcutPath }

$dest = Join-Path $env:LOCALAPPDATA 'Zentty'
if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }

Write-Host 'Zentty uninstalled.'
