$ErrorActionPreference = "Stop"

# LOCALAI_NODE_SYSTEM_CA
# Qwen Code runs on Node.js. Reuse the Windows system CA store for HTTPS/MCP TLS.
$LocalAiNodeSystemCaFlag = "--use-system-ca"
$LocalAiNodeOptions = [string]$env:NODE_OPTIONS

if ($LocalAiNodeOptions -notmatch '(^|\s)--use-system-ca(\s|$)') {
    if ([string]::IsNullOrWhiteSpace($LocalAiNodeOptions)) {
        $env:NODE_OPTIONS = $LocalAiNodeSystemCaFlag
    }
    else {
        $env:NODE_OPTIONS = (
            $LocalAiNodeOptions.TrimEnd() +
            " " +
            $LocalAiNodeSystemCaFlag
        )
    }
}

try {
. (Join-Path $PSScriptRoot "local_environment.ps1") -Initialize

$PatchScript = Join-Path $QwenRoot "patches\qwen_runtime_patches.ps1"
$ServerScript = Join-Path $QwenRoot "scripts\qwen_server.ps1"

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
Assert-LocalPath $CliLeaseRoot

New-Item `
    -Path $CliLeaseRoot `
    -ItemType Directory `
    -Force |
Out-Null

$CliLeasePath = Join-Path `
    $CliLeaseRoot `
    ("{0}.lock" -f $PID)
Assert-LocalPath $CliLeasePath

$CliLeaseStream = $null
$qwenExitCode = 0
$stopExitCode = 0
$primaryError = $null

try {
    Assert-LocalPath $CliLeasePath
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

    Assert-LocalTree (Join-Path $QwenRoot '.localai')
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
}
finally {
    if (Get-Command Restore-LocalEnvironment -ErrorAction SilentlyContinue) { Restore-LocalEnvironment }
}
