#Requires -Version 5.1
# Installs Zentty for the current user: copies the app to %LOCALAPPDATA%\Zentty
# and creates a Start-menu shortcut. No admin rights required.
$ErrorActionPreference = 'Stop'

$dest = Join-Path $env:LOCALAPPDATA 'Zentty'
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'Zentty.exe') $dest -Force
Copy-Item (Join-Path $PSScriptRoot 'zentty.ico') $dest -Force

$shortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Zentty.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $dest 'Zentty.exe'
$shortcut.IconLocation = Join-Path $dest 'zentty.ico'
$shortcut.WorkingDirectory = $env:USERPROFILE
$shortcut.Description = 'Zentty terminal'
$shortcut.Save()

Write-Host "Installed to $dest"
Write-Host "Start-menu shortcut: $shortcutPath"
