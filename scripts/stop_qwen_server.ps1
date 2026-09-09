$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ConfigPath = Join-Path $RepoRoot "config\local.ps1"

if (-not (Test-Path $ConfigPath -PathType Leaf)) {
    throw "Missing config file: $ConfigPath"
}

. $ConfigPath

$ExpectedExe = $LlamaServerExe
$ExpectedModelPath = $ModelPath
$HostAddress = [string]$ServerHost
$Port = [int]$ServerPort
$ShutdownTimeoutSeconds = 5

if (-not (Test-Path $ExpectedExe -PathType Leaf)) {
    throw "Expected llama-server.exe not found: $ExpectedExe"
}

if (-not (Test-Path $ExpectedModelPath -PathType Leaf)) {
    throw "Expected Qwen model not found: $ExpectedModelPath"
}

function Get-QwenListenerProcessIds {
    $connections = @(
        Get-NetTCPConnection `
            -LocalAddress $HostAddress `
            -LocalPort $Port `
            -State Listen `
            -ErrorAction SilentlyContinue
    )

    return @(
        $connections |
            Select-Object -ExpandProperty OwningProcess -Unique
    )
}

function Test-QwenListenerOwnedBy {
    param(
        [int]$ProcessId
    )

    $owners = @(
        Get-QwenListenerProcessIds
    )

    if ($owners.Count -ne 1) {
        return $false
    }

    return ([int]$owners[0] -eq $ProcessId)
}

$processIds = @(
    Get-QwenListenerProcessIds
)

if ($processIds.Count -eq 0) {
    Write-Host "QWEN_SERVER_STATUS=ALREADY_STOPPED"
    exit 0
}

if ($processIds.Count -ne 1) {
    throw (
        "Expected exactly one process listening on " +
        "${HostAddress}:${Port}, found $($processIds.Count). " +
        "Refusing to stop anything."
    )
}

$serverPid = [int]$processIds[0]

try {
    $processInfo = Get-CimInstance `
        -ClassName Win32_Process `
        -Filter "ProcessId = $serverPid" `
        -ErrorAction Stop
}
catch {
    if (-not (Test-QwenListenerOwnedBy -ProcessId $serverPid)) {
        Write-Host "QWEN_SERVER_STATUS=ALREADY_STOPPED"
        Write-Host "PID=$serverPid"
        exit 0
    }

    throw
}

if ($null -eq $processInfo) {
    if (-not (Test-QwenListenerOwnedBy -ProcessId $serverPid)) {
        Write-Host "QWEN_SERVER_STATUS=ALREADY_STOPPED"
        Write-Host "PID=$serverPid"
        exit 0
    }

    throw (
        "Could not query process identity for PID $serverPid. " +
        "Refusing to stop it."
    )
}

$expectedName = [System.IO.Path]::GetFileName(
    $ExpectedExe
)

$actualName = [string]$processInfo.Name

$nameMatches = $actualName.Equals(
    $expectedName,
    [System.StringComparison]::OrdinalIgnoreCase
)

if (-not $nameMatches) {
    throw (
        "Port $Port is owned by an unexpected process. " +
        "PID=$serverPid Name=$actualName. " +
        "Refusing to stop it."
    )
}

$expectedFullPath = [System.IO.Path]::GetFullPath(
    $ExpectedExe
)

$actualExe = [string]$processInfo.ExecutablePath
$commandLine = [string]$processInfo.CommandLine

$identitySource = ""

if (-not [string]::IsNullOrWhiteSpace($actualExe)) {
    $actualFullPath = [System.IO.Path]::GetFullPath(
        $actualExe
    )

    $pathMatches = $actualFullPath.Equals(
        $expectedFullPath,
        [System.StringComparison]::OrdinalIgnoreCase
    )

    if (-not $pathMatches) {
        throw (
            "Port $Port is owned by an unexpected process. " +
            "PID=$serverPid Path=$actualFullPath. " +
            "Refusing to stop it."
        )
    }

    $identitySource = "ExecutablePath"
}

if ([string]::IsNullOrWhiteSpace($identitySource)) {
    $expectedModelName = [System.IO.Path]::GetFileName(
        $ExpectedModelPath
    )

    $hostToken = "--host $HostAddress"
    $portToken = "--port $Port"

    $hasCommandLine = -not [string]::IsNullOrWhiteSpace(
        $commandLine
    )

    $hasHost = $false
    $hasPort = $false
    $hasModel = $false

    if ($hasCommandLine) {
        $hasHost = (
            $commandLine.IndexOf(
                $hostToken,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )

        $hasPort = (
            $commandLine.IndexOf(
                $portToken,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )

        $hasModel = (
            $commandLine.IndexOf(
                $expectedModelName,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )
    }

    $commandMatches = (
        $hasCommandLine -and
        $hasHost -and
        $hasPort -and
        $hasModel
    )

    if (-not $commandMatches) {
        throw (
            "Could not verify listener identity safely. " +
            "PID=$serverPid Name=$actualName. " +
            "ExecutablePath is unavailable and CommandLine " +
            "does not match the configured Qwen server."
        )
    }

    $identitySource = "Name+CommandLine"
}

if (-not (Test-QwenListenerOwnedBy -ProcessId $serverPid)) {
    Write-Host "QWEN_SERVER_STATUS=ALREADY_STOPPED"
    Write-Host "PID=$serverPid"
    exit 0
}

Write-Host "QWEN_SERVER_IDENTITY=$identitySource"

try {
    Stop-Process `
        -Id $serverPid `
        -Force `
        -ErrorAction Stop
}
catch {
    $remainingOwners = @(
        Get-QwenListenerProcessIds
    )

    if ($remainingOwners.Count -eq 0) {
        Write-Host "QWEN_SERVER_STATUS=STOPPED"
        Write-Host "PID=$serverPid"
        exit 0
    }

    throw
}

$deadline = (Get-Date).AddSeconds(
    $ShutdownTimeoutSeconds
)

while ((Get-Date) -lt $deadline) {
    $remainingOwners = @(
        Get-QwenListenerProcessIds
    )

    if ($remainingOwners.Count -eq 0) {
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
