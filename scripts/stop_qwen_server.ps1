$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ConfigPath = Join-Path $RepoRoot "config\local.ps1"

if (-not (Test-Path $ConfigPath -PathType Leaf)) {
    throw "Missing config file: $ConfigPath"
}

. $ConfigPath

$ExpectedExe = $LlamaServerExe
$HostAddress = $ServerHost
$Port = [int]$ServerPort
$ShutdownTimeoutSeconds = 5

if (-not (Test-Path $ExpectedExe -PathType Leaf)) {
    throw "Expected llama-server.exe not found: $ExpectedExe"
}

$connections = @(
    Get-NetTCPConnection `
        -LocalAddress $HostAddress `
        -LocalPort $Port `
        -State Listen `
        -ErrorAction SilentlyContinue
)

if ($connections.Count -eq 0) {
    Write-Host "QWEN_SERVER_STATUS=ALREADY_STOPPED"
    exit 0
}

$processIds = @(
    $connections |
        Select-Object -ExpandProperty OwningProcess -Unique
)

if ($processIds.Count -ne 1) {
    throw (
        "Expected exactly one process listening on " +
        "${HostAddress}:${Port}, found $($processIds.Count). " +
        "Refusing to stop anything."
    )
}

$serverPid = $processIds[0]

$process = Get-Process `
    -Id $serverPid `
    -ErrorAction Stop

$actualExe = $process.Path

if ([string]::IsNullOrWhiteSpace($actualExe)) {
    throw (
        "Could not determine executable path for PID $serverPid. " +
        "Refusing to stop it."
    )
}

$expectedFullPath = [System.IO.Path]::GetFullPath($ExpectedExe)
$actualFullPath = [System.IO.Path]::GetFullPath($actualExe)

if (
    -not $actualFullPath.Equals(
        $expectedFullPath,
        [System.StringComparison]::OrdinalIgnoreCase
    )
) {
    throw (
        "Port $Port is owned by an unexpected process. " +
        "PID=$serverPid Path=$actualFullPath. " +
        "Refusing to stop it."
    )
}

Stop-Process `
    -Id $serverPid `
    -Force `
    -ErrorAction Stop

$deadline = (Get-Date).AddSeconds(
    $ShutdownTimeoutSeconds
)

while ((Get-Date) -lt $deadline) {
    $stillListening =
        Get-NetTCPConnection `
            -LocalAddress $HostAddress `
            -LocalPort $Port `
            -State Listen `
            -ErrorAction SilentlyContinue

    if (-not $stillListening) {
        Write-Host "QWEN_SERVER_STATUS=STOPPED"
        Write-Host "PID=$serverPid"
        exit 0
    }

    Start-Sleep -Milliseconds 200
}

throw (
    "llama-server.exe PID $serverPid was stopped, " +
    "but port $Port did not become free within " +
    "$ShutdownTimeoutSeconds seconds."
)