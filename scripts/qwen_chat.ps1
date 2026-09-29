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

$Watcher = Join-Path `
    $PSScriptRoot `
    "watch_qwen_chat.ps1"

$ContextProxy = Join-Path `
    $PSScriptRoot `
    "qwen_chat_context_proxy.py"

foreach ($required in @(
    $ServerManager,
    $Watcher,
    $ContextProxy
)) {
    if (-not (Test-Path $required -PathType Leaf)) {
        throw "Required Qwen chat file not found: $required"
    }
}

$ChatRoot = Join-Path `
    $QwenUserRoot `
    "chat_ui"

$BrowserProfile = Join-Path `
    $ChatRoot `
    "browser-profile"

$ExportsRoot = Join-Path `
    $ChatRoot `
    "exports"

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

$ChatUrl = (
    "http://${ServerHost}:${ServerPort}/" +
    "?model=$ChatModelAlias"
)

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

function Test-QwenChatLeaseActive {
    if (-not (
        Test-Path `
            -LiteralPath $ChatLeasePath `
            -PathType Leaf
    )) {
        return $false
    }

    $stream = $null

    try {
        $stream = [System.IO.FileStream]::new(
            $ChatLeasePath,
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
            [string]$response.model -eq [string]$ChatModelAlias -and
            [int]$response.context_window -eq [int]$ContextWindowSize -and
            [int]$response.soft_threshold -eq 24888
        ) {
            return $response
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-QwenChatPython {
    $pythonCommand = Get-Command `
        python.exe `
        -ErrorAction SilentlyContinue

    if ($null -eq $pythonCommand) {
        $pythonCommand = Get-Command `
            python `
            -ErrorAction SilentlyContinue
    }

    if ($null -eq $pythonCommand) {
        throw "Python executable was not found for the Qwen chat context proxy."
    }

    $pythonExe = [string]$pythonCommand.Source
    $pythonDir = Split-Path $pythonExe -Parent
    $pythonw = Join-Path $pythonDir "pythonw.exe"

    if (Test-Path -LiteralPath $pythonw -PathType Leaf) {
        return $pythonw
    }

    return $pythonExe
}

function Quote-ProcessArgument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return (
        '"' +
        $Value.Replace('"', '\"') +
        '"'
    )
}

function Start-QwenChatContextProxy {
    $existing = Get-QwenChatProxyHealth
    if ($null -ne $existing) {
        return $existing
    }

    $portInUse = $false

    try {
        $connection = Get-NetTCPConnection `
            -LocalAddress $ServerHost `
            -LocalPort ([int]$ChatProxyPort) `
            -State Listen `
            -ErrorAction SilentlyContinue

        $portInUse = $null -ne $connection
    }
    catch {
        $portInUse = $false
    }

    if ($portInUse) {
        throw (
            "Chat proxy port $ChatProxyPort is already in use by an " +
            "unexpected process."
        )
    }

    New-Item `
        -Path $ProxyStateRoot `
        -ItemType Directory `
        -Force |
    Out-Null

    $pythonExe = Get-QwenChatPython

    $proxyArgs = @(
        (Quote-ProcessArgument $ContextProxy),
        "--listen-host",
        (Quote-ProcessArgument ([string]$ServerHost)),
        "--listen-port",
        ([string][int]$ChatProxyPort),
        "--backend-host",
        (Quote-ProcessArgument ([string]$ServerHost)),
        "--backend-port",
        ([string][int]$ServerPort),
        "--model",
        (Quote-ProcessArgument ([string]$ChatModelAlias)),
        "--context-window",
        ([string][int]$ContextWindowSize),
        "--soft-threshold",
        "24888",
        "--state-root",
        (Quote-ProcessArgument $ProxyStateRoot)
    )

    $process = Start-Process `
        -FilePath $pythonExe `
        -ArgumentList $proxyArgs `
        -WindowStyle Hidden `
        -PassThru

    $deadline = (Get-Date).AddSeconds(20)

    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) {
            throw (
                "Qwen chat context proxy exited during startup. " +
                "ExitCode=$($process.ExitCode)"
            )
        }

        $health = Get-QwenChatProxyHealth
        if ($null -ne $health) {
            return $health
        }

        Start-Sleep -Milliseconds 200
    }

    throw "Qwen chat context proxy did not become ready."
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

$BrowserCandidates = @()

if (-not [string]::IsNullOrWhiteSpace(
    [string]$env:ProgramFiles
)) {
    $BrowserCandidates += (
        Join-Path `
            $env:ProgramFiles `
            "Google\Chrome\Application\chrome.exe"
    )
}

if (-not [string]::IsNullOrWhiteSpace(
    [string]${env:ProgramFiles(x86)}
)) {
    $BrowserCandidates += (
        Join-Path `
            ${env:ProgramFiles(x86)} `
            "Google\Chrome\Application\chrome.exe"
    )
}

if (-not [string]::IsNullOrWhiteSpace(
    [string]${env:ProgramFiles(x86)}
)) {
    $BrowserCandidates += (
        Join-Path `
            ${env:ProgramFiles(x86)} `
            "Microsoft\Edge\Application\msedge.exe"
    )
}

if (-not [string]::IsNullOrWhiteSpace(
    [string]$env:ProgramFiles
)) {
    $BrowserCandidates += (
        Join-Path `
            $env:ProgramFiles `
            "Microsoft\Edge\Application\msedge.exe"
    )
}

$BrowserExe = $null

foreach ($candidate in $BrowserCandidates) {
    if (
        Test-Path `
            -LiteralPath $candidate `
            -PathType Leaf
    ) {
        $BrowserExe = $candidate
        break
    }
}

if ($null -eq $BrowserExe) {
    throw (
        "Chrome was not found and Edge fallback " +
        "is also unavailable."
    )
}

New-Item `
    -Path $BrowserProfile `
    -ItemType Directory `
    -Force |
Out-Null

New-Item `
    -Path $ExportsRoot `
    -ItemType Directory `
    -Force |
Out-Null

New-Item `
    -Path $ClientStateRoot `
    -ItemType Directory `
    -Force |
Out-Null

New-Item `
    -Path $ProxyStateRoot `
    -ItemType Directory `
    -Force |
Out-Null

& powershell.exe `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $ServerManager `
    -Action Ensure

if ($LASTEXITCODE -ne 0) {
    throw (
        "Qwen server preflight failed. ExitCode=" +
        $LASTEXITCODE
    )
}

$proxyStartedByThisInvocation = $false

try {
    $proxyWasActive = $null -ne (Get-QwenChatProxyHealth)

    if (-not $proxyWasActive) {
        $null = Start-QwenChatContextProxy
        $proxyStartedByThisInvocation = $true
    }

    $windowWasActive = Test-QwenChatWindowActive

    if (-not $windowWasActive) {
        $BrowserArgs = @(
            "--user-data-dir=`"$BrowserProfile`""
            "--app=$ChatUrl"
            "--proxy-server=http://${ServerHost}:${ChatProxyPort}"
            "--proxy-bypass-list=<-loopback>"
            "--no-first-run"
            "--disable-default-apps"
            "--disable-background-mode"
        )

        Start-Process `
            -FilePath $BrowserExe `
            -ArgumentList $BrowserArgs |
        Out-Null

        $browserDeadline = (
            Get-Date
        ).AddSeconds(20)

        while ((Get-Date) -lt $browserDeadline) {
            if (Test-QwenChatWindowActive) {
                break
            }

            Start-Sleep `
                -Milliseconds 250
        }

        if (-not (Test-QwenChatWindowActive)) {
            throw (
                "Dedicated Qwen chat app process " +
                "was not detected after startup."
            )
        }
    }

    if (-not (Test-QwenChatLeaseActive)) {
        Start-Process `
            -FilePath "powershell.exe" `
            -WindowStyle Hidden `
            -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                "`"$Watcher`""
            ) |
        Out-Null
    }

    $leaseDeadline = (
        Get-Date
    ).AddSeconds(10)

    while ((Get-Date) -lt $leaseDeadline) {
        if (Test-QwenChatLeaseActive) {
            break
        }

        Start-Sleep `
            -Milliseconds 200
    }

    if (-not (Test-QwenChatLeaseActive)) {
        throw (
            "Qwen chat watcher did not acquire " +
            "the chat client lease."
        )
    }
}
catch {
    if ($proxyStartedByThisInvocation) {
        try {
            Stop-QwenChatContextProxy
        }
        catch {
            Write-Warning (
                "Qwen chat context proxy cleanup failed: " +
                $_.Exception.Message
            )
        }
    }

    & powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $ServerManager `
        -Action Stop `
        -IfIdle |
    Out-Null

    throw
}

if ($windowWasActive) {
    Write-Host "QWEN_CHAT_STATUS=ALREADY_ACTIVE"
}
else {
    Write-Host "QWEN_CHAT_STATUS=STARTED"
}

Write-Host "BROWSER=$BrowserExe"
Write-Host "CHAT_DATA=$ChatRoot"
Write-Host "CHAT_MODEL=$ChatModelAlias"
Write-Host "CHAT_CONTEXT_PROXY=ACTIVE"
Write-Host "CHAT_CONTEXT_PROXY_URL=http://${ServerHost}:${ChatProxyPort}"
Write-Host "CHAT_CONTEXT_SOFT_THRESHOLD=24888"
Write-Host "CHAT_CONTEXT_WINDOW=$ContextWindowSize"
Write-Host "CHAT_LEASE=ACTIVE"
Write-Host "CHAT_URL=$ChatUrl"
