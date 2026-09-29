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

if ($null -eq $ChatProxyPort -or [int]$ChatProxyPort -le 0) {
    $ChatProxyPort = 8081
}

$ServerManager = Join-Path `
    $QwenRoot `
    "config\qwen_server.ps1"

$ContextProxy = Join-Path `
    $QwenRoot `
    "config\qwen_chat_context_proxy.py"

foreach ($required in @(
    $ServerManager,
    $ContextProxy
)) {
    if (-not (Test-Path $required -PathType Leaf)) {
        throw "Required Qwen chat watcher file not found: $required"
    }
}

$ChatRoot = Join-Path `
    $QwenUserRoot `
    "chat_ui"

$BrowserProfile = Join-Path `
    $ChatRoot `
    "browser-profile"

$ProxyStateRoot = Join-Path `
    $ChatRoot `
    "context-proxy"

$ProxyInstancePath = Join-Path `
    $ProxyStateRoot `
    "instance.json"

$ClientStateRoot = Join-Path `
    $QwenUserRoot `
    "runtime_clients"

$ChatLeasePath = Join-Path `
    $ClientStateRoot `
    "chat.lock"

$ChatAppPrefix = (
    "--app=http://${ServerHost}:${ServerPort}/"
)

$ProxyHealthUrl = (
    "http://${ServerHost}:${ChatProxyPort}" +
    "/__localai_chat_proxy/health"
)

$ProxyShutdownUrl = (
    "http://${ServerHost}:${ChatProxyPort}" +
    "/__localai_chat_proxy/shutdown"
)

function Test-QwenChatWindowActive {
    $profilePath = (
        [System.IO.Path]::GetFullPath(
            $BrowserProfile
        )
    )

    $processes = @(
        Get-CimInstance `
            -ClassName Win32_Process `
            -ErrorAction Stop |
        Where-Object {
            $_.Name -in @(
                "chrome.exe",
                "msedge.exe"
            )
        }
    )

    foreach ($process in $processes) {
        $commandLine = [string]$process.CommandLine

        if ([string]::IsNullOrWhiteSpace(
            $commandLine
        )) {
            continue
        }

        $hasProfile = (
            $commandLine.IndexOf(
                $profilePath,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )

        $hasApp = (
            $commandLine.IndexOf(
                $ChatAppPrefix,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )

        if (
            $hasProfile -and
            $hasApp
        ) {
            return $true
        }
    }

    return $false
}

function Get-QwenChatProxyHealth {
    try {
        $response = Invoke-RestMethod `
            -Uri $ProxyHealthUrl `
            -Method Get `
            -TimeoutSec 2 `
            -ErrorAction Stop

        if (
            [string]$response.status -eq "ok" -and
            [int]$response.listen_port -eq [int]$ChatProxyPort -and
            [int]$response.backend_port -eq [int]$ServerPort -and
            [string]$response.model -eq [string]$ChatModelAlias
        ) {
            return $response
        }
    }
    catch {
        return $null
    }

    return $null
}

function Stop-QwenChatContextProxy {
    $health = Get-QwenChatProxyHealth

    if ($null -eq $health) {
        return
    }

    if (-not (
        Test-Path `
            -LiteralPath $ProxyInstancePath `
            -PathType Leaf
    )) {
        throw (
            "Qwen chat context proxy is active, but its instance file " +
            "is missing: $ProxyInstancePath"
        )
    }

    $instance = Get-Content `
        -LiteralPath $ProxyInstancePath `
        -Raw `
        -Encoding UTF8 |
    ConvertFrom-Json

    $token = [string]$instance.shutdown_token

    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Qwen chat context proxy shutdown token is missing."
    }

    Invoke-RestMethod `
        -Uri $ProxyShutdownUrl `
        -Method Post `
        -Headers @{
            "X-LocalAI-Proxy-Token" = $token
        } `
        -TimeoutSec 5 `
        -ErrorAction Stop |
    Out-Null

    $deadline = (Get-Date).AddSeconds(10)

    while ((Get-Date) -lt $deadline) {
        if ($null -eq (Get-QwenChatProxyHealth)) {
            return
        }

        Start-Sleep -Milliseconds 200
    }

    throw "Qwen chat context proxy did not stop cleanly."
}

New-Item `
    -Path $ClientStateRoot `
    -ItemType Directory `
    -Force |
Out-Null

$LeaseStream = $null

try {
    $LeaseStream = [System.IO.FileStream]::new(
        $ChatLeasePath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None,
        4096,
        [System.IO.FileOptions]::DeleteOnClose
    )
}
catch [System.IO.IOException] {
    # Another watcher already owns the chat lease.
    exit 0
}

$watcherError = $null

try {
    $startupDeadline = (
        Get-Date
    ).AddSeconds(20)

    $seenWindow = $false

    while ((Get-Date) -lt $startupDeadline) {
        try {
            $windowActive = Test-QwenChatWindowActive
        }
        catch {
            Start-Sleep -Milliseconds 500
            continue
        }

        if ($windowActive) {
            $seenWindow = $true
            break
        }

        Start-Sleep -Milliseconds 250
    }

    if ($seenWindow) {
        $consecutiveMisses = 0
        $requiredMisses = 10

        while ($consecutiveMisses -lt $requiredMisses) {
            try {
                $windowActive = Test-QwenChatWindowActive
            }
            catch {
                Start-Sleep -Milliseconds 500
                continue
            }

            if ($windowActive) {
                $consecutiveMisses = 0
            }
            else {
                $consecutiveMisses++
            }

            Start-Sleep -Milliseconds 500
        }
    }
}
catch {
    $watcherError = $_
}
finally {
    try {
        Stop-QwenChatContextProxy
    }
    catch {
        if ($null -eq $watcherError) {
            $watcherError = $_
        }
    }

    if ($null -ne $LeaseStream) {
        $LeaseStream.Dispose()
        $LeaseStream = $null
    }
}

& powershell.exe `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $ServerManager `
    -Action Stop `
    -IfIdle |
Out-Null

$serverStopExitCode = $LASTEXITCODE

if ($null -ne $watcherError) {
    Write-Error `
        -Message $watcherError.Exception.Message `
        -ErrorAction Continue
    exit 1
}

exit $serverStopExitCode
