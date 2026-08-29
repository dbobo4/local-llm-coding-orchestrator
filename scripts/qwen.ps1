$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ConfigPath = Join-Path $RepoRoot "config\local.ps1"

if (-not (Test-Path $ConfigPath -PathType Leaf)) {
    Write-Error "Missing config\local.ps1. Copy config\local.example.ps1 to config\local.ps1 and adjust it for this machine."
    exit 1
}

. $ConfigPath

$PatchScript = Join-Path $RepoRoot "patches\ensure_qwen_code_patches.ps1"
$EnsureServerScript = Join-Path $PSScriptRoot "ensure_qwen_server.ps1"
$StopServerScript = Join-Path $PSScriptRoot "stop_qwen_server.ps1"

foreach ($required in @($PatchScript, $EnsureServerScript, $StopServerScript, $QwenCodeCli)) {
    if (-not (Test-Path $required -PathType Leaf)) {
        Write-Error "Required file not found: $required"
        exit 1
    }
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PatchScript
if ($LASTEXITCODE -ne 0) {
    Write-Error "Qwen Code patch integrity check failed."
    exit $LASTEXITCODE
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $EnsureServerScript
if ($LASTEXITCODE -ne 0) {
    Write-Error "Qwen server preflight failed."
    exit $LASTEXITCODE
}

$qwenExitCode = 0
$stopExitCode = 0

try {
    & $QwenCodeCli @args
    $qwenExitCode = $LASTEXITCODE
}
finally {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StopServerScript
    $stopExitCode = $LASTEXITCODE
}

if ($stopExitCode -ne 0 -and $qwenExitCode -eq 0) {
    Write-Error "Qwen server cleanup failed."
    exit $stopExitCode
}

exit $qwenExitCode