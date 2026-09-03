$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ConfigPath = Join-Path $RepoRoot "config\local.ps1"

if (-not (Test-Path $ConfigPath -PathType Leaf)) {
    throw "Missing config file: $ConfigPath"
}

. $ConfigPath

# Backward-compatible defaults for local.ps1 files created before
# role-specific model aliases were introduced.
if ([string]::IsNullOrWhiteSpace([string]$AlgorithmModelAlias)) {
    $AlgorithmModelAlias = "qwen3.8-27b-algorithm"
}

if ([string]::IsNullOrWhiteSpace([string]$TestModelAlias)) {
    $TestModelAlias = "qwen3.8-27b-test"
}

$ExpectedModels = @(
    $ModelAlias
    $AlgorithmModelAlias
    $TestModelAlias
)

if (@($ExpectedModels | Select-Object -Unique).Count -ne 3) {
    throw "PROMPT, ALGORITHM, and TEST model aliases must be unique."
}

$ExpectedModelSummary = $ExpectedModels -join ", "

$StartScript = Join-Path $PSScriptRoot "start_qwen_server.ps1"
$LogRoot = Join-Path $QwenRoot "logs"

$HostAddress = $ServerHost
$Port = [int]$ServerPort
$ApiUrl = "http://${HostAddress}:${Port}/v1/models"

$StartupTimeoutSeconds = 120
$PollIntervalMilliseconds = 1000

if (-not (Test-Path $StartScript -PathType Leaf)) {
    throw "Qwen server start script not found: $StartScript"
}

function Test-PortListening {
    param(
        [string]$ComputerName,
        [int]$Port
    )

    $client = New-Object System.Net.Sockets.TcpClient

    try {
        $async = $client.BeginConnect(
            $ComputerName,
            $Port,
            $null,
            $null
        )

        $connected = $async.AsyncWaitHandle.WaitOne(500)

        if (-not $connected) {
            return $false
        }

        $client.EndConnect($async)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Get-QwenApiState {
    try {
        $response = Invoke-RestMethod `
            -Uri $ApiUrl `
            -Method Get `
            -TimeoutSec 2

        if ($null -eq $response) {
            return "wrong_api"
        }

        $models = @($response.data)
        $advertisedModels = @()

        foreach ($model in $models) {
            if ($null -ne $model.id) {
                $advertisedModels += [string]$model.id
            }

            foreach ($alias in @($model.aliases)) {
                if ($null -ne $alias) {
                    $advertisedModels += [string]$alias
                }
            }
        }

        $advertisedModels = @(
            $advertisedModels |
                Select-Object -Unique
        )

        foreach ($expectedModel in $ExpectedModels) {
            if ($advertisedModels -notcontains $expectedModel) {
                return "wrong_model"
            }
        }

        return "ready"
    }
    catch {
        return "unreachable"
    }
}

$initialApiState = Get-QwenApiState

if ($initialApiState -eq "ready") {
    Write-Host "QWEN_SERVER_STATUS=OK"
    exit 0
}

$portListening = Test-PortListening `
    -ComputerName $HostAddress `
    -Port $Port

if ($portListening) {
    throw (
        "Port $Port is already in use, but the required models " +
        "'$ExpectedModelSummary' are not available at $ApiUrl. " +
        "Refusing to start a second server."
    )
}

New-Item `
    -Path $LogRoot `
    -ItemType Directory `
    -Force |
    Out-Null

$stdoutLog = Join-Path $LogRoot "qwen-server.stdout.log"
$stderrLog = Join-Path $LogRoot "qwen-server.stderr.log"

Write-Host "Qwen server is not running. Starting it..."

$process = Start-Process `
    -FilePath "powershell.exe" `
    -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "`"$StartScript`""
    ) `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog `
    -PassThru

$deadline = (Get-Date).AddSeconds(
    $StartupTimeoutSeconds
)

while ((Get-Date) -lt $deadline) {
    if ($process.HasExited) {
        throw (
            "Qwen server process exited before becoming ready. " +
            "ExitCode=$($process.ExitCode). " +
            "Check: $stdoutLog and $stderrLog"
        )
    }

    $state = Get-QwenApiState

    if ($state -eq "ready") {
        Write-Host "QWEN_SERVER_STATUS=STARTED"
        Write-Host "PID=$($process.Id)"
        exit 0
    }

    if ($state -eq "wrong_model") {
        throw (
            "A server responded at $ApiUrl, but required models " +
            "'$ExpectedModelSummary' were not all advertised. " +
            "Refusing to continue."
        )
    }

    Start-Sleep -Milliseconds $PollIntervalMilliseconds
}

throw (
    "Timed out after $StartupTimeoutSeconds seconds waiting for " +
    "required models '$ExpectedModelSummary' at $ApiUrl. " +
    "Check: $stdoutLog and $stderrLog"
)