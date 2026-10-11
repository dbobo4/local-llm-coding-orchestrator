param(
    [switch]$CheckOnly,
    [ValidatePattern('^v?\d+\.\d+\.\d+$')]
    [string]$Version
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path $PSScriptRoot -Parent
if (-not [string]::IsNullOrWhiteSpace($Version) -and $Version.TrimStart("v") -ne "0.22.3") {
    Write-Error "This installation is pinned to Qwen Code 0.22.3. Other versions require a validated migration."
    exit 1
}

# Initialization and repair share the local transaction and integrity gate.
$Installer = Join-Path $RepoRoot "scripts\install_local.py"
if ($CheckOnly) {
    & python -B $Installer check
}
else {
    & python -B $Installer
}
exit $LASTEXITCODE
