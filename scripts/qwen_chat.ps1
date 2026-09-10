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

$EnsureServer = Join-Path `
    $PSScriptRoot `
    "ensure_qwen_server.ps1"

$StopServer = Join-Path `
    $PSScriptRoot `
    "stop_qwen_server.ps1"

$Watcher = Join-Path `
    $PSScriptRoot `
    "watch_qwen_chat.ps1"

foreach ($required in @(
    $EnsureServer,
    $StopServer,
    $Watcher
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

& powershell.exe `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $EnsureServer

if ($LASTEXITCODE -ne 0) {
    throw (
        "Qwen server preflight failed. ExitCode=" +
        $LASTEXITCODE
    )
}

try {
    $windowWasActive = Test-QwenChatWindowActive

    if (-not $windowWasActive) {
        $BrowserArgs = @(
            "--user-data-dir=`"$BrowserProfile`""
            "--app=$ChatUrl"
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
    & powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $StopServer `
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
Write-Host "CHAT_LEASE=ACTIVE"
Write-Host "CHAT_URL=$ChatUrl"
