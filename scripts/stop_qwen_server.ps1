param(
    [switch]$IfIdle
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ConfigPath = Join-Path $RepoRoot "config\local.ps1"

if (-not (Test-Path $ConfigPath -PathType Leaf)) {
    throw "Missing config file: $ConfigPath"
}

. $ConfigPath

if ([string]::IsNullOrWhiteSpace([string]$ChatModelAlias)) {
    $ChatModelAlias = "qwen3.8-27b-chat"
}

$ExpectedExe = $LlamaServerExe
$ExpectedModelPath = $ModelPath
$ExpectedRouterPreset = Join-Path $QwenRoot "config\qwen_models.ini"

$HostAddress = [string]$ServerHost
$Port = [int]$ServerPort
$ShutdownTimeoutSeconds = 5

$RouterBaseUrl = "http://${HostAddress}:${Port}"
$RouterUnloadUrl = "$RouterBaseUrl/models/unload"

$ClientStateRoot = Join-Path `
    $QwenUserRoot `
    "runtime_clients"

$CliLeaseRoot = Join-Path `
    $ClientStateRoot `
    "cli"

$ChatLeasePath = Join-Path `
    $ClientStateRoot `
    "chat.lock"

if (-not (Test-Path $ExpectedExe -PathType Leaf)) {
    throw "Expected llama-server.exe not found: $ExpectedExe"
}

if (-not (Test-Path $ExpectedModelPath -PathType Leaf)) {
    throw "Expected Qwen model not found: $ExpectedModelPath"
}

function Test-QwenExclusiveLeaseActive {
    param(
        [string]$Path
    )

    if (-not (
        Test-Path `
            -LiteralPath $Path `
            -PathType Leaf
    )) {
        return $false
    }

    $stream = $null

    try {
        $stream = [System.IO.FileStream]::new(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None,
            4096,
            [System.IO.FileOptions]::DeleteOnClose
        )

        $stream.Dispose()
        $stream = $null

        return $false
    }
    catch [System.IO.FileNotFoundException] {
        if ($null -ne $stream) {
            $stream.Dispose()
        }

        return $false
    }
    catch [System.IO.DirectoryNotFoundException] {
        if ($null -ne $stream) {
            $stream.Dispose()
        }

        return $false
    }
    catch [System.IO.IOException] {
        if ($null -ne $stream) {
            $stream.Dispose()
        }

        return $true
    }
}

function Test-QwenCliActive {
    if (-not (
        Test-Path `
            -LiteralPath $CliLeaseRoot `
            -PathType Container
    )) {
        return $false
    }

    $leaseFiles = @(
        Get-ChildItem `
            -LiteralPath $CliLeaseRoot `
            -Filter "*.lock" `
            -File `
            -ErrorAction Stop
    )

    foreach ($leaseFile in $leaseFiles) {
        if (
            Test-QwenExclusiveLeaseActive `
                -Path $leaseFile.FullName
        ) {
            return $true
        }
    }

    return $false
}

function Test-QwenChatLeaseActive {
    return (
        Test-QwenExclusiveLeaseActive `
            -Path $ChatLeasePath
    )
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

function Test-QwenRouterMode {
    param(
        [string]$CommandLine
    )

    $expectedPresetName = [System.IO.Path]::GetFileName(
        $ExpectedRouterPreset
    )

    if (-not [string]::IsNullOrWhiteSpace($CommandLine)) {
        $hasPresetSwitch = (
            $CommandLine.IndexOf(
                "--models-preset",
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )

        $hasPresetName = (
            $CommandLine.IndexOf(
                $expectedPresetName,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )

        if (
            $hasPresetSwitch -and
            $hasPresetName
        ) {
            return $true
        }
    }

    try {
        $response = Invoke-RestMethod `
            -Uri "$RouterBaseUrl/v1/models" `
            -Method Get `
            -TimeoutSec 2

        foreach ($model in @($response.data)) {
            if (
                [string]$model.id -eq $ChatModelAlias -and
                [string]$model.source -eq "preset"
            ) {
                return $true
            }
        }
    }
    catch {
        return $false
    }

    return $false
}

function Get-QwenRouterModelChildIds {
    param(
        [int]$RouterProcessId
    )

    $expectedName = [System.IO.Path]::GetFileName(
        $ExpectedExe
    )

    $children = @(
        Get-CimInstance `
            -ClassName Win32_Process `
            -Filter "ParentProcessId = $RouterProcessId" `
            -ErrorAction Stop |
        Where-Object {
            $_.Name -ieq $expectedName
        }
    )

    return @(
        $children |
            Select-Object -ExpandProperty ProcessId
    )
}

function Invoke-QwenRouterModelUnload {
    param(
        [int]$RouterProcessId
    )

    $initialChildren = @(
        Get-QwenRouterModelChildIds `
            -RouterProcessId $RouterProcessId
    )

    if ($initialChildren.Count -eq 0) {
        Write-Host "QWEN_ROUTER_MODEL_STATUS=ALREADY_UNLOADED"
        return
    }

    if ($initialChildren.Count -ne 1) {
        throw (
            "Expected at most one llama.cpp router model child, found " +
            "$($initialChildren.Count). Refusing router shutdown."
        )
    }

    $payload = @{
        model = $ChatModelAlias
    } | ConvertTo-Json -Compress

    try {
        $response = Invoke-RestMethod `
            -Uri $RouterUnloadUrl `
            -Method Post `
            -ContentType "application/json" `
            -Body $payload `
            -TimeoutSec 10
    }
    catch {
        $remainingChildren = @(
            Get-QwenRouterModelChildIds `
                -RouterProcessId $RouterProcessId
        )

        if ($remainingChildren.Count -eq 0) {
            Write-Host "QWEN_ROUTER_MODEL_STATUS=UNLOADED"
            return
        }

        throw (
            "Could not unload router model '" +
            $ChatModelAlias +
            "'. Refusing to force-stop the router while " +
            "the model child may still be active. " +
            $_.Exception.Message
        )
    }

    if (
        $null -eq $response -or
        $response.success -ne $true
    ) {
        throw (
            "Router rejected model unload for '" +
            $ChatModelAlias +
            "'. Refusing to stop the router."
        )
    }

    $deadline = (
        Get-Date
    ).AddSeconds(15)

    while ((Get-Date) -lt $deadline) {
        $children = @(
            Get-QwenRouterModelChildIds `
                -RouterProcessId $RouterProcessId
        )

        if ($children.Count -eq 0) {
            Write-Host "QWEN_ROUTER_MODEL_STATUS=UNLOADED"
            return
        }

        Start-Sleep `
            -Milliseconds 250
    }

    throw (
        "Router model unload succeeded, but a model child " +
        "remained active after 15 seconds. Refusing to stop the router."
    )
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

    $expectedPresetName = [System.IO.Path]::GetFileName(
        $ExpectedRouterPreset
    )

    $hostToken = "--host $HostAddress"
    $portToken = "--port $Port"

    $hasCommandLine = -not [string]::IsNullOrWhiteSpace(
        $commandLine
    )

    $hasHost = $false
    $hasPort = $false
    $hasLegacyModel = $false
    $hasRouterPresetSwitch = $false
    $hasRouterPresetName = $false

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

        $hasLegacyModel = (
            $commandLine.IndexOf(
                $expectedModelName,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )

        $hasRouterPresetSwitch = (
            $commandLine.IndexOf(
                "--models-preset",
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )

        $hasRouterPresetName = (
            $commandLine.IndexOf(
                $expectedPresetName,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )
    }

    $hasRouterPreset = (
        $hasRouterPresetSwitch -and
        $hasRouterPresetName
    )

    $commandMatches = (
        $hasCommandLine -and
        $hasHost -and
        $hasPort -and
        (
            $hasLegacyModel -or
            $hasRouterPreset
        )
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

if ($IfIdle) {
    if (Test-QwenCliActive) {
        Write-Host "QWEN_SERVER_STATUS=KEPT_FOR_CLI"
        exit 0
    }

    if (Test-QwenChatLeaseActive) {
        Write-Host "QWEN_SERVER_STATUS=KEPT_FOR_CHAT"
        exit 0
    }
}

$isRouter = Test-QwenRouterMode `
    -CommandLine $commandLine

if ($isRouter) {
    Invoke-QwenRouterModelUnload `
        -RouterProcessId $serverPid
}

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
