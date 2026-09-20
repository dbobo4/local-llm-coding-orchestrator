param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("Start", "Ensure", "Status", "Stop")]
    [string]$Action = "Ensure",
    [switch]$IfIdle
)

$ErrorActionPreference = "Stop"

function Invoke-QwenServerStart {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    $ConfigPath = Join-Path $RepoRoot "config\local.ps1"

    if (-not (Test-Path $ConfigPath -PathType Leaf)) {
        throw "Missing config file: $ConfigPath"
    }

    . $ConfigPath

    if ([string]::IsNullOrWhiteSpace([string]$AlgorithmModelAlias)) {
        $AlgorithmModelAlias = "qwen3.8-27b-algorithm"
    }

    if ([string]::IsNullOrWhiteSpace([string]$TestModelAlias)) {
        $TestModelAlias = "qwen3.8-27b-test"
    }

    if ([string]::IsNullOrWhiteSpace([string]$ChatModelAlias)) {
        $ChatModelAlias = "qwen3.8-27b-chat"
    }

    # Backward-compatible inference defaults for local.ps1 files created
    # before the unified benchmark/local override layer was added.
    $BenchmarkDefaults = [ordered]@{
        ContextWindowSize = 40960
        SpecDraftPMin = "0.025"
        SpecNgramModNMin = 48
        SpecNgramModNMax = 64
        SpecNgramModNMatch = 16
        CacheTypeK = "q8_0"
        CacheTypeV = "q8_0"
    }

    foreach ($Entry in $BenchmarkDefaults.GetEnumerator()) {
        if ($null -eq (Get-Variable -Name $Entry.Key -ErrorAction SilentlyContinue)) {
            Set-Variable -Name $Entry.Key -Value $Entry.Value
        }
    }

    if ([int]$ContextWindowSize -le 0) {
        throw "ContextWindowSize must be a positive integer."
    }

    if ([double]::Parse(
        [string]$SpecDraftPMin,
        [System.Globalization.CultureInfo]::InvariantCulture
    ) -lt 0.0) {
        throw "SpecDraftPMin must be non-negative."
    }

    $RoleModelAliases = @(
        $ModelAlias
        $AlgorithmModelAlias
        $TestModelAlias
    )

    $AllModelNames = @(
        $ChatModelAlias
    ) + @($RoleModelAliases)

    if (@($AllModelNames | Select-Object -Unique).Count -ne 4) {
        throw "PROMPT, ALGORITHM, TEST, and CHAT model names must be unique."
    }

    foreach ($modelName in $AllModelNames) {
        if (
            [string]::IsNullOrWhiteSpace([string]$modelName) -or
            [string]$modelName -match '[,\[\]\r\n]'
        ) {
            throw "Invalid model name for llama.cpp router preset: '$modelName'"
        }
    }

    $ServerExe = $LlamaServerExe
    $ModelsPreset = Join-Path $QwenRoot "config\qwen_models.ini"

    if (-not (Test-Path $ServerExe -PathType Leaf)) {
        throw "llama-server.exe not found: $ServerExe"
    }

    if (-not (Test-Path $ModelPath -PathType Leaf)) {
        throw "Qwen model not found: $ModelPath"
    }

    $PresetRoot = Split-Path $ModelsPreset -Parent

    New-Item `
        -Path $PresetRoot `
        -ItemType Directory `
        -Force |
    Out-Null

    $PresetModelPath = (
        [System.IO.Path]::GetFullPath(
            $ModelPath
        )
    ).Replace(
        "\",
        "/"
    )

    $PresetText = @(
        "version = 1"
        ""
        "[$ChatModelAlias]"
        "model = $PresetModelPath"
        ("alias = " + ($RoleModelAliases -join ","))
        "load-on-startup = true"
        ""
    ) -join [Environment]::NewLine

    $PresetNeedsWrite = $true

    if (Test-Path -LiteralPath $ModelsPreset -PathType Leaf) {
        $CurrentPresetText = [System.IO.File]::ReadAllText($ModelsPreset)
        if ($CurrentPresetText -eq $PresetText) {
            $PresetNeedsWrite = $false
        }
    }

    if ($PresetNeedsWrite) {
        [System.IO.File]::WriteAllText(
            $ModelsPreset,
            $PresetText,
            (New-Object System.Text.UTF8Encoding($false))
        )
        Write-Host "QWEN_MODELS_PRESET=GENERATED"
    }
    else {
        Write-Host "QWEN_MODELS_PRESET=CURRENT"
    }

    Write-Host "========================================"
    Write-Host " Local Qwen Server"
    Write-Host "========================================"
    Write-Host "Model:    Qwen3.8-27B UD-Q3_K_XL + MTP2 + ngram-mod"
    Write-Host "Model ID: $ChatModelAlias"
    Write-Host "Aliases:  $($RoleModelAliases -join ', ')"
    Write-Host ("Context:  " + $ContextWindowSize)
    Write-Host "Reason:   xhigh"
    Write-Host "API:      http://${ServerHost}:${ServerPort}/v1"
    Write-Host "========================================"
    Write-Host ""

    & $ServerExe `
        --models-preset $ModelsPreset `
        --models-max 1 `
        --host $ServerHost `
        --port $ServerPort `
        --ctx-size $ContextWindowSize `
        --parallel 1 `
        --n-gpu-layers 99 `
        --fit off `
        --spec-type draft-mtp,ngram-mod `
        --spec-draft-n-max 2 `
        --spec-draft-p-min $SpecDraftPMin `
        --spec-ngram-mod-n-min $SpecNgramModNMin `
        --spec-ngram-mod-n-max $SpecNgramModNMax `
        --spec-ngram-mod-n-match $SpecNgramModNMatch `
        --threads 20 `
        --threads-batch 20 `
        --spec-draft-threads 20 `
        --spec-draft-threads-batch 20 `
        --flash-attn on `
        --cache-type-k $CacheTypeK `
        --cache-type-v $CacheTypeV `
        --batch-size 1024 `
        --ubatch-size 512 `
        --jinja `
        --reasoning on `
        --reasoning-effort xhigh `
        --reasoning-budget -1 `
        --reasoning-preserve
}

function Invoke-QwenServerEnsure {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    $ConfigPath = Join-Path $RepoRoot "config\local.ps1"

    if (-not (Test-Path $ConfigPath -PathType Leaf)) {
        throw "Missing config file: $ConfigPath"
    }

    . $ConfigPath

    if ([string]::IsNullOrWhiteSpace([string]$AlgorithmModelAlias)) {
        $AlgorithmModelAlias = "qwen3.8-27b-algorithm"
    }

    if ([string]::IsNullOrWhiteSpace([string]$TestModelAlias)) {
        $TestModelAlias = "qwen3.8-27b-test"
    }

    if ([string]::IsNullOrWhiteSpace([string]$ChatModelAlias)) {
        $ChatModelAlias = "qwen3.8-27b-chat"
    }

    $RoleModelAliases = @(
        $ModelAlias
        $AlgorithmModelAlias
        $TestModelAlias
    )

    $ExpectedModels = @(
        $ChatModelAlias
    ) + @($RoleModelAliases)

    if (@($ExpectedModels | Select-Object -Unique).Count -ne 4) {
        throw "PROMPT, ALGORITHM, TEST, and CHAT model names must be unique."
    }

    $ExpectedModelSummary = $ExpectedModels -join ", "

    $StartScript = $PSCommandPath
    $LogRoot = Join-Path $QwenRoot "logs"

    $HostAddress = [string]$ServerHost
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

            $canonicalMatches = @(
                @($response.data) |
                    Where-Object {
                        $null -ne $_.id -and
                        [string]$_.id -eq $ChatModelAlias
                    }
            )

            if ($canonicalMatches.Count -ne 1) {
                return "wrong_model"
            }

            $advertisedAliases = @(
                @($canonicalMatches[0].aliases) |
                    ForEach-Object {
                        [string]$_
                    } |
                    Select-Object -Unique
            )

            foreach ($expectedAlias in $RoleModelAliases) {
                if ($advertisedAliases -notcontains $expectedAlias) {
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
        return
    }

    $portListening = Test-PortListening `
        -ComputerName $HostAddress `
        -Port $Port

    if ($portListening) {
        throw (
            "Port $Port is already in use, but the required canonical model " +
            "'$ChatModelAlias' and role aliases '$($RoleModelAliases -join ", ")' " +
            "are not available at $ApiUrl. Refusing to start a second server."
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
            "`"$StartScript`"",
            "-Action",
            "Start"
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
            return
        }

        if ($state -eq "wrong_model") {
            throw (
                "A server responded at $ApiUrl, but the canonical model " +
                "'$ChatModelAlias' and required role aliases were not all advertised. " +
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
}

function Invoke-QwenServerStop {
    param([switch]$IfIdle)
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
        return
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
            return
        }

        throw
    }

    if ($null -eq $processInfo) {
        if (-not (Test-QwenListenerOwnedBy -ProcessId $serverPid)) {
            Write-Host "QWEN_SERVER_STATUS=ALREADY_STOPPED"
            Write-Host "PID=$serverPid"
            return
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
        return
    }

    Write-Host "QWEN_SERVER_IDENTITY=$identitySource"

    if ($IfIdle) {
        if (Test-QwenCliActive) {
            Write-Host "QWEN_SERVER_STATUS=KEPT_FOR_CLI"
            return
        }

        if (Test-QwenChatLeaseActive) {
            Write-Host "QWEN_SERVER_STATUS=KEPT_FOR_CHAT"
            return
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
            return
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
            return
        }

        Start-Sleep -Milliseconds 200
    }

    throw (
        "llama-server.exe PID $serverPid was stopped, " +
        "but port $Port did not become free within " +
        "$ShutdownTimeoutSeconds seconds."
    )
}

function Invoke-QwenServerStatus {
    $RepoRoot = Split-Path $PSScriptRoot -Parent
    $ConfigPath = Join-Path $RepoRoot "config\local.ps1"
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Missing config file: $ConfigPath" }
    . $ConfigPath
    if ([string]::IsNullOrWhiteSpace([string]$ChatModelAlias)) { $ChatModelAlias = "qwen3.8-27b-chat" }
    if ([string]::IsNullOrWhiteSpace([string]$AlgorithmModelAlias)) { $AlgorithmModelAlias = "qwen3.8-27b-algorithm" }
    if ([string]::IsNullOrWhiteSpace([string]$TestModelAlias)) { $TestModelAlias = "qwen3.8-27b-test" }
    $ExpectedAliases = @($ModelAlias, $AlgorithmModelAlias, $TestModelAlias)
    $ApiUrl = "http://${ServerHost}:${ServerPort}/v1/models"
    try {
        $response = Invoke-RestMethod -Uri $ApiUrl -Method Get -TimeoutSec 2
        $canonical = @(@($response.data) | Where-Object { [string]$_.id -eq $ChatModelAlias })
        if ($canonical.Count -ne 1) { Write-Host "QWEN_SERVER_STATUS=WRONG_MODEL"; return $false }
        $aliases = @($canonical[0].aliases | ForEach-Object { [string]$_ })
        foreach ($alias in $ExpectedAliases) {
            if ($aliases -notcontains $alias) { Write-Host "QWEN_SERVER_STATUS=WRONG_MODEL"; return $false }
        }
        Write-Host "QWEN_SERVER_STATUS=READY"
        return $true
    }
    catch {
        Write-Host "QWEN_SERVER_STATUS=STOPPED_OR_UNREACHABLE"
        return $false
    }
}

switch ($Action) {
    "Start"  { Invoke-QwenServerStart; break }
    "Ensure" { Invoke-QwenServerEnsure; break }
    "Status" { if (Invoke-QwenServerStatus) { exit 0 } else { exit 1 } }
    "Stop"   { Invoke-QwenServerStop -IfIdle:$IfIdle; break }
    default  { throw "Unsupported server action: $Action" }
}
