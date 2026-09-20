$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ConfigPath = Join-Path $RepoRoot "config\local.ps1"

if (-not (Test-Path $ConfigPath -PathType Leaf)) {
    Write-Error "Missing config\local.ps1. Copy config\local.example.ps1 to config\local.ps1 and adjust it for this machine."
    exit 1
}

. $ConfigPath

$PatchScript = Join-Path $QwenRoot "config\qwen_runtime_patches.ps1"
$ServerScript = Join-Path $QwenRoot "config\qwen_server.ps1"

foreach ($required in @(
    $PatchScript,
    $ServerScript,
    $QwenCodeCli
)) {
    if (-not (Test-Path $required -PathType Leaf)) {
        Write-Error "Required file not found: $required"
        exit 1
    }
}

$CliLeaseRoot = Join-Path `
    $QwenUserRoot `
    "runtime_clients\cli"

New-Item `
    -Path $CliLeaseRoot `
    -ItemType Directory `
    -Force |
Out-Null

$CliLeasePath = Join-Path `
    $CliLeaseRoot `
    ("{0}.lock" -f $PID)

$CliLeaseStream = $null
$qwenExitCode = 0
$stopExitCode = 0
$primaryError = $null

try {
    $CliLeaseStream = [System.IO.FileStream]::new(
        $CliLeasePath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None,
        4096,
        [System.IO.FileOptions]::DeleteOnClose
    )

    & powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $PatchScript

    if ($LASTEXITCODE -ne 0) {
        $qwenExitCode = $LASTEXITCODE
        throw "Qwen Code patch integrity check failed."
    }

    & powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $ServerScript `
        -Action Ensure

    if ($LASTEXITCODE -ne 0) {
        $qwenExitCode = $LASTEXITCODE
        throw "Qwen server preflight failed."
    }

    & $QwenCodeCli @args
    $qwenExitCode = $LASTEXITCODE
}
catch {
    $primaryError = $_

    if ($qwenExitCode -eq 0) {
        $qwenExitCode = 1
    }
}
finally {
    if ($null -ne $CliLeaseStream) {
        $CliLeaseStream.Dispose()
        $CliLeaseStream = $null
    }

    & powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $ServerScript `
        -Action Stop `
        -IfIdle

    $stopExitCode = $LASTEXITCODE
}

if ($null -ne $primaryError) {
    Write-Error `
        -Message $primaryError.Exception.Message `
        -ErrorAction Continue
}

if (
    $stopExitCode -ne 0 -and
    $qwenExitCode -eq 0
) {
    Write-Error "Qwen server cleanup failed."
    exit $stopExitCode
}

exit $qwenExitCode