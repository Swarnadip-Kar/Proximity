# Proximity Windows installer build helper — run on Windows in apps/proximity_app.
#   powershell -ExecutionPolicy Bypass -File packaging\windows\build_installer.ps1
# Requires: Flutter (windows desktop enabled) + Inno Setup 6 (iscc on PATH).
# Output: dist\Proximity-Setup-<version>-Windows-x64.exe
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
Set-Location $Root

$Version = ((Select-String -Path pubspec.yaml -Pattern '^version:\s*(.+)').Matches[0].Groups[1].Value -split '\+')[0].Trim()
Write-Host "Building Proximity $Version for Windows..."

flutter config --enable-windows-desktop
flutter pub get
flutter build windows --release

$env:APP_VERSION = $Version
$iscc = (Get-Command iscc -ErrorAction SilentlyContinue)
if (-not $iscc) {
  $iscc = Get-ChildItem "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
}
if (-not $iscc) { throw "ISCC.exe not found — install Inno Setup 6 (choco install innosetup)." }

& $iscc ("packaging\windows\proximity.iss")
Write-Host "Installer in dist\"
