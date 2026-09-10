$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ConfigPath = Join-Path $RepoRoot "config\local.ps1"

if (-not (Test-Path $ConfigPath -PathType Leaf)) {
    throw "Missing config file: $ConfigPath"
}

. $ConfigPath

$StopServer = Join-Path `
    $PSScriptRoot `
    "stop_qwen_server.ps1"

if (-not (Test-Path $StopServer -PathType Leaf)) {
    throw "Qwen server stop script not found: $StopServer"
}

$BrowserProfile = Join-Path `
    $QwenUserRoot `
    "chat_ui\browser-profile"

$ClientStateRoot = Join-Path `
    $QwenUserRoot `
    "runtime_clients"

$ChatLeasePath = Join-Path `
    $ClientStateRoot `
    "chat.lock"

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
finally {
    if ($null -ne $LeaseStream) {
        $LeaseStream.Dispose()
        $LeaseStream = $null
    }

}

& powershell.exe `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $StopServer `
    -IfIdle |
Out-Null

exit $LASTEXITCODE
